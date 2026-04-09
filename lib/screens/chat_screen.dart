import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../router/hark_router.dart';
import '../state/chat_notifier.dart';
import '../state/chat_state.dart';
import '../state/embedding_notifier.dart';
import '../state/init_notifier.dart';
import '../state/slot_filling_notifier.dart';
import 'widgets/chat_bubble.dart';
import 'widgets/composer_bar.dart';

/// Main conversation surface — replaces the old AssistantScreen.
///
/// All business logic lives in [ChatNotifier]. This widget is purely
/// presentational: it watches [chatProvider] and renders bubbles + the
/// composer bar, routing user actions back to the notifier.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final init = ref.watch(initProvider);
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    if (chat.messages.length != _lastMessageCount) {
      _lastMessageCount = chat.messages.length;
      _autoScroll();
    }

    return FScaffold(
      header: FHeader(
        title: const Text('Hark'),
        suffixes: [
          FButton.icon(
            onPress: () => context.push(HarkRoutes.actions),
            variant: FButtonVariant.ghost,
            child: const Icon(FIcons.listChecks),
          ),
        ],
      ),
      child: Column(
        children: [
          if (!chat.isDefaultAssistant)
            _DefaultAssistantBanner(
              onOpenSettings: () =>
                  ref.read(chatProvider.notifier).openAssistantSettings(),
            ),
          if (chat.initError != null)
            _InitErrorBanner(message: chat.initError!),
          Expanded(
            child: chat.messages.isEmpty
                ? _EmptyState(init: init, chat: chat)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: chat.messages.length,
                    itemBuilder: (_, index) =>
                        ChatBubble(message: chat.messages[index]),
                  ),
          ),
          // Show the status line whenever any pipeline state is active —
          // mic listening, NLU thinking, speaking/executing, or during
          // initial model load. Previously this was gated on `!init.isReady`
          // which hid the line exactly when it mattered most (during
          // _processTranscript after models are loaded).
          if (chat.statusText.isNotEmpty &&
              (chat.isThinking ||
                  chat.isListening ||
                  !init.isReady ||
                  chat.isInitializing))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                chat.statusText,
                style: typography.xs.copyWith(color: colors.mutedForeground),
                textAlign: TextAlign.center,
              ),
            ),
          ComposerBar(
            inputMode: chat.inputMode,
            isListening: chat.isListening,
            // Mic stays disabled until the notifier has finished its own
            // init (TTS/STT/MethodChannel) AND the model layer is ready
            // AND no resolution is in flight AND init hasn't errored.
            isEnabled: init.isReady &&
                !chat.isInitializing &&
                !chat.isThinking &&
                chat.initError == null,
            onMicPressed: () =>
                ref.read(chatProvider.notifier).onMicPressed(),
            onSendPressed: (text) =>
                ref.read(chatProvider.notifier).onTextSubmitted(text),
            onModeToggle: () {
              final current = ref.read(chatProvider).inputMode;
              ref.read(chatProvider.notifier).setInputMode(
                    current == InputMode.mic
                        ? InputMode.keyboard
                        : InputMode.mic,
                  );
            },
          ),
        ],
      ),
    );
  }
}

class _InitErrorBanner extends StatelessWidget {
  const _InitErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: colors.destructive.withValues(alpha: 0.14),
        border: Border(
          bottom: BorderSide(
            color: colors.destructive.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            FIcons.triangleAlert,
            size: 16,
            color: colors.destructive,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: typography.xs.copyWith(color: colors.destructive),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.init, required this.chat});

  final InitState init;
  final ChatState chat;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    final embeddingReady = init.embedding.isReady;
    final slotReady = init.slotFilling.isReady;
    final showProgress =
        !embeddingReady || !slotReady || chat.isInitializing;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/hark_logo.png',
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                  cacheWidth: 168,
                  cacheHeight: 168,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Tap the mic to talk',
              textAlign: TextAlign.center,
              style: typography.lg.copyWith(
                color: colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try “pause music”, “increment counter by 5”, or “what time is it”.',
              textAlign: TextAlign.center,
              style: typography.sm.copyWith(color: colors.mutedForeground),
            ),
            if (showProgress) ...[
              const SizedBox(height: 28),
              Text(
                _idleHint(init, chat),
                textAlign: TextAlign.center,
                style: typography.xs.copyWith(color: colors.mutedForeground),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _idleHint(InitState init, ChatState chat) {
    if (init.embedding.stage == EmbeddingStage.failed) {
      return init.embedding.message;
    }
    if (init.slotFilling.stage == SlotFillingStage.failed) {
      return init.slotFilling.message;
    }
    if (init.embedding.isBusy) {
      return init.embedding.message;
    }
    if (init.slotFilling.isBusy) {
      return init.slotFilling.message;
    }
    if (chat.isInitializing) {
      return 'Getting the mic ready…';
    }
    return 'Still warming up…';
  }
}

class _DefaultAssistantBanner extends StatelessWidget {
  const _DefaultAssistantBanner({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(
          bottom: BorderSide(color: colors.border),
        ),
      ),
      child: Row(
        children: [
          Icon(
            FIcons.info,
            size: 14,
            color: colors.mutedForeground,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Set Hark as your default assistant to use long-press Home.',
              style:
                  typography.xs.copyWith(color: colors.mutedForeground),
            ),
          ),
          const SizedBox(width: 8),
          FButton(
            onPress: onOpenSettings,
            variant: FButtonVariant.ghost,
            child: Text(
              'Open settings',
              style:
                  typography.xs.copyWith(color: colors.foreground),
            ),
          ),
        ],
      ),
    );
  }
}
