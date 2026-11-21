package dev.imranr.obtainium

import android.app.ActivityOptions
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle

// Notification plumbing shared by ObtainX's foreground services
// (DownloadForegroundService, UpdateCheckForegroundService) and MainActivity's
// download progress notification.

// Fixed for the life of the process; resolving it costs a package-manager
// call, and download progress builds a tap target several times a second.
private var cachedLaunchIntent: Intent? = null

private fun launchIntent(context: Context): Intent {
    cachedLaunchIntent?.let { return it }
    val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        ?: Intent(context, MainActivity::class.java)
    intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    cachedLaunchIntent = intent
    return intent
}

/// Creates [channelCode] at minimum importance unless it already exists. An
/// existing channel is left alone so the user's own channel settings stand.
internal fun ensureMinImportanceChannel(
    context: Context,
    channelCode: String,
    channelName: String,
    channelDescription: String,
) {
    val notificationManager = context.getSystemService(NotificationManager::class.java)
    if (notificationManager.getNotificationChannel(channelCode) != null) return
    notificationManager.createNotificationChannel(
        NotificationChannel(
            channelCode,
            channelName,
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = channelDescription
        },
    )
}

/// A tap target that brings ObtainX to the front.
internal fun openAppPendingIntent(context: Context, requestCode: Int): PendingIntent {
    return PendingIntent.getActivity(
        context,
        requestCode,
        launchIntent(context),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        notificationLaunchOptions(),
    )
}

private fun notificationLaunchOptions(): Bundle? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) {
        return null
    }
    return ActivityOptions.makeBasic()
        .setPendingIntentCreatorBackgroundActivityStartMode(
            ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_IF_VISIBLE,
        )
        .toBundle()
}
