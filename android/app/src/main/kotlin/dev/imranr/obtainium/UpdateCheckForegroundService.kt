package dev.imranr.obtainium

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

private const val UPDATE_CHECK_WAKE_LOCK_TAG = "ObtainX:UpdateCheckWakeLock"
private const val UPDATE_CHECK_WIFI_LOCK_TAG = "ObtainX:UpdateCheckWifiLock"

/// Keeps an update check the user started (pull-to-refresh, check on start,
/// obtainium://refresh) running after they leave ObtainX (#360).
///
/// That check runs on the activity's Dart isolate. With no foreground service,
/// Android caches the process as soon as no activity is visible and, from
/// Android 14 (earlier on some ROMs), freezes it, so the check stalls until the
/// app is reopened. This holds what a download holds (a foreground service plus
/// wake and Wi-Fi locks) for the length of the check.
///
/// Background checks don't use it: they already run as WorkManager work or
/// under the useFGService foreground task.
///
/// Callers pair [acquire] with [release]; the service stops when the last holder
/// releases. Everything here runs on the main thread (method-channel handlers
/// and service callbacks), so the state below needs no locking.
class UpdateCheckForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private lateinit var title: String
    private lateinit var channelCode: String
    // Built once per start: progress repaints the notification every second.
    private lateinit var contentIntent: PendingIntent

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Only [acquire] starts this, always with these extras; START_NOT_STICKY
        // means Android never restarts it with a null intent.
        val extras = requireNotNull(intent)
        title = requireNotNull(extras.getStringExtra(EXTRA_TITLE))
        channelCode = requireNotNull(extras.getStringExtra(EXTRA_CHANNEL_CODE))
        ensureMinImportanceChannel(
            this,
            channelCode,
            requireNotNull(extras.getStringExtra(EXTRA_CHANNEL_NAME)),
            requireNotNull(extras.getStringExtra(EXTRA_CHANNEL_DESCRIPTION)),
        )
        contentIntent = openAppPendingIntent(this, NOTIFICATION_ID)
        // Called even when the check has already finished: a service started
        // with startForegroundService that stops before startForeground crashes
        // the app.
        val notification = buildNotification(completed = null, total = null)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // Android refused (e.g. ForegroundServiceStartNotAllowedException
            // once Android 15's daily dataSync allowance is used up). Thrown
            // here, it would crash the app; the check runs on unprotected,
            // as it did before this service existed.
            startPending = false
            stopNow()
            return START_NOT_STICKY
        }
        startPending = false
        if (holders == 0) {
            stopNow()
        } else {
            instance = this
        }
        return START_NOT_STICKY
    }

    /// Android 15+ stops dataSync services after their daily time allowance.
    /// The check carries on unprotected, as it did before this service existed.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopNow()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        releaseLocks()
        super.onDestroy()
    }

    private fun stopNow() {
        if (instance === this) instance = null
        stopSelf()
    }

    private fun showProgress(completed: Int, total: Int) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(completed, total))
    }

    // No action buttons and no immediate-display behavior, so on Android 12+
    // the system holds this notification back for its first 10 seconds and a
    // short check never shows one. The Dart caller waits as long before
    // posting progress.
    private fun buildNotification(completed: Int?, total: Int?): Notification {
        val builder = Notification.Builder(this, channelCode)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
        if (completed != null && total != null && total > 0) {
            builder
                .setContentText("$completed/$total")
                .setProgress(total, completed.coerceIn(0, total), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                UPDATE_CHECK_WAKE_LOCK_TAG,
            ).apply {
                setReferenceCounted(false)
                // A cap against a lock outliving its check, not an expected
                // duration; onDestroy releases it when the check ends.
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        } catch (_: Exception) {
            wakeLock = null
        }
        try {
            val wifiManager =
                applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiLock = wifiManager?.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                UPDATE_CHECK_WIFI_LOCK_TAG,
            )?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            wifiLock = null
        }
    }

    private fun releaseLocks() {
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) { }
        wifiLock = null
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) { }
        wakeLock = null
    }

    companion object {
        /// Reserved among the fixed Dart notification IDs in
        /// lib/providers/notifications_provider.dart.
        private const val NOTIFICATION_ID = 12
        private const val WAKE_LOCK_TIMEOUT_MS = 60 * 60 * 1000L
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_CHANNEL_CODE = "channelCode"
        private const val EXTRA_CHANNEL_NAME = "channelName"
        private const val EXTRA_CHANNEL_DESCRIPTION = "channelDescription"

        private var holders = 0
        private var startPending = false
        private var instance: UpdateCheckForegroundService? = null

        /// Starts the service unless it is already running or starting. Throws
        /// if Android refuses the start (e.g. ForegroundServiceStartNotAllowedException
        /// when the app is already in the background).
        fun acquire(
            context: Context,
            title: String,
            channelCode: String,
            channelName: String,
            channelDescription: String,
        ) {
            if (instance == null && !startPending) {
                context.startForegroundService(
                    Intent(context, UpdateCheckForegroundService::class.java).apply {
                        putExtra(EXTRA_TITLE, title)
                        putExtra(EXTRA_CHANNEL_CODE, channelCode)
                        putExtra(EXTRA_CHANNEL_NAME, channelName)
                        putExtra(EXTRA_CHANNEL_DESCRIPTION, channelDescription)
                    },
                )
                startPending = true
            }
            holders += 1
        }

        /// Stops the service once the last holder releases. A release that
        /// lands before the service has started is handled in onStartCommand.
        fun release() {
            if (holders > 0) holders -= 1
            if (holders == 0) instance?.stopNow()
        }

        fun showProgress(completed: Int, total: Int) {
            instance?.showProgress(completed, total)
        }
    }
}
