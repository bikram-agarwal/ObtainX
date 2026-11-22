package dev.imranr.obtainium

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/// Hands `obtainium://` links, text shares, app-store launches and App Info's
/// "App details" to the existing ObtainX window, so none of them opens a
/// second one (#354). ObtainX's launcher shortcuts are `obtainium://` links
/// sent here too.
///
/// MainActivity is singleTop, which reuses a window only when it is on top of
/// the caller's task. A caller that starts it without
/// FLAG_ACTIVITY_NEW_TASK (some browsers, most share sheets, an app opening
/// "the app store") then stacks a second MainActivity, with its own Flutter
/// engine, on top of the caller. The stock installer's status intent names
/// MainActivity by class, so Android sends that intent to the original window
/// instead. The install prompt then opens behind the caller, and the page that
/// started the install waits for a result that never arrives.
///
/// This relay starts MainActivity with NEW_TASK, CLEAR_TOP and SINGLE_TOP.
/// NEW_TASK puts it in ObtainX's own task, and CLEAR_TOP with SINGLE_TOP hands
/// the intent to the MainActivity already there (onNewIntent) instead of
/// stacking another. Whatever caller and flags started the relay, there is one
/// window, and it receives every link, share and install result. CLEAR_TOP also
/// closes any ObtainX screen above MainActivity, such as a file picker, but
/// only when a link, share or store launch arrives.
///
/// Why not launchMode="singleTask" on MainActivity: it routes these the same
/// way, but it also closes those screens whenever ObtainX is reopened from its
/// launcher icon.
///
/// Upstream Obtainium declares these intent filters on MainActivity. When you
/// sync, keep them on this activity.
class LinkRelayActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            startActivity(mainActivityIntentFor(intent))
        } catch (_: ActivityNotFoundException) {
            // MainActivity ships in this app, so there is nothing to fall back to.
        }
        // The NoDisplay theme requires a call to finish() before onResume().
        finish()
    }

    /// Builds a new intent that holds only what MainActivity reads. A copy of
    /// the incoming intent would also carry a selector, component or flags
    /// that an explicit caller chose.
    ///
    /// Reopening from Recents never reaches here: this activity is
    /// excludeFromRecents and finishes at once. MainActivity skips a share
    /// replayed from Recents itself (getSharedTextFromIntent).
    private fun mainActivityIntentFor(source: Intent?): Intent {
        val target = Intent(this, MainActivity::class.java).addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        when (source?.action) {
            Intent.ACTION_VIEW -> {
                val link = source.data
                if (link?.scheme == LINK_SCHEME) {
                    target.setAction(Intent.ACTION_VIEW).setData(link)
                }
            }
            // App Info's "App details", shown for apps ObtainX installed:
            // open the app's page, as an obtainium://open link does.
            Intent.ACTION_SHOW_APP_INFO -> {
                val packageName = source.getStringExtra(Intent.EXTRA_PACKAGE_NAME)
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                if (packageName != null) {
                    val openUri = Uri.Builder()
                        .scheme(LINK_SCHEME)
                        .authority(OPEN_HOST)
                        .appendQueryParameter(OPEN_ID_PARAM, packageName)
                        .build()
                    target.setAction(Intent.ACTION_VIEW).setData(openUri)
                }
            }
            Intent.ACTION_SEND -> {
                val type = source.type
                if (type?.startsWith("text/") == true) {
                    target.setAction(Intent.ACTION_SEND)
                        .setType(type)
                        .putExtra(
                            Intent.EXTRA_TEXT,
                            source.getCharSequenceExtra(Intent.EXTRA_TEXT),
                        )
                }
            }
            // ACTION_MAIN with CATEGORY_APP_MARKET carries nothing to forward:
            // it only opens ObtainX.
        }
        return target
    }

    private companion object {
        const val LINK_SCHEME = "obtainium"
        const val OPEN_HOST = "open"
        const val OPEN_ID_PARAM = "id"
    }
}
