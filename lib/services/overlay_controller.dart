import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chat_notifier.dart';
import '../state/chat_state.dart';
import 'overlay_bridge.dart';

/// Watches [ChatState] and forwards relevant updates to the native overlay
/// via [OverlayBridge]. Also handles overlay commands (show, toggle, hide)
/// by delegating to [ChatNotifier].
///
/// This keeps the overlay integration decoupled from ChatNotifier's internals.
class OverlayController {
  OverlayController(this._ref);

  final Ref _ref;
  OverlayBridge? _bridge;
  bool _overlayActive = false;
  ProviderSubscription<ChatState>? _chatSub;

  void initialize() {
    _bridge = OverlayBridge(
      onOverlayShown: _onOverlayShown,
      onToggleListening: _onToggleListening,
      onOverlayHidden: _onOverlayHidden,
    );
    _bridge!.initialize();
    debugPrint('OverlayController: initialized');
  }

  void dispose() {
    _chatSub?.close();
    _bridge?.dispose();
    _bridge = null;
    _overlayActive = false;
  }

  void _onOverlayShown() {
    debugPrint('OverlayController: overlay shown');
    _overlayActive = true;

    // Start watching chat state to forward updates to the overlay.
    _chatSub?.close();
    _chatSub = _ref.listen<ChatState>(chatProvider, (previous, next) {
      if (!_overlayActive) return;
      _syncToOverlay(previous, next);
    });

    // Trigger listening via the chat notifier.
    final notifier = _ref.read(chatProvider.notifier);
    notifier.onMicPressed();
  }

  void _onToggleListening() {
    if (!_overlayActive) return;
    _ref.read(chatProvider.notifier).onMicPressed();
  }

  void _onOverlayHidden() {
    debugPrint('OverlayController: overlay hidden');
    _overlayActive = false;
    _chatSub?.close();
    _chatSub = null;

    // Cancel any active listening.
    final chatState = _ref.read(chatProvider);
    if (chatState.isListening) {
      _ref.read(chatProvider.notifier).cancelListening();
    }
  }

  void _syncToOverlay(ChatState? previous, ChatState next) {
    final bridge = _bridge;
    if (bridge == null) return;

    // Forward status text changes.
    if (previous?.statusText != next.statusText) {
      unawaited(bridge.updateStatus(next.statusText));
    }

    // Forward the latest user message text (transcript) when listening.
    if (next.isListening && next.messages.isNotEmpty) {
      final lastUserMsg = next.messages.lastWhere(
        (m) => m.role == ChatRole.user && m.isPending,
        orElse: () => const ChatMessage(id: '', role: ChatRole.user, text: ''),
      );
      if (lastUserMsg.text.isNotEmpty) {
        unawaited(bridge.updateTranscript(lastUserMsg.text));
      }
    }

    // Forward the latest assistant message (result).
    if (next.messages.isNotEmpty) {
      final lastAssistant = next.messages.lastWhere(
        (m) => m.role == ChatRole.assistant && !m.isPending,
        orElse: () =>
            const ChatMessage(id: '', role: ChatRole.assistant, text: ''),
      );
      if (lastAssistant.text.isNotEmpty &&
          (previous == null ||
              !previous.messages.any(
                (m) => m.id == lastAssistant.id && m.text == lastAssistant.text,
              ))) {
        unawaited(bridge.updateResult(lastAssistant.text));
      }
    }
  }
}

final overlayControllerProvider = Provider<OverlayController>((ref) {
  final controller = OverlayController(ref);
  controller.initialize();
  ref.onDispose(controller.dispose);
  return controller;
});
