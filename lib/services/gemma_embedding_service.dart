import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_embedder/flutter_embedder.dart';

enum GemmaEmbeddingStage { idle, downloading, loading, ready, failed }

class GemmaEmbeddingState {
  const GemmaEmbeddingState({
    required this.stage,
    required this.message,
    this.progress,
    this.receivedBytes,
    this.totalBytes,
  });

  final GemmaEmbeddingStage stage;
  final String message;
  final double? progress;
  final int? receivedBytes;
  final int? totalBytes;

  bool get isReady => stage == GemmaEmbeddingStage.ready;
  bool get isBusy =>
      stage == GemmaEmbeddingStage.downloading ||
      stage == GemmaEmbeddingStage.loading;
}

class GemmaEmbeddingService extends ChangeNotifier {
  static const modelId = 'onnx-community/embeddinggemma-300m-ONNX';

  GemmaEmbedder? _embedder;
  Future<GemmaEmbedder?>? _initFuture;
  ModelManager? _modelManager;
  GemmaEmbeddingState _state = const GemmaEmbeddingState(
    stage: GemmaEmbeddingStage.idle,
    message: 'Preparing EmbeddingGemma...',
  );

  GemmaEmbeddingState get state => _state;
  bool get isReady => _embedder != null;

  @override
  void dispose() {
    // GemmaEmbedder is a Rust opaque type — its native resources are freed
    // when the Dart object is garbage collected via flutter_rust_bridge.
    // We null out references to allow GC to collect them.
    _embedder = null;
    _initFuture = null;
    super.dispose();
  }

  Future<void> prewarm() async {
    await (_initFuture ??= _initialize());
  }

  Future<List<double>?> embedQuery(String text) async {
    final embedder = await (_initFuture ??= _initialize());
    if (embedder == null) return null;
    final formatted = GemmaEmbedder.formatQuery(query: text);
    final results = embedder.embed(texts: [formatted]);
    if (results.isEmpty) return null;
    return _normalize(results.first);
  }

  Future<List<double>?> embedDocument(String text) async {
    final embedder = await (_initFuture ??= _initialize());
    if (embedder == null) return null;
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

  Future<GemmaEmbedder?> _initialize() async {
    try {
      debugPrint('GemmaEmbeddingService: starting initialization...');
      _setState(const GemmaEmbeddingState(
        stage: GemmaEmbeddingStage.loading,
        message: 'Initializing EmbeddingGemma runtime...',
      ));

      await initFlutterEmbedder();
      debugPrint('GemmaEmbeddingService: runtime initialized OK');

      _modelManager ??= await ModelManager.withDefaultCacheDir();

      // Check if model is already downloaded
      final localModel = await _modelManager!.getLocalModel(modelId);
      if (localModel != null) {
        debugPrint('GemmaEmbeddingService: model already cached, loading from disk...');
        _setState(const GemmaEmbeddingState(
          stage: GemmaEmbeddingStage.loading,
          message: 'Loading EmbeddingGemma from cache...',
        ));
        final embedder = GemmaEmbedder.create(
          modelPath: localModel.modelPath,
          tokenizerPath: localModel.tokenizerPath,
        );
        _embedder = embedder;
        debugPrint('GemmaEmbeddingService: model loaded from cache!');
        _setState(const GemmaEmbeddingState(
          stage: GemmaEmbeddingStage.ready,
          message: 'EmbeddingGemma ready',
        ));
        return embedder;
      }

      // Not cached — download from HuggingFace
      _setState(const GemmaEmbeddingState(
        stage: GemmaEmbeddingStage.downloading,
        message: 'Downloading EmbeddingGemma model...',
        progress: 0,
      ));

      debugPrint('GemmaEmbeddingService: starting model download from HuggingFace...');
      final embedder = await GemmaEmbedderFactory.fromHuggingFace(
        manager: _modelManager,
        onnxFile: 'onnx/model_q4.onnx',
        onProgress: (file, received, total) {
          if (total > 0) {
            final pct = (received / total * 100).round();
            if (pct % 5 == 0) {
              debugPrint(
                'GemmaEmbeddingService: download $pct% '
                '(${_formatBytes(received)} / ${_formatBytes(total)})',
              );
            }
            _setState(GemmaEmbeddingState(
              stage: GemmaEmbeddingStage.downloading,
              message: 'Downloading EmbeddingGemma... '
                  '${_formatBytes(received)} / ${_formatBytes(total)}',
              progress: received / total,
              receivedBytes: received,
              totalBytes: total,
            ));
          }
        },
      );

      _embedder = embedder;
      debugPrint('GemmaEmbeddingService: model loaded successfully!');
      _setState(const GemmaEmbeddingState(
        stage: GemmaEmbeddingStage.ready,
        message: 'EmbeddingGemma ready',
      ));
      return embedder;
    } catch (error, stackTrace) {
      debugPrint('GemmaEmbeddingService: failed to initialize: $error');
      debugPrint('GemmaEmbeddingService: stackTrace: $stackTrace');
      _setState(GemmaEmbeddingState(
        stage: GemmaEmbeddingStage.failed,
        message: 'EmbeddingGemma failed: $error',
      ));
      _initFuture = null;
      return null;
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

  void _setState(GemmaEmbeddingState next) {
    if (_state.stage == next.stage &&
        _state.message == next.message &&
        (_state.progress ?? -1) == (next.progress ?? -1)) {
      return;
    }
    _state = next;
    notifyListeners();
  }
}
