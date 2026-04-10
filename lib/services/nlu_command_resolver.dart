import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/assistant_action.dart';
import '../models/command_resolution.dart';
import '../models/resolved_action.dart';
import 'command_resolver.dart';
import 'embedding_cache_store.dart';

/// Async callable that embeds a query string and returns a vector.
typedef EmbedFn = Future<List<double>?> Function(String text);

/// Async callable that extracts parameters for a resolved action from a
/// transcript, or returns null if required slots could not be filled.
typedef SlotFillFn = Future<Map<String, dynamic>?> Function({
  required String transcript,
  required AssistantAction action,
});

class NluCommandResolver implements CommandResolver {
  NluCommandResolver({
    required this.embedQuery,
    required this.embedDocument,
    required this.slotFill,
    required this.modelId,
    this.cacheStore,
  });

  /// Embeds a user transcript/query. Must return a unit-length vector or
  /// null if the model isn't available.
  final EmbedFn embedQuery;

  /// Embeds a stored action description (the "document" side of the retrieval
  /// pair). Must return a unit-length vector or null if the model isn't
  /// available.
  final EmbedFn embedDocument;

  /// Slot-filler that extracts parameters for an action from a transcript.
  /// Returns null if required parameters could not be extracted.
  final SlotFillFn slotFill;

  /// Model id string propagated on result/error records for logging.
  final String modelId;

  /// Optional disk-backed cache store for persisting action document
  /// embeddings across app restarts. When provided, the first
  /// `_ensureActionEmbeddings` call loads from disk, diffs against the
  /// current action set, and only re-embeds the delta. After each cache
  /// rebuild, the updated cache is written back to disk.
  final EmbeddingCacheStore? cacheStore;

  final Map<String, _CachedActionEmbedding> _embeddingCache = {};
  bool _diskCacheLoaded = false;
  bool _cacheIsDirty = false;

  @override
  void initialize() {}

  /// Pre-build the document embedding cache for a set of actions. Call this
  /// at app startup (after the embedding model + capability registry are
  /// both ready) to move the ~7s cold-cache cost from the first voice
  /// command to the init phase where the splash screen hides it.
  ///
  /// If a [cacheStore] was provided at construction, this also loads the
  /// disk cache first so subsequent cold starts skip embedding entirely.
  Future<void> preWarmEmbeddings(List<AssistantAction> actions) async {
    final sw = Stopwatch()..start();
    await _ensureActionEmbeddings(actions);
    sw.stop();
    debugPrint('NluCommandResolver: preWarmEmbeddings completed in '
        '${sw.elapsedMilliseconds}ms for ${actions.length} actions '
        '(${_embeddingCache.length} cached, '
        '${_cacheIsDirty ? "wrote to disk" : "disk hit"})');
  }

  @override
  Future<CommandResolutionResult> resolveCommand(
    String transcript,
    List<AssistantAction> actions,
  ) async {
    if (actions.isEmpty) {
      return CommandResolutionResult.failure(
        CommandResolutionErrorType.unavailable,
        message: 'No OACP actions are registered yet.',
        modelId: modelId,
      );
    }

    // Fast path: unambiguous keyword / alias match for zero-parameter
    // commands. Avoids the embedding + slot-filling pipeline entirely
    // for trivial utterances like "turn on the flashlight", "pause
    // music", "scan qr code". Also works during cold start before
    // models have finished loading.
    final fastPath = _tryKeywordFastPath(transcript, actions);
    if (fastPath != null) {
      _debugLog('resolve_fast_path', {
        'transcript': transcript,
        'modelId': modelId,
        'actionKey': '${fastPath.sourceId}.${fastPath.actionId}',
        'matchedVia': fastPath.parameters['__matched_via'],
      });
      // Strip the internal bookkeeping key before returning.
      final resolved = ResolvedAction(
        sourceType: fastPath.sourceType,
        sourceId: fastPath.sourceId,
        actionId: fastPath.actionId,
        parameters: {
          for (final entry in fastPath.parameters.entries)
            if (entry.key != '__matched_via') entry.key: entry.value,
        },
        confirmationMessage: fastPath.confirmationMessage,
      );
      return CommandResolutionResult.success(resolved, modelId: modelId);
    }

    final rankedOptions = await _rankActions(transcript, actions);
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
      parameters = await slotFill(
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

  /// Pre-embedding keyword / alias fast path for trivial zero-parameter
  /// commands. Returns a [ResolvedAction] if the transcript unambiguously
  /// matches exactly one action via an exact alias or a high-signal
  /// keyword hit, AND that action has no required parameters. Otherwise
  /// returns null and the full NLU pipeline runs.
  ///
  /// The returned `ResolvedAction.parameters` carries an internal
  /// `__matched_via` key that the caller strips before returning; it is
  /// used only for telemetry logging.
  ///
  /// Why this exists:
  /// 1. Latency — "turn on the flashlight" dispatches in microseconds.
  /// 2. Cold-start UX — commands fire before the embedding model has
  ///    finished loading during a fresh process launch.
  /// 3. Robustness — if the models fail to load, simple commands still
  ///    work.
  ResolvedAction? _tryKeywordFastPath(
    String transcript,
    List<AssistantAction> actions,
  ) {
    final normalized = transcript.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    // Only fire for actions with no required params — filling typed
    // slots needs the LLM even if the action itself is unambiguous.
    bool hasNoRequiredParams(AssistantAction a) =>
        !a.parameters.any((p) => p.required);

    // Pass 1: exact alias match. An action's `aliases` list is a
    // curated set of "the user literally said this" phrases. Exact
    // equality is the strongest possible signal.
    final exactAliasHits = <AssistantAction>[];
    for (final action in actions) {
      if (!hasNoRequiredParams(action)) continue;
      for (final alias in action.aliases) {
        if (alias.toLowerCase().trim() == normalized) {
          exactAliasHits.add(action);
          break;
        }
      }
    }
    if (exactAliasHits.length == 1) {
      return _buildFastPathResolution(exactAliasHits.single, 'exact_alias');
    }
    if (exactAliasHits.length > 1) {
      // Multiple actions claim the same alias — ambiguous, fall through
      // to the embedding model to decide.
      return null;
    }

    // Pass 2: keyword substring match. Keywords are single words or
    // short phrases that strongly imply the action (e.g. "flashlight",
    // "scan qr"). We require the keyword to appear as a whole token in
    // the transcript, not as a substring inside another word.
    final keywordHits = <AssistantAction>[];
    for (final action in actions) {
      if (!hasNoRequiredParams(action)) continue;
      for (final keyword in action.keywords) {
        final kw = keyword.toLowerCase().trim();
        if (kw.isEmpty) continue;
        if (_containsAsWord(normalized, kw)) {
          keywordHits.add(action);
          break;
        }
      }
    }
    if (keywordHits.length == 1) {
      return _buildFastPathResolution(keywordHits.single, 'keyword');
    }

    // Ambiguous or no hit — fall through to embedding.
    return null;
  }

  /// True if [needle] appears in [haystack] as a complete whitespace- or
  /// punctuation-delimited token (or sequence of tokens for multi-word
  /// needles). Avoids matching "pause" inside "pauseplay" or "can" in
  /// "cancel".
  bool _containsAsWord(String haystack, String needle) {
    final escaped = RegExp.escape(needle);
    // \b would work for ASCII but fails on unicode word boundaries.
    // Use a simple before/after character class instead.
    final pattern = RegExp(r'(^|[^a-z0-9])' + escaped + r'([^a-z0-9]|$)');
    return pattern.hasMatch(haystack);
  }

  /// Wraps a matched action in a [ResolvedAction] with empty params and
  /// a telemetry marker.
  ResolvedAction _buildFastPathResolution(
    AssistantAction action,
    String matchedVia,
  ) {
    return ResolvedAction(
      sourceType: action.sourceType.name,
      sourceId: action.sourceId,
      actionId: action.actionId,
      parameters: {'__matched_via': matchedVia},
      confirmationMessage: action.confirmationMessage,
    );
  }

  Future<List<_RankedAction>> _rankActions(
    String transcript,
    List<AssistantAction> actions,
  ) async {
    final normalizedTranscript = transcript.toLowerCase();

    final transcriptEmbedding = await embedQuery(normalizedTranscript);
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
    // Step 1: Load disk cache on first call (if a store was provided).
    if (!_diskCacheLoaded && cacheStore != null) {
      _diskCacheLoaded = true;
      final diskEntries = await cacheStore!.load();
      for (final entry in diskEntries.entries) {
        _embeddingCache[entry.key] = _CachedActionEmbedding(
          textHash: entry.value.textHash,
          embedding: entry.value.embedding,
        );
      }
      if (diskEntries.isNotEmpty) {
        debugPrint('NluCommandResolver: loaded ${diskEntries.length} '
            'embeddings from disk cache');
      }
    }

    // Step 2: Prune entries for actions no longer in the active set.
    final activeKeys = <String>{
      for (final action in actions) _actionKey(action),
    };
    final beforeCount = _embeddingCache.length;
    _embeddingCache.removeWhere((key, _) => !activeKeys.contains(key));
    if (_embeddingCache.length < beforeCount) {
      _cacheIsDirty = true;
    }

    // Step 3: Embed any actions that are missing or whose text changed.
    var embedded = 0;
    for (final action in actions) {
      final key = _actionKey(action);
      final text = _buildSemanticText(action);
      final textHash = EmbeddingCacheStore.hashText(text);
      final cached = _embeddingCache[key];

      // Cache hit: both text hash and embedding present.
      if (cached != null && cached.textHash == textHash) {
        continue;
      }

      final embedding = await embedDocument(text);
      if (embedding == null) {
        continue;
      }

      _embeddingCache[key] = _CachedActionEmbedding(
        textHash: textHash,
        embedding: embedding,
      );
      _cacheIsDirty = true;
      embedded += 1;
    }

    if (embedded > 0) {
      debugPrint('NluCommandResolver: embedded $embedded actions '
          '(${_embeddingCache.length} total cached)');
    }

    // Step 4: Persist to disk if anything changed.
    if (_cacheIsDirty && cacheStore != null) {
      _cacheIsDirty = false;
      await cacheStore!.save({
        for (final entry in _embeddingCache.entries)
          entry.key: CachedEmbedding(
            textHash: entry.value.textHash,
            embedding: entry.value.embedding,
          ),
      });
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
  const _CachedActionEmbedding({
    required this.textHash,
    required this.embedding,
  });

  final String textHash;
  final List<double> embedding;
}
