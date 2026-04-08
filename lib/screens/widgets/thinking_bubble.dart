import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// A small three-dot pulsing indicator rendered inside pending assistant
/// chat bubbles while the NLU pipeline is thinking.
///
/// Each dot scales between 0.6 and 1.0 and fades between 0.4 and 1.0 in
/// sequence, offset by 180ms. The full loop is 1200ms.
class ThinkingBubble extends StatefulWidget {
  const ThinkingBubble({this.color, this.dotSize = 6.0, super.key});

  final Color? color;
  final double dotSize;

  @override
  State<ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // Each dot occupies a slice of the 1200ms loop, starting at 0, 180, 360ms
  // and ending 540ms later (0.45 of the loop). This gives each dot enough
  // time to scale up and back down, with visible overlap between dots.
  static const double _loopMs = 1200.0;
  static const double _dotSpanMs = 540.0;
  static const List<double> _dotStartsMs = <double>[0.0, 180.0, 360.0];

  late final List<Animation<double>> _dotProgress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _loopMs ~/ 1),
    )..repeat();

    _dotProgress = _dotStartsMs.map((startMs) {
      final double begin = startMs / _loopMs;
      final double end = (startMs + _dotSpanMs) / _loopMs;
      return CurvedAnimation(
        parent: _controller,
        curve: Interval(begin, end, curve: Curves.easeInOut),
      );
    }).toList(growable: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color dotColor =
        widget.color ?? context.theme.colors.mutedForeground;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (int i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _buildDot(i, dotColor),
            ],
          ],
        );
      },
    );
  }

  Widget _buildDot(int index, Color color) {
    // Progress is a triangular wave: 0 -> 1 -> 0 across the interval, so we
    // map it through sin(pi * t) to get a smooth up/down curve.
    final double t = _dotProgress[index].value;
    // A symmetric 0..1..0 curve: 1 - |2t - 1|.
    final double wave = 1.0 - ((2.0 * t) - 1.0).abs();

    final double scale = 0.6 + (0.4 * wave); // 0.6 -> 1.0 -> 0.6
    final double opacity = 0.4 + (0.6 * wave); // 0.4 -> 1.0 -> 0.4

    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: widget.dotSize,
          height: widget.dotSize,
          decoration: ShapeDecoration(
            color: color,
            shape: const CircleBorder(),
          ),
        ),
      ),
    );
  }
}
