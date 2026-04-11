import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hark_platform/hark_platform.dart';

import '../state/chat_notifier.dart';
import '../state/chat_state.dart';

/// Bridges the main engine's [ChatNotifier] with the overlay engine via
/// native Pigeon relay.
///
/// **Inbound:** Receives overlay actions (mic pressed, cancel, text, mode)
/// from native via [HarkMainFlutterApi] and delegates to [ChatNotifier].
///
/// **Outbound:** Watches [chatProvider] and pushes state updates to native
/// via [HarkOverlayBridgeApi] whenever the chat state changes while the
/// overlay is active.
class OverlayBridgeService extends Notifier<bool>
    implements HarkMainFlutterApi {
  final _bridgeApi = HarkOverlayBridgeApi();

  @override
  bool build() {
    HarkMainFlutterApi.setUp(this);
    ref.onDispose(() => HarkMainFlutterApi.setUp(null));

    // When overlay is active, watch chat state and push updates.
    // TODO: Consider adding a ~50ms debounce timer here. During STT
    // streaming, partials arrive at 10-20Hz and each triggers a full
    // state serialize + Pigeon channel send. Not a problem observed
    // in testing but worth revisiting under load.
    ref.listen<ChatState>(chatProvider, (_, next) {
      if (state) {
        _pushState(next);
      }
    });

    return false; // overlay not active initially
  }

  // ── HarkMainFlutterApi: native relays overlay actions to us ────

  @override
  void onOverlayOpened() {
    final wasActive = state;
    debugPrint('OverlayBridge: overlay opened (wasActive=$wasActive)');
    state = true;

    if (!wasActive) {
      // Genuinely new session — clear previous conversation.
      ref.read(chatProvider.notifier).clearSession();
    }

    // Push current state so overlay has content.
    _pushState(ref.read(chatProvider));

    // Auto-start mic if not already listening or thinking.
    final chat = ref.read(chatProvider);
    if (!chat.isListening && !chat.isThinking) {
      ref.read(chatProvider.notifier).onMicPressed();
    }
  }

  @override
  void onOverlayDismissed() {
    debugPrint('OverlayBridge: overlay dismissed');
    state = false;
  }

  @override
  void onOverlayMicPressed() {
    debugPrint('OverlayBridge: mic pressed from overlay');
    ref.read(chatProvider.notifier).onMicPressed();
  }

  @override
  void onOverlayCancelListening() {
    debugPrint('OverlayBridge: cancel listening from overlay');
    ref.read(chatProvider.notifier).cancelListening();
  }

  @override
  void onOverlayTextSubmitted(String text) {
    debugPrint('OverlayBridge: text submitted from overlay: $text');
    ref.read(chatProvider.notifier).onTextSubmitted(text);
  }

  @override
  void onOverlayInputModeChanged(String mode) {
    debugPrint('OverlayBridge: input mode changed to $mode');
    final inputMode = mode == 'keyboard' ? InputMode.keyboard : InputMode.mic;
    ref.read(chatProvider.notifier).setInputMode(inputMode);
    // Auto-start listening when switching back to mic.
    if (inputMode == InputMode.mic) {
      ref.read(chatProvider.notifier).onMicPressed();
    }
  }

  // ── Push state to overlay engine via native relay ──────────────

  void _pushState(ChatState chat) {
    try {
      final messages = chat.messages.map((m) {
        return OverlayChatMessage(
          id: m.id,
          role: m.role == ChatRole.user ? 'user' : 'assistant',
          text: m.text,
          isPending: m.isPending,
          isError: m.isError,
          metadata: m.metadata,
          sourcePackageName: m.sourcePackageName,
          sourceAppName: m.sourceAppName,
        );
      }).toList();

      _bridgeApi.pushStateToOverlay(OverlayStateMessage(
        messages: messages,
        isListening: chat.isListening,
        isThinking: chat.isThinking,
        isInitializing: chat.isInitializing,
        statusText: chat.statusText,
        inputMode: chat.inputMode == InputMode.keyboard ? 'keyboard' : 'mic',
      ));
    } catch (e) {
      debugPrint('OverlayBridge: push failed: $e');
    }
  }
}

/// Provider that manages the overlay bridge on the main engine.
/// Must be eagerly watched from [HarkApp] so the FlutterApi handler
/// is registered before the overlay opens.
final overlayBridgeProvider = NotifierProvider<OverlayBridgeService, bool>(
  OverlayBridgeService.new,
);
