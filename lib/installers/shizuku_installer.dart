import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
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

  @override
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  }) async {
    final fakeInstallSource =
        installOptions['shizukuPretendToBeGooglePlay'] == true
        ? 'com.android.vending'
        : '';
    final uris = apkFilePaths.map((p) => File(p).uri.toString()).toList();
    final ShizukuApkInstaller shizukuInstaller = ShizukuApkInstaller();
    await shizukuInstaller.setInstallerMode(InstallerMode.shizuku);
    int? code;
    if (uris.length > 1) {
      code = await shizukuInstaller.installAABSplits(uris, fakeInstallSource);
    } else {
      code = await shizukuInstaller.installAPK(uris.first, fakeInstallSource);
    }
    return InstallResult.fromPlatformCode(code);
  }
}
