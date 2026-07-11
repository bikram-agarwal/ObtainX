import 'dart:async';
import 'dart:io';
import 'package:android_system_font/android_system_font.dart';
import 'package:flutter/services.dart';

class NativeFeatures {
  static const MethodChannel _powerChannel = MethodChannel(
    'dev.imranr.obtainium/power',
  );
  static const MethodChannel _storageChannel = MethodChannel(
    'dev.imranr.obtainium/storage',
  );
  static const MethodChannel _notificationsChannel = MethodChannel(
    'dev.imranr.obtainium/notifications',
  );
  static const MethodChannel _diagnosticsChannel = MethodChannel(
    'dev.imranr.obtainium/diagnostics',
  );
  static bool _systemFontLoaded = false;
  static bool _downloadCancelHandlerRegistered = false;

  static void registerDownloadCancelHandler(
    FutureOr<void> Function(String appId) handler,
  ) {
    if (_downloadCancelHandlerRegistered) return;
    _downloadCancelHandlerRegistered = true;
    _notificationsChannel.setMethodCallHandler((call) async {
      if (call.method != 'cancelDownload') {
        throw MissingPluginException();
      }
      final appId = call.arguments?.toString();
      if (appId == null || appId.isEmpty) return;
      await handler(appId);
    });
    unawaited(_consumePendingDownloadCancels(handler));
  }

  static Future<void> _consumePendingDownloadCancels(
    FutureOr<void> Function(String appId) handler,
  ) async {
    try {
      final pendingAppIds =
          await _notificationsChannel.invokeListMethod<String>(
            'consumePendingDownloadCancels',
          ) ??
          const <String>[];
      for (final String appId in pendingAppIds) {
        if (appId.isNotEmpty) {
          await handler(appId);
        }
      }
    } on PlatformException {
      // Notification actions remain best-effort on older native runners.
    } on MissingPluginException {
      // Non-Android builds and older native runners do not expose this method.
    }
  }

  static Future<ByteData> _readFileBytes(String path) async {
    var bytes = await File(path).readAsBytes();
    return ByteData.view(bytes.buffer);
  }

  static Future<void> loadSystemFont() async {
    if (_systemFontLoaded) return;
    var fontLoader = FontLoader('SystemFont');
    var fontFilePath = await AndroidSystemFont().getFilePath();
    fontLoader.addFont(_readFileBytes(fontFilePath!));
    await fontLoader.load();
    _systemFontLoaded = true;
  }

  static Future<String?> consumeNativeCrashLog() async {
    if (!Platform.isAndroid) return null;
    try {
      final log = await _diagnosticsChannel.invokeMethod<String>(
        'consumeNativeCrashLog',
      );
      if (log == null || log.trim().isEmpty) return null;
      return log;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
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

  static Future<bool> isDeviceInteractive() async {
    try {
      return await _powerChannel.invokeMethod<bool>('isDeviceInteractive') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<Uri?> openPersistedDocumentTree({Uri? initialUri}) async {
    try {
      final uriString = await _storageChannel.invokeMethod<String>(
        'openPersistedDocumentTree',
        <String, String?>{'initialUri': initialUri?.toString()},
      );
      if (uriString == null || uriString.isEmpty) {
        return null;
      }
      return Uri.parse(uriString);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> hasPersistedDocumentTreePermission(Uri uri) async {
    try {
      return await _storageChannel.invokeMethod<bool>(
            'hasPersistedDocumentTreePermission',
            <String, String>{'uri': uri.toString()},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> showDownloadProgressNotification({
    required int id,
    required String appId,
    required String title,
    required String message,
    required String channelCode,
    required int progressPercent,
    required bool indeterminate,
    required String cancelLabel,
    String? shortCriticalText,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _notificationsChannel
          .invokeMethod('showDownloadProgressNotification', <String, Object?>{
            'id': id,
            'appId': appId,
            'title': title,
            'message': message,
            'channelCode': channelCode,
            'progressPercent': progressPercent,
            'indeterminate': indeterminate,
            'cancelLabel': cancelLabel,
            'shortCriticalText': shortCriticalText,
          });
    } on PlatformException {
      // The regular Flutter notification remains the fallback.
    } on MissingPluginException {
      // Non-Android builds and older runners do not provide this channel.
    }
  }

  static Future<void> startDownloadForegroundService({
    required int id,
    required String appId,
    required String title,
    required String message,
    required String channelCode,
    required String channelName,
    required String channelDescription,
    required String cancelLabel,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _notificationsChannel
          .invokeMethod('startDownloadForegroundService', <String, Object?>{
            'id': id,
            'appId': appId,
            'title': title,
            'message': message,
            'channelCode': channelCode,
            'channelName': channelName,
            'channelDescription': channelDescription,
            'cancelLabel': cancelLabel,
          });
    } on PlatformException {
      // The download can still proceed; wake locks and progress notification remain best effort.
    } on MissingPluginException {
      // Non-Android builds and older runners do not provide this channel.
    }
  }

  static Future<void> stopDownloadForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _notificationsChannel.invokeMethod('stopDownloadForegroundService');
    } on PlatformException {
      // Android will tear the service down if the process dies.
    } on MissingPluginException {
      // Non-Android builds and older runners do not provide this channel.
    }
  }
}
