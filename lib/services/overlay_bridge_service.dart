import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hark_platform/hark_platform.dart';

import '../state/chat_notifier.dart';
import '../state/chat_state.dart';

/// Bridges the main engine's [ChatNotifier] with the overlay engine via
/// native Pigeon relay.
///
/// **Inbound:** Receives overlay actions (mic pressed, cancel, open/dismiss)
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
    debugPrint('OverlayBridge: overlay opened');
    state = true;
    // Push current state immediately so overlay has content.
    _pushState(ref.read(chatProvider));
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
          sourceAppName: m.sourceAppName,
        );
      }).toList();

      _bridgeApi.pushStateToOverlay(OverlayStateMessage(
        messages: messages,
        isListening: chat.isListening,
        isThinking: chat.isThinking,
        statusText: chat.statusText,
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
