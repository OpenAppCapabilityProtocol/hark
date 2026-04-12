package com.oacp.hark

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionSession
import android.util.Log
import com.oacp.hark_platform.HarkResultFlutterApi
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Custom Application that manages a [FlutterEngineGroup] for shared GPU/VM
 * resources across engines.
 *
 * - **Main engine** — created eagerly in [onCreate], runs [main] entrypoint.
 * - **Overlay engine** — created lazily on first assist gesture, runs
 *   [overlayMain] entrypoint.
 *
 * All platform channels are registered automatically by [HarkPlatformPlugin]
 * via [GeneratedPluginRegistrant]. No manual channel setup here.
 */
class HarkApplication : Application() {

    lateinit var engineGroup: FlutterEngineGroup
        private set

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()

        createNotificationChannels()

        engineGroup = FlutterEngineGroup(this)

        val mainEngine = engineGroup.createAndRunDefaultEngine(this)
        GeneratedPluginRegistrant.registerWith(mainEngine)
        FlutterEngineCache.getInstance().put(MAIN_ENGINE_ID, mainEngine)

        Log.i(TAG, "Main FlutterEngine created and cached")
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                WAKE_WORD_CHANNEL_ID,
                "Wake Word Detection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows when Hark is listening for the wake word"
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    /**
     * Called by [WakeWordService] when "Hey Hark" is detected.
     * Launches the overlay via [VoiceInteractionService.showSession] (the
     * system-sanctioned path, exempt from background activity restrictions)
     * and notifies the main engine's Dart side via Pigeon.
     */
    fun onWakeWordDetected() {
        Log.i(TAG, "Wake word detected — launching overlay")

        // Launch overlay via VoiceInteractionService if available.
        val vis = HarkVoiceInteractionService.instance
        if (vis != null) {
            vis.showSession(Bundle.EMPTY, VoiceInteractionSession.SHOW_WITH_ASSIST)
        } else {
            // Fallback: direct Activity launch (works when the app has a
            // foreground service, giving it foreground-equivalent priority).
            // TODO: Android 12+ blocks background activity launches from
            // Application context by default. This path relies on the wake
            // word FG service granting BAL_ALLOW_FGS privilege. Untested
            // when Hark is NOT the default assistant. If it fails silently
            // we should post a notification with a full-screen intent
            // instead of startActivity.
            Log.w(TAG, "VIS not available, launching OverlayActivity directly")
            val intent = Intent(this, OverlayActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            startActivity(intent)
        }

        // Notify Dart so ChatNotifier knows the wake word fired.
        val mainEngine = FlutterEngineCache.getInstance()
            .get(MAIN_ENGINE_ID) ?: return
        val api = HarkResultFlutterApi(mainEngine.dartExecutor.binaryMessenger)
        mainHandler.post { api.onWakeWordDetected { } }
    }

    /**
     * Returns the cached overlay engine, or creates one on first call.
     *
     * The overlay engine runs the `overlayMain` Dart entrypoint and shares
     * GPU context with the main engine via [FlutterEngineGroup].
     */
    // TODO: Consider adding @Synchronized if rapid double-tap assist gesture
    // can race two concurrent calls before the cache check.
    fun getOrCreateOverlayEngine(): FlutterEngine {
        FlutterEngineCache.getInstance().get(OVERLAY_ENGINE_ID)?.let { return it }

        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(this)
            loader.ensureInitializationComplete(this, null)
        }

        val engine = engineGroup.createAndRunEngine(
            this,
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "package:hark/overlay_main.dart",
                "overlayMain",
            ),
        )
        GeneratedPluginRegistrant.registerWith(engine)
        FlutterEngineCache.getInstance().put(OVERLAY_ENGINE_ID, engine)

        Log.i(TAG, "Overlay FlutterEngine created and cached")
        return engine
    }

    companion object {
        private const val TAG = "HarkApplication"
        const val MAIN_ENGINE_ID = "main"
        const val OVERLAY_ENGINE_ID = "overlay"
        const val WAKE_WORD_CHANNEL_ID = "wake_word"
    }
}
