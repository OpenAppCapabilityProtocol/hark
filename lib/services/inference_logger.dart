import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class InferenceLogEntry {
  final DateTime timestamp;
  final String modelId;
  final String transcript;
  final int actionCount;
  final bool success;
  final String? resolvedActionId;
  final String? resolvedSourceId;
  final Map<String, dynamic>? resolvedParameters;
  final String? errorType;
  final String? errorMessage;
  final int elapsedMs;

  const InferenceLogEntry({
    required this.timestamp,
    required this.modelId,
    required this.transcript,
    required this.actionCount,
    required this.success,
    this.resolvedActionId,
    this.resolvedSourceId,
    this.resolvedParameters,
    this.errorType,
    this.errorMessage,
    required this.elapsedMs,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'model_id': modelId,
        'transcript': transcript,
        'action_count': actionCount,
        'success': success,
        if (resolvedActionId != null) 'resolved_action_id': resolvedActionId,
        if (resolvedSourceId != null) 'resolved_source_id': resolvedSourceId,
        if (resolvedParameters != null)
          'resolved_parameters': resolvedParameters,
        if (errorType != null) 'error_type': errorType,
        if (errorMessage != null) 'error_message': errorMessage,
        'elapsed_ms': elapsedMs,
      };
}

/// A single phase of model loading, timed.
///
/// Written to `model_load_logs/load_<date>.jsonl` alongside the existing
/// inference logs, so we can diff cold/hot/warm timings across sessions
/// without scraping `flutter logs`.
class ModelLoadLogEntry {
  final DateTime timestamp;
  final String phase;
  final int elapsedMs;
  final Map<String, dynamic>? extra;

  const ModelLoadLogEntry({
    required this.timestamp,
    required this.phase,
    required this.elapsedMs,
    this.extra,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'phase': phase,
        'elapsed_ms': elapsedMs,
        if (extra != null) 'extra': extra,
      };
}

class InferenceLogger {
  Directory? _logDir;
  Directory? _loadLogDir;

  Future<Directory> _getLogDir() async {
    if (_logDir != null) return _logDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _logDir = Directory('${appDir.path}/inference_logs');
    if (!await _logDir!.exists()) {
      await _logDir!.create(recursive: true);
    }
    return _logDir!;
  }

  Future<Directory> _getLoadLogDir() async {
    if (_loadLogDir != null) return _loadLogDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _loadLogDir = Directory('${appDir.path}/model_load_logs');
    if (!await _loadLogDir!.exists()) {
      await _loadLogDir!.create(recursive: true);
    }
    return _loadLogDir!;
  }

  String _todayFileName() {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'inference_$date.jsonl';
  }

  String _todayLoadFileName() {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'load_$date.jsonl';
  }

  Future<void> log(InferenceLogEntry entry) async {
    try {
      final dir = await _getLogDir();
      final file = File('${dir.path}/${_todayFileName()}');
      final line = '${jsonEncode(entry.toJson())}\n';
      await file.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      debugPrint('InferenceLogger: Failed to write log: $e');
    }
  }

  /// Record a single timed phase of model loading.
  ///
  /// Fires both a `HarkLoadPerf: <phase> <ms>ms` line to `debugPrint` (so
  /// timings are grep-able in `flutter logs`) and an append to
  /// `model_load_logs/load_<date>.jsonl` (so timings survive the log
  /// buffer for later analysis). Safe to call from any isolate.
  Future<void> logModelLoad(
    String phase,
    int elapsedMs, {
    Map<String, dynamic>? extra,
  }) async {
    debugPrint('HarkLoadPerf: $phase ${elapsedMs}ms');
    try {
      final dir = await _getLoadLogDir();
      final file = File('${dir.path}/${_todayLoadFileName()}');
      final entry = ModelLoadLogEntry(
        timestamp: DateTime.now(),
        phase: phase,
        elapsedMs: elapsedMs,
        extra: extra,
      );
      final line = '${jsonEncode(entry.toJson())}\n';
      await file.writeAsString(line, mode: FileMode.append);
    } catch (e) {
      debugPrint('InferenceLogger: Failed to write load log: $e');
    }
  }

  Future<List<FileSystemEntity>> getLogFiles() async {
    try {
      final dir = await _getLogDir();
      return dir.listSync()..sort((a, b) => b.path.compareTo(a.path));
    } catch (_) {
      return [];
    }
  }

  Future<List<FileSystemEntity>> getLoadLogFiles() async {
    try {
      final dir = await _getLoadLogDir();
      return dir.listSync()..sort((a, b) => b.path.compareTo(a.path));
    } catch (_) {
      return [];
    }
  }
}
