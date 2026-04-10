import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/command_resolver.dart';
import '../services/embedding_cache_store.dart';
import '../services/logging_command_resolver.dart';
import '../services/nlu_command_resolver.dart';
import 'embedding_notifier.dart';
import 'services_providers.dart';
import 'slot_filling_notifier.dart';

/// Wires [LoggingCommandResolver] → [NluCommandResolver] to the Riverpod
/// notifiers that own the embedding and slot-filling models.
///
/// The resolver is Riverpod-agnostic: it takes closures that call into the
/// notifiers via `ref.read`, keeping the NLU logic trivially unit-testable.
///
/// The [EmbeddingCacheStore] persists action document embeddings to disk
/// so subsequent cold starts skip the ~7s re-embedding pass that otherwise
/// runs on the first voice command. See Phase 2b-2 of the near-term plan.
final commandResolverProvider = Provider<CommandResolver>((ref) {
  final logger = ref.watch(inferenceLoggerProvider);

  final nlu = NluCommandResolver(
    embedQuery: (text) async =>
        ref.read(embeddingProvider.notifier).embedQuery(text),
    embedDocument: (text) async =>
        ref.read(embeddingProvider.notifier).embedDocument(text),
    slotFill: ({required transcript, required action}) async => ref
        .read(slotFillingProvider.notifier)
        .extractParameters(transcript: transcript, action: action),
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
