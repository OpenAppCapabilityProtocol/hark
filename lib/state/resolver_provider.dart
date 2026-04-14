import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud/cloud_errors.dart';
import '../services/cloud/cloud_provider_config.dart';
import '../services/command_resolver.dart';
import '../services/embedding_cache_store.dart';
import '../services/logging_command_resolver.dart';
import '../services/nlu_command_resolver.dart';
import 'cloud_provider_notifier.dart';
import 'cloud_slot_filler_provider.dart';
import 'embedding_notifier.dart';
import 'services_providers.dart';
import 'slot_filling_notifier.dart';

/// Wires [LoggingCommandResolver] → [NluCommandResolver] to the Riverpod
/// notifiers that own the embedding, slot-filling, and (optionally)
/// cloud slot-filling models.
///
/// The resolver is Riverpod-agnostic: it takes closures that call into the
/// notifiers via `ref.read`, keeping the NLU logic trivially unit-testable.
///
/// The [EmbeddingCacheStore] persists action document embeddings to disk
/// so subsequent cold starts skip the ~7s re-embedding pass that otherwise
/// runs on the first voice command. See Phase 2b-2 of the near-term plan.
///
/// **Slot-fill routing (Slice 4):**
///
/// The `slotFill` closure picks local vs cloud at call time based on
/// the user's [CloudRoutingMode]. Modes:
///
/// - `localOnly` (default when no key configured) → always local Qwen3
/// - `cloudPreferred` → cloud first; fall back to local on any
///   [CloudUnavailableError]; rethrow [CloudHardError]
/// - `cloudOnly` → cloud or fail (no silent fallback)
///
/// In all cases the closure returns a [SlotFillOutcome] tagged with the
/// backend that actually produced the params, which the resolver writes
/// to the `stage2_backend` metric.
final commandResolverProvider = Provider<CommandResolver>((ref) {
  final logger = ref.watch(inferenceLoggerProvider);

  Future<SlotFillOutcome> localSlotFill({
    required String transcript,
    required action,
  }) async {
    final params = await ref
        .read(slotFillingProvider.notifier)
        .extractParameters(transcript: transcript, action: action);
    return SlotFillOutcome(params: params, backend: 'qwen3_local');
  }

  final nlu = NluCommandResolver(
    embedQuery: (text) async =>
        ref.read(embeddingProvider.notifier).embedQuery(text),
    embedDocument: (text) async =>
        ref.read(embeddingProvider.notifier).embedDocument(text),
    slotFill: ({required transcript, required action}) async {
      final mode = ref.read(cloudProviderNotifierProvider).mode;
      final cloud = ref.read(cloudSlotFillerProvider);

      // No cloud configured OR user wants local-only → straight to local.
      if (cloud == null || mode == CloudRoutingMode.localOnly) {
        return localSlotFill(transcript: transcript, action: action);
      }

      // Cloud path. Catch only the recoverable error type so hard errors
      // (CloudHardError, programmer errors) propagate to the user.
      try {
        return await cloud.extract(
          transcript: transcript,
          action: action,
        );
      } on CloudUnavailableError catch (e) {
        if (mode == CloudRoutingMode.cloudPreferred) {
          debugPrint(
            'commandResolver: cloud unavailable in cloudPreferred mode, '
            'falling back to local. Reason: $e',
          );
          return localSlotFill(transcript: transcript, action: action);
        }
        // cloudOnly → surface as StateError so existing
        // NluCommandResolver.unavailable path handles it.
        debugPrint(
          'commandResolver: cloud unavailable in cloudOnly mode. '
          'Reason: $e',
        );
        throw StateError('Cloud unavailable: ${e.message}');
      }
    },
    modelId: EmbeddingNotifier.modelId,
    cacheStore: EmbeddingCacheStore(modelId: EmbeddingNotifier.modelId),
  );

  return LoggingCommandResolver(
    nlu,
    logger,
    fallbackModelId: EmbeddingNotifier.modelId,
  );
});

/// Provides the [NluCommandResolver] for callers that need the concrete
/// type (e.g. to call [preWarmEmbeddings]). This is the same resolver
/// instance as [commandResolverProvider], unwrapped from the logging wrapper.
final nluResolverProvider = Provider<NluCommandResolver>((ref) {
  final resolver = ref.watch(commandResolverProvider);
  if (resolver is LoggingCommandResolver) {
    return resolver.delegate as NluCommandResolver;
  }
  return resolver as NluCommandResolver;
});
