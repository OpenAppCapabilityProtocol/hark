import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../state/app_icon_provider.dart';
import '../../state/chat_state.dart';
import 'thinking_bubble.dart';

/// A single chat message rendered as a rounded bubble.
///
/// Layout and styling vary based on role and pending/error state:
/// - **User** messages hug the right edge in the primary accent color.
/// - **Assistant** messages hug the left edge in the secondary surface color.
///   When the message originated from a resolved OACP action, a small app
///   icon + app name header is shown above the text (Google Assistant style).
/// - **Pending assistant** messages render a [ThinkingBubble] (an animated
///   [FCircularProgress] loader) in place of text.
/// - **Pending user** messages get a subtle border to hint they are still
///   being updated (live transcript).
/// - **Error assistant** messages tint the bubble with the destructive color.
class ChatBubble extends ConsumerWidget {
  const ChatBubble({required this.message, super.key});

  final ChatMessage message;

  static const double _maxWidth = 320.0;
  static const double _cornerLarge = 18.0;
  static const double _cornerSmall = 4.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.theme.colors;
    final typography = context.theme.typography;

    final bool isUser = message.role == ChatRole.user;
    final bool isError = message.isError;
    final bool isPending = message.isPending;
    final bool hasAppAttribution =
        !isUser && message.sourcePackageName != null;

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

    final Border? border = (isUser && isPending)
        ? Border.all(
            color: colors.primary.withValues(alpha: 0.4),
            width: 1.0,
          )
        : null;

    // --- App attribution header (assistant messages from OACP actions) -------
    Widget? appHeader;
    if (hasAppAttribution) {
      final appInfo = ref.watch(appInfoProvider(message.sourcePackageName!));
      final iconBytes = appInfo.asData?.value?.icon;
      final appName = message.sourceAppName ?? message.sourcePackageName!;

      appHeader = Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox.square(
                dimension: 20,
                child: (iconBytes != null && iconBytes.isNotEmpty)
                    ? Image.memory(
                        iconBytes,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        cacheWidth: 48,
                        cacheHeight: 48,
                        errorBuilder: (_, _, _) => Icon(
                          FIcons.package,
                          size: 12,
                          color: foregroundColor.withValues(alpha: 0.6),
                        ),
                      )
                    : Icon(
                        FIcons.package,
                        size: 12,
                        color: foregroundColor.withValues(alpha: 0.6),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              appName,
              style: typography.xs.copyWith(
                color: foregroundColor.withValues(alpha: 0.75),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    // --- Role label (for messages without app attribution) -------------------
    Widget? roleLabel;
    if (!hasAppAttribution) {
      roleLabel = Text(
        isUser ? 'You' : 'Hark',
        style: typography.xs.copyWith(
          color: foregroundColor.withValues(alpha: 0.7),
          fontWeight: FontWeight.w600,
        ),
      );
    }

    // --- Body ---------------------------------------------------------------
    Widget body;
    if (!isUser && isPending) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: ThinkingBubble(),
      );
    } else {
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
                ?appHeader,
                if (roleLabel != null) ...[
                  roleLabel,
                  const SizedBox(height: 4),
                ],
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
