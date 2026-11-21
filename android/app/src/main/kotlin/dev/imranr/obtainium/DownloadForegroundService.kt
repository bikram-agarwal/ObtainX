package dev.imranr.obtainium

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class DownloadForegroundService : Service() {
    // Whether a startForeground on this instance succeeded. Concurrent
    // downloads share the service, so a later download's refused start must
    // not stop the service an earlier one is still running under.
    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification(intent)
        val notificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, DEFAULT_NOTIFICATION_ID)
            ?: DEFAULT_NOTIFICATION_ID
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    notificationId,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(notificationId, notification)
            }
            inForeground = true
        } catch (_: Exception) {
            // Android refused (e.g. ForegroundServiceStartNotAllowedException
            // once Android 15's daily dataSync allowance is used up). Thrown
            // here, it would crash the app; the download carries on
            // unprotected, and its progress notification is still posted.
            if (!inForeground) stopSelf()
        }
        return START_NOT_STICKY
    }

    /// Android 15+ stops dataSync services after their daily time allowance,
    /// and crashes an app whose service is still running a few seconds later.
    /// Running downloads carry on unprotected.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    private fun buildNotification(intent: Intent?): Notification {
        val channelCode = intent?.getStringExtra(EXTRA_CHANNEL_CODE) ?: DEFAULT_CHANNEL_CODE
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME) ?: channelCode
        val channelDescription = intent?.getStringExtra(EXTRA_CHANNEL_DESCRIPTION) ?: channelName
        val notificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, DEFAULT_NOTIFICATION_ID)
            ?: DEFAULT_NOTIFICATION_ID
        val appId = intent?.getStringExtra(EXTRA_APP_ID)
        ensureMinImportanceChannel(this, channelCode, channelName, channelDescription)

        val contentIntent = openAppPendingIntent(this, notificationId)
        val cancelIntent = if (!appId.isNullOrBlank()) {
            PendingIntent.getBroadcast(
                this,
                appId.hashCode(),
                Intent(this, DownloadActionReceiver::class.java).apply {
                    action = DownloadActionReceiver.ACTION_CANCEL_DOWNLOAD
                    putExtra(DownloadActionReceiver.EXTRA_APP_ID, appId)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else {
            null
        }

        val builder = Notification.Builder(this, channelCode)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(intent?.getStringExtra(EXTRA_TITLE) ?: channelName)
            .setContentText(intent?.getStringExtra(EXTRA_MESSAGE) ?: channelDescription)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setProgress(100, 0, false)
        if (cancelIntent != null) {
            builder.addAction(
                R.drawable.ic_notification,
                intent?.getStringExtra(EXTRA_CANCEL_LABEL) ?: "Cancel",
                cancelIntent,
            )
        }
        return builder.build()
    }

    companion object {
        const val EXTRA_NOTIFICATION_ID = "notificationId"
        const val EXTRA_APP_ID = "appId"
        const val EXTRA_TITLE = "title"
        const val EXTRA_MESSAGE = "message"
        const val EXTRA_CHANNEL_CODE = "channelCode"
        const val EXTRA_CHANNEL_NAME = "channelName"
        const val EXTRA_CHANNEL_DESCRIPTION = "channelDescription"
        const val EXTRA_CANCEL_LABEL = "cancelLabel"
        private const val DEFAULT_NOTIFICATION_ID = 7701
        private const val DEFAULT_CHANNEL_CODE = "APP_DOWNLOADING"
    }
}
