import 'dart:async';
import 'dart:io';
import 'package:android_system_font/android_system_font.dart';
import 'package:flutter/services.dart';

class NativeFeatures {
  static const MethodChannel _powerChannel = MethodChannel(
    'dev.imranr.obtainium/power',
  );
  static bool _systemFontLoaded = false;

  static Future<ByteData> _readFileBytes(String path) async {
    var bytes = await File(path).readAsBytes();
    return ByteData.view(bytes.buffer);
  }

  static Future loadSystemFont() async {
    if (_systemFontLoaded) return;
    var fontLoader = FontLoader('SystemFont');
    var fontFilePath = await AndroidSystemFont().getFilePath();
    fontLoader.addFont(_readFileBytes(fontFilePath!));
    fontLoader.load();
    _systemFontLoaded = true;
  }

  static Future<bool> acquireDownloadKeepAwake() async {
    try {
      return await _powerChannel.invokeMethod<bool>(
            'acquireDownloadKeepAwake',
          ) ??
          false;
    } on PlatformException {
      // Downloads should still proceed if the platform cannot hold a lock.
      return false;
    } on MissingPluginException {
      // Non-Android builds do not provide this channel.
      return false;
    }
  }

  static Future<void> releaseDownloadKeepAwake() async {
    try {
      await _powerChannel.invokeMethod('releaseDownloadKeepAwake');
    } on PlatformException {
      // Best-effort cleanup; Android also releases locks if the process dies.
    } on MissingPluginException {
      // Non-Android builds do not provide this channel.
    }
  }
}
