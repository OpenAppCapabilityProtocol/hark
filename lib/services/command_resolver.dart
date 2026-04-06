import '../models/assistant_action.dart';
import '../models/command_resolution.dart';

abstract class CommandResolver {
  void initialize();

  Future<CommandResolutionResult> resolveCommand(
    String transcript,
    List<AssistantAction> actions,
  );
}
