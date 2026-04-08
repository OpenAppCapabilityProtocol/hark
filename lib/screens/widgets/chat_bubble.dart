import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../../state/chat_state.dart';
import 'thinking_bubble.dart';

/// A single chat message rendered as a rounded bubble.
///
/// Layout and styling vary based on role and pending/error state:
/// - **User** messages hug the right edge in the primary accent color.
/// - **Assistant** messages hug the left edge in the secondary surface color.
/// - **Pending assistant** messages render a [ThinkingBubble] in place of text.
/// - **Pending user** messages get a subtle border to hint they are still
///   being updated (live transcript).
/// - **Error assistant** messages tint the bubble with the destructive color.
///
/// This widget is purely presentational — it takes a [ChatMessage] and paints
/// it. No state, no business logic, no providers.
class ChatBubble extends StatelessWidget {
  const ChatBubble({required this.message, super.key});

  final ChatMessage message;

  static const double _maxWidth = 320.0;
  static const double _cornerLarge = 18.0;
  static const double _cornerSmall = 4.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    final bool isUser = message.role == ChatRole.user;
    final bool isError = message.isError;
    final bool isPending = message.isPending;

    // --- Colors -------------------------------------------------------------
    final Color backgroundColor;
    final Color foregroundColor;
    if (isUser) {
      backgroundColor = colors.primary;
      foregroundColor = colors.primaryForeground;
    } else if (isError) {
      backgroundColor = colors.destructive.withValues(alpha: 0.15);
      foregroundColor = colors.destructive;
    } else {
      backgroundColor = colors.secondary;
      foregroundColor = colors.secondaryForeground;
    }

    // --- Shape --------------------------------------------------------------
    // Flat corner points toward the sender: bottom-right for user, bottom-left
    // for assistant. The other three corners are rounded.
    final BorderRadius borderRadius = isUser
        ? const BorderRadius.only(
            topLeft: Radius.circular(_cornerLarge),
            topRight: Radius.circular(_cornerLarge),
            bottomLeft: Radius.circular(_cornerLarge),
            bottomRight: Radius.circular(_cornerSmall),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(_cornerLarge),
            topRight: Radius.circular(_cornerLarge),
            bottomLeft: Radius.circular(_cornerSmall),
            bottomRight: Radius.circular(_cornerLarge),
          );

    // Subtle border for pending *user* messages (live transcript hint).
    final Border? border = (isUser && isPending)
        ? Border.all(
            color: colors.primary.withValues(alpha: 0.4),
            width: 1.0,
          )
        : null;

    // --- Role label ---------------------------------------------------------
    final String roleLabel = isUser ? 'You' : 'Hark';
    final TextStyle roleLabelStyle = typography.xs.copyWith(
      color: foregroundColor.withValues(alpha: 0.7),
      fontWeight: FontWeight.w600,
    );

    // --- Body ---------------------------------------------------------------
    Widget body;
    if (!isUser && isPending) {
      // Assistant is thinking — render animated dots.
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ThinkingBubble(color: foregroundColor),
      );
    } else {
      // Normal text rendering. For an empty pending user bubble we show a
      // dim ellipsis placeholder so the bubble is visible.
      final bool showPlaceholder = isUser && isPending && message.text.isEmpty;
      final String bodyText = showPlaceholder ? '…' : message.text;
      final TextStyle bodyStyle = typography.sm.copyWith(
        color: showPlaceholder
            ? foregroundColor.withValues(alpha: 0.5)
            : foregroundColor,
      );
      body = Text(bodyText, style: bodyStyle);
    }

    // --- Metadata -----------------------------------------------------------
    final Widget? metadataBlock = message.metadata == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              message.metadata!,
              style: typography.xs2.copyWith(
                color: foregroundColor.withValues(alpha: 0.6),
              ),
            ),
          );

    // --- Assemble -----------------------------------------------------------
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: borderRadius,
              border: border,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(roleLabel, style: roleLabelStyle),
                const SizedBox(height: 4),
                body,
                ?metadataBlock,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
