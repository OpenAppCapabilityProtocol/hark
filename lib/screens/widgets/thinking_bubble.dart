import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// A circular loading indicator rendered inside pending assistant chat
/// bubbles while the NLU pipeline is thinking.
///
/// Wraps [FCircularProgress.loader] at [FCircularProgressSizeVariant.md] so
/// the indicator is comfortably visible against the chat bubble background
/// and inherits forui's theme motion and icon styling.
class ThinkingBubble extends StatelessWidget {
  const ThinkingBubble({super.key});

  @override
  Widget build(BuildContext context) =>
      const FCircularProgress.loader(size: .md);
}
