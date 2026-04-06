package com.oacp.hark

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionService

/**
 * Stub RecognitionService required by Android to qualify the app as a
 * digital assistant. Hark uses Flutter's speech_to_text plugin for actual
 * speech recognition — this service exists only to satisfy the manifest
 * validation in VoiceInteractionManagerService.
 */
class HarkRecognitionService : RecognitionService() {

    override fun onStartListening(intent: Intent?, callback: Callback?) {
        // Not used — speech recognition handled by Flutter speech_to_text
    }

    override fun onCancel(callback: Callback?) {}

    override fun onStopListening(callback: Callback?) {}
}
