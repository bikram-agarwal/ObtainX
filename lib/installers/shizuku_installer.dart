import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/installers/installer.dart';
import 'package:obtainium/installers/shizuku_plugin.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shizuku_apk_installer/shizuku_apk_installer.dart';

/// Installs via the Shizuku/Sui binder API for elevated installs with
/// no user-facing permission dialog. Supports silent installs.
class ShizukuInstaller extends Installer {
  ShizukuInstaller(super.settingsProvider);

  @override
  String get modeKey => 'shizuku';

  @override
  Future<bool> canInstallSilently(App app) async => true;

  @override
  Future<bool> checkPermission() async => isShizukuPluginPermissionGranted(
    InstallerMode.shizuku,
    await checkShizukuPluginPermission(InstallerMode.shizuku),
  );

  @override
  Future<void> ensurePermission({ThemeData? toastTheme}) async {
    final String? res = await checkShizukuPluginPermission(
      InstallerMode.shizuku,
    );
    if (isShizukuPluginPermissionGranted(InstallerMode.shizuku, res)) return;
    switch (res) {
      case 'services_not_found':
        throw ObtainiumError(tr('shizukuBinderNotFound'));
      case 'old_shizuku':
        throw ObtainiumError(tr('shizukuOld'));
      case 'old_android_with_adb':
        throw ObtainiumError(tr('shizukuOldAndroidWithADB'));
      default:
        throw ObtainiumError(tr('cancelled'));
    }
  }

  /// The latest [installApk] call, for [releaseStalledInstall].
  ShizukuPluginCall<int?>? _pendingInstall;

  @override
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  }) async {
    // The installer of record (Google Play or, for Samsung apps, the Galaxy
    // Store; upstream a652ee08, D14) and update ownership for a first install
    // (upstream #3445). The backend stays Shizuku: ObtainX has Dhizuku as its
    // own installer mode, so upstream's `shizukuInstallerMode` sub-backend
    // (#2844) has no place here (INST-3).
    final String fakeInstallSource =
        installOptions['installerPackageName'] as String? ?? '';
    final bool requestUpdateOwnership =
        installOptions['requestUpdateOwnership'] as bool? ?? false;
    final uris = apkFilePaths.map((p) => File(p).uri.toString()).toList();
    final ShizukuApkInstaller shizukuInstaller = ShizukuApkInstaller();
    final ShizukuPluginCall<int?> install = startExclusiveShizukuPluginCall(
      () async {
        await shizukuInstaller.setInstallerMode(InstallerMode.shizuku);
        return uris.length > 1
            ? shizukuInstaller.installAABSplits(
                uris,
                fakeInstallSource,
                requestUpdateOwnership: requestUpdateOwnership,
              )
            : shizukuInstaller.installAPK(
                uris.first,
                fakeInstallSource,
                requestUpdateOwnership: requestUpdateOwnership,
              );
      },
    );
    _pendingInstall = install;
    return InstallResult.fromPlatformCode(await install.result);
  }

  @override
  Future<void> releaseStalledInstall() async =>
      _pendingInstall?.releaseIfStalled();
}
