import 'dart:async';

import 'package:flutter/services.dart';

typedef SharedTextHandler = FutureOr<void> Function(String sharedText);

class SharedUrlReceiver {
  SharedUrlReceiver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'dev.imranr.obtainium/share';
  static const String _onSharedTextMethod = 'onSharedText';

  final MethodChannel _channel;

  Future<String?> getInitialSharedText() async {
    try {
      final String? sharedText = await _channel.invokeMethod<String>(
        'getInitialSharedText',
      );
      return _normalizeSharedText(sharedText);
    } on MissingPluginException {
      return null;
    }
  }

  void listen(SharedTextHandler onSharedText) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != _onSharedTextMethod) return null;
      final String? sharedText = _normalizeSharedText(
        call.arguments as String?,
      );
      if (sharedText != null) {
        await onSharedText(sharedText);
      }
      return null;
    });
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }

  static String? extractFirstUrl(String? sharedText) {
    final String? normalized = _normalizeSharedText(sharedText);
    if (normalized == null) return null;

    final match = RegExp(
      r'''https?://[^\s<>"']+''',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (match == null) return null;

    return _trimTrailingUrlPunctuation(match.group(0)!);
  }

  static String? _normalizeSharedText(String? sharedText) {
    final String? normalized = sharedText?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String _trimTrailingUrlPunctuation(String url) {
    return url.replaceFirst(RegExp(r'[.,;:!?\)\]\}]+$'), '');
  }
}
