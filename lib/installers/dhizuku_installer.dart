import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/installers/installer.dart';
import 'package:obtainium/installers/shizuku_plugin.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shizuku_apk_installer/shizuku_apk_installer.dart';

/// Installs via the Dhizuku binder API for elevated Device Owner installs with
/// no user-facing permission dialog. Supports silent installs.
class DhizukuInstaller extends Installer {
  DhizukuInstaller(super.settingsProvider);

  @override
  String get modeKey => 'dhizuku';

  @override
  Future<bool> canInstallSilently(App app) async => true;

  @override
  Future<bool> checkPermission() async => isShizukuPluginPermissionGranted(
    InstallerMode.dhizuku,
    await checkShizukuPluginPermission(InstallerMode.dhizuku),
  );

  @override
  Future<void> ensurePermission({ThemeData? toastTheme}) async {
    final String? res = await checkShizukuPluginPermission(
      InstallerMode.dhizuku,
    );
    if (isShizukuPluginPermissionGranted(InstallerMode.dhizuku, res)) return;
    switch (res) {
      case 'services_not_found':
        throw ObtainiumError(tr('dhizukuBinderNotFound'));
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
    // `installerPackageName` is ignored on purpose: Dhizuku installs as the
    // device owner and the plugin can't set another installer of record
    // there. Update ownership for a first install does apply (#3445).
    final bool requestUpdateOwnership =
        installOptions['requestUpdateOwnership'] as bool? ?? false;
    final uris = apkFilePaths.map((p) => File(p).uri.toString()).toList();
    final ShizukuApkInstaller dhizukuInstaller = ShizukuApkInstaller();
    final ShizukuPluginCall<int?> install = startExclusiveShizukuPluginCall(
      () async {
        await dhizukuInstaller.setInstallerMode(InstallerMode.dhizuku);
        return uris.length > 1
            ? dhizukuInstaller.installAABSplits(
                uris,
                '',
                requestUpdateOwnership: requestUpdateOwnership,
              )
            : dhizukuInstaller.installAPK(
                uris.first,
                '',
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
