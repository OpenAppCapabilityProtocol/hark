package com.oacp.hark

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.fragment.app.FragmentActivity
import com.oacp.hark_platform.HarkOverlayApi
import com.oacp.hark_platform.HarkOverlayFlutterApi
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import java.util.UUID

/**
 * Translucent Activity that hosts the overlay Flutter UI.
 *
 * Launched by [HarkSession] (assist gesture) or WakeWordService. Uses the
 * cached overlay [FlutterEngine] (with `overlayMain` entrypoint) via
 * [FlutterFragment].
 *
 * Registers [HarkOverlayApi] on create and tears it down on destroy to
 * prevent the cached engine from holding a dead Activity reference.
 */
class OverlayActivity : FragmentActivity() {

    private var engine: FlutterEngine? = null
    private var flutterApi: HarkOverlayFlutterApi? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_overlay)

        val app = application as HarkApplication
        engine = app.getOrCreateOverlayEngine()

        engine?.let { eng ->
            val messenger = eng.dartExecutor.binaryMessenger

            // Register Activity-bound HostApi so Dart can call dismiss/openFullApp.
            HarkOverlayApi.setUp(messenger, OverlayApiHandler())

            // Create FlutterApi to talk to Dart.
            flutterApi = HarkOverlayFlutterApi(messenger)

            // Attach FlutterFragment with transparency.
            if (savedInstanceState == null) {
                val fragment = FlutterFragment
                    .withCachedEngine(HarkApplication.OVERLAY_ENGINE_ID)
                    .renderMode(RenderMode.texture)
                    .transparencyMode(TransparencyMode.transparent)
                    .shouldAttachEngineToActivity(false)
                    .build<FlutterFragment>()

                supportFragmentManager
                    .beginTransaction()
                    .replace(R.id.flutter_container, fragment)
                    .commit()
            }

            // Notify Dart of new session so it can reset state.
            notifyNewSession()
        }

        Log.i(TAG, "OverlayActivity created")
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

    override fun onDestroy() {
        // CRITICAL: Teardown API so cached engine drops Activity reference.
        engine?.let { eng ->
            HarkOverlayApi.setUp(eng.dartExecutor.binaryMessenger, null)
        }
        flutterApi = null
        engine = null

        Log.i(TAG, "OverlayActivity destroyed — APIs torn down")
        super.onDestroy()
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
