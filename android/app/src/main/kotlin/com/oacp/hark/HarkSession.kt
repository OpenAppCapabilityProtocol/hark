package com.oacp.hark

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionSession
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.widget.ImageButton
import android.widget.TextView
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Compact overlay session for the Hark voice assistant.
 *
 * When the user triggers the assist gesture (long-press home, corner swipe),
 * Android creates this session. Instead of launching the full MainActivity,
 * we show a compact bottom-card overlay via [onCreateContentView] that
 * floats above the current app.
 *
 * Communication with the Flutter Dart code happens through the pre-warmed
 * [FlutterEngine] cached by [HarkApplication]. The overlay sends commands
 * (start listening, dismiss) via MethodChannel and receives state updates
 * (transcript, status, results) via a separate overlay EventChannel.
 */
class HarkSession(context: Context) : VoiceInteractionSession(context) {

    private val handler = Handler(Looper.getMainLooper())

    // Views
    private var statusText: TextView? = null
    private var transcriptText: TextView? = null
    private var resultText: TextView? = null
    private var micButton: ImageButton? = null

    // Flutter channels
    private var overlayChannel: MethodChannel? = null
    private var overlayEventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onCreateContentView(): View {
        val inflater = LayoutInflater.from(context)
        val root = inflater.inflate(R.layout.overlay_assistant, null)

        statusText = root.findViewById(R.id.overlay_status)
        transcriptText = root.findViewById(R.id.overlay_transcript)
        resultText = root.findViewById(R.id.overlay_result)
        micButton = root.findViewById(R.id.overlay_mic_btn)

        micButton?.setOnClickListener {
            overlayChannel?.invokeMethod("toggleListening", null)
        }

        // Tap outside the card to dismiss
        root.setOnClickListener {
            hide()
        }

        // Prevent card taps from dismissing
        root.findViewById<View>(R.id.overlay_card)?.setOnClickListener { /* consume */ }

        setupFlutterChannels()

        return root
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        Log.i(TAG, "Overlay session onShow")

        statusText?.text = "Listening..."
        transcriptText?.visibility = View.GONE
        resultText?.visibility = View.GONE

        // Tell Flutter to start listening
        overlayChannel?.invokeMethod("overlayShown", null)
    }

    override fun onHide() {
        super.onHide()
        Log.i(TAG, "Overlay session onHide")

        // Tell Flutter the overlay was dismissed
        overlayChannel?.invokeMethod("overlayHidden", null)
    }

    private fun setupFlutterChannels() {
        val engine = FlutterEngineCache.getInstance().get(HarkApplication.ENGINE_ID)
        if (engine == null) {
            Log.e(TAG, "FlutterEngine not found in cache — falling back to Activity launch")
            launchMainActivity()
            return
        }

        val messenger = engine.dartExecutor.binaryMessenger

        // Outbound: overlay → Flutter
        overlayChannel = MethodChannel(messenger, "com.oacp.hark/overlay").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateStatus" -> {
                        val status = call.argument<String>("status") ?: ""
                        handler.post { statusText?.text = status }
                        result.success(null)
                    }
                    "updateTranscript" -> {
                        val transcript = call.argument<String>("transcript") ?: ""
                        handler.post {
                            transcriptText?.text = "\"$transcript\""
                            transcriptText?.visibility =
                                if (transcript.isNotEmpty()) View.VISIBLE else View.GONE
                        }
                        result.success(null)
                    }
                    "updateResult" -> {
                        val resultMsg = call.argument<String>("result") ?: ""
                        handler.post {
                            resultText?.text = resultMsg
                            resultText?.visibility =
                                if (resultMsg.isNotEmpty()) View.VISIBLE else View.GONE
                        }
                        result.success(null)
                    }
                    "dismiss" -> {
                        handler.post { hide() }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        Log.i(TAG, "Flutter overlay channels set up")
    }

    private fun launchMainActivity() {
        try {
            val intent = android.content.Intent(context, MainActivity::class.java).apply {
                addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                        or android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
                putExtra(EXTRA_LAUNCHED_FROM_ASSIST, true)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch assistant activity", e)
        }
    }

    companion object {
        private const val TAG = "HarkSession"
        const val EXTRA_LAUNCHED_FROM_ASSIST = "com.oacp.LAUNCHED_FROM_ASSIST"
    }
}
