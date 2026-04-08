import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_embedder/flutter_embedder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lifecycle stages of the EmbeddingGemma model — identical to the values
/// exposed by the legacy [GemmaEmbeddingService] so any status UI can keep
/// using the same keys during the Riverpod migration.
enum EmbeddingStage { idle, downloading, loading, ready, failed }

/// Immutable state container for [EmbeddingNotifier].
///
/// Holds the current stage, a human-readable status message, an optional
/// download progress value in the `[0, 1]` range, raw byte counters, and the
/// live [GemmaEmbedder] handle once the model has been loaded.
@immutable
class EmbeddingState {
  const EmbeddingState({
    required this.stage,
    required this.message,
    this.progress,
    this.receivedBytes,
    this.totalBytes,
    this.embedder,
  });

  final EmbeddingStage stage;
  final String message;
  final double? progress;
  final int? receivedBytes;
  final int? totalBytes;
  final GemmaEmbedder? embedder;

  bool get isReady => stage == EmbeddingStage.ready && embedder != null;
  bool get isBusy =>
      stage == EmbeddingStage.downloading ||
      stage == EmbeddingStage.loading;

  EmbeddingState copyWith({
    EmbeddingStage? stage,
    String? message,
    double? progress,
    bool clearProgress = false,
    int? receivedBytes,
    bool clearReceivedBytes = false,
    int? totalBytes,
    bool clearTotalBytes = false,
    GemmaEmbedder? embedder,
    bool clearEmbedder = false,
  }) {
    return EmbeddingState(
      stage: stage ?? this.stage,
      message: message ?? this.message,
      progress: clearProgress ? null : (progress ?? this.progress),
      receivedBytes: clearReceivedBytes
          ? null
          : (receivedBytes ?? this.receivedBytes),
      totalBytes:
          clearTotalBytes ? null : (totalBytes ?? this.totalBytes),
      embedder: clearEmbedder ? null : (embedder ?? this.embedder),
    );
  }
}

/// Riverpod 3.x [Notifier] that owns the EmbeddingGemma runtime.
///
/// This is a direct port of the legacy `GemmaEmbeddingService`. Behavior,
/// download flow, progress messages, HuggingFace coordinates, and the
/// query/document embedding helpers are preserved byte-for-byte so
/// downstream callers can switch over without observable differences.
class EmbeddingNotifier extends Notifier<EmbeddingState> {
  static const modelId = 'onnx-community/embeddinggemma-300m-ONNX';

  ModelManager? _modelManager;
  Future<void>? _initFuture;
  bool _disposed = false;

  @override
  EmbeddingState build() {
    ref.onDispose(() {
      _disposed = true;
      // GemmaEmbedder is a Rust opaque type — its native resources are freed
      // when the Dart object is garbage collected via flutter_rust_bridge.
      // We null out references to allow GC to collect them.
      state = state.copyWith(clearEmbedder: true);
      _initFuture = null;
    });

    // Kick off initialization on first read, mirroring the old lazy
    // `prewarm()` semantics but without requiring an external caller.
    Future.microtask(() {
      if (_disposed) return;
      _initFuture ??= _initialize();
    });

    return const EmbeddingState(
      stage: EmbeddingStage.idle,
      message: 'Preparing EmbeddingGemma...',
    );
  }

  /// True when the model has been fully loaded and is ready for inference.
  bool get isReady => state.embedder != null;

  /// Legacy no-op alias kept for migration compatibility. The notifier
  /// auto-initializes in [build], so external prewarm is no longer required,
  /// but existing callers may still invoke this during the migration.
  Future<void> prewarm() async {
    if (_disposed) return;
    await (_initFuture ??= _initialize());
  }

  /// Embed a short query string. Applies the EmbeddingGemma query prompt
  /// template via [GemmaEmbedder.formatQuery] and returns an L2-normalized
  /// vector, matching the legacy service's exact behavior.
  Future<List<double>?> embedQuery(String text) async {
    await (_initFuture ??= _initialize());
    final embedder = state.embedder;
    if (embedder == null || _disposed) return null;
    final formatted = GemmaEmbedder.formatQuery(query: text);
    final results = embedder.embed(texts: [formatted]);
    if (results.isEmpty) return null;
    return _normalize(results.first);
  }

  /// Embed a longer document string. Applies the EmbeddingGemma document
  /// prompt template via [GemmaEmbedder.formatDocument] and returns an
  /// L2-normalized vector, matching the legacy service's exact behavior.
  Future<List<double>?> embedDocument(String text) async {
    await (_initFuture ??= _initialize());
    final embedder = state.embedder;
    if (embedder == null || _disposed) return null;
    final formatted = GemmaEmbedder.formatDocument(text: text);
    final results = embedder.embed(texts: [formatted]);
    if (results.isEmpty) return null;
    return _normalize(results.first);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _initialize() async {
    try {
      debugPrint('EmbeddingNotifier: starting initialization...');
      _setState(const EmbeddingState(
        stage: EmbeddingStage.loading,
        message: 'Initializing EmbeddingGemma runtime...',
      ));

      await initFlutterEmbedder();
      if (_disposed) return;
      debugPrint('EmbeddingNotifier: runtime initialized OK');

      _modelManager ??= await ModelManager.withDefaultCacheDir();
      if (_disposed) return;

      // Check if model is already downloaded
      final localModel = await _modelManager!.getLocalModel(modelId);
      if (_disposed) return;
      if (localModel != null) {
        debugPrint(
            'EmbeddingNotifier: model already cached, loading from disk...');
        _setState(const EmbeddingState(
          stage: EmbeddingStage.loading,
          message: 'Loading EmbeddingGemma from cache...',
        ));
        final embedder = GemmaEmbedder.create(
          modelPath: localModel.modelPath,
          tokenizerPath: localModel.tokenizerPath,
        );
        if (_disposed) return;
        debugPrint('EmbeddingNotifier: model loaded from cache!');
        _setState(EmbeddingState(
          stage: EmbeddingStage.ready,
          message: 'EmbeddingGemma ready',
          embedder: embedder,
        ));
        return;
      }

      // Not cached — download from HuggingFace
      _setState(const EmbeddingState(
        stage: EmbeddingStage.downloading,
        message: 'Downloading EmbeddingGemma model...',
        progress: 0,
      ));

      debugPrint(
          'EmbeddingNotifier: starting model download from HuggingFace...');
      final embedder = await GemmaEmbedderFactory.fromHuggingFace(
        manager: _modelManager,
        onnxFile: 'onnx/model_q4.onnx',
        onProgress: (file, received, total) {
          if (_disposed) return;
          if (total > 0) {
            final pct = (received / total * 100).round();
            if (pct % 5 == 0) {
              debugPrint(
                'EmbeddingNotifier: download $pct% '
                '(${_formatBytes(received)} / ${_formatBytes(total)})',
              );
            }
            _setState(EmbeddingState(
              stage: EmbeddingStage.downloading,
              message: 'Downloading EmbeddingGemma... '
                  '${_formatBytes(received)} / ${_formatBytes(total)}',
              progress: received / total,
              receivedBytes: received,
              totalBytes: total,
            ));
          }
        },
      );

      if (_disposed) return;
      debugPrint('EmbeddingNotifier: model loaded successfully!');
      _setState(EmbeddingState(
        stage: EmbeddingStage.ready,
        message: 'EmbeddingGemma ready',
        embedder: embedder,
      ));
    } catch (error, stackTrace) {
      debugPrint('EmbeddingNotifier: failed to initialize: $error');
      debugPrint('EmbeddingNotifier: stackTrace: $stackTrace');
      _setState(EmbeddingState(
        stage: EmbeddingStage.failed,
        message: 'EmbeddingGemma failed: $error',
      ));
      _initFuture = null;
    }
  }

  List<double> _normalize(Float32List values) {
    var norm = 0.0;
    for (final v in values) {
      norm += v * v;
    }
    if (norm <= 0) return values.toList();
    final scale = 1.0 / math.sqrt(norm);
    return [for (final v in values) v * scale];
  }

  void _setState(EmbeddingState next) {
    if (_disposed) return;
    final current = state;
    if (current.stage == next.stage &&
        current.message == next.message &&
        (current.progress ?? -1) == (next.progress ?? -1) &&
        identical(current.embedder, next.embedder)) {
      return;
    }
    state = next;
  }
}

/// Riverpod provider that exposes the [EmbeddingNotifier] and its state.
final embeddingProvider =
    NotifierProvider<EmbeddingNotifier, EmbeddingState>(
  EmbeddingNotifier.new,
);
