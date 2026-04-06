import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/assistant_action.dart';
import '../models/command_resolution.dart';
import '../models/resolved_action.dart';
import 'command_resolver.dart';
import 'gemma_embedding_service.dart';
import 'slot_filling_service.dart';

class NluCommandResolver implements CommandResolver {
  NluCommandResolver(this._embeddingService, this._slotFillingService);

  final GemmaEmbeddingService _embeddingService;
  final SlotFillingService _slotFillingService;
  final Map<String, _CachedActionEmbedding> _embeddingCache = {};

  @override
  void initialize() {}

  @override
  Future<CommandResolutionResult> resolveCommand(
    String transcript,
    List<AssistantAction> actions,
  ) async {
    if (actions.isEmpty) {
      return const CommandResolutionResult.failure(
        CommandResolutionErrorType.unavailable,
        message: 'No OACP actions are registered yet.',
        modelId: 'oacp-nlu-embedding',
      );
    }

    final rankedOptions = await _rankActions(transcript, actions);
    final modelId = GemmaEmbeddingService.modelId;
    _debugLog('resolve_ranked', {
      'transcript': transcript,
      'modelId': modelId,
      'shortlist': [
        for (final option in rankedOptions.take(5))
          {
            'actionKey': option.actionKey,
            'score': option.score,
            'semanticScore': option.semanticScore,
          },
      ],
    });

    if (rankedOptions.isEmpty) {
      _debugLog('resolve_declined', {
        'transcript': transcript,
        'modelId': modelId,
        'reason': 'empty_shortlist',
      });
      return CommandResolutionResult.failure(
        CommandResolutionErrorType.noMatch,
        message: 'No matching action was found.',
        modelId: modelId,
      );
    }

    final best = rankedOptions.first;
    if (best.semanticScore == null || best.semanticScore! < 0.30) {
      _debugLog('resolve_declined', {
        'transcript': transcript,
        'modelId': modelId,
        'reason': 'score_below_floor',
        'score': best.score,
        'semanticScore': best.semanticScore,
      });
      return CommandResolutionResult.failure(
        CommandResolutionErrorType.noMatch,
        message: 'No matching action was found.',
        modelId: modelId,
      );
    }

    if (!_isConfidentMatch(rankedOptions)) {
      _debugLog('resolve_declined', {
        'transcript': transcript,
        'modelId': modelId,
        'reason': 'confidence_gate',
        'bestScore': best.score,
        'bestSemanticScore': best.semanticScore,
        'secondSemanticScore': rankedOptions.length > 1
            ? rankedOptions[1].semanticScore
            : null,
      });
      return CommandResolutionResult.failure(
        CommandResolutionErrorType.noMatch,
        message: 'The command was too ambiguous to match confidently.',
        modelId: modelId,
      );
    }

    // Layer 2: Slot filling via on-device LLM.
    final action = best.action;
    final Map<String, dynamic>? parameters;
    try {
      parameters = await _slotFillingService.extractParameters(
        transcript: transcript,
        action: action,
      );
    } on StateError {
      _debugLog('resolve_declined', {
        'transcript': transcript,
        'modelId': modelId,
        'reason': 'model_unavailable',
        'actionKey': best.actionKey,
      });
      return CommandResolutionResult.failure(
        CommandResolutionErrorType.unavailable,
        message: 'The slot-filling model is not available.',
        modelId: modelId,
      );
    }

    if (parameters == null) {
      _debugLog('resolve_declined', {
        'transcript': transcript,
        'modelId': modelId,
        'reason': 'slot_filling_failed',
        'actionKey': best.actionKey,
      });
      return CommandResolutionResult.failure(
        CommandResolutionErrorType.invalidResponse,
        message: 'The selected action is missing required parameters.',
        modelId: modelId,
      );
    }

    final resolved = ResolvedAction(
      sourceType: action.sourceType.name,
      sourceId: action.sourceId,
      actionId: action.actionId,
      parameters: parameters,
      confirmationMessage: action.confirmationMessage,
    );

    _debugLog('resolve_success', {
      'transcript': transcript,
      'modelId': modelId,
      'actionKey': best.actionKey,
      'semanticScore': best.semanticScore,
      'score': best.score,
      'parameters': resolved.parameters,
    });
    return CommandResolutionResult.success(resolved, modelId: modelId);
  }

  bool _isConfidentMatch(List<_RankedAction> rankedOptions) {
    if (rankedOptions.isEmpty) {
      return false;
    }

    final best = rankedOptions.first;
    final semanticScore = best.semanticScore;

    // Simple absolute threshold — trust the embedding model's top-1 pick.
    // The floor check already rejects scores below 0.30.
    // Here we require a modest minimum to filter weak-but-not-garbage matches.
    return semanticScore != null && semanticScore >= 0.35;
  }

  Future<List<_RankedAction>> _rankActions(
    String transcript,
    List<AssistantAction> actions,
  ) async {
    final normalizedTranscript = transcript.toLowerCase();

    final transcriptEmbedding =
        await _embeddingService.embedQuery(normalizedTranscript);
    if (transcriptEmbedding == null) {
      return [];
    }

    await _ensureActionEmbeddings(actions);

    final ranked = actions.map((action) {
      final key = _actionKey(action);
      final cached = _embeddingCache[key];
      final semanticScore = cached == null
          ? null
          : _dotProduct(transcriptEmbedding, cached.embedding);
      return _RankedAction(
        action: action,
        score: semanticScore != null ? (semanticScore * 100).round() : 0,
        semanticScore: semanticScore,
      );
    }).toList(growable: false);

    ranked.sort((left, right) {
      final semanticComparison =
          (right.semanticScore ?? -1).compareTo(left.semanticScore ?? -1);
      if (semanticComparison != 0) {
        return semanticComparison;
      }
      return right.score.compareTo(left.score);
    });

    return ranked;
  }

  Future<void> _ensureActionEmbeddings(List<AssistantAction> actions) async {
    final activeKeys = <String>{
      for (final action in actions) _actionKey(action),
    };
    _embeddingCache.removeWhere((key, _) => !activeKeys.contains(key));

    for (final action in actions) {
      final key = _actionKey(action);
      final text = _buildSemanticText(action);
      final cached = _embeddingCache[key];
      if (cached != null && cached.text == text) {
        continue;
      }

      final embedding = await _embeddingService.embedDocument(text);
      if (embedding == null) {
        continue;
      }

      _embeddingCache[key] = _CachedActionEmbedding(
        text: text,
        embedding: embedding,
      );
    }
  }

  static String _actionKey(AssistantAction action) =>
      '${action.sourceType.name}:${action.sourceId}:${action.actionId}';

  void _debugLog(String event, Map<String, Object?> payload) {
    final encoded = jsonEncode({'event': event, ...payload});
    debugPrint('HarkNlu: $encoded');
    developer.log(encoded, name: 'HarkDebugNlu');
  }

  String _buildSemanticText(AssistantAction action) {
    final parts = <String>[
      action.displayName,
      action.description,
      if (action.aliases.isNotEmpty) action.aliases.take(3).join('. '),
      if (action.examples.isNotEmpty) action.examples.take(3).join('. '),
      if (action.keywords.isNotEmpty) action.keywords.take(6).join(' '),
      if (action.appAliases.isNotEmpty) action.appAliases.take(3).join(' '),
      if (action.appKeywords.isNotEmpty) action.appKeywords.take(6).join(' '),
      for (final parameter in action.parameters)
        [parameter.name, parameter.description, ...parameter.enumValues]
            .whereType<String>()
            .join(' '),
    ];
    return parts.where((part) => part.trim().isNotEmpty).join('. ');
  }

  double _dotProduct(List<double> left, List<double> right) {
    final limit = math.min(left.length, right.length);
    var total = 0.0;
    for (var index = 0; index < limit; index += 1) {
      total += left[index] * right[index];
    }
    return total;
  }
}

class _RankedAction {
  const _RankedAction({
    required this.action,
    required this.score,
    this.semanticScore,
  });

  final AssistantAction action;
  final int score;
  final double? semanticScore;

  String get actionKey =>
      '${action.sourceType.name}:${action.sourceId}:${action.actionId}';
}

class _CachedActionEmbedding {
  const _CachedActionEmbedding({required this.text, required this.embedding});

  final String text;
  final List<double> embedding;
}
