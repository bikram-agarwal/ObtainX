package dev.imranr.obtainium

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.system.Os
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
                            val targetActivity = call.argument<String?>("activity")
                            val useChooser = call.argument<Boolean>("useChooser") ?: false
                            launchInstallIntent(path, targetPackage, targetActivity, useChooser)
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
        val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(dummyUri, apkMime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(dummyUri, apkMime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val seen = mutableSetOf<Pair<String, String>>()
        val result = mutableListOf<Map<String, String>>()
        for (resolveInfo in packageManager.queryIntentActivities(installIntent, 0)) {
            val pkg = resolveInfo.activityInfo.packageName
            val activity = resolveInfo.activityInfo.name
            if (seen.add(pkg to activity)) {
                result.add(mapOf(
                    "packageName" to pkg,
                    "activityName" to activity,
                    "label" to resolveInfo.loadLabel(packageManager).toString()
                ))
            }
        }
        for (resolveInfo in packageManager.queryIntentActivities(viewIntent, 0)) {
            val pkg = resolveInfo.activityInfo.packageName
            val activity = resolveInfo.activityInfo.name
            if (seen.add(pkg to activity)) {
                result.add(mapOf(
                    "packageName" to pkg,
                    "activityName" to activity,
                    "label" to resolveInfo.loadLabel(packageManager).toString()
                ))
            }
        }
        return result
    }

    private fun copyToReleaseCache(sourceFile: File): File {
        val releasesDir = File(cacheDir, "releases").apply { mkdirs() }
        val releaseFile = File(releasesDir, sourceFile.name)
        sourceFile.inputStream().use { input ->
            releaseFile.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val cacheRoot = cacheDir.parentFile!!.parentFile!!
                generateSequence(releaseFile) { it.parentFile }
                    .takeWhile { it != cacheRoot }
                    .forEach { f ->
                        val mode = if (f.isDirectory) 0b001001001 else 0b100100100
                        val oldMode = Os.stat(f.path).st_mode and 0b111111111111
                        val newMode = oldMode or mode
                        if (newMode != oldMode) Os.chmod(f.path, newMode)
                    }
            } catch (_: Exception) { }
        }
        return releaseFile
    }

    @Suppress("DEPRECATION")
    private fun launchInstallIntent(
        apkFilePath: String,
        targetPackage: String?,
        targetActivity: String?,
        useChooser: Boolean
    ) {
        val sourceFile = File(apkFilePath)
        if (!sourceFile.exists()) throw IllegalStateException("APK file not found: $apkFilePath")
        val releaseFile = copyToReleaseCache(sourceFile)
        val uri = FileProvider.getUriForFile(this, "$packageName", releaseFile)
        val apkMime = "application/vnd.android.package-archive"
        val installFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            Intent.FLAG_GRANT_READ_URI_PERMISSION
        } else {
            0
        }

        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(uri, apkMime)
            addFlags(installFlag)
            if (targetPackage != null && targetActivity != null) {
                component = ComponentName(targetPackage, targetActivity)
            }
        }

        val installIntent = if (useChooser) {
            Intent.createChooser(intent, getString(R.string.select_installer))
        } else {
            intent
        }

        try {
            startActivity(installIntent)
        } catch (e: Exception) {
            installIntent.addFlags(installFlag or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(installIntent)
        }
    }
}
