// @author Bikram Agarwal
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.imranr.obtainium/installer');

typedef ThirdPartyInstallPackageChangedCallback =
    FutureOr<void> Function(String packageName);

ThirdPartyInstallPackageChangedCallback? _thirdPartyInstallPackageChanged;

void registerThirdPartyInstallPackageChangedCallback(
  ThirdPartyInstallPackageChangedCallback? callback,
) {
  _thirdPartyInstallPackageChanged = callback;
  if (!Platform.isAndroid) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'thirdPartyInstallPackageChanged') {
      throw MissingPluginException();
    }
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final packageName = arguments['packageName']?.toString();
    if (packageName == null || packageName.isEmpty) return;
    await _thirdPartyInstallPackageChanged?.call(packageName);
  });
}

/// Sends one or more APK paths to a user-chosen third-party installer (Settings: Third-Party mode).
/// Multiple paths use the same comma-separated convention as [AndroidPackageInstaller.installApk]
/// so split / multi-APK installs are handed off whole (not only the base split).
/// Returns true if the system broadcast confirms the package was installed.
/// Times out after 2 minutes and returns false.
Future<bool> installApkViaThirdParty(
  String apkFilePathsCommaSeparated, {
  required String targetPackage,
  required String targetActivity,
  required String expectedPackageName,
}) async {
  if (!Platform.isAndroid) return false;
  final result = await _channel
      .invokeMethod<bool>('launchInstallIntent', <String, dynamic>{
        'path': apkFilePathsCommaSeparated,
        'package': targetPackage,
        'activity': targetActivity,
        'expectedPackageName': expectedPackageName,
      });
  return result ?? false;
}

/// Hands a file to whatever the device resolves for it - its default
/// installer, or a chooser if there's more than one candidate - the same as
/// tapping the file in a file manager. No target package/activity, so the
/// native side neither addresses a specific app nor waits for an install
/// result: once the intent is launched, ObtainX takes no further part in
/// whatever happens to the file.
Future<void> viewInstallableFile(String filePath) async {
  if (!Platform.isAndroid) return;
  await _channel.invokeMethod<bool>('launchInstallIntent', <String, dynamic>{
    'path': filePath,
  });
}
