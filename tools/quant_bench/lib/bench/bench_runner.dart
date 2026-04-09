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
    final resolved = await _resolveModelFile(quant);
    if (resolved == null) {
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
    final path = resolved.path;
    final fileSize = resolved.sizeBytes;

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
  /// directory. Returns the first path that can be opened for reading,
  /// or null if none can.
  ///
  /// Three-pass strategy to work around Android 11+ scoped storage +
  /// SELinux restrictions on files placed under
  /// `/storage/emulated/0/Android/data/<pkg>/files/...` by `adb push`:
  ///
  /// 1. **Case-insensitive listing** (works on macOS / Linux / iOS and
  ///    any Android path where the files were created by the app
  ///    itself). Best-effort — may throw `Directory listing failed` on
  ///    Android when the files have the `media_rw_data_file` SELinux
  ///    label from the FUSE adb-push shim.
  /// 2. **Exact-match `open(O_RDONLY)` probe**. If listing throws or
  ///    didn't find a match, try to open each candidate path directly
  ///    via [File.open]. This uses the `open()` syscall, which has an
  ///    SELinux allow rule for `untrusted_app` on `media_rw_data_file`
  ///    even though `stat()` and `readdir()` do not. If `open()`
  ///    succeeds we know the file exists and is readable; we can even
  ///    get its size from the [RandomAccessFile] without ever calling
  ///    `stat`.
  /// 3. **Fallback return**: if neither works, return null and the
  ///    runner records the failure.
  Future<_ResolvedModelFile?> _resolveModelFile(QuantConfig quant) async {
    final dir = Directory(modelsDir);
    if (!dir.existsSync()) return null;

    // Pass 1: case-insensitive listing (for hosts where readdir works).
    try {
      final entries = dir
          .listSync(followLinks: false)
          .whereType<File>()
          .toList(growable: false);
      final lookup = <String, String>{
        for (final f in entries) p.basename(f.path).toLowerCase(): f.path,
      };
      for (final name in quant.filenameCandidates) {
        final hit = lookup[name.toLowerCase()];
        if (hit != null) {
          final size = File(hit).lengthSync();
          return _ResolvedModelFile(path: hit, sizeBytes: size);
        }
      }
    } on FileSystemException catch (e) {
      _log('  directory listing failed (${e.message}), '
          'falling back to open() probe');
    }

    // Pass 2: open() probe. Works on Android scoped storage where
    // stat()/readdir() are SELinux-blocked.
    for (final name in quant.filenameCandidates) {
      final candidate = p.join(modelsDir, name);
      try {
        final raf = await File(candidate).open(mode: FileMode.read);
        try {
          final size = await raf.length();
          return _ResolvedModelFile(path: candidate, sizeBytes: size);
        } finally {
          await raf.close();
        }
      } on FileSystemException catch (_) {
        // File not openable — try the next candidate.
      }
    }
    return null;
  }

  Future<void> _writeResults(List<QuantRunResult> results) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final payload = {
      'version': 1,
      'timestamp': DateTime.now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'models_dir': modelsDir,
      'results': results.map((r) => r.toJson()).toList(growable: false),
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(payload);

    // Always write to internal app documents (for macOS where
    // external storage doesn't exist and documents is easily
    // accessible).
    final docsDir = await getApplicationDocumentsDirectory();
    final docsOutDir = Directory(p.join(docsDir.path, 'quant_bench'));
    if (!docsOutDir.existsSync()) docsOutDir.createSync(recursive: true);
    final docsFile = File(
      p.join(docsOutDir.path, 'results_$timestamp.json'),
    );
    await docsFile.writeAsString(jsonStr);
    _log('Results path: ${docsFile.path}');

    // On Android, ALSO write to the app's scoped external storage
    // directory. Release APKs don't expose app_flutter internal docs
    // via `adb run-as`, but external storage under
    // /storage/emulated/0/Android/data/<pkg>/files/ is pullable via
    // plain `adb pull`. This makes results auto-fetchable from the
    // host without requiring the user to manually export from the UI.
    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final extOutDir = Directory(p.join(ext.path, 'quant_bench'));
          if (!extOutDir.existsSync()) extOutDir.createSync(recursive: true);
          final extFile = File(
            p.join(extOutDir.path, 'results_$timestamp.json'),
          );
          await extFile.writeAsString(jsonStr);
          // Also overwrite a fixed-name "latest.json" so `adb pull`
          // doesn't need to know the timestamp.
          final latestFile = File(p.join(extOutDir.path, 'latest.json'));
          await latestFile.writeAsString(jsonStr);
          _log('External results: ${extFile.path}');
          _log('Latest (pullable): ${latestFile.path}');
        }
      } catch (e) {
        _log('Warning: could not write external results: $e');
      }
    }
  }

  void dispose() {
    _progressController.close();
  }
}

/// Result of a successful model-file probe: the path to use and the
/// file size in bytes (obtained via a read-mode open, not a stat call).
class _ResolvedModelFile {
  const _ResolvedModelFile({required this.path, required this.sizeBytes});
  final String path;
  final int sizeBytes;
}
