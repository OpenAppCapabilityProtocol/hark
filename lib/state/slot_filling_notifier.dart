import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/assistant_action.dart';

/// Lifecycle stages of the slot-filling model — identical to the values
/// exposed by the legacy [SlotFillingService] so the splash screen can keep
/// using the same status keys during the Riverpod migration.
enum SlotFillingStage { idle, downloading, loading, ready, failed }

/// Immutable state container for [SlotFillingNotifier].
///
/// Holds the current stage, a human-readable status message, an optional
/// download progress value in the `[0, 1]` range, and the live
/// [InferenceModel] handle once the model has been loaded.
@immutable
class SlotFillingState {
  const SlotFillingState({
    required this.stage,
    required this.message,
    this.progress,
    this.model,
  });

  final SlotFillingStage stage;
  final String message;
  final double? progress;
  final InferenceModel? model;

  bool get isReady => stage == SlotFillingStage.ready && model != null;
  bool get isBusy =>
      stage == SlotFillingStage.downloading ||
      stage == SlotFillingStage.loading;

  SlotFillingState copyWith({
    SlotFillingStage? stage,
    String? message,
    double? progress,
    bool clearProgress = false,
    InferenceModel? model,
    bool clearModel = false,
  }) {
    return SlotFillingState(
      stage: stage ?? this.stage,
      message: message ?? this.message,
      progress: clearProgress ? null : (progress ?? this.progress),
      model: clearModel ? null : (model ?? this.model),
    );
  }
}

/// Riverpod 3.x [Notifier] that owns the Qwen3 0.6B slot-filling runtime.
///
/// Behavior, prompt template, JSON parsing, progress messages, and Qwen3
/// model coordinates are all preserved from the prior implementation so the
/// splash screen and downstream callers have no observable differences.
class SlotFillingNotifier extends Notifier<SlotFillingState> {
  static const modelUrl =
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm';
  static const modelId = 'Qwen3-0.6B';

  Future<void>? _initFuture;
  bool _disposed = false;

  @override
  SlotFillingState build() {
    ref.onDispose(() {
      _disposed = true;
      // Close the model handle if one was ever loaded. We read from `state`
      // rather than a stored field so there is a single source of truth.
      state.model?.close();
      _initFuture = null;
    });

    // Kick off initialization on first read, mirroring the old lazy
    // `prewarm()` semantics but without requiring an external caller.
    Future.microtask(() {
      if (_disposed) return;
      _initFuture ??= _initialize();
    });

    return const SlotFillingState(
      stage: SlotFillingStage.idle,
      message: 'Preparing slot-filling model...',
    );
  }

  /// True when the model has been fully loaded and is ready for inference.
  bool get isReady => state.model != null;

  /// Legacy no-op alias kept for migration compatibility. The notifier
  /// auto-initializes in [build], so external prewarm is no longer required,
  /// but existing callers may still invoke this during the migration.
  Future<void> prewarm() async {
    if (_disposed) return;
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
    final model = state.model;
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
      debugPrint('SlotFillingNotifier: inference failed: $error');
      debugPrint('SlotFillingNotifier: $stackTrace');
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
      debugPrint('SlotFillingNotifier: starting initialization...');
      _setState(const SlotFillingState(
        stage: SlotFillingStage.loading,
        message: 'Initializing slot-filling runtime...',
      ));

      await FlutterGemma.initialize();

      // Check if model is already installed.
      if (FlutterGemma.hasActiveModel()) {
        debugPrint(
            'SlotFillingNotifier: model already installed, loading...');
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

        debugPrint('SlotFillingNotifier: downloading model from $modelUrl');
        await FlutterGemma.installModel(
          modelType: ModelType.qwen,
          fileType: ModelFileType.litertlm,
        )
            .fromNetwork(modelUrl)
            .withProgress((pct) {
          if (pct % 5 == 0) {
            debugPrint('SlotFillingNotifier: download $pct%');
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

      if (_disposed) {
        // A dispose happened while awaiting the model — don't leak it.
        await model.close();
        return;
      }

      debugPrint('SlotFillingNotifier: model loaded successfully!');
      _setState(SlotFillingState(
        stage: SlotFillingStage.ready,
        message: 'Qwen3 ready',
        model: model,
      ));
    } catch (error, stackTrace) {
      debugPrint('SlotFillingNotifier: failed to initialize: $error');
      debugPrint('SlotFillingNotifier: $stackTrace');
      _setState(SlotFillingState(
        stage: SlotFillingStage.failed,
        message: 'Slot-filling model failed: $error',
      ));
      _initFuture = null;
    }
  }

  void _setState(SlotFillingState next) {
    if (_disposed) return;
    final current = state;
    if (current.stage == next.stage &&
        current.message == next.message &&
        (current.progress ?? -1) == (next.progress ?? -1) &&
        identical(current.model, next.model)) {
      return;
    }
    state = next;
  }

  void _debugLog(String event, Map<String, Object?> payload) {
    final encoded = jsonEncode({'event': event, ...payload});
    debugPrint('HarkSlotFill: $encoded');
    developer.log(encoded, name: 'HarkSlotFill');
  }
}

/// Riverpod provider that exposes the [SlotFillingNotifier] and its state.
final slotFillingProvider =
    NotifierProvider<SlotFillingNotifier, SlotFillingState>(
  SlotFillingNotifier.new,
);
