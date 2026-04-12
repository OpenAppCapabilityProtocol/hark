package com.oacp.hark

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.oacp.hark_platform.HarkPlatformPlugin
import com.oacp.hark_platform.WakeWordDetector

/**
 * Foreground service that keeps wake word detection alive and visible.
 *
 * The service owns a [WakeWordDetector] and shows a persistent notification
 * while listening. On detection it pauses the detector (releasing the mic
 * for STT) and delegates to [HarkApplication.onWakeWordDetected].
 *
 * Controlled via intent actions from [HarkPlatformPlugin]:
 * - [ACTION_START] — start detection + foreground notification
 * - [ACTION_STOP]  — stop detection + remove notification + stop service
 * - [ACTION_PAUSE] — pause detector (release mic for STT)
 * - [ACTION_RESUME] — resume detector (re-acquire mic after STT)
 */
class WakeWordService : Service() {

    private var detector: WakeWordDetector? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (detector?.isRunning == true) {
                    Log.d(TAG, "Already running, ignoring START")
                    return START_STICKY
                }
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
                startDetection()
                HarkPlatformPlugin.wakeWordRunning = true
                Log.i(TAG, "Wake word service started")
            }
            ACTION_STOP -> {
                detector?.release()
                detector = null
                HarkPlatformPlugin.wakeWordRunning = false
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                Log.i(TAG, "Wake word service stopped")
            }
            ACTION_PAUSE -> {
                detector?.pause()
                Log.d(TAG, "Detection paused")
            }
            ACTION_RESUME -> {
                detector?.resume()
                Log.d(TAG, "Detection resumed")
            }
            null -> {
                // Service restarted by system (START_STICKY with null intent).
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
                startDetection()
                HarkPlatformPlugin.wakeWordRunning = true
                Log.i(TAG, "Wake word service restarted by system")
            }
        }
        return START_STICKY
    }

    private fun startDetection() {
        detector = WakeWordDetector(this).apply {
            start(
                listener = { onWakeWordDetected() },
                modelPath = "wakeword/hey_harkh.onnx",
                threshold = 0.3f,
            )
        }
    }

    private fun onWakeWordDetected() {
        // Release mic immediately so STT can use it when the overlay opens.
        detector?.pause()
        (application as HarkApplication).onWakeWordDetected()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        detector?.release()
        detector = null
        HarkPlatformPlugin.wakeWordRunning = false
        Log.i(TAG, "Wake word service destroyed")
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, HarkApplication.WAKE_WORD_CHANNEL_ID)
            .setContentTitle("Hark")
            .setContentText("Listening for \"Hey Hark\"")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "WakeWordService"
        const val ACTION_START = "com.oacp.hark.WAKE_WORD_START"
        const val ACTION_STOP = "com.oacp.hark.WAKE_WORD_STOP"
        const val ACTION_PAUSE = "com.oacp.hark.WAKE_WORD_PAUSE"
        const val ACTION_RESUME = "com.oacp.hark.WAKE_WORD_RESUME"
        const val NOTIFICATION_ID = 1001
    }
}
