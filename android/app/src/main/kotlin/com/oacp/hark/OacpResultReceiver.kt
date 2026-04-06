package com.oacp.hark

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.plugin.common.EventChannel

class OacpResultReceiver : BroadcastReceiver(), EventChannel.StreamHandler {
    private val sinkLock = Any()
    private var eventSink: EventChannel.EventSink? = null
    private var registeredContext: Context? = null

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null) return

        val requestId = intent.getStringExtra("org.oacp.extra.REQUEST_ID")
        if (requestId.isNullOrEmpty()) return

        val result = mutableMapOf<String, Any?>()
        result["requestId"] = requestId
        result["status"] = intent.getStringExtra("org.oacp.extra.STATUS") ?: "completed"
        result["capabilityId"] = intent.getStringExtra("org.oacp.extra.CAPABILITY_ID")
        result["message"] = intent.getStringExtra("org.oacp.extra.MESSAGE")
        result["error"] = intent.getStringExtra("org.oacp.extra.ERROR")
        result["sourcePackage"] = intent.`package` ?: intent.getStringExtra("org.oacp.extra.SOURCE_PACKAGE")

        val resultJson = intent.getStringExtra("org.oacp.extra.RESULT")
        if (resultJson != null) {
            result["result"] = resultJson
        }

        synchronized(sinkLock) {
            try {
                eventSink?.success(result)
            } catch (e: Exception) {
                android.util.Log.e("OacpResultReceiver", "Error sending result", e)
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        synchronized(sinkLock) { eventSink = events }
    }

    override fun onCancel(arguments: Any?) {
        synchronized(sinkLock) { eventSink = null }
    }

    fun register(context: Context) {
        val filter = IntentFilter("org.oacp.ACTION_RESULT")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(this, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(this, filter)
        }
        registeredContext = context
    }

    fun unregister() {
        try {
            registeredContext?.unregisterReceiver(this)
        } catch (_: IllegalArgumentException) {
            // Already unregistered
        }
        registeredContext = null
    }
}
