package com.oacp.hark

import android.app.role.RoleManager
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val resultReceiver = OacpResultReceiver()
    private var assistChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.oacp.hark/discovery",
        ).setMethodCallHandler(OacpDiscoveryHandler(applicationContext))
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.oacp.hark/local_model_storage",
        ).setMethodCallHandler(LocalModelStorageHandler(applicationContext))
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.oacp.hark/results",
        ).setStreamHandler(resultReceiver)

        assistChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.oacp.hark/assist",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAssistantSettings" -> {
                        openAssistantSettings()
                        result.success(null)
                    }
                    "isDefaultAssistant" -> {
                        result.success(isDefaultAssistant())
                    }
                    else -> result.notImplemented()
                }
            }
        }

        resultReceiver.register(applicationContext)
        checkAssistLaunch(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        checkAssistLaunch(intent)
    }

    private fun checkAssistLaunch(intent: Intent?) {
        if (intent == null) return

        val isAssist = intent.action == Intent.ACTION_ASSIST
            || intent.getBooleanExtra(HarkSession.EXTRA_LAUNCHED_FROM_ASSIST, false)

        if (isAssist) {
            intent.removeExtra(HarkSession.EXTRA_LAUNCHED_FROM_ASSIST)
            assistChannel?.invokeMethod("startListening", null)
        }
    }

    private fun isDefaultAssistant(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = getSystemService(RoleManager::class.java)
            if (roleManager?.isRoleHeld(RoleManager.ROLE_ASSISTANT) == true) {
                val viService = Settings.Secure.getString(
                    contentResolver, "voice_interaction_service"
                )
                return viService != null && viService.contains(packageName)
            }
            return false
        }
        val assistant = Settings.Secure.getString(contentResolver, "assistant")
        return assistant != null && assistant.contains(packageName)
    }

    private fun openAssistantSettings() {
        try {
            startActivity(Intent("android.settings.VOICE_INPUT_SETTINGS"))
        } catch (e: Exception) {
            Log.w(TAG, "Could not open voice input settings", e)
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
            } catch (e2: Exception) {
                Log.w(TAG, "Could not open default apps settings", e2)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        resultReceiver.unregister()
        assistChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        private const val TAG = "HarkMainActivity"
    }
}
