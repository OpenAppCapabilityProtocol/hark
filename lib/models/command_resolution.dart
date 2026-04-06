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

  const CommandResolutionResult._({
    this.action,
    this.errorType,
    this.message,
    this.modelId,
  });

  const CommandResolutionResult.success(ResolvedAction action, {String? modelId})
    : this._(action: action, modelId: modelId);

  const CommandResolutionResult.failure(
    CommandResolutionErrorType errorType, {
    String? message,
    String? modelId,
  }) : this._(errorType: errorType, message: message, modelId: modelId);

  bool get isSuccess => action != null;
}
