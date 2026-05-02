package dev.imranr.obtainium

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

private const val CHANNEL = "dev.imranr.obtainium/installer"
private const val DEVICE_APPS_CHANNEL = "dev.imranr.obtainium/device_apps"
private const val APK_MIME = "application/vnd.android.package-archive"
private const val RELEASE_DIR = "releases"
private const val INSTALL_TIMEOUT_MS = 120_000L
/// Ignore focus regain cancel if we lost focus more recently than this (transition bounce).
private const val FOCUS_REGAIN_CANCEL_MIN_MS = 200L

class MainActivity : FlutterActivity() {

    private class InstallWatcher(
        val methodResult: MethodChannel.Result,
        val handler: Handler,
        val receiver: BroadcastReceiver,
        val releaseCacheFiles: List<File>,
        var responded: Boolean = false,
        var focusLost: Boolean = false,
        var focusLostAtUptimeMs: Long = 0L,
        /// Set when PACKAGE_ADDED/REPLACED matches expected package. We intentionally do not complete the
        /// MethodChannel here: completing immediately would let Dart start the next batch install while
        /// InstallerX (or similar) is still showing the previous app's Done UI, so later intents are dropped.
        /// Session completes from [onResume], [onWindowFocusChanged], or timeout.
        var packageInstallBroadcastReceived: Boolean = false,
    )

    private sealed class InstallSessionOutcome {
        data class Success(val installSucceeded: Boolean) : InstallSessionOutcome()
        data class Error(val code: String, val message: String?) : InstallSessionOutcome()
    }

    private var installWatcher: InstallWatcher? = null

    private fun completeThirdPartyInstallSession(watcher: InstallWatcher, outcome: InstallSessionOutcome) {
        if (watcher.responded) return
        watcher.responded = true
        if (installWatcher === watcher) {
            installWatcher = null
        }
        watcher.handler.removeCallbacksAndMessages(null)
        try { unregisterReceiver(watcher.receiver) } catch (_: Exception) { }
        for (cacheFile in watcher.releaseCacheFiles) {
            try { cacheFile.delete() } catch (_: Exception) { }
        }
        when (outcome) {
            is InstallSessionOutcome.Success -> watcher.methodResult.success(outcome.installSucceeded)
            is InstallSessionOutcome.Error -> watcher.methodResult.error(outcome.code, outcome.message, null)
        }
    }

    override fun onResume() {
        super.onResume()
        val watcher = installWatcher ?: return
        if (watcher.responded || !watcher.packageInstallBroadcastReceived) return
        // Complete immediately so Flutter can clear installing UI without an extra frame delay.
        completeThirdPartyInstallSession(watcher, InstallSessionOutcome.Success(true))
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        val watcher = installWatcher ?: return
        if (!hasFocus) {
            watcher.focusLost = true
            watcher.focusLostAtUptimeMs = SystemClock.uptimeMillis()
            return
        }
        // Regained focus — third-party installer overlay dismissed (or user cancelled without installing).
        if (!watcher.focusLost || watcher.responded) return
        if (SystemClock.uptimeMillis() - watcher.focusLostAtUptimeMs < FOCUS_REGAIN_CANCEL_MIN_MS) {
            return
        }
        completeThirdPartyInstallSession(
            watcher,
            InstallSessionOutcome.Success(watcher.packageInstallBroadcastReceived),
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "queryApkInstallerActivities" -> {
                    try {
                        result.success(queryApkInstallerActivities())
                    } catch (ex: Exception) {
                        result.error("QUERY_ERROR", ex.message, null)
                    }
                }
                "launchInstallIntent" -> {
                    try {
                        val pathArg = call.argument<String>("path")!!
                        val apkSourcePaths = pathArg.split(',')
                            .map { it.trim() }
                            .filter { it.isNotEmpty() }
                        val targetPackage = call.argument<String>("package")
                        val targetActivity = call.argument<String>("activity")
                        val expectedPkgName = call.argument<String>("expectedPackageName")
                        launchInstallIntent(apkSourcePaths, targetPackage, targetActivity, expectedPkgName, result)
                    } catch (ex: Exception) {
                        result.error("INSTALL_ERROR", ex.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_APPS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getApplicationLabels" -> {
                    val packageNames = call.argument<List<String>>("packageNames")
                    if (packageNames == null) {
                        result.success(emptyMap<String, String>())
                        return@setMethodCallHandler
                    }
                    result.success(getApplicationLabels(packageNames))
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun getApplicationLabels(packageNames: List<String>): Map<String, String> {
        val labelsByPackageName = mutableMapOf<String, String>()
        for (packageName in packageNames) {
            try {
                val applicationInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.getApplicationInfo(
                        packageName,
                        PackageManager.ApplicationInfoFlags.of(0),
                    )
                } else {
                    packageManager.getApplicationInfo(packageName, 0)
                }
                labelsByPackageName[packageName] =
                    packageManager.getApplicationLabel(applicationInfo).toString()
            } catch (_: PackageManager.NameNotFoundException) {
                // App was uninstalled between package scan and label lookup.
            }
        }
        return labelsByPackageName
    }

    private fun queryApkInstallerActivities(): List<Map<String, Any>> {
        val results = mutableMapOf<String, Map<String, Any>>()

        val installIntent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(Uri.parse("content://dummy/test.apk"), APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        for (resolveInfo in packageManager.queryIntentActivities(installIntent, 0)) {
            val key = "${resolveInfo.activityInfo.packageName}|${resolveInfo.activityInfo.name}"
            if (!results.containsKey(key)) {
                results[key] = resolveInfoToMap(resolveInfo)
            }
        }

        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse("content://dummy/test.apk"), APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        for (resolveInfo in packageManager.queryIntentActivities(viewIntent, 0)) {
            val key = "${resolveInfo.activityInfo.packageName}|${resolveInfo.activityInfo.name}"
            if (!results.containsKey(key)) {
                results[key] = resolveInfoToMap(resolveInfo)
            }
        }

        return results.values.toList()
    }

    private fun resolveInfoToMap(resolveInfo: ResolveInfo): Map<String, Any> {
        val pkgName = resolveInfo.activityInfo.packageName
        val activityName = resolveInfo.activityInfo.name
        val label = resolveInfo.loadLabel(packageManager).toString()
        val iconBytes = try {
            val drawable = resolveInfo.loadIcon(packageManager)
            val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
                drawable.bitmap
            } else {
                val bmp = Bitmap.createBitmap(
                    drawable.intrinsicWidth.coerceAtLeast(1),
                    drawable.intrinsicHeight.coerceAtLeast(1),
                    Bitmap.Config.ARGB_8888
                )
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
                bmp
            }
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        } catch (_: Exception) {
            ByteArray(0)
        }
        val result = mutableMapOf<String, Any>(
            "packageName" to pkgName,
            "activityName" to activityName,
            "label" to label,
        )
        if (iconBytes.isNotEmpty()) {
            result["icon"] = iconBytes
        }
        return result
    }

    @Suppress("DEPRECATION")
    private fun launchInstallIntent(
        apkSourcePaths: List<String>,
        targetPackage: String?,
        targetActivity: String?,
        expectedPkgName: String?,
        methodResult: MethodChannel.Result
    ) {
        if (apkSourcePaths.isEmpty()) {
            methodResult.error("INSTALL_ERROR", "No APK paths", null)
            return
        }
        val sourceFiles = apkSourcePaths.map { path -> File(path) }
        for (source in sourceFiles) {
            if (!source.isFile) {
                methodResult.error("INSTALL_ERROR", "Not a readable file: ${source.path}", null)
                return
            }
        }
        val releaseFiles = sourceFiles.map { copyToReleaseCacheUnique(it) }
        val contentUris = releaseFiles.map { releaseFileToContentUri(it) }

        val installFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            Intent.FLAG_GRANT_READ_URI_PERMISSION
        } else {
            0
        }

        val primaryMime = if (releaseFiles.size == 1) {
            mimeTypeForInstallableFile(releaseFiles[0])
        } else {
            APK_MIME
        }
        // XAPK/APKM/ZIP bundles: use ACTION_VIEW so targets that only handle "open file"
        // (e.g. InstallerX from a file manager) receive the same intent shape.
        val intentAction =
            if (releaseFiles.size == 1 && primaryMime == "application/zip") {
                Intent.ACTION_VIEW
            } else {
                Intent.ACTION_INSTALL_PACKAGE
            }
        val intent = Intent(intentAction).apply {
            if (contentUris.size == 1) {
                setDataAndType(contentUris[0], primaryMime)
            } else {
                clipData = ClipData.newUri(contentResolver, "apk", contentUris[0]).apply {
                    for (idx in 1 until contentUris.size) {
                        addItem(ClipData.Item(contentUris[idx]))
                    }
                }
                setDataAndType(contentUris[0], primaryMime)
            }
            flags = installFlag or Intent.FLAG_ACTIVITY_NEW_TASK
            if (!targetPackage.isNullOrEmpty() && !targetActivity.isNullOrEmpty()) {
                component = ComponentName(targetPackage, targetActivity)
            }
        }

        if (expectedPkgName.isNullOrEmpty()) {
            try {
                startActivity(intent)
            } catch (_: Exception) {
                //
            } finally {
                for (releaseFile in releaseFiles) {
                    try { releaseFile.delete() } catch (_: Exception) { }
                }
            }
            methodResult.success(false)
            return
        }

        val handler = Handler(Looper.getMainLooper())

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, broadcastIntent: Intent) {
                // Use [installWatcher] only (one assignment before [registerReceiver]) so there is no
                // window where a captured ref and [installWatcher] disagree. Tie this callback to the
                // watcher instance via [InstallWatcher.receiver] so a stale registration after a new
                // install does not mutate the wrong session.
                val session = installWatcher ?: return
                if (session.receiver !== this) return
                val changedPkg = broadcastIntent.data?.schemeSpecificPart ?: return
                if (changedPkg != expectedPkgName || session.responded) return
                if (session.packageInstallBroadcastReceived) return
                session.packageInstallBroadcastReceived = true
            }
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        val sessionWatcher = InstallWatcher(methodResult, handler, receiver, releaseFiles)
        installWatcher = sessionWatcher
        registerReceiver(receiver, filter)

        handler.postDelayed({
            if (installWatcher !== sessionWatcher || sessionWatcher.responded) return@postDelayed
            completeThirdPartyInstallSession(
                sessionWatcher,
                InstallSessionOutcome.Success(sessionWatcher.packageInstallBroadcastReceived),
            )
        }, INSTALL_TIMEOUT_MS)

        handler.post {
            try {
                startActivity(intent)
            } catch (ex: Exception) {
                if (installWatcher === sessionWatcher && !sessionWatcher.responded) {
                    completeThirdPartyInstallSession(
                        sessionWatcher,
                        InstallSessionOutcome.Error("INSTALL_ERROR", ex.message),
                    )
                } else {
                    // Guard failed: session already finished or replaced — still drop cache copies
                    // (success path keeps files until [completeThirdPartyInstallSession] runs).
                    for (releaseFile in releaseFiles) {
                        try { releaseFile.delete() } catch (_: Exception) { }
                    }
                }
            }
        }
    }

    private fun releaseFileToContentUri(releaseFile: File): Uri {
        val providerAuthority = findCacheProviderAuthority()
        val relativePath = releaseFile.path.drop(cacheDir.path.length)
        return Uri.Builder()
            .scheme("content")
            .authority(providerAuthority)
            .encodedPath(relativePath)
            .build()
    }

    private fun findCacheProviderAuthority(): String {
        val packageInfo = packageManager.getPackageInfo(packageName, PackageManager.GET_PROVIDERS)
        val providerInfo = packageInfo.providers?.find {
            it.name == CacheContentProvider::class.java.name
        } ?: throw IllegalStateException("CacheContentProvider not found in manifest")
        return providerInfo.authority
    }

    private fun copyToReleaseCacheUnique(sourceFile: File): File {
        val releasesDir = File(cacheDir, RELEASE_DIR).apply { mkdirs() }
        val uniquePrefix = UUID.randomUUID().toString()
        val releaseFile = File(releasesDir, "${uniquePrefix}_${sourceFile.name}")
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
                    .forEach { file ->
                        val mode = if (file.isDirectory) 0b001001001 else 0b100100100
                        val oldMode = Os.stat(file.path).st_mode and 0b111111111111
                        val newMode = oldMode or mode
                        if (newMode != oldMode) Os.chmod(file.path, newMode)
                    }
            } catch (_: Exception) { }
        }
        return releaseFile
    }
}
