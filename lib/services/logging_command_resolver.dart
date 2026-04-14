import 'package:flutter/foundation.dart';

import '../models/assistant_action.dart';
import '../models/command_resolution.dart';
import 'command_resolver.dart';
import 'inference_logger.dart';

class LoggingCommandResolver implements CommandResolver {
  LoggingCommandResolver(
    this._delegate,
    this._logger, {
    required this.fallbackModelId,
  });

  final CommandResolver _delegate;
  final InferenceLogger _logger;

  /// Exposes the underlying resolver for callers that need the concrete
  /// type (e.g. to call `NluCommandResolver.preWarmEmbeddings`).
  CommandResolver get delegate => _delegate;

  /// Model id used when the delegate did not surface one on the result.
  final String fallbackModelId;

  @override
  void initialize() => _delegate.initialize();

  @override
  Future<CommandResolutionResult> resolveCommand(
    String transcript,
    List<AssistantAction> actions,
  ) async {
    final stopwatch = Stopwatch()..start();
    final result = await _delegate.resolveCommand(transcript, actions);
    stopwatch.stop();

    final metrics = result.metrics;
    // Grep-able metrics line for device verification without pulling log
    // files: `adb logcat | grep HarkMetrics`.
    debugPrint(
      'HarkMetrics: total=${stopwatch.elapsedMilliseconds}ms '
      'stage1=${metrics?['stage1_ms']}ms '
      'stage2=${metrics?['stage2_ms']}ms '
      'backend=${metrics?['stage2_backend']} '
      'success=${result.isSuccess}',
    );
    await _logger.log(InferenceLogEntry(
      timestamp: DateTime.now(),
      modelId: result.modelId ?? fallbackModelId,
      transcript: transcript,
      actionCount: actions.length,
      success: result.isSuccess,
      resolvedActionId: result.action?.actionId,
      resolvedSourceId: result.action?.sourceId,
      resolvedParameters: result.action?.parameters,
      errorType: result.errorType?.name,
      errorMessage: result.message,
      elapsedMs: stopwatch.elapsedMilliseconds,
      stage1Ms: metrics?['stage1_ms'] as int?,
      stage2Ms: metrics?['stage2_ms'] as int?,
      stage2Backend: metrics?['stage2_backend'] as String?,
    ));

    return result;
  }
}
