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

class InferenceLogger {
  Directory? _logDir;

  Future<Directory> _getLogDir() async {
    if (_logDir != null) return _logDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _logDir = Directory('${appDir.path}/inference_logs');
    if (!await _logDir!.exists()) {
      await _logDir!.create(recursive: true);
    }
    return _logDir!;
  }

  String _todayFileName() {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'inference_$date.jsonl';
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

  Future<List<FileSystemEntity>> getLogFiles() async {
    try {
      final dir = await _getLogDir();
      return dir.listSync()..sort((a, b) => b.path.compareTo(a.path));
    } catch (_) {
      return [];
    }
  }
}
