import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bench_types.dart';
import 'embedding_eval.dart';
import 'gold_loader.dart';
import 'slot_fill_eval.dart';

/// Orchestrates the full quant benchmark matrix.
///
/// For each model in [QuantMatrixConfig], iterates its quants in
/// priority order, loads the GGUF file (if found in the models
/// directory), runs the appropriate eval, measures cold-load +
/// single-inference time, checks the quality gate, and stops
/// escalating for that model as soon as a quant passes.
///
/// Emits progress events via [progressStream] for the UI.
class BenchRunner {
  BenchRunner({
    required this.modelsDir,
    required this.goldLoader,
  });

  final String modelsDir;
  final GoldLoader goldLoader;

  final _progressController = StreamController<String>.broadcast();
  Stream<String> get progressStream => _progressController.stream;

  void _log(String message) {
    // ignore: avoid_print
    print('[quant_bench] $message');
    _progressController.add(message);
  }

  Future<List<QuantRunResult>> runAll() async {
    _log('Loading gold sets and quant matrix...');
    final embeddingGold = await goldLoader.loadEmbeddingGold();
    final slotFillGold = await goldLoader.loadSlotFillGold();
    final matrix = await goldLoader.loadQuantMatrix();

    _log(
      'Loaded ${embeddingGold.cases.length} embedding cases, '
      '${slotFillGold.cases.length} slot-fill cases, '
      '${matrix.models.length} models to test.',
    );

    final results = <QuantRunResult>[];
    for (final model in matrix.models.values) {
      _log('');
      _log('=== ${model.displayName} (${model.kind.name}) ===');
      // Priority-ordered escalation: stop at first pass.
      for (final quant in model.quants) {
        final result = await _runOneQuant(
          model: model,
          quant: quant,
          embeddingGold: embeddingGold,
          slotFillGold: slotFillGold,
        );
        results.add(result);

        if (result.passedQualityGate) {
          _log(
            'PASS ${model.displayName} ${quant.tag} — stopping escalation.',
          );
          break;
        }
        if (result.error != null) {
          _log(
            'SKIP ${model.displayName} ${quant.tag} — ${result.error}. '
            'Trying next quant.',
          );
          continue;
        }
        _log(
          'FAIL ${model.displayName} ${quant.tag} — '
          'escalating to next quant.',
        );
      }
    }

    await _writeResults(results);
    _log('');
    _log('Benchmark complete. Results written to quant_bench_results.json');
    return results;
  }

  Future<QuantRunResult> _runOneQuant({
    required ModelConfig model,
    required QuantConfig quant,
    required EmbeddingGoldSet embeddingGold,
    required SlotFillGoldSet slotFillGold,
  }) async {
    final path = _resolveModelFile(quant);
    if (path == null) {
      return QuantRunResult(
        modelId: model.modelId,
        displayName: model.displayName,
        quantTag: quant.tag,
        modelPath: '',
        kind: model.kind,
        embedding: null,
        slotFill: null,
        perf: null,
        passedQualityGate: false,
        notes: const [],
        error: 'File not found in $modelsDir. Tried: '
            '${quant.filenameCandidates.join(", ")}',
      );
    }
    final fileSize = File(path).lengthSync();

    _log('--- ${model.displayName} ${quant.tag} (${quant.tag}) ---');
    _log('  Path: $path (${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB)');

    final engine = LlamaEngine(LlamaBackend());
    EmbeddingMetrics? embedding;
    SlotFillMetrics? slotFill;
    PerfMetrics? perf;
    final notes = <String>[];
    String? error;
    var passed = false;

    try {
      final loadSw = Stopwatch()..start();
      await engine.loadModel(
        path,
        modelParams: ModelParams(
          contextSize: model.contextSize ?? 0,
          preferredBackend: GpuBackend.auto,
          numberOfThreads: 0,
          numberOfThreadsBatch: 0,
        ),
      );
      loadSw.stop();
      _log('  Cold load: ${loadSw.elapsedMilliseconds}ms');

      final inferenceSw = Stopwatch()..start();
      if (model.kind == ModelKind.embedding) {
        // Time a single embed call as the "inference" metric.
        await engine.embed('warm up query', normalize: true);
        inferenceSw.stop();
        _log('  Single embed: ${inferenceSw.elapsedMilliseconds}ms');

        final eval = EmbeddingEvaluator(
          engine: engine,
          goldSet: embeddingGold,
          log: _log,
        );
        embedding = await eval.run();

        final gate = model.embeddingGate!;
        passed =
            embedding.top1Accuracy >= gate.top1AccuracyMin &&
            embedding.top3Recall >= gate.top3RecallMin &&
            embedding.disambiguationCoverage >= gate.disambiguationCoverageMin &&
            (!gate.exactMatchTop1MustAllPass ||
                embedding.exactMatchAllPassed);

        _log(
          '  Embedding: top1=${(embedding.top1Accuracy * 100).toStringAsFixed(0)}% '
          'top3=${(embedding.top3Recall * 100).toStringAsFixed(0)}% '
          'disamb=${(embedding.disambiguationCoverage * 100).toStringAsFixed(0)}% '
          'exact=${embedding.exactMatchTop1Correct}/${embedding.exactMatchTotal}',
        );
      } else {
        // Time a single short generation as the "inference" metric.
        var tokenCount = 0;
        await for (final chunk in engine.create(
          [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Reply with only the word OK.',
            ),
          ],
          enableThinking: false,
        )) {
          for (final c in chunk.choices) {
            if (c.delta.content != null) tokenCount += 1;
          }
          if (tokenCount > 16) break;
        }
        inferenceSw.stop();
        _log('  Single gen warmup: ${inferenceSw.elapsedMilliseconds}ms');

        final eval = SlotFillEvaluator(
          engine: engine,
          goldSet: slotFillGold,
          log: _log,
        );
        slotFill = await eval.run();

        final gate = model.slotFillGate!;
        passed =
            slotFill.jsonValidityRate >= gate.jsonValidityMin &&
            slotFill.exactMatchRate >= gate.exactMatchMin &&
            slotFill.typeCorrectRate >= gate.typeCorrectMin &&
            slotFill.hallucinationRate <= gate.hallucinationMax &&
            slotFill.requiredFieldsRate >= gate.requiredFieldsPopulatedMin;

        _log(
          '  Slot-fill: json=${(slotFill.jsonValidityRate * 100).toStringAsFixed(0)}% '
          'exact=${(slotFill.exactMatchRate * 100).toStringAsFixed(0)}% '
          'type=${(slotFill.typeCorrectRate * 100).toStringAsFixed(0)}% '
          'halluc=${(slotFill.hallucinationRate * 100).toStringAsFixed(0)}%',
        );
      }

      perf = PerfMetrics(
        coldLoadMs: loadSw.elapsedMilliseconds,
        singleInferenceMs: inferenceSw.elapsedMilliseconds,
        fileSizeBytes: fileSize,
      );
    } catch (e, st) {
      error = 'Exception: $e';
      _log('  ERROR: $e');
      _log('  $st');
    } finally {
      try {
        await engine.dispose();
      } catch (e) {
        notes.add('dispose error: $e');
      }
    }

    return QuantRunResult(
      modelId: model.modelId,
      displayName: model.displayName,
      quantTag: quant.tag,
      modelPath: path,
      kind: model.kind,
      embedding: embedding,
      slotFill: slotFill,
      perf: perf,
      passedQualityGate: passed,
      notes: notes,
      error: error,
    );
  }

  /// Checks each filename candidate in [quant] against the models
  /// directory. Returns the first existing path, or null if none found.
  ///
  /// Matching is case-insensitive so that community quantization
  /// repos with different capitalization conventions (e.g. admiralakber
  /// uses `embeddinggemma-300m-q4_k_m.gguf` all-lowercase while unsloth
  /// prefers `embeddinggemma-300M-Q4_K_M.gguf` camelCase) work without
  /// updating quant_matrix.json for every new source.
  String? _resolveModelFile(QuantConfig quant) {
    final dir = Directory(modelsDir);
    if (!dir.existsSync()) return null;
    final entries = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .toList(growable: false);
    final lookup = <String, String>{
      for (final f in entries) p.basename(f.path).toLowerCase(): f.path,
    };
    for (final name in quant.filenameCandidates) {
      final hit = lookup[name.toLowerCase()];
      if (hit != null) return hit;
    }
    return null;
  }

  Future<void> _writeResults(List<QuantRunResult> results) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(docsDir.path, 'quant_bench'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final outFile = File(p.join(outDir.path, 'results_$timestamp.json'));
    final payload = {
      'version': 1,
      'timestamp': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'models_dir': modelsDir,
      'results': results.map((r) => r.toJson()).toList(growable: false),
    };
    await outFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    _log('Results path: ${outFile.path}');
  }

  void dispose() {
    _progressController.close();
  }
}
