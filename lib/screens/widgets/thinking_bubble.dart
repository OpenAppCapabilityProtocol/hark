import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// A small circular loading indicator rendered inside pending assistant
/// chat bubbles while the NLU pipeline is thinking.
///
/// Wraps [FCircularProgress.loader] at [FCircularProgressSizeVariant.sm] so
/// the indicator inherits forui's theme motion and icon styling.
class ThinkingBubble extends StatelessWidget {
  const ThinkingBubble({super.key});

  @override
  Widget build(BuildContext context) =>
      const FCircularProgress.loader(size: .sm);
}
