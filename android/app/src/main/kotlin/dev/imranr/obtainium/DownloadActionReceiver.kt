package dev.imranr.obtainium

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class DownloadActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CANCEL_DOWNLOAD) return
        val appId = intent.getStringExtra(EXTRA_APP_ID) ?: return
        MainActivity.cancelDownloadFromNotification(appId)
    }

    companion object {
        const val ACTION_CANCEL_DOWNLOAD = "dev.imranr.obtainium.CANCEL_DOWNLOAD"
        const val EXTRA_APP_ID = "appId"
    }
}
