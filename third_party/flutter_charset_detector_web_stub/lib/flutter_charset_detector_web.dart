/// Android-only stand-in for `flutter_charset_detector_web`.
///
/// `flutter_charset_detector` is a purely federated plugin: it resolves its
/// implementation through the platform interface and never imports this package
/// itself, so the published web implementation is dead weight in an Android
/// build. What it does cost is its bundled asset - jschardet.min.js adds
/// ~1.17 MB uncompressed (~712 KB compressed) to `assets/flutter_assets/` of
/// every APK - so `pubspec.yaml` overrides it with this local package to keep
/// that asset out while the federated plugin graph still resolves.
///
/// The override is not about dependency count: `flutter_web_plugins` and
/// `package:web` stay in `pubspec.lock` through other plugins
/// (url_launcher_web, shared_preferences_web, app_links_web, workmanager_web,
/// fluttertoast, ...).
///
/// There is deliberately no `flutter: plugin:` block in this package's
/// pubspec, so this class is never registered as a platform instance - not on
/// Android, and not on web either. If the app ever targets web, this throws
/// instead of silently returning wrong text; switch back to the published
/// `flutter_charset_detector_web`.
library;

import 'dart:typed_data';

import 'package:flutter_charset_detector_platform_interface/decoding_result.dart';
import 'package:flutter_charset_detector_platform_interface/flutter_charset_detector_platform_interface.dart';

/// Constant message shared by the unimplemented methods.
const String _unsupportedMessage =
    'flutter_charset_detector_web is stubbed out in this build '
    '(ObtainX targets Android only).';

/// Throwing stand-in for the web implementation of [CharsetDetectorPlatform].
///
/// It is never registered as a platform instance (this package declares no
/// `flutter: plugin:` block); the override exists so the federated plugin
/// resolves without the real package's bundled asset.
class CharsetDetectorWeb extends CharsetDetectorPlatform {
  @override
  Future<DecodingResult> autoDecode(Uint8List bytes) =>
      throw UnsupportedError(_unsupportedMessage);

  @override
  Future<String> detect(Uint8List bytes) =>
      throw UnsupportedError(_unsupportedMessage);
}
