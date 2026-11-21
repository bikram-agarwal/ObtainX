import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An [AppsProvider] carrying only settings, for [AppsProviderInstall]
/// methods that read nothing else.
class _SettingsOnlyAppsProvider implements AppsProvider {
  _SettingsOnlyAppsProvider(this.settingsProvider);

  @override
  SettingsProvider settingsProvider;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeArm64DeviceInfoPlatform extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async => BaseDeviceInfo({
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
    'time': 0,
    'systemFeatures': const <String>[],
  });
}

const String _base = 'https://github.com/example/app/releases/download/v1';
const MapEntry<String, String> _universal = MapEntry(
  'app-universal.apk',
  '$_base/app-universal.apk',
);
const MapEntry<String, String> _arm64 = MapEntry(
  'app-arm64-v8a.apk',
  '$_base/app-arm64-v8a.apk',
);

App _app(
  List<MapEntry<String, String>> apkUrls, {
  bool archFilter = true,
  int preferredApkIndex = 0,
}) => App(
  id: 'com.example.app',
  url: 'https://github.com/example/app',
  author: 'example',
  name: 'App',
  latestVersion: '1.0',
  apkUrls: apkUrls,
  preferredApkIndex: preferredApkIndex,
  additionalSettings: {'autoApkFilterByArch': archFilter},
);

// v1.7.4 sync D12 C: the arch filter keeps universal APKs next to the ABI
// build (upstream #3349). Universal-only alternatives are no reason to show
// the APK picker: the ABI build is taken, as upstream #3473 does for a saved
// universal choice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DeviceInfoPlatform.instance = _FakeArm64DeviceInfoPlatform();

  late AppsProvider provider;
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    provider = _SettingsOnlyAppsProvider(
      SettingsProvider()..prefs = await SharedPreferences.getInstance(),
    );
  });

  test('universal-only alternatives take the ABI build', () async {
    final picked = await provider.confirmAppFileUrl(
      _app([_universal, _arm64]),
      false,
      allowUserInteraction: true,
    );
    expect(picked?.key, _arm64.key);
  });

  test('without the arch filter the saved choice stands', () async {
    final picked = await provider.confirmAppFileUrl(
      _app([_universal, _arm64], archFilter: false),
      false,
      allowUserInteraction: true,
    );
    expect(picked?.key, _universal.key);
  });

  test('a real choice between ABI builds is left to the user', () async {
    const MapEntry<String, String> arm64Debug = MapEntry(
      'app-arm64-v8a-debug.apk',
      '$_base/app-arm64-v8a-debug.apk',
    );
    final picked = await provider.confirmAppFileUrl(
      _app([_universal, _arm64, arm64Debug], preferredApkIndex: 2),
      false,
      allowUserInteraction: true,
    );
    expect(picked?.key, arm64Debug.key);
  });

  test('picking any asset keeps the full choice', () async {
    final picked = await provider.confirmAppFileUrl(
      _app([_universal, _arm64]),
      true,
      allowUserInteraction: true,
    );
    expect(picked?.key, _universal.key);
  });

  // Phase C C-9: a universal APK next to the ABI build must not stop silent
  // (background) installs, as it didn't when the filter kept only the ABI
  // build. A real choice still does.
  test('universal-only alternatives need no manual APK choice', () {
    expect(needsManualApkChoice(_app([_arm64])), isFalse);
    expect(needsManualApkChoice(_app([_universal, _arm64])), isFalse);
    expect(
      needsManualApkChoice(_app([_universal, _arm64], archFilter: false)),
      isTrue,
    );
    const MapEntry<String, String> arm64Debug = MapEntry(
      'app-arm64-v8a-debug.apk',
      '$_base/app-arm64-v8a-debug.apk',
    );
    expect(
      needsManualApkChoice(_app([_universal, _arm64, arm64Debug])),
      isTrue,
    );
  });
}
