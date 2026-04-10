package com.oacp.hark

import android.content.Intent
import android.provider.Settings
import android.util.Log
import com.oacp.hark_platform.HarkMainApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Main Activity hosting the full Hark chat UI.
 *
 * Uses the cached main [FlutterEngine] and registers [HarkMainApi] for
 * Activity-bound operations (opening system settings).
 */
class MainActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get(HarkApplication.MAIN_ENGINE_ID)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        HarkMainApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            MainApiHandler(),
        )

        Log.i(TAG, "HarkMainApi registered")
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        HarkMainApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        Log.i(TAG, "HarkMainApi torn down")
    }

    // ── HarkMainApi implementation ───────────────────────────────

    private inner class MainApiHandler : HarkMainApi {
        override fun openAssistantSettings() {
            try {
                startActivity(
                    Intent("android.settings.VOICE_INPUT_SETTINGS")
                )
            } catch (e: Exception) {
                Log.w(TAG, "Could not open voice input settings", e)
                try {
                    startActivity(
                        Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                    )
                } catch (e2: Exception) {
                    Log.e(TAG, "Could not open any settings activity", e2)
                }
            }
        }
    }

    companion object {
        private const val TAG = "HarkMainActivity"
    }
}
