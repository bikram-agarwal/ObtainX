import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ApkSource extends AppSource {
  @override
  String sourceSpecificStandardizeURL(
    String url, {
    bool forSelection = false,
  }) => url;

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async => APKDetails(
    '1.0',
    const [
      MapEntry('app-release.apk', 'https://example.com/app-release.apk'),
      MapEntry('app-fdroid.apk', 'https://example.com/app-fdroid.apk'),
    ],
    const AppNames('Example', 'App'),
    appId: 'com.example.app',
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final source = _ApkSource();
  final provider = SourceProvider();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const deviceChannel = MethodChannel('dev.fluttercommunity.plus/device_info');

  Future<App> getApp(Map<String, dynamic> settings) => provider.getApp(
    source,
    'https://example.com/app',
    {'minimumUpdateAgeDays': '0', ...settings},
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({'globalApkFilterRegEx': 'release'});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => Directory.systemTemp.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      deviceChannel,
      (_) async => {
        'version': {
          'codename': 'REL',
          'incremental': '',
          'release': '17',
          'sdkInt': 37,
        },
        for (final key in [
          'board',
          'bootloader',
          'brand',
          'device',
          'display',
          'fingerprint',
          'hardware',
          'host',
          'id',
          'manufacturer',
          'model',
          'product',
          'tags',
          'type',
        ])
          key: '',
        for (final key in [
          'time',
          'freeDiskSize',
          'totalDiskSize',
          'physicalRamSize',
          'availableRamSize',
        ])
          key: 0,
        'isPhysicalDevice': false,
        'isLowRamDevice': false,
      },
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      deviceChannel,
      null,
    );
  });

  test('blank form default uses the global APK filter', () async {
    final settings = getDefaultValuesFromFormItems(
      source.combinedAppSpecificSettingFormItems,
    )..['autoApkFilterByArch'] = false;
    expect(settings['apkFilterRegEx'], '');

    final app = await getApp(settings);

    expect(app.apkUrls.map((entry) => entry.key), ['app-release.apk']);
  });

  test('a nonempty per-app filter overrides the global filter', () async {
    final app = await getApp({'apkFilterRegEx': 'fdroid'});

    expect(app.apkUrls.map((entry) => entry.key), ['app-fdroid.apk']);
  });

  test(
    'blank per-app filter keeps all APKs when no global filter is set',
    () async {
      SharedPreferences.setMockInitialValues({});

      final app = await getApp({'apkFilterRegEx': ''});

      expect(app.apkUrls, hasLength(2));
    },
  );

  test('a whitespace-only per-app filter counts as unset', () async {
    final app = await getApp({'apkFilterRegEx': '   '});

    expect(app.apkUrls.map((entry) => entry.key), ['app-release.apk']);
  });

  test('an invalid global filter is ignored', () async {
    SharedPreferences.setMockInitialValues({
      'globalApkFilterRegEx': '(release',
    });

    final app = await getApp({'apkFilterRegEx': ''});

    expect(app.apkUrls, hasLength(2));
  });

  test("the app's invert switch doesn't apply to the global filter", () async {
    final app = await getApp({'apkFilterRegEx': '', 'invertAPKFilter': true});

    expect(app.apkUrls.map((entry) => entry.key), ['app-release.apk']);
  });

  test('a package ID from the source becomes the app ID', () async {
    final app = await getApp({'apkFilterRegEx': ''});

    expect(app.id, 'com.example.app');
  });

  test('an explicit appId setting still wins over the source ID', () async {
    final app = await getApp({'apkFilterRegEx': '', 'appId': 'org.mine.app'});

    expect(app.id, 'org.mine.app');
  });

  test(
    'global filter with no matches rejects a blank per-app filter',
    () async {
      SharedPreferences.setMockInitialValues({
        'globalApkFilterRegEx': 'NO_APK_SHOULD_MATCH',
      });

      await expectLater(
        getApp({'apkFilterRegEx': ''}),
        throwsA(isA<NoAPKError>()),
      );
    },
  );
}
