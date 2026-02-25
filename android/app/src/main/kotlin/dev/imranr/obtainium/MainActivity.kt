package dev.imranr.obtainium

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "dev.imranr.obtainium/installer_resolver"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "queryApkInstallerActivities" -> {
                    try {
                        val installers = queryApkInstallerActivities()
                        result.success(installers)
                    } catch (e: Exception) {
                        result.error("QUERY_FAILED", e.message, null)
                    }
                }
                "launchInstallIntent" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGS", "path required", null)
                    } else {
                        try {
                            val targetPackage = call.argument<String?>("package")
                            launchInstallIntent(path, targetPackage)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("LAUNCH_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun queryApkInstallerActivities(): List<Map<String, String>> {
        val apkMime = "application/vnd.android.package-archive"
        val dummyUri = Uri.parse("content://$packageName/dummy.apk")
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(dummyUri, apkMime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = apkMime
            putExtra(Intent.EXTRA_STREAM, dummyUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val seen = mutableSetOf<String>()
        val result = mutableListOf<Map<String, String>>()
        for (resolveInfo in packageManager.queryIntentActivities(viewIntent, 0)) {
            val pkg = resolveInfo.activityInfo.packageName
            if (seen.add(pkg)) {
                result.add(mapOf(
                    "packageName" to pkg,
                    "label" to resolveInfo.loadLabel(packageManager).toString()
                ))
            }
        }
        for (resolveInfo in packageManager.queryIntentActivities(shareIntent, 0)) {
            val pkg = resolveInfo.activityInfo.packageName
            if (seen.add(pkg)) {
                result.add(mapOf(
                    "packageName" to pkg,
                    "label" to resolveInfo.loadLabel(packageManager).toString()
                ))
            }
        }
        return result
    }

    private fun launchInstallIntent(apkFilePath: String, targetPackage: String?) {
        val file = File(apkFilePath)
        if (!file.exists()) throw IllegalStateException("APK file not found: $apkFilePath")
        val uri = FileProvider.getUriForFile(this, "$packageName", file)
        if (targetPackage != null) {
            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                type = "application/vnd.android.package-archive"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                setPackage(targetPackage)
            }
            startActivity(shareIntent)
        } else {
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(viewIntent)
        }
    }
}
