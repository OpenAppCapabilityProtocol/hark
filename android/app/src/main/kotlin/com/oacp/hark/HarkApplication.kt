package com.oacp.hark

import android.app.Application
import android.util.Log
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

    override fun onCreate() {
        super.onCreate()

        engineGroup = FlutterEngineGroup(this)

        val mainEngine = engineGroup.createAndRunDefaultEngine(this)
        GeneratedPluginRegistrant.registerWith(mainEngine)
        FlutterEngineCache.getInstance().put(MAIN_ENGINE_ID, mainEngine)

        Log.i(TAG, "Main FlutterEngine created and cached")
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
    }
}
