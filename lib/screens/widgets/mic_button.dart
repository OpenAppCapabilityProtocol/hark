import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// Primary "tap to talk" control for the chat screen.
///
/// A large circular filled button rendered in the forui primary accent. When
/// [isListening] is true, a decorative ring pulses outward from beneath the
/// button. Tapping the button triggers a subtle scale-down press feedback.
/// When [enabled] is false the button is dimmed and taps are ignored.
class MicButton extends StatefulWidget {
  const MicButton({
    required this.isListening,
    required this.onTap,
    this.size = 80.0,
    this.enabled = true,
    super.key,
  });

  final bool isListening;
  final VoidCallback onTap;
  final double size;
  final bool enabled;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  late final Animation<double> _pulseOpacity;

  late final AnimationController _pressController;
  late final Animation<double> _pressScale;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    final pulseCurve =
        CurvedAnimation(parent: _pulseController, curve: Curves.easeOut);
    _pulseScale = Tween<double>(begin: 1.0, end: 1.4).animate(pulseCurve);
    _pulseOpacity = Tween<double>(begin: 0.6, end: 0.0).animate(pulseCurve);

    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      value: 0.0,
    );
    _pressScale = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );

    if (widget.isListening && widget.enabled) {
      _pulseController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldPulse = widget.isListening && widget.enabled;
    final wasPulsing = oldWidget.isListening && oldWidget.enabled;
    if (shouldPulse && !wasPulsing) {
      _pulseController.repeat();
    } else if (!shouldPulse && wasPulsing) {
      _pulseController.stop();
      _pulseController.value = 0.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    if (!widget.enabled) return;
    _pressController.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    if (!widget.enabled) return;
    _pressController.reverse();
  }

  void _handleTapCancel() {
    if (!widget.enabled) return;
    _pressController.reverse();
  }

  void _handleTap() {
    if (!widget.enabled) return;
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;

    final bool isActive = widget.enabled;
    final Color backgroundColor =
        isActive ? colors.primary : colors.muted;
    final Color foregroundColor =
        isActive ? colors.primaryForeground : colors.mutedForeground;

    final double size = widget.size;
    // Stack needs to be large enough to show the full pulsing ring (scale 1.4).
    final double stackSize = size * 1.4;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: _handleTap,
      child: SizedBox(
        width: stackSize,
        height: stackSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Pulse ring — rendered first so it sits BELOW the button.
            if (widget.isListening && widget.enabled)
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  return Opacity(
                    opacity: _pulseOpacity.value,
                    child: Transform.scale(
                      scale: _pulseScale.value,
                      child: Container(
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.primary.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  );
                },
              ),
            // Pressable filled button.
            AnimatedBuilder(
              animation: _pressController,
              builder: (context, child) {
                return Transform.scale(
                  scale: _pressScale.value,
                  child: child,
                );
              },
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: backgroundColor,
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: colors.primary.withValues(alpha: 0.25),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Icon(
                    FIcons.mic,
                    size: size * 0.4,
                    color: foregroundColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
