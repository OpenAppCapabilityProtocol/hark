import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:hark_platform/hark_platform.dart';

import 'screens/overlay_screen.dart';
import 'state/chat_state.dart';
import 'theme/hark_theme.dart';

/// Dart entrypoint for the overlay FlutterEngine.
///
/// This is a **thin UI shell** — no models, no STT, no TTS. All voice
/// processing happens on the main engine. State is pushed from the main
/// engine via [HarkOverlayFlutterApi.onStateUpdate].
@pragma('vm:entry-point')
Future<void> overlayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: OverlayApp()));
}

// ── Overlay display state ──────────────────────────────────────────

/// Lightweight state for the overlay display. Mirrors the main engine's
/// [ChatState] but only contains what the overlay needs to render.
@immutable
class OverlayDisplayState {
  const OverlayDisplayState({
    this.messages = const [],
    this.isListening = false,
    this.isThinking = false,
    this.isInitializing = false,
    this.statusText = 'Tap to speak',
    this.inputMode = InputMode.mic,
  });

  final List<ChatMessage> messages;
  final bool isListening;
  final bool isThinking;
  final bool isInitializing;
  final String statusText;
  final InputMode inputMode;

  bool get isEnabled => !isInitializing && !isThinking;

  static const empty = OverlayDisplayState();
}

// ── Overlay display notifier ───────────────────────────────────────

/// Receives state updates from the main engine and session lifecycle
/// events from native. The overlay screen watches this provider.
final overlayDisplayProvider =
    NotifierProvider<OverlayDisplayNotifier, OverlayDisplayState>(
  OverlayDisplayNotifier.new,
);

class OverlayDisplayNotifier extends Notifier<OverlayDisplayState>
    implements HarkOverlayFlutterApi {
  @override
  OverlayDisplayState build() {
    HarkOverlayFlutterApi.setUp(this);
    ref.onDispose(() => HarkOverlayFlutterApi.setUp(null));
    return const OverlayDisplayState();
  }

  @override
  void onNewSession(String sessionId) {
    debugPrint('OverlayDisplay: new session $sessionId');
    state = const OverlayDisplayState();
  }

  @override
  void onStateUpdate(OverlayStateMessage stateMsg) {
    state = OverlayDisplayState(
      messages: stateMsg.messages.map(_toMessage).toList(),
      isListening: stateMsg.isListening,
      isThinking: stateMsg.isThinking,
      isInitializing: stateMsg.isInitializing,
      statusText: stateMsg.statusText,
      inputMode: stateMsg.inputMode == 'keyboard'
          ? InputMode.keyboard
          : InputMode.mic,
    );
  }

  static ChatMessage _toMessage(OverlayChatMessage m) {
    return ChatMessage(
      id: m.id,
      role: m.role == 'user' ? ChatRole.user : ChatRole.assistant,
      text: m.text,
      isPending: m.isPending,
      isError: m.isError,
      metadata: m.metadata,
      sourceAppName: m.sourceAppName,
    );
  }
}

// ── Overlay app shell ──────────────────────────────────────────────

class OverlayApp extends ConsumerWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly initialize so the FlutterApi handler is registered.
    ref.watch(overlayDisplayProvider);

    final theme = buildHarkTheme();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      theme: theme.toApproximateMaterialTheme(),
      builder: (_, child) => FTheme(
        data: theme,
        child: child!,
      ),
      home: const OverlayScreen(),
    );
  }
}
