import 'dart:io';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/installers/installer.dart';
import 'package:obtainium/providers/source_provider.dart';

/// Android PackageInstaller status codes (`PackageInstaller.STATUS_*`).
const int _statusFailure = 1;
const int _statusFailureAborted = 3;
const int _statusFailureInvalid = 4;
const int _statusFailureConflict = 5;
const int _statusFailureStorage = 6;
const int _statusFailureIncompatible = 7;

/// Android 14, from which `pm install` refuses an app that targets an API
/// below [_lowTargetSdkBlockBelow] unless told to bypass that block.
const int _androidApiLevelU = 34;
const int _lowTargetSdkBlockBelow = 23;

/// The `pm install` line of the root install script (upstream #3478).
///
/// v1.7.5 sync D-07: ObtainX's shape. The user is the script's `$uid`, set to
/// the Android user ObtainX runs as (or the current user when that can't be
/// read), not a number with upstream's user-0 fallback. `-i` is the installer
/// of record from [installerPackageNameForApp] (D14).
@visibleForTesting
String buildRootInstallCommand({
  required String installerPackageName,
  required List<String> stagedApks,
  required bool bypassLowTargetSdkBlock,
}) => [
  'pm',
  'install',
  '-r',
  if (installerPackageName.isNotEmpty) ...[
    '-i',
    RootInstaller._quoteShell(installerPackageName),
  ],
  '--user',
  '"\$uid"',
  if (bypassLowTargetSdkBlock) '--bypass-low-target-sdk-block',
  ...stagedApks,
].join(' ');

/// Installs via the Android `pm` CLI over root (`su`) (upstream #3277).
///
/// Adapted for ObtainX: `pm`'s failure reasons are mapped to PackageInstaller
/// status codes so Needs attention works as with the other installers, the
/// install targets the Android user ObtainX itself runs as (work profiles,
/// secondary users), and a granted root check is briefly reused across a batch.
class RootInstaller extends Installer {
  RootInstaller(super.settingsProvider);

  /// How long a granted `su` check stays valid, so a batch of installs doesn't
  /// raise one superuser toast per app.
  static const Duration _rootCheckReuse = Duration(minutes: 2);
  static DateTime? _rootConfirmedAt;

  @override
  String get modeKey => 'root';

  @override
  Future<bool> canInstallSilently(App app) async => checkPermission();

  @override
  Future<bool> checkPermission() async {
    final DateTime? confirmedAt = _rootConfirmedAt;
    if (confirmedAt != null &&
        DateTime.now().difference(confirmedAt) < _rootCheckReuse) {
      return true;
    }
    try {
      final bool granted =
          (await _runAsRoot('id -u')).stdout.toString().trim() == '0';
      _rootConfirmedAt = granted ? DateTime.now() : null;
      return granted;
    } on ProcessException {
      _rootConfirmedAt = null;
      AppLogger.info(
        'Root check failed: su binary or caller is not available.',
      );
      return false;
    }
  }

  @override
  Future<void> ensurePermission({ThemeData? toastTheme}) async {
    if (!await checkPermission()) {
      throw ObtainiumError(tr('rootNotGranted'));
    }
  }

  @override
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  }) async {
    try {
      // Stage the APKs under /data/local/tmp, which pm can read,
      // then install and remove the temp copies in the same session.
      // Paths are written by index so the base APK (index 0) stays first
      // for split-APK installs.
      final stagedCopies = [
        for (var i = 0; i < apkFilePaths.length; i++)
          'cp ${_quoteShell(apkFilePaths[i])} "\$d/obt$i.apk"',
      ].join('\n');
      final stagedApks = [
        for (var i = 0; i < apkFilePaths.length; i++) '"\$d/obt$i.apk"',
      ];
      // The installer of record from [installerPackageNameForApp] (Google
      // Play, or the Galaxy Store for a Samsung app; D14), the same option
      // Shizuku reads.
      final installerPackageName =
          installOptions['installerPackageName'] as String? ?? '';
      final installLine = buildRootInstallCommand(
        installerPackageName: installerPackageName,
        stagedApks: stagedApks,
        bypassLowTargetSdkBlock:
            apkFilePaths.isNotEmpty &&
            await _shouldBypassLowTargetSdkBlock(apkFilePaths.first),
      );
      // The user ObtainX runs as, not the foreground user: in a work profile
      // or secondary user, `am get-current-user` names a different user.
      final int? ownUserId = await _ownAndroidUserId();
      final script = [
        'd="\$(mktemp -d /data/local/tmp/obtainium.XXXXXX)" || exit 1',
        'trap \'rm -rf "\$d"\' EXIT',
        stagedCopies,
        ownUserId != null
            ? 'uid=$ownUserId'
            : 'uid="\$(am get-current-user 2>/dev/null)"; uid="\${uid:-0}"',
        installLine,
      ].join('\n');
      final result = await _runAsRoot(script);
      final String output = '${result.stdout}\n${result.stderr}'.trim();
      // pm reports failures on stdout as `Failure [INSTALL_FAILED_X: ...]`.
      final RegExpMatch? failure = RegExp(r'Failure \[([A-Z0-9_]+)')
          .firstMatch(output);
      if (result.exitCode != 0 || failure != null) {
        AppLogger.warn(
          'Root pm install failed for $appId (exit ${result.exitCode}): $output',
        );
        return InstallResult.error(statusCodeForPmFailure(failure?.group(1)));
      }
      return InstallResult.success();
    } on ProcessException catch (e) {
      AppLogger.error(e, message: 'Root pm install failed for $appId');
      return InstallResult.error(_statusFailure);
    } on IOException catch (e) {
      AppLogger.error(e, message: 'Root pm install I/O error for $appId');
      return InstallResult.error(_statusFailure);
    }
  }

  /// Maps a `pm install` failure reason to the PackageInstaller status the
  /// session installer would have reported for it, mirroring Android's
  /// `PackageManager.installStatusToPublicStatus`.
  @visibleForTesting
  static int statusCodeForPmFailure(String? reason) {
    if (reason == null) return _statusFailure;
    if (reason.startsWith('INSTALL_PARSE_FAILED_')) {
      return _statusFailureInvalid;
    }
    switch (reason) {
      case 'INSTALL_FAILED_ALREADY_EXISTS':
      case 'INSTALL_FAILED_DUPLICATE_PACKAGE':
      case 'INSTALL_FAILED_NO_SHARED_USER':
      case 'INSTALL_FAILED_UPDATE_INCOMPATIBLE':
      case 'INSTALL_FAILED_SHARED_USER_INCOMPATIBLE':
      case 'INSTALL_FAILED_REPLACE_COULDNT_DELETE':
      case 'INSTALL_FAILED_CONFLICTING_PROVIDER':
      case 'INSTALL_FAILED_DUPLICATE_PERMISSION':
        return _statusFailureConflict;
      case 'INSTALL_FAILED_MISSING_SHARED_LIBRARY':
      case 'INSTALL_FAILED_OLDER_SDK':
      case 'INSTALL_FAILED_NEWER_SDK':
      case 'INSTALL_FAILED_CPU_ABI_INCOMPATIBLE':
      case 'INSTALL_FAILED_MISSING_FEATURE':
      case 'INSTALL_FAILED_USER_RESTRICTED':
      case 'INSTALL_FAILED_NO_MATCHING_ABIS':
      case 'INSTALL_FAILED_MISSING_SPLIT':
      case 'INSTALL_FAILED_DEPRECATED_SDK_VERSION':
        return _statusFailureIncompatible;
      case 'INSTALL_FAILED_INVALID_APK':
      case 'INSTALL_FAILED_INVALID_URI':
      case 'INSTALL_FAILED_DEXOPT':
      case 'INSTALL_FAILED_TEST_ONLY':
      case 'INSTALL_FAILED_PACKAGE_CHANGED':
      case 'INSTALL_FAILED_UID_CHANGED':
      case 'INSTALL_FAILED_VERSION_DOWNGRADE':
        return _statusFailureInvalid;
      case 'INSTALL_FAILED_INSUFFICIENT_STORAGE':
      case 'INSTALL_FAILED_CONTAINER_ERROR':
      case 'INSTALL_FAILED_INVALID_INSTALL_LOCATION':
      case 'INSTALL_FAILED_MEDIA_UNAVAILABLE':
        return _statusFailureStorage;
      case 'INSTALL_FAILED_VERIFICATION_TIMEOUT':
      case 'INSTALL_FAILED_VERIFICATION_FAILURE':
      case 'INSTALL_FAILED_ABORTED':
        return _statusFailureAborted;
      default:
        return _statusFailure;
    }
  }

  /// The Android user id this app runs as (uid / 100000), or null if `id` is
  /// unavailable.
  static Future<int?> _ownAndroidUserId() async {
    try {
      final int? uid = int.tryParse(
        (await Process.run('id', ['-u'])).stdout.toString().trim(),
      );
      return uid == null ? null : uid ~/ 100000;
    } on ProcessException {
      return null;
    }
  }

  /// Whether Android would refuse the base APK at [apkPath] for targeting an
  /// API below 23, as it does from Android 14 (upstream #3478). The session
  /// installers aren't refused this way; plain `pm install` is. Anything that
  /// can't be read leaves the usual command.
  Future<bool> _shouldBypassLowTargetSdkBlock(String apkPath) async {
    try {
      final int sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      if (sdkInt < _androidApiLevelU) return false;
      final PackageInfo? info = await AndroidPackageManager()
          .getPackageArchiveInfo(archiveFilePath: apkPath);
      final int? targetSdkVersion = info?.applicationInfo?.targetSdkVersion;
      return targetSdkVersion != null &&
          targetSdkVersion < _lowTargetSdkBlockBelow;
    } catch (e) {
      AppLogger.warn('Failed to inspect target SDK for $apkPath: $e');
      return false;
    }
  }

  Future<ProcessResult> _runAsRoot(String cmd) =>
      Process.run('su', ['-c', cmd]);

  static String _quoteShell(String path) =>
      "'${path.replaceAll("'", "'\\''")}'";
}
