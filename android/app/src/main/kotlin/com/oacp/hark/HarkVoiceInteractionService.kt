package com.oacp.hark

import android.service.voice.VoiceInteractionService
import android.util.Log

class HarkVoiceInteractionService : VoiceInteractionService() {

    override fun onReady() {
        super.onReady()
        Log.i(TAG, "HarkVoiceInteractionService is ready")
    }

    companion object {
        private const val TAG = "HarkVIS"
    }
}
