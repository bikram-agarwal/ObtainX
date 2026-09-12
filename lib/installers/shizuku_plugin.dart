import 'dart:async';

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

// Tail of the queue of native plugin calls; see [runExclusiveShizukuPluginCall].
Future<void> _shizukuPluginCallQueue = Future<void>.value();

/// Runs [call] with exclusive access to the `shizuku_apk_installer` plugin.
///
/// The plugin is a single native object whose mode is *global state*: every
/// call site does `setInstallerMode` and then acts on whatever mode is
/// currently selected. Two overlapping sequences can therefore interleave so
/// that one of them installs under the other's mode. Worse, a bulk update with
/// parallel downloads used to fire one permission check per app the moment its
/// APK was ready (all at once when the APKs were already cached), and the first
/// check to return would start an install while the rest were still in flight -
/// the batch then stalled with every row stuck at "downloaded" or "installing"
/// and nothing in the logs, because a hang here happens before any install line
/// is written (ObtainX#283).
///
/// Serializing every native call removes the interleaving entirely. Queued
/// calls run in submission order; a failing call passes its error to its own
/// caller without breaking the queue for the calls behind it.
Future<T> runExclusiveShizukuPluginCall<T>(Future<T> Function() call) {
  final Completer<T> completer = Completer<T>();
  _shizukuPluginCallQueue = _shizukuPluginCallQueue.then((_) async {
    try {
      completer.complete(await call());
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  });
  return completer.future;
}

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
    // Mode selection and the check that reads it have to be one atomic unit, or
    // a concurrent caller can switch the mode out from under this check.
    final String? resCode = await runExclusiveShizukuPluginCall(() async {
      await installer.setInstallerMode(mode);
      return installer.checkPermission();
    });
    if (resCode != 'services_not_found' || attempt >= retries) {
      return resCode;
    }
    // Backoff waits outside the lock so a retrying check doesn't block installs.
    await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
  }
}
