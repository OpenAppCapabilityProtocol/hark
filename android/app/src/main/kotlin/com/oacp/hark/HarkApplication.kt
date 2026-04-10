package com.oacp.hark

import android.app.Application
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Custom Application that pre-warms the FlutterEngine at process start.
 *
 * This allows the VoiceInteractionSession overlay to communicate with the
 * Flutter Dart code (STT, NLU, dispatch) via MethodChannel even when
 * MainActivity is not in the foreground. The same engine is reused by
 * MainActivity via FlutterEngineCache.
 */
class HarkApplication : Application() {

    override fun onCreate() {
        super.onCreate()

        // Pre-warm a FlutterEngine and cache it. MainActivity will pick it
        // up via providedFlutterEngine() and the overlay session will use
        // its binary messenger for MethodChannel calls.
        val flutterEngine = FlutterEngine(this).apply {
            dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
        }
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
        Log.i(TAG, "FlutterEngine pre-warmed and cached")
    }

    companion object {
        private const val TAG = "HarkApplication"
        const val ENGINE_ID = "hark_engine"
    }
}
