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
        var instance: HarkVoiceInteractionService? = null
            private set
    }
}
