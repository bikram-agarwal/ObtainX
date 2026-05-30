import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/providers/source_provider.dart';

/// Stub source that returns a controllable [APKDetails] from
/// [getLatestAPKDetails] without doing any network or HTML work.
///
/// Inherits APKMirror so [APKMirror]'s `enforceTrackOnly = true` flag is
/// kept (the size-keying branch we're testing only ever fires for
/// track-only APKMirror apps in production), and so [SourceProvider.getApp]
/// recognizes it via `source is APKMirror` for its (now removed) special
/// case checks. If those special cases ever come back, this stub will
/// surface the regression.
class _StubAPKMirror extends APKMirror {
  _StubAPKMirror({required this.version, this.apkSizeFromSource});
  final String version;
  final int? apkSizeFromSource;

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return APKDetails(
      version,
      const <MapEntry<String, String>>[],
      AppNames('Example', 'example'),
      apkSizeBytes: apkSizeFromSource,
    );
  }

  // tryInferringAppId hits the network in the real APKMirror; short-circuit
  // it so tests never reach out. We always pass an explicit appId via the
  // currentApp/additionalSettings path anyway, so this never fires — it's
  // here as a safety net.
  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async => null;
}

App _buildCurrentApp({required String latestVersion, int? apkSizeBytes}) {
  return App(
    'com.example.app',
    'https://www.apkmirror.com/apk/example/example',
    'Example',
    'Example',
    null, // installedVersion
    latestVersion,
    const <MapEntry<String, String>>[],
    0,
    {'trackOnly': true, 'appId': 'com.example.app'},
    DateTime.now(),
    false,
    apkSizeBytes: apkSizeBytes,
  );
}

class _FakeAndroidDeviceInfoPlatform extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    return BaseDeviceInfo({
      'version': {
        'sdkInt': 35,
        'release': '15',
        'codename': 'REL',
        'incremental': '1',
        'previewSdkInt': 0,
        'securityPatch': '2026-05-01',
        'baseOS': '',
      },
      'board': '',
      'bootloader': '',
      'brand': '',
      'device': '',
      'display': '',
      'fingerprint': '',
      'hardware': '',
      'host': '',
      'id': '',
      'manufacturer': '',
      'model': '',
      'product': '',
      'supported32BitAbis': const ['armeabi-v7a'],
      'supported64BitAbis': const ['arm64-v8a'],
      'supportedAbis': const ['arm64-v8a', 'armeabi-v7a'],
      'tags': '',
      'type': 'user',
      'isPhysicalDevice': true,
      'freeDiskSize': 1,
      'totalDiskSize': 1,
      'isLowRamDevice': false,
      'physicalRamSize': 1,
      'availableRamSize': 1,
      'systemFeatures': const <String>[],
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DeviceInfoPlatform.instance = _FakeAndroidDeviceInfoPlatform();

  // ── Size cache key invalidation ─────────────────────────────────────
  // The contract: the size persisted onto an App is keyed implicitly by
  // (appId, latestVersion). When a refresh returns the same version,
  // any size already on the App should survive (nothing better is
  // available for APKMirror until the AppPage's lazy resolver runs).
  // When the version changes, the stale size MUST be cleared so the
  // next AppPage open re-resolves.

  test('apkSizeBytes is preserved when source version is unchanged', () async {
    final source = _StubAPKMirror(version: '2.0', apkSizeFromSource: null);
    final currentApp = _buildCurrentApp(
      latestVersion: '2.0',
      apkSizeBytes: 12345678,
    );
    final newApp = await SourceProvider().getApp(
      source,
      'https://www.apkmirror.com/apk/example/example',
      {'trackOnly': true, 'appId': 'com.example.app'},
      currentApp: currentApp,
    );
    expect(newApp.apkSizeBytes, 12345678);
    expect(newApp.latestVersion, '2.0');
  });

  test(
    'apkSizeBytes is cleared when source reports a different version',
    () async {
      final source = _StubAPKMirror(version: '3.0', apkSizeFromSource: null);
      final currentApp = _buildCurrentApp(
        latestVersion: '2.0',
        apkSizeBytes: 12345678,
      );
      final newApp = await SourceProvider().getApp(
        source,
        'https://www.apkmirror.com/apk/example/example',
        {'trackOnly': true, 'appId': 'com.example.app'},
        currentApp: currentApp,
      );
      expect(newApp.apkSizeBytes, isNull);
      expect(newApp.latestVersion, '3.0');
    },
  );

  test('apkSizeBytes from source wins over the cached value', () async {
    final source = _StubAPKMirror(version: '3.0', apkSizeFromSource: 99999999);
    final currentApp = _buildCurrentApp(
      latestVersion: '2.0',
      apkSizeBytes: 12345678,
    );
    final newApp = await SourceProvider().getApp(
      source,
      'https://www.apkmirror.com/apk/example/example',
      {'trackOnly': true, 'appId': 'com.example.app'},
      currentApp: currentApp,
    );
    expect(newApp.apkSizeBytes, 99999999);
  });

  test(
    'apkSizeBytes is null on first add when source returns no size',
    () async {
      final source = _StubAPKMirror(version: '1.0', apkSizeFromSource: null);
      final newApp = await SourceProvider().getApp(
        source,
        'https://www.apkmirror.com/apk/example/example',
        {'trackOnly': true, 'appId': 'com.example.app'},
        // No currentApp — simulating first-time add.
      );
      expect(newApp.apkSizeBytes, isNull);
    },
  );
}
