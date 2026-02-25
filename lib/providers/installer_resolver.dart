import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.imranr.obtainium/installer_resolver');

Future<List<Map<String, String>>> getApkInstallerApps() async {
  if (!Platform.isAndroid) return [];
  final raw = await _channel.invokeMethod<List<dynamic>>('queryApkInstallerActivities');
  if (raw == null) return [];
  return raw.map((e) => Map<String, String>.from(Map<dynamic, dynamic>.from(e as Map))).toList();
}

Future<void> installApkViaLegacy(
  String apkFilePath, {
  String? targetPackage,
  String? targetActivity,
  bool useChooser = false,
}) async {
  if (!Platform.isAndroid) return;
  await _channel.invokeMethod<void>('launchInstallIntent', <String, dynamic>{
    'path': apkFilePath,
    'package': targetPackage,
    'activity': targetActivity,
    'useChooser': useChooser,
  });
}
