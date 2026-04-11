// @author Bikram Agarwal
package dev.imranr.obtainium

import java.io.File

private const val APK_MIME = "application/vnd.android.package-archive"

/**
 * MIME type for intents and [CacheContentProvider.getType] so third-party installers
 * (e.g. InstallerX) receive XAPK/ZIP bundles the same way as when opened from a file manager.
 */
fun mimeTypeForInstallableFile(file: File): String {
    val name = file.name.lowercase()
    return when {
        name.endsWith(".xapk") ||
            name.endsWith(".apkm") ||
            name.endsWith(".zip") -> "application/zip"
        name.endsWith(".apks") -> APK_MIME
        else -> APK_MIME
    }
}
