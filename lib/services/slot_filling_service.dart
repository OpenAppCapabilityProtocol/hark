import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import '../models/assistant_action.dart';

enum SlotFillingStage { idle, downloading, loading, ready, failed }

class SlotFillingState {
  const SlotFillingState({
    required this.stage,
    required this.message,
    this.progress,
  });

  final SlotFillingStage stage;
  final String message;
  final double? progress;

  bool get isReady => stage == SlotFillingStage.ready;
  bool get isBusy =>
      stage == SlotFillingStage.downloading ||
      stage == SlotFillingStage.loading;
}

class SlotFillingService extends ChangeNotifier {
  static const modelUrl =
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm';
  static const modelId = 'Qwen3-0.6B';

  InferenceModel? _model;
  Future<void>? _initFuture;
  bool _disposed = false;
  SlotFillingState _state = const SlotFillingState(
    stage: SlotFillingStage.idle,
    message: 'Preparing slot-filling model...',
  );

  SlotFillingState get state => _state;
  bool get isReady => _model != null;

  @override
  void dispose() {
    _disposed = true;
    _model?.close();
    _model = null;
    _initFuture = null;
    super.dispose();
  }

  Future<void> prewarm() async {
    await (_initFuture ??= _initialize());
  }

  /// Extract parameters from a voice transcript given a matched action.
  ///
  /// Returns null if required parameters could not be extracted.
  /// Throws [StateError] if the model is not available.
  Future<Map<String, dynamic>?> extractParameters({
    required String transcript,
    required AssistantAction action,
  }) async {
    await (_initFuture ??= _initialize());
    final model = _model;
    if (model == null || _disposed) {
      throw StateError('Slot-filling model is not available');
    }

    // Skip if no parameters to extract.
    if (action.parameters.isEmpty) return const {};

    final prompt = _buildPrompt(transcript, action);
    _debugLog('slot_fill_prompt', {
      'transcript': transcript,
      'actionId': action.actionId,
      'prompt': prompt,
    });

    try {
      final session = await model.createSession(
        temperature: 0.1,
        topK: 1,
        randomSeed: 42,
      );

      try {
        await session.addQueryChunk(Message(text: prompt, isUser: true));
        final rawOutput = await session.getResponse();

        _debugLog('slot_fill_raw', {
          'actionId': action.actionId,
          'rawOutput': rawOutput,
        });

        final parsed = _parseOutput(rawOutput, action);

        _debugLog('slot_fill_result', {
          'actionId': action.actionId,
          'parsed': parsed,
        });

        return parsed;
      } finally {
        await session.close();
      }
    } catch (error, stackTrace) {
      debugPrint('SlotFillingService: inference failed: $error');
      debugPrint('SlotFillingService: $stackTrace');
      return null;
    }
  }

  String _buildPrompt(String transcript, AssistantAction action) {
    final paramDefs = StringBuffer();
    for (final p in action.parameters) {
      paramDefs.write('"${p.name}" (${p.type}');
      if (p.required) paramDefs.write(', required');
      paramDefs.writeln(')');

      if (p.extractionHint != null) {
        paramDefs.writeln('  hint: ${p.extractionHint}');
      } else if (p.description != null) {
        paramDefs.writeln('  description: ${p.description}');
      }

      if (p.enumValues.isNotEmpty) {
        paramDefs.writeln(
          '  allowed values: ${p.enumValues.join(", ")}',
        );
      }
      if (p.minimum != null || p.maximum != null) {
        final bounds = <String>[];
        if (p.minimum != null) bounds.add('min: ${p.minimum}');
        if (p.maximum != null) bounds.add('max: ${p.maximum}');
        paramDefs.writeln('  ${bounds.join(", ")}');
      }
      paramDefs.writeln();
    }

    return '/no_think\n'
        'Extract parameters from the voice command below.\n'
        'ONLY extract values explicitly stated in the voice command.\n'
        'If a parameter is NOT mentioned, set it to null. '
        'Do NOT guess or use example values.\n'
        'Return ONLY a JSON object.\n\n'
        'Action: ${action.actionId}\n'
        'Voice command: "$transcript"\n\n'
        'Parameters:\n'
        '$paramDefs'
        'JSON:';
  }

  Map<String, dynamic>? _parseOutput(String raw, AssistantAction action) {
    // Strip markdown fences and whitespace.
    var cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      cleaned = cleaned
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```\s*$'), '');
    }

    // Find the JSON object bounds.
    final openBrace = cleaned.indexOf('{');
    final closeBrace = cleaned.lastIndexOf('}');
    if (openBrace == -1 || closeBrace == -1 || closeBrace <= openBrace) {
      return null;
    }
    cleaned = cleaned.substring(openBrace, closeBrace + 1);

    Map<String, dynamic> json;
    try {
      json = jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    // Validate and coerce types.
    final result = <String, dynamic>{};
    for (final p in action.parameters) {
      final value = json[p.name];

      if (value == null) {
        if (p.required) return null;
        continue;
      }

      final coerced = _coerceValue(value, p);
      if (coerced == null) {
        if (p.required) return null;
        continue;
      }

      result[p.name] = coerced;
    }

    return result;
  }

  dynamic _coerceValue(dynamic value, AssistantActionParameter param) {
    switch (param.type) {
      case 'integer':
        if (value is int) return _clampInt(value, param);
        if (value is double) return _clampInt(value.round(), param);
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) return _clampInt(parsed, param);
        }
        return null;

      case 'boolean':
        if (value is bool) return value;
        if (value is String) {
          final lower = value.toLowerCase();
          if (lower == 'true' || lower == 'yes') return true;
          if (lower == 'false' || lower == 'no') return false;
        }
        return null;

      case 'enum':
        final str = value.toString();
        if (param.enumValues.contains(str)) return str;
        // Try case-insensitive match.
        final lower = str.toLowerCase();
        for (final enumVal in param.enumValues) {
          if (enumVal.toLowerCase() == lower) return enumVal;
        }
        // Try alias match.
        for (final entry in param.aliases.entries) {
          for (final alias in entry.value) {
            if (alias.toLowerCase() == lower) return entry.key;
          }
        }
        return null;

      case 'number':
      case 'double':
        if (value is double) return _clampDouble(value, param);
        if (value is int) return _clampDouble(value.toDouble(), param);
        if (value is String) {
          final parsed = double.tryParse(value);
          if (parsed != null) return _clampDouble(parsed, param);
        }
        return null;

      case 'string':
        final str = value.toString().trim();
        return str.isEmpty ? null : str;

      default:
        return value;
    }
  }

  int _clampInt(int value, AssistantActionParameter param) {
    if (param.minimum != null && value < param.minimum!) {
      return param.minimum!.toInt();
    }
    if (param.maximum != null && value > param.maximum!) {
      return param.maximum!.toInt();
    }
    return value;
  }

  double _clampDouble(double value, AssistantActionParameter param) {
    if (param.minimum != null && value < param.minimum!) {
      return param.minimum!.toDouble();
    }
    if (param.maximum != null && value > param.maximum!) {
      return param.maximum!.toDouble();
    }
    return value;
  }

  Future<void> _initialize() async {
    try {
      debugPrint('SlotFillingService: starting initialization...');
      _setState(const SlotFillingState(
        stage: SlotFillingStage.loading,
        message: 'Initializing slot-filling runtime...',
      ));

      await FlutterGemma.initialize();

      // Check if model is already installed.
      if (FlutterGemma.hasActiveModel()) {
        debugPrint('SlotFillingService: model already installed, loading...');
        _setState(const SlotFillingState(
          stage: SlotFillingStage.loading,
          message: 'Loading Qwen3 from cache...',
        ));
      } else {
        // Download from HuggingFace.
        _setState(const SlotFillingState(
          stage: SlotFillingStage.downloading,
          message: 'Downloading Qwen3 0.6B...',
          progress: 0,
        ));

        debugPrint('SlotFillingService: downloading model from $modelUrl');
        await FlutterGemma.installModel(
                modelType: ModelType.qwen,
                fileType: ModelFileType.litertlm,
            )
            .fromNetwork(modelUrl)
            .withProgress((pct) {
          if (pct % 5 == 0) {
            debugPrint('SlotFillingService: download $pct%');
          }
          _setState(SlotFillingState(
            stage: SlotFillingStage.downloading,
            message: 'Downloading Qwen3 0.6B... $pct%',
            progress: pct / 100,
          ));
        }).install();
      }

      // Create the model with small context — slot filling needs very little.
      final model = await FlutterGemma.getActiveModel(maxTokens: 512);
      _model = model;

      debugPrint('SlotFillingService: model loaded successfully!');
      _setState(const SlotFillingState(
        stage: SlotFillingStage.ready,
        message: 'Qwen3 ready',
      ));
    } catch (error, stackTrace) {
      debugPrint('SlotFillingService: failed to initialize: $error');
      debugPrint('SlotFillingService: $stackTrace');
      _setState(SlotFillingState(
        stage: SlotFillingStage.failed,
        message: 'Slot-filling model failed: $error',
      ));
      _initFuture = null;
    }
  }

  void _setState(SlotFillingState next) {
    if (_disposed) return;
    if (_state.stage == next.stage &&
        _state.message == next.message &&
        (_state.progress ?? -1) == (next.progress ?? -1)) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  void _debugLog(String event, Map<String, Object?> payload) {
    final encoded = jsonEncode({'event': event, ...payload});
    debugPrint('HarkSlotFill: $encoded');
    developer.log(encoded, name: 'HarkSlotFill');
  }
}
