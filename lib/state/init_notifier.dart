import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'embedding_notifier.dart';
import 'registry_provider.dart';
import 'resolver_provider.dart';
import 'services_providers.dart';
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

  bool get isReady => embedding.isReady && slotFilling.isReady && registryReady;

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
    return sum /
        2.0; // always average over both models, not just reporting ones
  }
}

class InitNotifier extends Notifier<InitState> {
  // HarkLoadPerf: wall-time Stopwatch that starts when the notifier is
  // first built (shortly after splash). When all three dependencies flip
  // to ready, we log `init.all_ready` once. This is the end-to-end
  // "cold start to usable" number that PHASE2 cares about.
  final Stopwatch _buildSw = Stopwatch()..start();
  bool _allReadyLogged = false;
  bool _embeddingWarmupTriggered = false;

  /// Retry all failed notifiers. Called from the splash retry button.
  void retryAll() {
    _allReadyLogged = false;
    _embeddingWarmupTriggered = false;
    _buildSw.reset();
    _buildSw.start();

    final embedding = ref.read(embeddingProvider);
    final slotFilling = ref.read(slotFillingProvider);

    if (embedding.stage == EmbeddingStage.failed) {
      ref.read(embeddingProvider.notifier).retry();
    }
    if (slotFilling.stage == SlotFillingStage.failed) {
      ref.read(slotFillingProvider.notifier).retry();
    }
  }

  @override
  InitState build() {
    final embedding = ref.watch(embeddingProvider);
    final slotFilling = ref.watch(slotFillingProvider);
    final registry = ref.watch(capabilityRegistryProvider);

    final next = InitState(
      embedding: embedding,
      slotFilling: slotFilling,
      registryReady: registry.hasValue,
      registryError: registry.hasError ? registry.error : null,
    );

    if (next.isReady && !_allReadyLogged) {
      _allReadyLogged = true;
      _buildSw.stop();
      final logger = ref.read(inferenceLoggerProvider);
      unawaited(
        logger.logModelLoad('init.all_ready', _buildSw.elapsedMilliseconds),
      );

      // Phase 2b-2: pre-warm the action document embedding cache AFTER
      // all models are loaded — not during init. Running it during init
      // causes CPU contention with the slot filler's model_open on
      // Dimensity 7025 (measured: slot_filling.model_open regressed from
      // 16378ms to 30644ms when the warmup ran concurrently).
      //
      // Triggering here means:
      // - First-ever run: 49 actions × ~280ms each = ~14s of embedding
      //   work runs after splash. The user has the mic visible but the
      //   first command will block on the warmup. Happens only once.
      // - Second+ runs: the disk cache makes this ~50ms. The first
      //   command resolves in ~200ms.
      if (!_embeddingWarmupTriggered && registry.hasValue) {
        _embeddingWarmupTriggered = true;
        final actions = registry.requireValue.actions;
        final nluResolver = ref.read(nluResolverProvider);
        unawaited(() async {
          final sw = Stopwatch()..start();
          await nluResolver.preWarmEmbeddings(actions);
          sw.stop();
          debugPrint(
            'HarkLoadPerf: embedding.cache_warmup '
            '${sw.elapsedMilliseconds}ms',
          );
          unawaited(
            logger.logModelLoad(
              'embedding.cache_warmup',
              sw.elapsedMilliseconds,
            ),
          );
        }());
      }
    }

    return next;
  }
}

final initProvider = NotifierProvider<InitNotifier, InitState>(
  InitNotifier.new,
);
