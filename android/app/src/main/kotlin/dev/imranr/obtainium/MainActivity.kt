package dev.imranr.obtainium

import android.app.Activity
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
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.DocumentsContract
import android.system.Os
import com.topjohnwu.superuser.Shell
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

private const val CHANNEL = "dev.imranr.obtainium/installer"
private const val DEVICE_APPS_CHANNEL = "dev.imranr.obtainium/device_apps"
private const val POWER_CHANNEL = "dev.imranr.obtainium/power"
private const val STORAGE_CHANNEL = "dev.imranr.obtainium/storage"
private const val SHARE_CHANNEL = "dev.imranr.obtainium/share"
private const val DOWNLOAD_WAKE_LOCK_TAG = "ObtainX:DownloadWakeLock"
private const val DOWNLOAD_WIFI_LOCK_TAG = "ObtainX:DownloadWifiLock"
private const val APK_MIME = "application/vnd.android.package-archive"
private const val RELEASE_DIR = "releases"
private const val INSTALL_TIMEOUT_MS = 120_000L
private const val INSTALL_BROADCAST_BATCH_CONTINUE_DELAY_MS = 200L
private const val OPEN_PERSISTED_DOCUMENT_TREE_REQUEST_CODE = 5107
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
    private var installerChannel: MethodChannel? = null
    private val downloadKeepAwakeLock = Any()
    private var downloadKeepAwakeCount = 0
    private var downloadWakeLock: PowerManager.WakeLock? = null
    private var downloadWifiLock: WifiManager.WifiLock? = null
    private var openPersistedDocumentTreeResult: MethodChannel.Result? = null
    private var shareChannel: MethodChannel? = null
    private var initialSharedTextConsumed = false
    private var pendingSharedText: String? = null

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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val sharedText = getSharedTextFromIntent(intent) ?: return
        enqueueSharedText(sharedText)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        installerChannel?.setMethodCallHandler { call, result ->
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
                "isRootAvailable" -> {
                    Thread {
                        try {
                            val granted = Shell.getShell().isRoot
                            runOnUiThread { result.success(granted) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(false) }
                        }
                    }.start()
                }
                "performRootInstall" -> {
                    val apkSourcePaths = call.argument<List<String>>("paths")!!
                    val pretendToBeGooglePlay = call.argument<Boolean>("pretendToBeGooglePlay") ?: false
                    performRootInstall(apkSourcePaths, pretendToBeGooglePlay, result)
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            POWER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireDownloadKeepAwake" -> {
                    result.success(acquireDownloadKeepAwake())
                }
                "releaseDownloadKeepAwake" -> {
                    releaseDownloadKeepAwake()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openPersistedDocumentTree" -> {
                    openPersistedDocumentTree(call.argument<String>("initialUri"), result)
                }
                "hasPersistedDocumentTreePermission" -> {
                    result.success(
                        hasPersistedDocumentTreePermission(call.argument<String>("uri")),
                    )
                }
                else -> result.notImplemented()
            }
        }
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialSharedText" -> {
                        if (initialSharedTextConsumed) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        initialSharedTextConsumed = true
                        val sharedText = pendingSharedText ?: getSharedTextFromIntent(intent)
                        pendingSharedText = null
                        result.success(sharedText)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        deliverPendingSharedText()
    }

    private fun enqueueSharedText(sharedText: String) {
        pendingSharedText = sharedText
        deliverPendingSharedText()
    }

    private fun deliverPendingSharedText() {
        val channel = shareChannel ?: return
        val sharedText = pendingSharedText ?: return
        channel.invokeMethod(
            "onSharedText",
            sharedText,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (pendingSharedText == sharedText) {
                        pendingSharedText = null
                    }
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                }

                override fun notImplemented() {
                }
            },
        )
    }

    private fun getSharedTextFromIntent(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent?.type != "text/plain") {
            return null
        }
        return intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
            ?.toString()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }

    private fun hasPersistedDocumentTreePermission(uriString: String?): Boolean {
        if (uriString.isNullOrBlank()) {
            return false
        }
        val uri = Uri.parse(uriString)
        return contentResolver.persistedUriPermissions.any { persistedPermission ->
            persistedPermission.uri == uri &&
                persistedPermission.isReadPermission &&
                persistedPermission.isWritePermission
        }
    }

    private fun openPersistedDocumentTree(initialUri: String?, result: MethodChannel.Result) {
        if (openPersistedDocumentTreeResult != null) {
            result.error("PICKER_ACTIVE", "A document tree picker is already active.", null)
            return
        }

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            if (!initialUri.isNullOrBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(initialUri))
            }
        }

        openPersistedDocumentTreeResult = result
        try {
            startActivityForResult(intent, OPEN_PERSISTED_DOCUMENT_TREE_REQUEST_CODE)
        } catch (ex: Exception) {
            openPersistedDocumentTreeResult = null
            result.error("OPEN_TREE_FAILED", ex.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != OPEN_PERSISTED_DOCUMENT_TREE_REQUEST_CODE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val pendingResult = openPersistedDocumentTreeResult ?: return
        openPersistedDocumentTreeResult = null

        if (resultCode != Activity.RESULT_OK) {
            pendingResult.success(null)
            return
        }

        val uri = data?.data
        if (uri == null) {
            pendingResult.success(null)
            return
        }

        val permissionFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val grantedPermissionFlags = data.flags and permissionFlags
        if (grantedPermissionFlags != permissionFlags) {
            pendingResult.error(
                "PERSIST_TREE_PERMISSION_FAILED",
                "The selected folder did not grant read and write permissions.",
                null,
            )
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                grantedPermissionFlags,
            )
            pendingResult.success(uri.toString())
        } catch (ex: Exception) {
            pendingResult.error("PERSIST_TREE_PERMISSION_FAILED", ex.message, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun acquireDownloadKeepAwake(): Boolean = synchronized(downloadKeepAwakeLock) {
        var acquiredWakeLock: PowerManager.WakeLock? = null
        var acquiredWifiLock: WifiManager.WifiLock? = null
        try {
            if (downloadWakeLock?.isHeld != true) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                acquiredWakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    DOWNLOAD_WAKE_LOCK_TAG,
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }

            if (downloadWifiLock?.isHeld != true) {
                val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    ?: throw IllegalStateException("Wifi service unavailable")
                acquiredWifiLock = wifiManager.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    DOWNLOAD_WIFI_LOCK_TAG,
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }

            if (acquiredWakeLock != null) {
                downloadWakeLock = acquiredWakeLock
            }
            if (acquiredWifiLock != null) {
                downloadWifiLock = acquiredWifiLock
            }
            downloadKeepAwakeCount += 1
            true
        } catch (_: Exception) {
            try {
                if (acquiredWifiLock?.isHeld == true) {
                    acquiredWifiLock.release()
                }
            } catch (_: Exception) { }
            try {
                if (acquiredWakeLock?.isHeld == true) {
                    acquiredWakeLock.release()
                }
            } catch (_: Exception) { }
            false
        }
    }

    private fun releaseDownloadKeepAwake() {
        synchronized(downloadKeepAwakeLock) {
            if (downloadKeepAwakeCount > 0) {
                downloadKeepAwakeCount -= 1
            }
            if (downloadKeepAwakeCount > 0) return@synchronized

            try {
                if (downloadWifiLock?.isHeld == true) {
                    downloadWifiLock?.release()
                }
            } catch (_: Exception) { }
            downloadWifiLock = null

            try {
                if (downloadWakeLock?.isHeld == true) {
                    downloadWakeLock?.release()
                }
            } catch (_: Exception) { }
            downloadWakeLock = null
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
                installerChannel?.invokeMethod(
                    "thirdPartyInstallPackageChanged",
                    mapOf("packageName" to changedPkg),
                )
                if (!session.focusLost) {
                    session.handler.postDelayed({
                        if (
                            installWatcher === session &&
                            !session.responded &&
                            session.packageInstallBroadcastReceived &&
                            !session.focusLost
                        ) {
                            completeThirdPartyInstallSession(
                                session,
                                InstallSessionOutcome.Success(true),
                            )
                        }
                    }, INSTALL_BROADCAST_BATCH_CONTINUE_DELAY_MS)
                }
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

    private fun performRootInstall(
        apkSourcePaths: List<String>,
        pretendToBeGooglePlay: Boolean,
        methodResult: MethodChannel.Result
    ) {
        val apkFiles = apkSourcePaths.map { File(it) }
        val totalSize = apkFiles.sumOf { it.length() }

        Thread {
            // Root check
            try {
                Shell.getShell()
            } catch (e: Exception) {
                runOnUiThread {
                    methodResult.error("INSTALL_ERROR", "Failed to get root shell: ${e.message}", null)
                }
                return@Thread
            }

            // Session creation
            val createCmd = StringBuilder("pm install-create -r -S $totalSize")
            if (pretendToBeGooglePlay) {
                createCmd.append(" -i com.android.vending")
            }

            val createResult = Shell.cmd(createCmd.toString()).exec()
            if (!createResult.isSuccess) {
                runOnUiThread {
                    methodResult.error("INSTALL_ERROR", createResult.out.joinToString("\n"), null)
                }
                return@Thread
            }

            val sessionId = createResult.out.firstOrNull()?.let { line: String ->
                Regex("\\[(\\d+)]").find(line)?.groupValues?.get(1)
            }
            if (sessionId == null) {
                runOnUiThread {
                    methodResult.error("INSTALL_ERROR", "Failed to get session ID", null)
                }
                return@Thread
            }

            // Install logic
            try {
                for ((index, file) in apkFiles.withIndex()) {
                    val size = file.length()
                    val apkName = "base_$index"
                    val stdoutOutput = StringBuilder()
                    val stderrOutput = StringBuilder()

                    val process = Runtime.getRuntime().exec(
                        arrayOf("su", "-c", "pm install-write -S $size $sessionId $apkName -")
                    )

                    val stdoutDrain = Thread {
                        process.inputStream.bufferedReader().use {
                            stdoutOutput.append(it.readText())
                        }
                    }
                    val stderrDrain = Thread {
                        process.errorStream.bufferedReader().use {
                            stderrOutput.append(it.readText())
                        }
                    }
                    stdoutDrain.start()
                    stderrDrain.start()

                    val timeoutSeconds = 30L + (size / (1024 * 1024 * 10))
                    val writeToProcess = CompletableFuture.runAsync {
                        try {
                            file.inputStream().use { it.copyTo(process.outputStream) }
                        } finally {
                            runCatching { process.outputStream.close() }
                        }
                        process.waitFor()
                    }

                    try {
                        writeToProcess.get(timeoutSeconds, TimeUnit.SECONDS)
                    } catch (e: Exception) {
                        process.destroyForcibly()
                        throw Exception("install-write failed for $apkName")
                    } finally {
                        stdoutDrain.join(500)
                        stderrDrain.join(500)
                    }
                }

                val commitResult = Shell.cmd("pm install-commit $sessionId").exec()
                if (commitResult.isSuccess) {
                    runOnUiThread {
                        methodResult.success(true)
                    }
                } else {
                    throw Exception("pm install-commit failed: ${commitResult.out.joinToString("\n")}")
                }
            } catch (e: Exception) {
                Shell.cmd("pm install-abandon $sessionId").exec()
                runOnUiThread {
                    methodResult.error("INSTALL_ERROR", e.message, null)
                }
            }
        }.start()
    }
}
