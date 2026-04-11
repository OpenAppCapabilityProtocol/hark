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
 * simultaneously with Android STT. Use [pause]/[resume] to stop/restart
 * the engine and release the mic for STT.
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

        _startEngine()
        Log.i(TAG, "Wake word detection started (model=$modelPath, threshold=$threshold)")
    }

    private fun _startEngine() {
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
                Log.i(TAG, "Wake word detected: ${detection.model.name} " +
                    "(score=${String.format("%.3f", detection.score)})")
                kotlinx.coroutines.withContext(Dispatchers.Main) {
                    listener?.onDetected()
                }
            }
        }

        wakeEngine.start()
    }

    /**
     * Pauses detection by fully stopping the engine and releasing the
     * microphone. This frees [AudioRecord] so STT can use it.
     * Call [resume] to restart detection after STT finishes.
     */
    fun pause() {
        if (isPaused) return
        isPaused = true
        _stopEngine()
        Log.i(TAG, "Detection paused (mic released for STT)")
    }

    /**
     * Resumes detection after a [pause]. Restarts the engine and
     * re-acquires the microphone.
     */
    fun resume() {
        if (!isPaused) return
        isPaused = false
        _startEngine()
        Log.i(TAG, "Detection resumed (mic re-acquired)")
    }

    private fun _stopEngine() {
        collectorJob?.cancel()
        collectorJob = null
        engine?.stop()
        engine = null
        scope?.cancel()
        scope = null
    }

    /**
     * Fully releases all resources. The detector cannot be restarted
     * after this. Create a new [WakeWordDetector] instance instead.
     */
    fun release() {
        _stopEngine()
        listener = null
        isPaused = false
        Log.i(TAG, "Wake word detector released")
    }

    companion object {
        private const val TAG = "WakeWordDetector"
    }
}
