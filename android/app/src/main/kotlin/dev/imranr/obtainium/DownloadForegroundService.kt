package dev.imranr.obtainium

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.ActivityOptions
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class DownloadForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification(intent)
        val notificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, DEFAULT_NOTIFICATION_ID)
            ?: DEFAULT_NOTIFICATION_ID
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                notificationId,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(notificationId, notification)
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(intent: Intent?): Notification {
        val channelCode = intent?.getStringExtra(EXTRA_CHANNEL_CODE) ?: DEFAULT_CHANNEL_CODE
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME) ?: channelCode
        val channelDescription = intent?.getStringExtra(EXTRA_CHANNEL_DESCRIPTION) ?: channelName
        val notificationId = intent?.getIntExtra(EXTRA_NOTIFICATION_ID, DEFAULT_NOTIFICATION_ID)
            ?: DEFAULT_NOTIFICATION_ID
        val appId = intent?.getStringExtra(EXTRA_APP_ID)
        ensureChannel(channelCode, channelName, channelDescription)

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val contentIntent = PendingIntent.getActivity(
            this,
            notificationId,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            activityLaunchOptions(),
        )
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

    private fun activityLaunchOptions(): android.os.Bundle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) {
            return null
        }
        return ActivityOptions.makeBasic()
            .setPendingIntentCreatorBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_IF_VISIBLE,
            )
            .toBundle()
    }

    private fun ensureChannel(
        channelCode: String,
        channelName: String,
        channelDescription: String,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val notificationManager = getSystemService(NotificationManager::class.java)
        if (notificationManager.getNotificationChannel(channelCode) != null) return
        notificationManager.createNotificationChannel(
            NotificationChannel(
                channelCode,
                channelName,
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = channelDescription
            },
        )
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
