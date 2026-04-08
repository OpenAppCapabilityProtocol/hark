import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../../state/chat_state.dart';
import 'mic_button.dart';

/// Bottom composer bar for the chat screen.
///
/// Cross-fades between two modes based on [inputMode]:
///
/// - [InputMode.mic]: a large [MicButton] is centered horizontally with a
///   smaller "keyboard" toggle button sitting to its right. Tapping the mic
///   invokes [onMicPressed]; tapping the keyboard toggle invokes
///   [onModeToggle].
///
/// - [InputMode.keyboard]: a small "back to mic" toggle on the left, an
///   expanded [FTextField] in the middle (hint "Type a command…"), and a
///   send button on the right. Submitting via the keyboard or tapping send
///   invokes [onSendPressed] with the current text and then clears the
///   field.
///
/// [isEnabled] gates the mic/text-field/send controls while models are
/// warming up. The keyboard-toggle button always stays enabled so the user
/// can pre-select text mode during warmup.
class ComposerBar extends StatefulWidget {
  const ComposerBar({
    required this.inputMode,
    required this.isListening,
    required this.isEnabled,
    required this.onMicPressed,
    required this.onSendPressed,
    required this.onModeToggle,
    super.key,
  });

  final InputMode inputMode;
  final bool isListening;
  final bool isEnabled;
  final VoidCallback onMicPressed;
  final void Function(String text) onSendPressed;
  final VoidCallback onModeToggle;

  @override
  State<ComposerBar> createState() => _ComposerBarState();
}

class _ComposerBarState extends State<ComposerBar> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _handleSubmit(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    widget.onSendPressed(trimmed);
    _textController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(
          top: BorderSide(color: colors.border),
        ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: widget.inputMode == InputMode.mic
            ? _buildMicMode(key: const ValueKey<String>('composer-mic'))
            : _buildKeyboardMode(
                key: const ValueKey<String>('composer-keyboard'),
              ),
      ),
    );
  }

  /// Mic mode: centered mic button with a keyboard toggle to its right.
  ///
  /// Uses a three-child row where the outer children are [Expanded]s so the
  /// middle [MicButton] stays visually centered. The right expanded slot
  /// hosts the keyboard-toggle button aligned to the left of its slot, so it
  /// sits just to the right of the mic.
  Widget _buildMicMode({required Key key}) {
    return Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Expanded(child: SizedBox.shrink()),
        MicButton(
          isListening: widget.isListening,
          enabled: widget.isEnabled,
          onTap: widget.onMicPressed,
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: FButton.icon(
                // Always enabled so user can pre-select text mode during
                // model warmup.
                onPress: widget.onModeToggle,
                child: const Icon(FIcons.keyboard),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Keyboard mode: [mic-toggle] [text field] [send].
  Widget _buildKeyboardMode({required Key key}) {
    return Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Back-to-mic toggle. Always enabled.
        FButton.icon(
          onPress: widget.onModeToggle,
          child: const Icon(FIcons.mic),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FTextField(
            control: FTextFieldControl.managed(controller: _textController),
            hint: 'Type a command…',
            textInputAction: TextInputAction.send,
            enabled: widget.isEnabled,
            onSubmit: _handleSubmit,
          ),
        ),
        const SizedBox(width: 8),
        FButton.icon(
          onPress: widget.isEnabled
              ? () => _handleSubmit(_textController.text)
              : null,
          child: const Icon(FIcons.send),
        ),
      ],
    );
  }
}
