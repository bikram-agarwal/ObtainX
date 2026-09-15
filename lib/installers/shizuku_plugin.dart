import 'package:shizuku_apk_installer/shizuku_apk_installer.dart';

/// Shared entry point for the `shizuku_apk_installer` permission check, used by
/// [ShizukuInstaller], [DhizukuInstaller] and the installer-mode dropdown so
/// the mode handshake and the retry workaround below can't drift between them.

/// Extra attempts allowed for a `services_not_found` result in Shizuku mode.
///
/// Three retries with the backoff below give the native listener up to ~900ms
/// to land, which is far more than a main-thread hand-off needs even on a busy
/// UI thread.
const int _shizukuBinderRetries = 3;

/// Whether [resCode] means the plugin is ready to install in [mode].
bool isShizukuPluginPermissionGranted(InstallerMode mode, String? resCode) =>
    mode == InstallerMode.dhizuku
    ? resCode == 'granted_owner'
    : resCode == 'granted_adb' || resCode == 'granted_root';

/// Selects [mode] on the plugin and returns its raw `checkPermission` result.
///
/// Shizuku mode retries a `services_not_found` result, because the native side
/// reports it spuriously on the first check in any Flutter engine: the plugin's
/// `ShizukuWorker` registers its `OnBinderReceivedListener` lazily, the first
/// time `checkPermission` runs, then reads the flag that listener sets on the
/// same background thread. `Shizuku.addBinderReceivedListenerSticky` posts the
/// callback to the main thread, so it cannot have run by the time the flag is
/// read, and a running, authorised Shizuku is reported as not running (#230).
/// Warming the worker up once at startup wouldn't cover it — WorkManager's
/// headless engine builds a fresh worker on every background run — so the retry
/// has to live inside the call.
///
/// Retrying is safe precisely because `services_not_found` is the one branch
/// that returns *before* `Shizuku.requestPermission`, so no permission dialog
/// has been raised and a second attempt can't produce a duplicate prompt. Every
/// other result — including `denied` — is returned untouched on the first pass.
///
/// Dhizuku mode is not retried: there, `services_not_found` means
/// `Dhizuku.init` returned false, which is a synchronous `ContentResolver.call`
/// answering "Dhizuku isn't available" directly rather than a deferred
/// callback. Retrying would only delay a legitimate error.
Future<String?> checkShizukuPluginPermission(InstallerMode mode) async {
  final ShizukuApkInstaller installer = ShizukuApkInstaller();
  final int retries = mode == InstallerMode.shizuku ? _shizukuBinderRetries : 0;
  for (int attempt = 0; ; attempt++) {
    await installer.setInstallerMode(mode);
    final String? resCode = await installer.checkPermission();
    if (resCode != 'services_not_found' || attempt >= retries) {
      return resCode;
    }
    await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
  }
}
