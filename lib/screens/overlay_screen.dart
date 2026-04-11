import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:hark_platform/hark_platform.dart';

import '../overlay_main.dart';
import 'widgets/chat_bubble.dart';

/// Compact overlay panel shown when the assist gesture fires.
///
/// This is a **thin UI shell** — it renders chat bubbles from state pushed
/// by the main engine. User actions (mic tap, dismiss) are relayed to the
/// main engine via [HarkOverlayApi].
class OverlayScreen extends ConsumerStatefulWidget {
  const OverlayScreen({super.key});

  @override
  ConsumerState<OverlayScreen> createState() => _OverlayScreenState();
}

class _OverlayScreenState extends ConsumerState<OverlayScreen> {
  final _overlayApi = HarkOverlayApi();
  final _scrollController = ScrollController();

  void _dismiss() {
    _overlayApi.dismiss();
  }

  void _openFullApp() {
    _overlayApi.openFullApp();
  }

  void _onMicTap() {
    final display = ref.read(overlayDisplayProvider);
    if (display.isListening) {
      _overlayApi.cancelListening();
    } else {
      _overlayApi.micPressed();
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final display = ref.watch(overlayDisplayProvider);
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    // Auto-scroll when messages change.
    ref.listen(
      overlayDisplayProvider.select((s) => s.messages.length),
      (_, _) => _scrollToBottom(),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // Scrim area — tap to dismiss.
          Expanded(
            child: GestureDetector(
              onTap: _dismiss,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // Bottom sheet card.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.65,
            ),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag handle.
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 12),
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color:
                              colors.mutedForeground.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Status text.
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        display.statusText,
                        style: typography.sm.copyWith(
                          color: colors.mutedForeground,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    // Chat messages.
                    if (display.messages.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Flexible(
                        child: ListView.builder(
                          controller: _scrollController,
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: display.messages.length,
                          itemBuilder: (_, index) {
                            return ChatBubble(
                              message: display.messages[index],
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    // Mic button.
                    Material(
                      color: display.isListening
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
                            display.isListening ? Icons.stop : Icons.mic,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Open full app.
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
                    const SizedBox(height: 8),
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
