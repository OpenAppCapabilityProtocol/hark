package com.oacp.hark

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.oacp.hark_platform.HarkOverlayApi
import com.oacp.hark_platform.HarkOverlayFlutterApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import java.util.UUID

/**
 * Translucent Activity that hosts the overlay Flutter UI.
 *
 * Extends [FlutterActivity] with a cached overlay engine for proper touch
 * dispatch and rendering. Launched by [HarkSession] (assist gesture).
 *
 * Registers [HarkOverlayApi] on create and tears it down on destroy to
 * prevent the cached engine from holding a dead Activity reference.
 */
class OverlayActivity : FlutterActivity() {

    private var flutterApi: HarkOverlayFlutterApi? = null

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

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Register Activity-bound HostApi so Dart can call dismiss/openFullApp.
        HarkOverlayApi.setUp(messenger, OverlayApiHandler())

        // Create FlutterApi to talk to Dart.
        flutterApi = HarkOverlayFlutterApi(messenger)

        // Notify Dart of new session so it can reset state.
        notifyNewSession()

        Log.i(TAG, "HarkOverlayApi registered")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Re-invocation (e.g. second assist gesture while overlay is showing).
        notifyNewSession()
        Log.i(TAG, "OverlayActivity onNewIntent — new session")
    }

    private fun notifyNewSession() {
        val sessionId = UUID.randomUUID().toString()
        flutterApi?.onNewSession(sessionId) { result ->
            result.onFailure { e ->
                Log.w(TAG, "onNewSession delivery failed", e)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // CRITICAL: Teardown API so cached engine drops Activity reference.
        HarkOverlayApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        flutterApi = null
        Log.i(TAG, "HarkOverlayApi torn down")
    }

    // ── HarkOverlayApi implementation ────────────────────────────

    private inner class OverlayApiHandler : HarkOverlayApi {
        override fun dismiss() {
            Log.i(TAG, "dismiss() — finishing overlay")
            this@OverlayActivity.moveTaskToBack(true)
            this@OverlayActivity.finish()
        }

        override fun openFullApp() {
            Log.i(TAG, "openFullApp() — launching MainActivity")
            val intent = Intent(this@OverlayActivity, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            startActivity(intent)
            this@OverlayActivity.finish()
        }
    }

    companion object {
        private const val TAG = "OverlayActivity"
    }
}
