import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:flutter/foundation.dart';

class SttService {
  final SpeechToText _speechToText = SpeechToText();
  bool _isInitialized = false;
  Function()? _onDone;
  bool _doneFired = false;

  Future<bool> initialize() async {
    if (_isInitialized) return true;
    _isInitialized = await _speechToText.initialize(
      onError: (error) {
        debugPrint('STT Error: $error');
        if (error.permanent) {
          _fireDone();
        }
      },
      onStatus: (status) => debugPrint('STT Status: $status'),
    );
    return _isInitialized;
  }

  Future<void> startListening({
    required Function(String) onResult,
    required Function() onDone,
  }) async {
    if (!_isInitialized) {
      debugPrint('STT not initialized');
      return;
    }

    _onDone = onDone;
    _doneFired = false;

    await _speechToText.listen(
      localeId: 'en_US',
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 3),
      onResult: (SpeechRecognitionResult result) {
        onResult(result.recognizedWords);
        if (result.finalResult) {
          _fireDone();
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        onDevice: false,
        cancelOnError: true,
      ),
    );
  }

  void _fireDone() {
    if (_doneFired) return;
    _doneFired = true;
    final callback = _onDone;
    _onDone = null;
    callback?.call();
  }

  Future<void> stopListening() async {
    _onDone = null;
    _doneFired = true;
    if (_speechToText.isListening) {
      await _speechToText.stop();
    }
  }

  bool get isListening => _speechToText.isListening;
}
