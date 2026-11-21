package dev.imranr.obtainium

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle

/// Hands `obtainium://` links and text shares to the existing ObtainX window,
/// so a link or share never opens a second one (#354).
///
/// MainActivity is singleTop, which reuses a window only when it is on top of
/// the caller's task. A browser that opens links without
/// FLAG_ACTIVITY_NEW_TASK (Chrome adds the flag, other browsers may not) then
/// stacks a second MainActivity, with its own Flutter engine, on top of the
/// browser. The stock installer's status intent names MainActivity by class,
/// so Android sends that intent to the original window instead. The install
/// prompt then opens behind the browser, and the page that started the
/// install waits for a result that never arrives. This relay starts
/// MainActivity with the flags Chrome uses, so every caller gets Chrome's
/// result: a single window, which receives every link, share and install
/// result.
///
/// Why not launchMode="singleTask" on MainActivity: it routes links the same
/// way, but it also closes any screen above MainActivity (file pickers, the
/// install-permission page) when ObtainX is reopened from its icon.
///
/// Upstream Obtainium declares these two intent filters on MainActivity. When
/// you sync, keep them on this activity.
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
    private fun mainActivityIntentFor(source: Intent?): Intent {
        val target = Intent(this, MainActivity::class.java).addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        val fromHistory = source != null &&
            (source.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (source == null || fromHistory) {
            // Reopened from Recents: open ObtainX, but do not replay the link.
            return target
        }
        when (source.action) {
            Intent.ACTION_VIEW -> {
                val link = source.data
                if (link?.scheme == LINK_SCHEME) {
                    target.setAction(Intent.ACTION_VIEW).setData(link)
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
        }
        return target
    }

    private companion object {
        const val LINK_SCHEME = "obtainium"
    }
}
