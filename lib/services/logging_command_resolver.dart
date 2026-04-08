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
    ));

    return result;
  }
}
