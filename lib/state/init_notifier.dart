import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'embedding_notifier.dart';
import 'registry_provider.dart';
import 'slot_filling_notifier.dart';

/// Aggregate "is the app ready to accept voice commands?" state.
///
/// Watches the embedding model, slot-filling model, and capability registry
/// providers and exposes a single predicate ([isReady]) plus granular
/// sub-states so the splash screen can render per-dependency progress.
@immutable
class InitState {
  const InitState({
    required this.embedding,
    required this.slotFilling,
    required this.registryReady,
    required this.registryError,
  });

  final EmbeddingState embedding;
  final SlotFillingState slotFilling;
  final bool registryReady;
  final Object? registryError;

  bool get isReady =>
      embedding.isReady && slotFilling.isReady && registryReady;

  bool get hasFailure =>
      embedding.stage == EmbeddingStage.failed ||
      slotFilling.stage == SlotFillingStage.failed ||
      registryError != null;

  String? get failureMessage {
    if (embedding.stage == EmbeddingStage.failed) {
      return embedding.message;
    }
    if (slotFilling.stage == SlotFillingStage.failed) {
      return slotFilling.message;
    }
    if (registryError != null) {
      return 'Could not load capability registry: $registryError';
    }
    return null;
  }

  /// Rough 0..1 progress fraction averaged across the two models, for the
  /// splash's aggregate progress indicator. Returns null while both models
  /// are still idle so the UI can render an indeterminate bar.
  double? get aggregateProgress {
    final values = <double>[];
    if (embedding.isReady) {
      values.add(1.0);
    } else if (embedding.progress != null) {
      values.add(embedding.progress!.clamp(0.0, 1.0));
    }
    if (slotFilling.isReady) {
      values.add(1.0);
    } else if (slotFilling.progress != null) {
      values.add(slotFilling.progress!.clamp(0.0, 1.0));
    }
    if (values.isEmpty) {
      return null;
    }
    final sum = values.fold<double>(0, (a, b) => a + b);
    return sum / 2.0; // always average over both models, not just reporting ones
  }
}

class InitNotifier extends Notifier<InitState> {
  @override
  InitState build() {
    final embedding = ref.watch(embeddingProvider);
    final slotFilling = ref.watch(slotFillingProvider);
    final registry = ref.watch(capabilityRegistryProvider);

    return InitState(
      embedding: embedding,
      slotFilling: slotFilling,
      registryReady: registry.hasValue,
      registryError: registry.hasError ? registry.error : null,
    );
  }
}

final initProvider =
    NotifierProvider<InitNotifier, InitState>(InitNotifier.new);
