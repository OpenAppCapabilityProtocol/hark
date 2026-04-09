import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'bench/bench_runner.dart';
import 'bench/bench_types.dart';
import 'bench/gold_loader.dart';

void main() {
  runApp(const QuantBenchApp());
}

class QuantBenchApp extends StatelessWidget {
  const QuantBenchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hark quant_bench',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BenchHomePage(),
    );
  }
}

class BenchHomePage extends StatefulWidget {
  const BenchHomePage({super.key});

  @override
  State<BenchHomePage> createState() => _BenchHomePageState();
}

class _BenchHomePageState extends State<BenchHomePage> {
  final _log = <String>[];
  final _scrollController = ScrollController();
  final _modelsDirController = TextEditingController();

  bool _running = false;
  List<QuantRunResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _initDefaultModelsDir();
  }

  Future<void> _initDefaultModelsDir() async {
    // Platform-specific default. On macOS, ~/Downloads/hark-bench-models
    // is the sane default. On Android, we use the app's external storage
    // directory so adb push targets are easy to script.
    if (Platform.isAndroid) {
      final dir = await getExternalStorageDirectory();
      if (dir != null && mounted) {
        _modelsDirController.text = p.join(dir.path, 'hark-bench-models');
      }
    } else {
      final home = Platform.environment['HOME'] ?? '';
      if (mounted) {
        _modelsDirController.text =
            p.join(home, 'Downloads', 'hark-bench-models');
      }
    }
    if (mounted) setState(() {});
  }

  void _append(String line) {
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _runBenchmark() async {
    if (_running) return;
    final dir = _modelsDirController.text.trim();
    if (dir.isEmpty) {
      _append('! Models directory is empty. Fill it in first.');
      return;
    }
    if (!Directory(dir).existsSync()) {
      _append('! Models directory does not exist: $dir');
      _append('  Create it and drop the GGUF files in there:');
      _append('    embeddinggemma-300m-Q4_K_M.gguf');
      _append('    Qwen3-0.6B-Q4_K_M.gguf');
      _append('  (or the Q5_K_M / Q8_0 variants per quant_matrix.json)');
      return;
    }

    setState(() {
      _running = true;
      _results = const [];
      _log.clear();
    });

    final runner = BenchRunner(
      modelsDir: dir,
      goldLoader: const GoldLoader(),
    );
    final sub = runner.progressStream.listen(_append);
    try {
      final results = await runner.runAll();
      setState(() => _results = results);
    } catch (e, st) {
      _append('FATAL: $e');
      _append(st.toString());
    } finally {
      await sub.cancel();
      runner.dispose();
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hark quant_bench')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _modelsDirController,
              enabled: !_running,
              decoration: const InputDecoration(
                labelText: 'Models directory',
                helperText:
                    'Directory containing the GGUF files. Fill per quant_matrix.json filename_candidates.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _running ? null : _runBenchmark,
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(_running ? 'Running...' : 'Run benchmark'),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_results.length} result(s)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _log.length,
                itemBuilder: (context, i) => Text(
                  _log[i],
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            if (_results.isNotEmpty) ...[
              const Divider(),
              _ResultsSummary(results: _results),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultsSummary extends StatelessWidget {
  const _ResultsSummary({required this.results});

  final List<QuantRunResult> results;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      child: ListView.builder(
        itemCount: results.length,
        itemBuilder: (context, i) {
          final r = results[i];
          final passColor = r.passedQualityGate
              ? Colors.greenAccent
              : (r.error != null ? Colors.orangeAccent : Colors.redAccent);
          final label = r.passedQualityGate
              ? 'PASS'
              : (r.error != null ? 'SKIP' : 'FAIL');
          return ListTile(
            dense: true,
            leading: Chip(
              label: Text(label),
              backgroundColor: passColor.withValues(alpha: 0.2),
              side: BorderSide(color: passColor),
            ),
            title: Text('${r.displayName} — ${r.quantTag}'),
            subtitle: Text(_subtitleFor(r)),
          );
        },
      ),
    );
  }

  String _subtitleFor(QuantRunResult r) {
    if (r.error != null) return r.error!;
    final parts = <String>[];
    if (r.perf != null) {
      parts.add('load ${r.perf!.coldLoadMs}ms');
      parts.add(
        '${(r.perf!.fileSizeBytes / (1024 * 1024)).toStringAsFixed(0)}MB',
      );
    }
    if (r.embedding != null) {
      parts.add(
        'top1 ${(r.embedding!.top1Accuracy * 100).toStringAsFixed(0)}%',
      );
      parts.add(
        'top3 ${(r.embedding!.top3Recall * 100).toStringAsFixed(0)}%',
      );
    }
    if (r.slotFill != null) {
      parts.add(
        'json ${(r.slotFill!.jsonValidityRate * 100).toStringAsFixed(0)}%',
      );
      parts.add(
        'match ${(r.slotFill!.exactMatchRate * 100).toStringAsFixed(0)}%',
      );
    }
    return parts.join(' · ');
  }
}
