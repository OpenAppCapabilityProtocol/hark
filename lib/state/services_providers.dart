import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/capability_help_service.dart';
import '../services/inference_logger.dart';
import '../services/oacp_result_service.dart';
import '../services/stt_service.dart';
import '../services/tts_service.dart';

/// Speech-to-text service.
///
/// [SttService] has an async `initialize()` step that must be awaited before
/// use, but it is not wired here: callers are expected to await it from a
/// widget/notifier after reading the provider. A plain [Provider] is the
/// correct wrapper because the service itself is a stateless singleton and
/// its async init has side effects (mic permission) that should not run at
/// provider construction time.
final sttServiceProvider = Provider<SttService>((ref) {
  return SttService();
});

/// Text-to-speech service.
///
/// Like [sttServiceProvider], [TtsService] has an async `initialize()` that
/// callers must await before invoking `speak()`. Exposing the raw service via
/// a plain [Provider] keeps lifetime management in caller code.
final ttsServiceProvider = Provider<TtsService>((ref) {
  return TtsService();
});

/// Writes inference telemetry as JSONL files under the app documents dir.
final inferenceLoggerProvider = Provider<InferenceLogger>((ref) {
  return InferenceLogger();
});

/// Receives OACP capability results from the host Android side.
final oacpResultServiceProvider = Provider<OacpResultService>((ref) {
  return OacpResultService();
});

/// Resolves capability help queries ("what can you do in X?") against the
/// currently loaded action catalog.
final capabilityHelpServiceProvider = Provider<CapabilityHelpService>((ref) {
  return CapabilityHelpService();
});
