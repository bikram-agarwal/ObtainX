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
        val intent = Intent(Intent.ACTION_VIEW).apply {
            type = "application/vnd.android.package-archive"
        }
        val resolveInfoList = packageManager.queryIntentActivities(intent, 0)
        return resolveInfoList.map { resolveInfo ->
            val label = resolveInfo.loadLabel(packageManager).toString()
            mapOf(
                "packageName" to resolveInfo.activityInfo.packageName,
                "label" to label
            )
        }
    }

    private fun launchInstallIntent(apkFilePath: String, targetPackage: String?) {
        val file = File(apkFilePath)
        if (!file.exists()) throw IllegalStateException("APK file not found: $apkFilePath")
        val uri = FileProvider.getUriForFile(this, "$packageName", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            targetPackage?.let { setPackage(it) }
        }
        startActivity(intent)
    }
}
