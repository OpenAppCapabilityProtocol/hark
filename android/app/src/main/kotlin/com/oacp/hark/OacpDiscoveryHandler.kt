package com.oacp.hark

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

class OacpDiscoveryHandler(
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "discoverOacpApps" -> result.success(discoverOacpApps())
            else -> result.notImplemented()
        }
    }

    private fun discoverOacpApps(): List<Map<String, Any?>> {
        val packageManager = context.packageManager
        val packageInfos = getInstalledPackages(packageManager)
        val discoveredApps = mutableListOf<Map<String, Any?>>()

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
                    val baseRecord = mutableMapOf<String, Any?>(
                        "packageName" to packageInfo.packageName,
                        "authority" to authority,
                        "appLabel" to resolveAppLabel(packageManager, packageInfo),
                        "versionName" to (packageInfo.versionName ?: ""),
                    )

                    try {
                        baseRecord["manifestJson"] = readProviderText(authority, "manifest")
                        baseRecord["contextMarkdown"] = readProviderText(authority, "context")
                    } catch (error: Exception) {
                        baseRecord["error"] = error.message ?: error.javaClass.simpleName
                    }

                    discoveredApps.add(baseRecord)
                }
            }
        }

        return discoveredApps.distinctBy { "${it["packageName"]}:${it["authority"]}" }
    }

    private fun getInstalledPackages(packageManager: PackageManager): List<PackageInfo> {
        val flags = PackageManager.GET_PROVIDERS.toLong()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getInstalledPackages(PackageManager.PackageInfoFlags.of(flags))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstalledPackages(PackageManager.GET_PROVIDERS)
        }
    }

    private fun resolveAppLabel(packageManager: PackageManager, packageInfo: PackageInfo): String {
        val applicationInfo = packageInfo.applicationInfo ?: return packageInfo.packageName
        return packageManager.getApplicationLabel(applicationInfo).toString()
    }

    private fun readProviderText(authority: String, path: String): String {
        val uri = Uri.parse("content://$authority/$path")
        context.contentResolver.openInputStream(uri)?.use { input ->
            return input.bufferedReader().readText()
        }

        throw IOException("Unable to read $uri")
    }
}
