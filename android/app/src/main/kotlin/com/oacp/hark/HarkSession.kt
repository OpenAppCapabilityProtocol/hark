package com.oacp.hark

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.util.Log

/**
 * VoiceInteractionSession that launches [OverlayActivity].
 *
 * When the assist gesture fires, Android creates this session. We launch
 * the dedicated [OverlayActivity] which hosts the overlay Flutter UI on
 * its own engine.
 */
class HarkSession(context: Context) : VoiceInteractionSession(context) {

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        Log.i(TAG, "Assistant session onShow — launching OverlayActivity")

        try {
            val intent = Intent(context, OverlayActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch OverlayActivity", e)
        }

        // Close the session window so it doesn't sit on top of
        // OverlayActivity and intercept all touch events.
        finish()
    }

    override fun onHide() {
        super.onHide()
        Log.i(TAG, "Assistant session onHide")
    }

    companion object {
        private const val TAG = "HarkSession"
    }
}
