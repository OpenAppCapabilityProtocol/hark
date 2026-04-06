package com.oacp.hark

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.util.Log

class HarkSession(context: Context) : VoiceInteractionSession(context) {

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        Log.i(TAG, "Assistant session onShow")

        try {
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra(EXTRA_LAUNCHED_FROM_ASSIST, true)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch assistant activity", e)
        }
    }

    override fun onHide() {
        super.onHide()
        Log.i(TAG, "Assistant session onHide")
    }

    companion object {
        private const val TAG = "HarkSession"
        const val EXTRA_LAUNCHED_FROM_ASSIST = "com.oacp.LAUNCHED_FROM_ASSIST"
    }
}
