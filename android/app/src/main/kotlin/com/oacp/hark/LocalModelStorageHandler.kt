package com.oacp.hark

import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.thread
import kotlin.concurrent.withLock

/**
 * Manages persistent model backup in Downloads/local-llm/.
 *
 * flutter_gemma handles download + app-private storage. This handler provides
 * a persistent backup layer so models survive app reinstalls:
 *
 * - findBackup: check if a backup exists (with size)
 * - saveBackup: atomic copy from app-internal to backup
 * - restoreBackup: atomic copy from backup to app-internal
 * - deleteBackup: remove a backup file
 */
class LocalModelStorageHandler(
    private val context: android.content.Context,
) : MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val fileLocks = ConcurrentHashMap<String, ReentrantLock>()

    private fun lockFor(fileName: String): ReentrantLock =
        fileLocks.getOrPut(fileName) { ReentrantLock() }

    /** Validate fileName is a simple filename (no path traversal). */
    private fun isValidFileName(fileName: String): Boolean =
        !fileName.contains("/") && !fileName.contains("\\") &&
        !fileName.startsWith(".") && fileName == File(fileName).name

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "findBackup" -> {
                val fileName = call.argument<String>("fileName")
                if (fileName.isNullOrBlank() || !isValidFileName(fileName)) {
                    result.error("invalid_args", "Invalid fileName", null)
                } else {
                    val file = backupFile(fileName)
                    if (file.exists()) {
                        result.success(mapOf(
                            "path" to file.absolutePath,
                            "sizeBytes" to file.length(),
                        ))
                    } else {
                        result.success(null)
                    }
                }
            }

            "saveBackup" -> {
                val fileName = call.argument<String>("fileName")
                if (fileName.isNullOrBlank() || !isValidFileName(fileName)) {
                    result.error("invalid_args", "Invalid fileName", null)
                } else {
                    saveBackup(fileName, result)
                }
            }

            "restoreBackup" -> {
                val fileName = call.argument<String>("fileName")
                if (fileName.isNullOrBlank() || !isValidFileName(fileName)) {
                    result.error("invalid_args", "Invalid fileName", null)
                } else {
                    restoreBackup(fileName, result)
                }
            }

            "deleteBackup" -> {
                val fileName = call.argument<String>("fileName")
                if (fileName.isNullOrBlank() || !isValidFileName(fileName)) {
                    result.error("invalid_args", "Invalid fileName", null)
                } else {
                    val file = backupFile(fileName)
                    result.success(if (file.exists()) file.delete() else true)
                }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Atomic copy from flutter_gemma's app documents dir to persistent backup.
     * Writes to .tmp file first, renames on success. Per-file locking prevents
     * concurrent writes to the same model.
     */
    private fun saveBackup(fileName: String, result: MethodChannel.Result) {
        thread {
            lockFor(fileName).withLock {
                try {
                    val source = internalModelFile(fileName)
                    if (!source.exists()) {
                        Log.w(TAG, "No internal model file to back up: ${source.absolutePath}")
                        postSuccess(result, null)
                        return@withLock
                    }

                    val target = backupFile(fileName)
                    val tmpFile = File(target.parentFile, "${fileName}.tmp")
                    target.parentFile?.mkdirs()

                    // Atomic: write to tmp, then rename
                    source.inputStream().buffered().use { input ->
                        tmpFile.outputStream().buffered().use { output ->
                            input.copyTo(output)
                        }
                    }

                    // Validate size matches source
                    if (tmpFile.length() != source.length()) {
                        tmpFile.delete()
                        postError(result, "backup_failed",
                            "Size mismatch: expected ${source.length()}, got ${tmpFile.length()}", null)
                        return@withLock
                    }

                    // Atomic rename
                    if (target.exists()) target.delete()
                    if (!tmpFile.renameTo(target)) {
                        tmpFile.delete()
                        postError(result, "backup_failed", "Rename failed", null)
                        return@withLock
                    }

                    Log.i(TAG, "Backed up model: $fileName (${target.length() / 1024 / 1024} MB)")
                    postSuccess(result, target.absolutePath)
                } catch (error: Exception) {
                    // Clean up tmp file on any failure
                    try {
                        backupFile(fileName).parentFile?.let { dir ->
                            File(dir, "${fileName}.tmp").delete()
                        }
                    } catch (_: Exception) {}
                    Log.e(TAG, "Backup failed for $fileName: ${error.javaClass.simpleName}", error)
                    postError(result, "backup_failed",
                        "${error.javaClass.simpleName}: ${error.message ?: "unknown"}", null)
                }
            }
        }
    }

    /**
     * Atomic copy from persistent backup to app-internal storage.
     * Returns the internal path on success, null if no backup exists.
     */
    private fun restoreBackup(fileName: String, result: MethodChannel.Result) {
        thread {
            lockFor(fileName).withLock {
                try {
                    val source = backupFile(fileName)
                    if (!source.exists()) {
                        postSuccess(result, null)
                        return@withLock
                    }

                    val target = internalModelFile(fileName)
                    target.parentFile?.mkdirs()

                    // Skip copy if already restored (same size)
                    if (target.exists() && target.length() == source.length()) {
                        Log.i(TAG, "Internal file matches backup, skipping copy")
                        postSuccess(result, target.absolutePath)
                        return@withLock
                    }

                    val tmpFile = File(target.parentFile, "${fileName}.tmp")

                    // Atomic: write to tmp, then rename
                    source.inputStream().buffered().use { input ->
                        tmpFile.outputStream().buffered().use { output ->
                            input.copyTo(output)
                        }
                    }

                    if (tmpFile.length() != source.length()) {
                        tmpFile.delete()
                        postError(result, "restore_failed",
                            "Size mismatch: expected ${source.length()}, got ${tmpFile.length()}", null)
                        return@withLock
                    }

                    if (target.exists()) target.delete()
                    if (!tmpFile.renameTo(target)) {
                        tmpFile.delete()
                        postError(result, "restore_failed", "Rename failed", null)
                        return@withLock
                    }

                    Log.i(TAG, "Restored from backup: $fileName (${target.length() / 1024 / 1024} MB)")
                    postSuccess(result, target.absolutePath)
                } catch (error: Exception) {
                    try {
                        internalModelFile(fileName).parentFile?.let { dir ->
                            File(dir, "${fileName}.tmp").delete()
                        }
                    } catch (_: Exception) {}
                    Log.e(TAG, "Restore failed for $fileName: ${error.javaClass.simpleName}", error)
                    postError(result, "restore_failed",
                        "${error.javaClass.simpleName}: ${error.message ?: "unknown"}", null)
                }
            }
        }
    }

    /** flutter_gemma's documents dir: context.filesDir/app_flutter/ */
    private fun internalModelFile(fileName: String): File {
        val appFlutterDir = File(context.filesDir, "app_flutter")
        return File(appFlutterDir, fileName)
    }

    /** Persistent backup: Downloads/local-llm/ */
    private fun backupFile(fileName: String): File {
        @Suppress("DEPRECATION")
        val downloadsDir =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        return File(File(downloadsDir, "local-llm"), fileName)
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun postError(
        result: MethodChannel.Result,
        code: String,
        message: String?,
        details: Any?,
    ) {
        mainHandler.post { result.error(code, message, details) }
    }

    companion object {
        private const val TAG = "LocalModelStorage"
    }
}
