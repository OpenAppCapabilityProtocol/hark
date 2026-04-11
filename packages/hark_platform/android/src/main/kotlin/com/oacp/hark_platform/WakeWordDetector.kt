package com.oacp.hark_platform

import android.content.Context
import android.util.Log
import com.rementia.openwakeword.lib.WakeWordEngine
import com.rementia.openwakeword.lib.model.DetectionMode
import com.rementia.openwakeword.lib.model.WakeWordModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Wraps openWakeWord's [WakeWordEngine] with a simple start/stop/release
 * lifecycle and a callback-based detection interface.
 *
 * The engine keeps its [AudioRecord] and audio buffer running continuously.
 * During STT, detections are suppressed but the buffer stays warm so
 * detection resumes instantly after STT finishes (no 10-second buffer
 * rebuild delay).
 *
 * Android's [SpeechRecognizer] (used by speech_to_text) manages its own
 * audio session and can coexist with [AudioRecord] on most devices.
 */
class WakeWordDetector(private val context: Context) {

    fun interface Listener {
        fun onDetected()
    }

    private var engine: WakeWordEngine? = null
    private var scope: CoroutineScope? = null
    private var collectorJob: Job? = null
    private var listener: Listener? = null
    private var modelPath: String = "wakeword/hello_world.onnx"
    private var threshold: Float = 0.5f

    @Volatile
    private var isPaused = false

    val isRunning: Boolean get() = engine != null

    /**
     * Starts wake word detection. The engine opens the microphone and
     * begins continuous inference. Detections are delivered to [listener]
     * on the main thread.
     */
    fun start(
        listener: Listener,
        modelPath: String = "wakeword/hello_world.onnx",
        threshold: Float = 0.5f,
    ) {
        if (engine != null) {
            Log.w(TAG, "Already running, ignoring start()")
            return
        }

        this.listener = listener
        this.modelPath = modelPath
        this.threshold = threshold

        val engineScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
        scope = engineScope

        val models = listOf(
            WakeWordModel(
                name = "hey_hark",
                modelPath = modelPath,
                threshold = threshold,
            )
        )

        val wakeEngine = WakeWordEngine(
            context = context,
            models = models,
            detectionMode = DetectionMode.SINGLE_BEST,
            detectionCooldownMs = 1500L,
            scope = engineScope,
        )
        engine = wakeEngine

        collectorJob = engineScope.launch {
            wakeEngine.detections.collect { detection ->
                if (!isPaused) {
                    Log.i(TAG, "Wake word detected: ${detection.model.name} " +
                        "(score=${String.format("%.3f", detection.score)})")
                    kotlinx.coroutines.withContext(Dispatchers.Main) {
                        listener?.onDetected()
                    }
                } else {
                    Log.d(TAG, "Wake word detected but suppressed (paused)")
                }
            }
        }

        wakeEngine.start()
        Log.i(TAG, "Wake word detection started (model=$modelPath, threshold=$threshold)")
    }

    /**
     * Suppresses detections without stopping the engine. The audio buffer
     * stays warm so detection resumes instantly when [resume] is called.
     */
    fun pause() {
        isPaused = true
        Log.d(TAG, "Detection suppressed (engine still running)")
    }

    /**
     * Resumes detection after a [pause]. Instant because the audio buffer
     * was never cleared.
     */
    fun resume() {
        isPaused = false
        Log.d(TAG, "Detection resumed")
    }

    /**
     * Fully releases all resources. The detector cannot be restarted
     * after this. Create a new [WakeWordDetector] instance instead.
     */
    fun release() {
        collectorJob?.cancel()
        collectorJob = null
        engine?.stop()
        engine = null
        scope?.cancel()
        scope = null
        listener = null
        isPaused = false
        Log.i(TAG, "Wake word detector released")
    }

    companion object {
        private const val TAG = "WakeWordDetector"
    }
}
