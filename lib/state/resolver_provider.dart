import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/command_resolver.dart';
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
  );

  return LoggingCommandResolver(
    nlu,
    logger,
    fallbackModelId: EmbeddingNotifier.modelId,
  );
});
