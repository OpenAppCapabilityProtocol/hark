package com.oacp.hark

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.oacp.hark_platform.HarkMainFlutterApi
import com.oacp.hark_platform.HarkOverlayApi
import com.oacp.hark_platform.HarkOverlayBridgeApi
import com.oacp.hark_platform.HarkOverlayFlutterApi
import com.oacp.hark_platform.OverlayStateMessage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import java.util.UUID

/**
 * Translucent Activity that hosts the overlay Flutter UI and relays
 * between the overlay engine and the main engine.
 *
 * The overlay engine is a thin UI shell — no models, no STT. All
 * processing happens on the main engine. This Activity bridges them:
 *
 * - Overlay → micPressed/cancelListening → relay to main engine
 * - Main engine → pushStateToOverlay → relay to overlay engine
 */
class OverlayActivity : FlutterActivity(), HarkOverlayBridgeApi {

    private var overlayFlutterApi: HarkOverlayFlutterApi? = null
    private var mainFlutterApi: HarkMainFlutterApi? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val app = application as HarkApplication
        return app.getOrCreateOverlayEngine()
    }

    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun getTransparencyMode(): TransparencyMode = TransparencyMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "OverlayActivity created")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val overlayMessenger = flutterEngine.dartExecutor.binaryMessenger

        // Set up overlay engine APIs.
        HarkOverlayApi.setUp(overlayMessenger, OverlayApiHandler())
        overlayFlutterApi = HarkOverlayFlutterApi(overlayMessenger)

        // Set up main engine APIs for the relay.
        val mainEngine = FlutterEngineCache.getInstance()
            .get(HarkApplication.MAIN_ENGINE_ID)
        if (mainEngine != null) {
            val mainMessenger = mainEngine.dartExecutor.binaryMessenger
            mainFlutterApi = HarkMainFlutterApi(mainMessenger)

            // Register bridge so main engine can push state to us.
            HarkOverlayBridgeApi.setUp(mainMessenger, this)
        } else {
            Log.e(TAG, "Main engine not found — relay will not work")
        }

        // Notify main engine that overlay is now active.
        mainFlutterApi?.onOverlayOpened { }

        // Notify overlay of new session.
        notifyNewSession()

        Log.i(TAG, "Relay configured — overlay ↔ main bridge active")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        notifyNewSession()
        // Notify main engine again (re-invocation).
        mainFlutterApi?.onOverlayOpened { }
        Log.i(TAG, "onNewIntent — new session")
    }

    private fun notifyNewSession() {
        val sessionId = UUID.randomUUID().toString()
        overlayFlutterApi?.onNewSession(sessionId) { result ->
            result.onFailure { e ->
                Log.w(TAG, "onNewSession delivery failed", e)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Teardown overlay APIs.
        HarkOverlayApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        overlayFlutterApi = null

        // Teardown main engine bridge.
        val mainEngine = FlutterEngineCache.getInstance()
            .get(HarkApplication.MAIN_ENGINE_ID)
        if (mainEngine != null) {
            HarkOverlayBridgeApi.setUp(mainEngine.dartExecutor.binaryMessenger, null)
            mainFlutterApi?.onOverlayDismissed { }
        }
        mainFlutterApi = null

        Log.i(TAG, "Relay torn down")
    }

    // ── HarkOverlayBridgeApi: main engine pushes state to overlay ─

    override fun pushStateToOverlay(state: OverlayStateMessage) {
        overlayFlutterApi?.onStateUpdate(state) { result ->
            result.onFailure { e ->
                Log.w(TAG, "State push to overlay failed", e)
            }
        }
    }

    override fun notifyOverlayActive(active: Boolean) {
        // Main engine can query this — no-op for now.
    }

    // ── HarkOverlayApi: overlay sends actions → relay to main ────

    private inner class OverlayApiHandler : HarkOverlayApi {
        override fun dismiss() {
            Log.i(TAG, "dismiss()")
            mainFlutterApi?.onOverlayDismissed { }
            this@OverlayActivity.moveTaskToBack(true)
            this@OverlayActivity.finish()
        }

        override fun openFullApp() {
            Log.i(TAG, "openFullApp()")
            mainFlutterApi?.onOverlayDismissed { }
            val intent = Intent(this@OverlayActivity, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            startActivity(intent)
            this@OverlayActivity.finish()
        }

        override fun micPressed() {
            Log.d(TAG, "micPressed() → relay to main")
            mainFlutterApi?.onOverlayMicPressed { }
        }

        override fun cancelListening() {
            Log.d(TAG, "cancelListening() → relay to main")
            mainFlutterApi?.onOverlayCancelListening { }
        }
    }

    companion object {
        private const val TAG = "OverlayActivity"
    }
}
