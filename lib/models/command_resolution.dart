import 'resolved_action.dart';

enum CommandResolutionErrorType {
  noMatch,
  invalidResponse,
  unavailable,
  unknown,
}

class CommandResolutionResult {
  final ResolvedAction? action;
  final CommandResolutionErrorType? errorType;
  final String? message;
  final String? modelId;

  /// Optional per-stage timing and backend metadata populated by the
  /// resolver. Threaded out to [LoggingCommandResolver] so we can compare
  /// local vs cloud stage-2 latency without scraping logs. Keys today:
  /// `stage1_ms`, `stage2_ms`, `stage2_backend`.
  final Map<String, dynamic>? metrics;

  const CommandResolutionResult._({
    this.action,
    this.errorType,
    this.message,
    this.modelId,
    this.metrics,
  });

  const CommandResolutionResult.success(
    ResolvedAction action, {
    String? modelId,
    Map<String, dynamic>? metrics,
  }) : this._(action: action, modelId: modelId, metrics: metrics);

  const CommandResolutionResult.failure(
    CommandResolutionErrorType errorType, {
    String? message,
    String? modelId,
    Map<String, dynamic>? metrics,
  }) : this._(
          errorType: errorType,
          message: message,
          modelId: modelId,
          metrics: metrics,
        );

  bool get isSuccess => action != null;
}
