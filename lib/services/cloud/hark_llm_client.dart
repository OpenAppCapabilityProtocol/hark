import '../../models/assistant_action.dart';
import 'cloud_errors.dart';

/// Abstract port for cloud LLM stage-2 parameter extraction.
///
/// Each provider adapter (OpenAI/Azure/Gemini/Anthropic/Custom) implements
/// this. The shape is intentionally minimal — one method, one return
/// value — so adapters stay small and the resolver wiring (Slice 4) only
/// has to know about a single interface.
///
/// **Failure semantics** (must be honored by every adapter):
///
/// - Throw [CloudUnavailableError] on **recoverable** failures (network
///   error, 401, 429, malformed response, model returned non-JSON tool
///   args). The resolver in `CLOUD_PREFERRED` mode will fall back to the
///   on-device slot filler. In `CLOUD_ONLY` mode it surfaces as a hard
///   error to the user.
///
/// - Throw [CloudHardError] for **unrecoverable** failures the user
///   should fix (invalid base URL, deployment not found, schema
///   translation failure). The resolver does NOT fall back — the user
///   needs to update settings.
///
/// - Return `null` if the model produced output but the validated
///   parameter map is missing required fields (after running through
///   [SlotResultValidator]). The resolver maps this to its existing
///   `slot_filling_failed` failure mode — same as the local path.
///
/// - Return a `Map<String, dynamic>` on success. The map MUST already
///   be validated against `action.parameters` so the resolver does not
///   need to re-coerce types. Use [SlotResultValidator.validateMap]
///   inside the adapter before returning.
abstract class HarkLlmClient {
  /// Extract parameters for [action] from [transcript]. Returns the
  /// validated parameter map on success, `null` on schema-validation
  /// failure, throws [CloudUnavailableError] / [CloudHardError] on
  /// other failure modes.
  Future<Map<String, dynamic>?> extract({
    required String transcript,
    required AssistantAction action,
    Duration timeout,
  });
}
