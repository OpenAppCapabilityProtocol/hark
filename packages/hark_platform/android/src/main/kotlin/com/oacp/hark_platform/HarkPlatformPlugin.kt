package com.oacp.hark_platform

import android.app.role.RoleManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

/**
 * Flutter plugin that owns all Hark ↔ Android communication.
 *
 * Implements [HarkCommonApi] (cross-engine) and auto-registers on every
 * FlutterEngine via [onAttachedToEngine]. Activity-specific APIs
 * ([HarkOverlayApi], [HarkMainApi]) are registered by their respective
 * Activities, not by this plugin.
 */
class HarkPlatformPlugin : FlutterPlugin, HarkCommonApi {

    private var context: Context? = null
    private var resultFlutterApi: HarkResultFlutterApi? = null
    private var resultReceiver: OacpResultBroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── FlutterPlugin lifecycle ──────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        HarkCommonApi.setUp(binding.binaryMessenger, this)

        resultFlutterApi = HarkResultFlutterApi(binding.binaryMessenger)
        val receiver = OacpResultBroadcastReceiver(resultFlutterApi!!)
        receiver.register(binding.applicationContext)
        resultReceiver = receiver

        Log.i(TAG, "Plugin attached to engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        HarkCommonApi.setUp(binding.binaryMessenger, null)
        resultReceiver?.unregister()
        resultReceiver = null
        resultFlutterApi = null
        context = null
        Log.i(TAG, "Plugin detached from engine")
    }

    // ── HarkCommonApi: isDefaultAssistant ────────────────────────

    override fun isDefaultAssistant(callback: (Result<Boolean>) -> Unit) {
        val ctx = context ?: run {
            callback(Result.success(false))
            return
        }
        val isDefault = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager = ctx.getSystemService(RoleManager::class.java)
            if (roleManager?.isRoleHeld(RoleManager.ROLE_ASSISTANT) == true) {
                val viService = Settings.Secure.getString(
                    ctx.contentResolver, "voice_interaction_service"
                )
                viService != null && viService.contains(ctx.packageName)
            } else {
                false
            }
        } else {
            val assistant = Settings.Secure.getString(ctx.contentResolver, "assistant")
            assistant != null && assistant.contains(ctx.packageName)
        }
        callback(Result.success(isDefault))
    }

    // ── HarkCommonApi: OACP discovery ────────────────────────────

    override fun discoverOacpApps(
        callback: (Result<List<DiscoveredAppMessage>>) -> Unit,
    ) {
        val ctx = context ?: run {
            callback(Result.success(emptyList()))
            return
        }
        try {
            val apps = discoverApps(ctx)
            callback(Result.success(apps))
        } catch (e: Exception) {
            callback(Result.failure(
                FlutterError("discovery_failed", e.message, null)
            ))
        }
    }

    private fun discoverApps(ctx: Context): List<DiscoveredAppMessage> {
        val packageManager = ctx.packageManager
        val packageInfos = getInstalledPackages(packageManager)
        val seen = mutableSetOf<String>()
        val results = mutableListOf<DiscoveredAppMessage>()

        for (packageInfo in packageInfos) {
            val providers = packageInfo.providers ?: continue
            for (providerInfo in providers) {
                if (!providerInfo.exported) continue
                val authorities = providerInfo.authority
                    ?.split(';')
                    ?.map(String::trim)
                    ?.filter { it.endsWith(".oacp") }
                    .orEmpty()

                for (authority in authorities) {
                    val key = "${packageInfo.packageName}:$authority"
                    if (!seen.add(key)) continue

                    var manifestJson: String? = null
                    var contextMarkdown: String? = null
                    var error: String? = null

                    try {
                        manifestJson = readProviderText(ctx, authority, "manifest")
                        contextMarkdown = readProviderText(ctx, authority, "context")
                    } catch (e: Exception) {
                        error = e.message ?: e.javaClass.simpleName
                    }

                    results.add(DiscoveredAppMessage(
                        packageName = packageInfo.packageName,
                        authority = authority,
                        appLabel = resolveAppLabel(packageManager, packageInfo),
                        versionName = packageInfo.versionName ?: "",
                        manifestJson = manifestJson,
                        contextMarkdown = contextMarkdown,
                        error = error,
                    ))
                }
            }
        }
        return results
    }

    private fun getInstalledPackages(pm: PackageManager): List<PackageInfo> {
        val flags = PackageManager.GET_PROVIDERS.toLong()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(flags))
        } else {
            @Suppress("DEPRECATION")
            pm.getInstalledPackages(PackageManager.GET_PROVIDERS)
        }
    }

    private fun resolveAppLabel(pm: PackageManager, info: PackageInfo): String {
        val appInfo = info.applicationInfo ?: return info.packageName
        return pm.getApplicationLabel(appInfo).toString()
    }

    private fun readProviderText(ctx: Context, authority: String, path: String): String {
        val uri = Uri.parse("content://$authority/$path")
        ctx.contentResolver.openInputStream(uri)?.use { input ->
            return input.bufferedReader().readText()
        }
        throw IOException("Unable to read $uri")
    }

    // ── HarkCommonApi: local model storage ───────────────────────

    private val fileLocks = ConcurrentHashMap<String, ReentrantLock>()

    private fun lockFor(fileName: String): ReentrantLock =
        fileLocks.getOrPut(fileName) { ReentrantLock() }

    private fun isValidFileName(fileName: String): Boolean =
        !fileName.contains("/") && !fileName.contains("\\") &&
        !fileName.startsWith(".") && fileName == File(fileName).name

    private fun internalModelFile(fileName: String): File {
        val appFlutterDir = File(context!!.filesDir, "app_flutter")
        return File(appFlutterDir, fileName)
    }

    private fun backupFile(fileName: String): File {
        @Suppress("DEPRECATION")
        val downloadsDir =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        return File(File(downloadsDir, "local-llm"), fileName)
    }

    override fun findBackup(fileName: String, callback: (Result<BackupInfo?>) -> Unit) {
        if (!isValidFileName(fileName)) {
            callback(Result.failure(FlutterError("invalid_args", "Invalid fileName", null)))
            return
        }
        val file = backupFile(fileName)
        if (file.exists()) {
            callback(Result.success(BackupInfo(
                path = file.absolutePath,
                sizeBytes = file.length(),
            )))
        } else {
            callback(Result.success(null))
        }
    }

    override fun saveBackup(fileName: String, callback: (Result<String>) -> Unit) {
        if (!isValidFileName(fileName)) {
            callback(Result.failure(FlutterError("invalid_args", "Invalid fileName", null)))
            return
        }
        thread {
            lockFor(fileName).withLock {
                try {
                    val source = internalModelFile(fileName)
                    if (!source.exists()) {
                        Log.w(TAG, "No internal model file to back up: ${source.absolutePath}")
                        mainHandler.post {
                            callback(Result.failure(
                                FlutterError("not_found", "No internal file: $fileName", null)
                            ))
                        }
                        return@withLock
                    }

                    val target = backupFile(fileName)
                    val tmpFile = File(target.parentFile, "${fileName}.tmp")
                    target.parentFile?.mkdirs()

                    source.inputStream().buffered().use { input ->
                        tmpFile.outputStream().buffered().use { output ->
                            input.copyTo(output)
                        }
                    }

                    if (tmpFile.length() != source.length()) {
                        tmpFile.delete()
                        mainHandler.post {
                            callback(Result.failure(FlutterError(
                                "backup_failed",
                                "Size mismatch: expected ${source.length()}, got ${tmpFile.length()}",
                                null,
                            )))
                        }
                        return@withLock
                    }

                    if (target.exists()) target.delete()
                    if (!tmpFile.renameTo(target)) {
                        tmpFile.delete()
                        mainHandler.post {
                            callback(Result.failure(
                                FlutterError("backup_failed", "Rename failed", null)
                            ))
                        }
                        return@withLock
                    }

                    Log.i(TAG, "Backed up model: $fileName (${target.length() / 1024 / 1024} MB)")
                    mainHandler.post { callback(Result.success(target.absolutePath)) }
                } catch (error: Exception) {
                    try {
                        backupFile(fileName).parentFile?.let { dir ->
                            File(dir, "${fileName}.tmp").delete()
                        }
                    } catch (_: Exception) {}
                    Log.e(TAG, "Backup failed for $fileName", error)
                    mainHandler.post {
                        callback(Result.failure(FlutterError(
                            "backup_failed",
                            "${error.javaClass.simpleName}: ${error.message ?: "unknown"}",
                            null,
                        )))
                    }
                }
            }
        }
    }

    override fun restoreBackup(fileName: String, callback: (Result<String?>) -> Unit) {
        if (!isValidFileName(fileName)) {
            callback(Result.failure(FlutterError("invalid_args", "Invalid fileName", null)))
            return
        }
        thread {
            lockFor(fileName).withLock {
                try {
                    val source = backupFile(fileName)
                    if (!source.exists()) {
                        mainHandler.post { callback(Result.success(null)) }
                        return@withLock
                    }

                    val target = internalModelFile(fileName)
                    target.parentFile?.mkdirs()

                    if (target.exists() && target.length() == source.length()) {
                        Log.i(TAG, "Internal file matches backup, skipping copy")
                        mainHandler.post { callback(Result.success(target.absolutePath)) }
                        return@withLock
                    }

                    val tmpFile = File(target.parentFile, "${fileName}.tmp")

                    source.inputStream().buffered().use { input ->
                        tmpFile.outputStream().buffered().use { output ->
                            input.copyTo(output)
                        }
                    }

                    if (tmpFile.length() != source.length()) {
                        tmpFile.delete()
                        mainHandler.post {
                            callback(Result.failure(FlutterError(
                                "restore_failed",
                                "Size mismatch: expected ${source.length()}, got ${tmpFile.length()}",
                                null,
                            )))
                        }
                        return@withLock
                    }

                    if (target.exists()) target.delete()
                    if (!tmpFile.renameTo(target)) {
                        tmpFile.delete()
                        mainHandler.post {
                            callback(Result.failure(
                                FlutterError("restore_failed", "Rename failed", null)
                            ))
                        }
                        return@withLock
                    }

                    Log.i(TAG, "Restored from backup: $fileName (${target.length() / 1024 / 1024} MB)")
                    mainHandler.post { callback(Result.success(target.absolutePath)) }
                } catch (error: Exception) {
                    try {
                        internalModelFile(fileName).parentFile?.let { dir ->
                            File(dir, "${fileName}.tmp").delete()
                        }
                    } catch (_: Exception) {}
                    Log.e(TAG, "Restore failed for $fileName", error)
                    mainHandler.post {
                        callback(Result.failure(FlutterError(
                            "restore_failed",
                            "${error.javaClass.simpleName}: ${error.message ?: "unknown"}",
                            null,
                        )))
                    }
                }
            }
        }
    }

    override fun deleteBackup(fileName: String, callback: (Result<Boolean>) -> Unit) {
        if (!isValidFileName(fileName)) {
            callback(Result.failure(FlutterError("invalid_args", "Invalid fileName", null)))
            return
        }
        val file = backupFile(fileName)
        callback(Result.success(if (file.exists()) file.delete() else true))
    }

    // ── OACP result receiver (BroadcastReceiver → FlutterApi) ────

    private class OacpResultBroadcastReceiver(
        private val flutterApi: HarkResultFlutterApi,
    ) : BroadcastReceiver() {

        private var registeredContext: Context? = null

        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            val requestId = intent.getStringExtra("org.oacp.extra.REQUEST_ID")
            if (requestId.isNullOrEmpty()) return

            val msg = OacpResultMessage(
                requestId = requestId,
                status = intent.getStringExtra("org.oacp.extra.STATUS") ?: "completed",
                capabilityId = intent.getStringExtra("org.oacp.extra.CAPABILITY_ID"),
                message = intent.getStringExtra("org.oacp.extra.MESSAGE"),
                error = intent.getStringExtra("org.oacp.extra.ERROR"),
                sourcePackage = intent.`package`
                    ?: intent.getStringExtra("org.oacp.extra.SOURCE_PACKAGE"),
                result = intent.getStringExtra("org.oacp.extra.RESULT"),
            )

            try {
                flutterApi.onOacpResult(msg) { /* delivery callback — log on error */ }
            } catch (e: Exception) {
                Log.e(TAG, "Error forwarding OACP result", e)
            }
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

    companion object {
        private const val TAG = "HarkPlatform"
    }
}
