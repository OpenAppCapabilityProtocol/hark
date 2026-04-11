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
 * Manages its own [CoroutineScope] for the audio pipeline. The engine
 * owns an internal [AudioRecord] at 16 kHz mono, so it cannot run
 * simultaneously with Android STT. Use [pause]/[resume] to gate
 * detection while STT is active.
 */
class WakeWordDetector(private val context: Context) {

    fun interface Listener {
        fun onDetected()
    }

    private var engine: WakeWordEngine? = null
    private var scope: CoroutineScope? = null
    private var collectorJob: Job? = null
    private var isPaused = false

    val isRunning: Boolean get() = engine != null

    /**
     * Starts wake word detection. The engine opens the microphone and
     * begins continuous inference. Detections are delivered to [listener]
     * on the main thread via [kotlinx.coroutines.Dispatchers.Main].
     *
     * @param modelPath Asset path to the wake word ONNX model
     *        (e.g. "wakeword/hey_hark.onnx")
     * @param threshold Detection confidence threshold (0.0-1.0).
     *        Lower = more sensitive, higher = fewer false positives.
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
            detectionCooldownMs = 3000L,
            scope = engineScope,
        )
        engine = wakeEngine

        // Collect detections on Default, notify listener on Main.
        collectorJob = engineScope.launch {
            wakeEngine.detections.collect { detection ->
                if (!isPaused) {
                    Log.i(TAG, "Wake word detected: ${detection.model.name} " +
                        "(score=${String.format("%.3f", detection.score)})")
                    kotlinx.coroutines.withContext(Dispatchers.Main) {
                        listener.onDetected()
                    }
                }
            }
        }

        wakeEngine.start()
        Log.i(TAG, "Wake word detection started (model=$modelPath, threshold=$threshold)")
    }

    /**
     * Pauses detection without releasing resources. Use when STT is
     * active to avoid AudioRecord conflicts. The engine continues
     * running but detections are suppressed.
     */
    fun pause() {
        isPaused = true
        Log.d(TAG, "Detection paused")
    }

    /**
     * Resumes detection after a [pause].
     */
    fun resume() {
        isPaused = false
        Log.d(TAG, "Detection resumed")
    }

    /**
     * Stops detection and releases the microphone, but keeps the engine
     * instance for quick restart. Call [release] for full cleanup.
     */
    fun stop() {
        engine?.stop()
        Log.i(TAG, "Wake word detection stopped")
    }

    /**
     * Fully releases all resources: ONNX sessions, audio pipeline,
     * coroutine scope. The detector cannot be restarted after this.
     * Create a new [WakeWordDetector] instance instead.
     */
    fun release() {
        collectorJob?.cancel()
        collectorJob = null
        engine?.stop()
        engine = null
        scope?.cancel()
        scope = null
        isPaused = false
        Log.i(TAG, "Wake word detector released")
    }

    companion object {
        private const val TAG = "WakeWordDetector"
    }
}
