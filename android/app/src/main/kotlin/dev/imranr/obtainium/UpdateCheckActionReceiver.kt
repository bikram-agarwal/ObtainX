package dev.imranr.obtainium

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// The Stop action on UpdateCheckForegroundService's notification (v1.7.5 sync
/// U1, upstream #698's cancel). Shows the notification as stopping, then asks
/// the Dart check to take no more apps. Works with the activity in the
/// background: the service keeps its process, and the Dart isolate, running.
class UpdateCheckActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_STOP_UPDATE_CHECK) return
        UpdateCheckForegroundService.showStopping()
        MainActivity.stopUpdateCheckFromNotification()
    }

    companion object {
        const val ACTION_STOP_UPDATE_CHECK = "dev.imranr.obtainium.STOP_UPDATE_CHECK"
    }
}
