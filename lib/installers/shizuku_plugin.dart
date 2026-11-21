import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:obtainium/core/logging/app_logger.dart';
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
Future<T> runExclusiveShizukuPluginCall<T>(Future<T> Function() call) =>
    startExclusiveShizukuPluginCall(call).result;

/// How long a plugin call may stay pending once the install race (#3369, D15)
/// has already settled its install by package polling, before it counts as
/// stalled and [ShizukuPluginCall.releaseIfStalled] frees the queue. Not a
/// const only so tests can shorten it.
@visibleForTesting
Duration shizukuStalledCallGrace = const Duration(seconds: 30);

/// Queues [call] like [runExclusiveShizukuPluginCall] and returns a handle
/// that can free the queue if the call's native result never arrives.
ShizukuPluginCall<T> startExclusiveShizukuPluginCall<T>(
  Future<T> Function() call,
) {
  final ShizukuPluginCall<T> handle = ShizukuPluginCall<T>._();
  _shizukuPluginCallQueue = _shizukuPluginCallQueue.then((_) async {
    if (handle._released.isCompleted) return;
    handle._started = true;
    final Future<void> settled = () async {
      try {
        final T value = await call();
        if (!handle._result.isCompleted) handle._result.complete(value);
      } catch (error, stackTrace) {
        if (!handle._result.isCompleted) {
          handle._result.completeError(error, stackTrace);
        }
      }
    }();
    await Future.any([settled, handle._released.future]);
  });
  return handle;
}

/// A call in the exclusive plugin queue (see [startExclusiveShizukuPluginCall]).
class ShizukuPluginCall<T> {
  ShizukuPluginCall._();

  final Completer<T> _result = Completer<T>();
  final Completer<void> _released = Completer<void>();
  bool _started = false;

  /// The call's own result.
  Future<T> get result => _result.future;

  /// Frees the queue from this call if it is still pending after [grace].
  ///
  /// Some ROMs (HyperOS, #3369) commit a privileged install but never deliver
  /// the session result, so the plugin call never returns and every later
  /// call waits behind it forever. The install race settles the app's own
  /// outcome by polling; this handles the queue.
  ///
  /// Not released at once (D15 a): the plugin keeps one shared result slot,
  /// so a late result could otherwise answer whichever call came next — the
  /// cross-talk the queue exists to prevent (#283).
  ///
  /// The plugin answers any call made while a job is active with `cancelled`
  /// and cancels that job. One harmless sacrificial call, sent past the queue
  /// (which this call holds), therefore cancels the stalled job and is
  /// expected to fail with `cancelled`; then the queue moves on. A call that
  /// never reached the plugin is simply dropped from the queue.
  Future<void> releaseIfStalled({Duration? grace}) async {
    if (_result.isCompleted || _released.isCompleted) return;
    grace ??= shizukuStalledCallGrace;
    await Future.any<void>([
      _result.future.then<void>((_) {}, onError: (Object _) {}),
      Future<void>.delayed(grace),
    ]);
    if (_result.isCompleted || _released.isCompleted) return;
    if (_started) {
      AppLogger.warn(
        'Shizuku plugin call still pending ${grace.inSeconds}s after its '
        'install was settled; cancelling it to free the plugin queue.',
      );
      try {
        await ShizukuApkInstaller().getPlatformVersion();
      } on PlatformException catch (e) {
        if (e.code != 'cancelled') {
          AppLogger.info(
            'Sacrificial Shizuku plugin call failed: ${e.code} ${e.message}',
          );
        }
      } catch (e) {
        AppLogger.info('Sacrificial Shizuku plugin call failed: $e');
      }
    }
    if (_result.isCompleted || _released.isCompleted) return;
    _result.completeError(
      PlatformException(
        code: 'cancelled',
        message: 'Released a stalled plugin call',
      ),
    );
    _released.complete();
  }
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
