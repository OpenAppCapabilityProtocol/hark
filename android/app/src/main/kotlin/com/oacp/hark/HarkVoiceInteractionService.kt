package com.oacp.hark

import android.service.voice.VoiceInteractionService
import android.util.Log

class HarkVoiceInteractionService : VoiceInteractionService() {

    override fun onReady() {
        super.onReady()
        instance = this
        Log.i(TAG, "HarkVoiceInteractionService is ready")
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "HarkVIS"

        /** Live reference used by [HarkApplication.onWakeWordDetected] to launch the overlay. */
        // TODO: mark @Volatile — onDestroy/onReady can race a wake word detection
        // reading `instance` from the service thread. Very unlikely in practice
        // but cheap to harden.
        var instance: HarkVoiceInteractionService? = null
            private set
    }
}
