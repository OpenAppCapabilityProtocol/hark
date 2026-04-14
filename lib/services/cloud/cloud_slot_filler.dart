import '../../models/assistant_action.dart';
import '../nlu_command_resolver.dart';
import 'cloud_errors.dart';
import 'hark_llm_client.dart';

/// Adapts a [HarkLlmClient] to the resolver's [SlotFillFn] contract.
///
/// Wraps the client's `extract()` call so the resolver receives a
/// [SlotFillOutcome] tagged with the right backend identifier
/// (`openai_compat`, `anthropic`, `cache`, etc.) for telemetry. The
/// underlying client retains its own typed-error semantics —
/// [CloudUnavailableError] / [CloudHardError] propagate through so the
/// resolver wiring (in `resolver_provider.dart`) can decide whether to
/// fall back to the local slot filler or surface a hard error.
class CloudSlotFiller {
  const CloudSlotFiller({
    required this.client,
    required this.backend,
  });

  final HarkLlmClient client;

  /// Stable backend identifier for telemetry (`openai_compat`,
  /// `anthropic`, etc.). The resolver writes this to the `stage2_backend`
  /// metric so we can compare cloud vs local latency in the inference log.
  final String backend;

  /// Run the cloud extraction. On success returns a [SlotFillOutcome]
  /// with `params` set (or null if the model returned a result that
  /// failed schema validation — equivalent to local `slot_filling_failed`).
  ///
  /// On any [CloudUnavailableError] / [CloudHardError] the exception
  /// propagates — the caller decides whether to fall back.
  Future<SlotFillOutcome> extract({
    required String transcript,
    required AssistantAction action,
  }) async {
    final params = await client.extract(
      transcript: transcript,
      action: action,
    );
    return SlotFillOutcome(params: params, backend: backend);
  }
}
