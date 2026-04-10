import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:hark_platform/hark_platform.dart';

import '../state/chat_notifier.dart';
import '../state/chat_state.dart';

/// Compact overlay panel shown when the assist gesture fires.
///
/// Renders a bottom sheet card with mic button, status text, transcript,
/// and result. Tapping the scrim area dismisses back to the home screen.
/// "Open full app" tells the native side to launch MainActivity.
class OverlayScreen extends ConsumerStatefulWidget {
  const OverlayScreen({super.key});

  @override
  ConsumerState<OverlayScreen> createState() => _OverlayScreenState();
}

class _OverlayScreenState extends ConsumerState<OverlayScreen> {
  final _overlayApi = HarkOverlayApi();

  void _dismiss() {
    final chatState = ref.read(chatProvider);
    if (chatState.isListening) {
      ref.read(chatProvider.notifier).cancelListening();
    }
    _overlayApi.dismiss();
  }

  void _openFullApp() {
    _overlayApi.openFullApp();
  }

  void _onMicTap() {
    ref.read(chatProvider.notifier).onMicPressed();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    // Find the latest user pending message (live transcript).
    final liveTranscript = chat.messages
        .where((m) => m.role == ChatRole.user && m.isPending)
        .lastOrNull
        ?.text;

    // Find the latest assistant message (result).
    final lastResult = chat.messages
        .where((m) => m.role == ChatRole.assistant && !m.isPending)
        .lastOrNull
        ?.text;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // Scrim area — tap to dismiss
          Expanded(
            child: GestureDetector(
              onTap: _dismiss,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // Bottom sheet card
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag handle
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.mutedForeground.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Status
                    Text(
                      chat.statusText,
                      style: typography.sm.copyWith(
                        color: colors.mutedForeground,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    // Live transcript
                    if (liveTranscript != null &&
                        liveTranscript.isNotEmpty) ...[
                      Text(
                        '"$liveTranscript"',
                        style: typography.sm.copyWith(
                          color: colors.foreground,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                    ],
                    // Result
                    if (lastResult != null &&
                        lastResult.isNotEmpty &&
                        !chat.isListening) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          lastResult,
                          style: typography.sm.copyWith(
                            color: colors.foreground,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 8),
                    // Mic button
                    Material(
                      color: chat.isListening
                          ? colors.destructive
                          : colors.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        onTap: _onMicTap,
                        customBorder: const CircleBorder(),
                        child: SizedBox(
                          width: 64,
                          height: 64,
                          child: Icon(
                            chat.isListening ? Icons.stop : Icons.mic,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Open full app
                    FButton(
                      onPress: _openFullApp,
                      variant: FButtonVariant.ghost,
                      child: Text(
                        'Open full app',
                        style: typography.xs.copyWith(
                          color: colors.mutedForeground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
