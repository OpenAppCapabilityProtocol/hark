import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Bridges the native VoiceInteractionSession overlay with the Flutter
/// Dart code. The overlay sends commands (overlayShown, toggleListening,
/// overlayHidden) and receives state updates (status, transcript, result)
/// via a MethodChannel.
class OverlayBridge {
  OverlayBridge({
    required this.onOverlayShown,
    required this.onToggleListening,
    required this.onOverlayHidden,
  });

  static const _channel = MethodChannel('com.oacp.hark/overlay');

  final VoidCallback onOverlayShown;
  final VoidCallback onToggleListening;
  final VoidCallback onOverlayHidden;

  void initialize() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'overlayShown':
        onOverlayShown();
        return null;
      case 'toggleListening':
        onToggleListening();
        return null;
      case 'overlayHidden':
        onOverlayHidden();
        return null;
      default:
        throw PlatformException(
          code: 'UNIMPLEMENTED',
          message: 'Unknown overlay method: ${call.method}',
        );
    }
  }

  /// Update the overlay's status text.
  Future<void> updateStatus(String status) async {
    try {
      await _channel.invokeMethod('updateStatus', {'status': status});
    } on MissingPluginException {
      // Overlay not visible — ignore.
    }
  }

  /// Update the overlay's transcript display.
  Future<void> updateTranscript(String transcript) async {
    try {
      await _channel.invokeMethod('updateTranscript', {
        'transcript': transcript,
      });
    } on MissingPluginException {
      // Overlay not visible — ignore.
    }
  }

  /// Update the overlay's result text.
  Future<void> updateResult(String result) async {
    try {
      await _channel.invokeMethod('updateResult', {'result': result});
    } on MissingPluginException {
      // Overlay not visible — ignore.
    }
  }

  /// Dismiss the overlay from the Flutter side.
  Future<void> dismiss() async {
    try {
      await _channel.invokeMethod('dismiss', null);
    } on MissingPluginException {
      // Overlay not visible — ignore.
    }
  }
}
