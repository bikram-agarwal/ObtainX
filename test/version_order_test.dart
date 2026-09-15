import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

class FixtureAPKMirror extends APKMirror {
  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    if (url.endsWith('/feed/')) {
      return Response(
        '<rss><channel><item><title>Example 2.0 by Example</title></item></channel></rss>',
        200,
      );
    }
    if (url == 'https://www.apkmirror.com/apk/example/example') {
      return Response('File size:4.20 MB Downloads:10', 200);
    }
    return Response('', 404);
  }
}

class ReleasePageBlockedAPKMirror extends APKMirror {
  final List<String> requestedUrls = [];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requestedUrls.add(url);
    if (url.endsWith('/feed/')) {
      return Response('''
<rss><channel><item>
<title>YouTube 21.18.163 beta by Google LLC</title>
<link>https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/</link>
</item></channel></rss>
''', 200);
    }
    if (url.contains('/youtube/youtube-21-18-163-release/') &&
        !url.contains('android-apk-download')) {
      return Response('blocked', 403);
    }
    if (url.contains('/youtube-21-18-163-android-apk-download/')) {
      return Response(
        'Download APK Bundle Base APK and 35 splits, 160.33 MB',
        200,
      );
    }
    if (url.contains('/youtube-21-18-163-2-android-apk-download/')) {
      return Response(
        'Download APK Bundle Base APK and 27 splits, 64.86 MB',
        200,
      );
    }
    if (url.contains('/youtube-21-18-163-3-android-apk-download/')) {
      return Response('Download APK 177.65 MB (186,277,274 bytes)', 200);
    }
    if (url == 'https://www.apkmirror.com/apk/google-inc/youtube') {
      return Response('File size:55.08 MB Downloads:651', 200);
    }
    return Response('', 404);
  }
}

class AbiAwareReleaseAPKMirror extends APKMirror {
  final List<String> requestedUrls = [];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requestedUrls.add(url);
    if (url.endsWith('/feed/')) {
      return Response('''
<rss><channel><item>
<title>YouTube Music 9.17.51 by Google LLC</title>
<link>https://www.apkmirror.com/apk/google-inc/youtube-music/youtube-music-9-17-51-release/</link>
</item></channel></rss>
''', 200);
    }
    if (url.endsWith('/youtube-music-9-17-51-release/')) {
      return Response('''
<div>9.17.51 APK armeabi-v7a <a href="youtube-music-9-17-51-4-android-apk-download/">download</a></div>
<div>9.17.51 APK arm64-v8a <a href="youtube-music-9-17-51-5-android-apk-download/">download</a></div>
''', 200);
    }
    if (url.endsWith('/youtube-music-9-17-51-4-android-apk-download/')) {
      return Response(
        'Download APK 57.79 MB (60,595,084 bytes) arm-v7a nodpi',
        200,
      );
    }
    if (url.endsWith('/youtube-music-9-17-51-5-android-apk-download/')) {
      return Response(
        'Download APK 58.00 MB (60,817,408 bytes) arm64-v8a nodpi',
        200,
      );
    }
    if (url == 'https://www.apkmirror.com/apk/google-inc/youtube-music') {
      return Response('', 200);
    }
    return Response('', 404);
  }
}

class FakeAndroidDeviceInfoPlatform extends DeviceInfoPlatform {
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
      'board': 'board',
      'bootloader': 'bootloader',
      'brand': 'brand',
      'device': 'device',
      'display': 'display',
      'fingerprint': 'fingerprint',
      'hardware': 'hardware',
      'host': 'host',
      'id': 'id',
      'manufacturer': 'manufacturer',
      'model': 'model',
      'product': 'product',
      'supported32BitAbis': ['armeabi-v7a'],
      'supported64BitAbis': ['arm64-v8a'],
      'supportedAbis': ['arm64-v8a', 'armeabi-v7a'],
      'tags': 'tags',
      'type': 'user',
      'isPhysicalDevice': true,
      'freeDiskSize': 70729949184,
      'totalDiskSize': 113281839104,
      'isLowRamDevice': false,
      'physicalRamSize': 8192,
      'availableRamSize': 4096,
      'systemFeatures': <String>[],
    });
  }
}

class FakePackageInfo extends PackageInfo {
  const FakePackageInfo({
    required String packageName,
    required String versionName,
    required int versionCode,
  }) : super(
         installLocation: AndroidInstallLocation.unspecified,
         packageName: packageName,
         versionName: versionName,
         versionCode: versionCode,
       );
}

App _buildPersistenceTestApp({
  required String id,
  required String name,
  Map<String, dynamic> additionalSettings = const <String, dynamic>{},
}) {
  return App(
    id: id,
    url: 'https://github.com/example/$id',
    author: 'Example',
    name: name,
    installedVersion: null,
    latestVersion: '1.0.0',
    apkUrls: const <MapEntry<String, String>>[],
    preferredApkIndex: 0,
    additionalSettings: additionalSettings,
    lastUpdateCheck: DateTime.now(),
    pinned: false,
  );
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this._path);
  final String _path;

  @override
  Future<String?> getTemporaryPath() async => _path;
  @override
  Future<String?> getApplicationSupportPath() async => _path;
  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
  @override
  Future<String?> getApplicationCachePath() async => _path;
  @override
  Future<String?> getExternalStoragePath() async => _path;
  @override
  Future<List<String>?> getExternalCachePaths() async => <String>[_path];
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => <String>[_path];
  @override
  Future<String?> getDownloadsPath() async => _path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AppsProvider's constructor opens a sqflite DB (LogsProvider), reads
  // SharedPreferences, resolves directories (path_provider), reads device info,
  // and queries installed packages — provide test doubles for all of them.
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PathProviderPlatform.instance = _FakePathProvider(
      Directory.systemTemp.createTempSync('obtainx_test_').path,
    );
    DeviceInfoPlatform.instance = FakeAndroidDeviceInfoPlatform();
    // No installed packages in the test VM.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('android_package_manager'),
          (MethodCall call) async => null,
        );
  });

  // The constructor's init runs as fire-and-forget async work; drain the event
  // loop after each test so it completes within scope instead of leaking.
  tearDown(() => pumpEventQueue());

  test(
    'semver with parenthetical decimal build is not version order unclear',
    () {
      expect(versionOrderIsUnclear('8.8 (88957691)', '8.6 (86672232)'), false);
      expect(
        compareVersionsByNumericSegments('8.8 (88957691)', '8.6 (86672232)'),
        1,
      );
    },
  );

  test(
    'real hex in version string still participates in versionsEffectivelyEqual',
    () {
      expect(
        versionsEffectivelyEqual('1.5.3-DEV (75094D8)', 'debug-75094d8'),
        true,
      );
    },
  );

  test(
    'dot releases like 153.0 and 153.0.2 are recognized as distinct versions',
    () {
      expect(versionsEffectivelyEqual('153.0', '153.0.2'), false);
      expect(versionsEffectivelyEqual('153.0.2', '153.0'), false);
      expect(compareVersionsByNumericSegments('153.0', '153.0.2'), -1);
      expect(compareVersionsByNumericSegments('153.0.2', '153.0'), 1);
    },
  );

  test(
    'dot-separated hash suffixes like 26.03 and 26.03.a4d75424 are recognized as distinct versions',
    () {
      expect(versionsEffectivelyEqual('26.03', '26.03.a4d75424'), false);
      expect(versionsEffectivelyEqual('26.03.a4d75424', '26.03'), false);
    },
  );

  test(
    'zero-only trailing dot segments like 1.2 and 1.2.0 are effectively equal',
    () {
      expect(versionsEffectivelyEqual('1.2', '1.2.0'), true);
      expect(versionsEffectivelyEqual('1.2.0', '1.2'), true);
      expect(versionOrderIsUnclear('1.2', '1.2.0'), false);
    },
  );

  test('leading v is ignored throughout version comparison', () {
    expect(versionsEffectivelyEqual('v4.0.0', '4.0.0'), true);
    expect(compareVersionsByNumericSegments('v4.0.0', '4.0.0'), 0);
    expect(versionOrderIsUnclear('v4.0.0', '4.0.0'), false);
    expect(
      versionsEffectivelyEqual('2.9.8-preview-240', 'v2.9.8-Preview-240'),
      true,
    );
    expect(
      compareVersionsByNumericSegments(
        '2.9.8-preview-240',
        'v2.9.8-Preview-240',
      ),
      0,
    );
    expect(
      versionOrderIsUnclear('2.9.8-preview-240', 'v2.9.8-Preview-240'),
      false,
    );
    expect(isBareIntegerVersion('v4000'), true);
    expect(compareReleaseDateVersionStrings('v2026-08-01', '2026-08-02'), -1);
  });

  test('stable release supersedes recognized matching prereleases', () {
    for (final String prereleaseSuffix in <String>[
      'preview',
      'preview-123',
      'alpha',
      'alpha-2',
      'beta',
      'beta.3',
      'rc',
      'rc1',
    ]) {
      final String prereleaseVersion = '4.0.0-$prereleaseSuffix';
      final VersionComparison? prereleaseToStableReconciliation =
          reconcileVersionDifferences(prereleaseVersion, '4.0.0');
      final VersionComparison? stableToPrereleaseReconciliation =
          reconcileVersionDifferences('4.0.0', 'v$prereleaseVersion');
      expect(versionsEffectivelyEqual(prereleaseVersion, '4.0.0'), false);
      expect(versionsEffectivelyEqual('4.0.0', prereleaseVersion), false);
      expect(prereleaseToStableReconciliation?.areEqual, false);
      expect(prereleaseToStableReconciliation?.version, prereleaseVersion);
      expect(stableToPrereleaseReconciliation?.areEqual, false);
      expect(stableToPrereleaseReconciliation?.version, '4.0.0');
      expect(compareVersionsByNumericSegments(prereleaseVersion, '4.0.0'), -1);
      expect(compareVersionsByNumericSegments('4.0.0', prereleaseVersion), 1);
      expect(compareVersionsByNumericSegments(prereleaseVersion, 'v4.0.0'), -1);
      expect(compareVersionsByNumericSegments('v4.0.0', prereleaseVersion), 1);
      expect(versionOrderIsUnclear(prereleaseVersion, '4.0.0'), false);
    }
    expect(
      compareVersionsByNumericSegments(
        '4.0.0-preview-233',
        'v4.0.0-Preview-234',
      ),
      -1,
    );

    final App previewInstallation = App(
      id: 'dev.bikram.obtainx',
      url: 'https://github.com/bikram-agarwal/ObtainX',
      author: 'Bikram Agarwal',
      name: 'ObtainX',
      installedVersion: '4.0.0-preview-233',
      latestVersion: 'v4.0.0',
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: <String, dynamic>{'versionDetection': 'auto'},
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    expect(appHasActionableUpdate(previewInstallation), true);
  });

  test('pseudo display inference respects the selected detection mode', () {
    AppInMemory appWithMode(String versionDetectionMode) {
      return AppInMemory(
        App(
          id: 'app.example',
          url: 'https://github.com/example/app',
          author: 'Example',
          name: 'Example',
          installedVersion: 'source-build-106',
          latestVersion: 'source-build-106',
          apkUrls: const <MapEntry<String, String>>[],
          preferredApkIndex: 0,
          additionalSettings: <String, dynamic>{
            'versionDetection': versionDetectionMode,
          },
          lastUpdateCheck: DateTime.now(),
          pinned: false,
        ),
        null,
        const FakePackageInfo(
          packageName: 'app.example',
          versionName: '9.18.50',
          versionCode: 451,
        ),
        null,
      );
    }

    expect(isInstalledVersionPseudoForDisplay(appWithMode('auto')), true);
    expect(isInstalledVersionPseudoForDisplay(appWithMode('pseudo')), true);
    expect(isInstalledVersionPseudoForDisplay(appWithMode('standard')), false);
    expect(
      isInstalledVersionPseudoForDisplay(appWithMode('versionCode')),
      false,
    );
  });

  test(
    'stable install is not replaced by its latest preview in auto or standard mode',
    () {
      for (final String versionDetectionMode in <String>['auto', 'standard']) {
        final AppsProvider appsProvider = AppsProvider(isBg: true);
        addTearDown(appsProvider.dispose);
        final App app = App(
          id: 'dev.bikram.obtainx',
          url: 'https://github.com/bikram-agarwal/ObtainX',
          author: 'Bikram Agarwal',
          name: 'ObtainX',
          installedVersion: 'v2.9.8-Preview-245',
          latestVersion: 'v2.9.8-Preview-245',
          apkUrls: const <MapEntry<String, String>>[],
          preferredApkIndex: 0,
          additionalSettings: <String, dynamic>{
            'versionDetection': versionDetectionMode,
          },
          lastUpdateCheck: DateTime.now(),
          pinned: false,
        );

        expect(isVersionPseudo(app), false);

        final App correctedApp =
            appsProvider.getCorrectedInstallStatusAppIfPossible(
              app,
              const FakePackageInfo(
                packageName: 'dev.bikram.obtainx',
                versionName: '2.9.8',
                versionCode: 3980,
              ),
            ) ??
            app;

        expect(
          correctedApp.additionalSettings['versionDetection'],
          versionDetectionMode,
        );
        expect(correctedApp.installedVersion, '2.9.8');
        expect(correctedApp.latestVersion, 'v2.9.8-Preview-245');
        expect(appHasActionableUpdate(correctedApp), false);
      }
    },
  );

  test(
    'auto detection keeps two- and three-segment numeric versions standard',
    () {
      final AppsProvider appsProvider = AppsProvider(isBg: true);
      final App app = App(
        id: 'com.example.numericversion',
        url: 'https://github.com/example/numeric-version',
        author: 'Example',
        name: 'Numeric Version',
        installedVersion: '153.0',
        latestVersion: '153.0.2',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final App? correctedApp = appsProvider
          .getCorrectedInstallStatusAppIfPossible(
            app,
            const FakePackageInfo(
              packageName: 'com.example.numericversion',
              versionName: '153.0',
              versionCode: 15300,
            ),
          );
      final App effectiveApp = correctedApp ?? app;

      expect(effectiveApp.additionalSettings['versionDetection'], 'auto');
      expect(effectiveApp.installedVersion, '153.0');
      expect(effectiveApp.latestVersion, '153.0.2');
      expect(appHasActionableUpdate(effectiveApp), true);
    },
  );

  test(
    'auto detection keeps a newer installed preview comparable to an older stable release',
    () {
      const String installedVersion = '2.9.8-Preview-241';
      const String latestVersion = 'v2.9.7';
      final AppsProvider appsProvider = AppsProvider(isBg: true);
      addTearDown(appsProvider.dispose);
      final App app = App(
        id: 'dev.bikram.obtainx',
        url: 'https://github.com/bikram-agarwal/ObtainX',
        author: 'Bikram Agarwal',
        name: 'ObtainX',
        installedVersion: installedVersion,
        latestVersion: latestVersion,
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );
      const FakePackageInfo installedInfo = FakePackageInfo(
        packageName: 'dev.bikram.obtainx',
        versionName: installedVersion,
        versionCode: 39803,
      );

      expect(
        recognizedNumericReleaseVersionsAreComparable(
          installedVersion,
          latestVersion,
        ),
        true,
      );
      expect(
        compareVersionsByNumericSegments(installedVersion, latestVersion),
        1,
      );
      expect(
        appsProvider.isVersionDetectionPossible(
          AppInMemory(app, null, installedInfo, null),
        ),
        true,
      );

      final App effectiveApp =
          appsProvider.getCorrectedInstallStatusAppIfPossible(
            app,
            installedInfo,
          ) ??
          app;

      expect(effectiveApp.additionalSettings['versionDetection'], 'auto');
      expect(effectiveApp.installedVersion, installedVersion);
      expect(appHasActionableUpdate(effectiveApp), false);
    },
  );

  test(
    'release package lookup only includes debug build when requested',
    () async {
      // The standalone packageNamesToTryForInstalledInfo helper was inlined into
      // getInstalledInfo. Observe the same contract (which package names are
      // probed, in order) by recording the getPackageInfo channel calls: the mock
      // returns null for every name, so getInstalledInfo tries them all.
      final List<String> requested = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('android_package_manager'),
        (MethodCall call) async {
          if (call.method == 'getPackageInfo') {
            requested.add((call.arguments as Map)['packageName'] as String);
          }
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('android_package_manager'),
          (MethodCall call) async => null,
        );
      });

      requested.clear();
      await getInstalledInfo('dev.bikram.obtainx');
      expect(requested, const ['dev.bikram.obtainx']);

      requested.clear();
      await getInstalledInfo('dev.bikram.obtainx', includeOwnDebugBuild: true);
      expect(
        requested,
        kDebugMode
            ? const ['dev.bikram.obtainx.debug', 'dev.bikram.obtainx']
            : const ['dev.bikram.obtainx'],
      );
    },
    skip:
        'packageNamesToTryForInstalledInfo was removed and inlined into '
        'getInstalledInfo, which reaches packageManager (android_package_manager). '
        'That plugin\'s factory throws "Can only be run on Android devices", so '
        'the candidate-name resolution can no longer be exercised on a non-Android '
        'test host. Re-enable with an on-device / Robolectric-style harness.',
  );

  test('legacy release-date microseconds compare with ISO release dates', () {
    expect(
      versionsEffectivelyEqual('1777370225000000', '2026-04-28T09:57:05.000Z'),
      true,
    );
    expect(
      compareVersionsByNumericSegments(
        '1777370225000000',
        '2026-04-28T09:57:06.000Z',
      ),
      -1,
    );
    expect(
      compareVersionsByNumericSegments(
        '1777370225000000',
        '2026-04-28T09:57:04.000Z',
      ),
      1,
    );
  });

  test(
    'unreconciled source tag version is preserved as installed pseudo version',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.revanced.android.youtube',
        url: 'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        author: 'LovecraftianGodsKiller',
        name: 'YouTube-Morphe',
        installedVersion: '106',
        latestVersion: '106',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.revanced.android.youtube',
          versionName: '9.18.50',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNotNull);
      expect(correctedApp!.installedVersion, '106');
      expect(correctedApp.latestVersion, '106');
      expect(correctedApp.additionalSettings['versionDetection'], 'pseudo');
    },
  );

  test(
    'disabled version detection does not overwrite source tag with manifest version',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.revanced.android.youtube',
        url: 'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        author: 'LovecraftianGodsKiller',
        name: 'YouTube-Morphe',
        installedVersion: '106',
        latestVersion: '107',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'pseudo'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.revanced.android.youtube',
          versionName: '9.18.50',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNull);
      expect(app.installedVersion, '106');
      expect(app.latestVersion, '107');
      expect(app.additionalSettings['versionDetection'], 'pseudo');
    },
  );

  test(
    'disabled version detection sets installedVersion to latestVersion when installed version is null',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.revanced.android.youtube',
        url: 'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        author: 'LovecraftianGodsKiller',
        name: 'YouTube-Morphe',
        installedVersion: null,
        latestVersion: '107',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'pseudo'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.revanced.android.youtube',
          versionName: '9.18.50',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNotNull);
      expect(correctedApp!.installedVersion, '107');
      expect(correctedApp.latestVersion, '107');
      expect(correctedApp.additionalSettings['versionDetection'], 'pseudo');
    },
  );

  test(
    'legacy reset sentinel restores the device version for pseudo detection',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.revanced.android.youtube',
        url: 'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        author: 'LovecraftianGodsKiller',
        name: 'YouTube-Morphe',
        installedVersion: null,
        latestVersion: '107',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {
          'versionDetection': 'pseudo',
          installStatusResetKey: 123456,
        },
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.revanced.android.youtube',
          versionName: '9.18.50',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNotNull);
      expect(correctedApp!.installedVersion, '9.18.50');
      expect(
        correctedApp.additionalSettings.containsKey(installStatusResetKey),
        false,
      );
    },
  );

  test('reset install status honors version-code detection', () {
    final app = App(
      id: 'app.example',
      url: 'https://example.com/app',
      author: 'Example',
      name: 'Example',
      installedVersion: 'release-107',
      latestVersion: 'release-107',
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: {
        'versionDetection': 'versionCode',
        'useVersionCodeAsOSVersion': true,
        installStatusResetKey: 123456,
      },
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    final resetApp = resetInstallStatusToDeviceVersion(
      app,
      const FakePackageInfo(
        packageName: 'app.example',
        versionName: '9.18.50',
        versionCode: 106,
      ),
    );

    expect(resetApp.installedVersion, '106');
    expect(
      resetApp.additionalSettings.containsKey(installStatusResetKey),
      false,
    );
  });

  test(
    'reset removes the legacy sentinel when package info is unavailable',
    () {
      final app = App(
        id: 'app.example',
        url: 'https://example.com/app',
        author: 'Example',
        name: 'Example',
        installedVersion: 'release-107',
        latestVersion: 'release-107',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {
          'versionDetection': 'pseudo',
          installStatusResetKey: 123456,
        },
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final resetApp = resetInstallStatusToDeviceVersion(app, null);

      expect(resetApp.installedVersion, isNull);
      expect(
        resetApp.additionalSettings.containsKey(installStatusResetKey),
        false,
      );
    },
  );

  test(
    'disabled version detection preserves installed version when system version equals stored version',
    () {
      // installed == realInstalledVersion == '9.18.50', but latest == '107' (different format).
      // The system must NOT silently coerce installedVersion → latestVersion here; that would hide
      // the available update. The update from '9.18.50' to '107' must remain visible.
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.revanced.android.youtube',
        url: 'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        author: 'LovecraftianGodsKiller',
        name: 'YouTube-Morphe',
        installedVersion: '9.18.50',
        latestVersion: '107',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'pseudo'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.revanced.android.youtube',
          versionName: '9.18.50',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNull);
      expect(app.installedVersion, '9.18.50');
      expect(app.latestVersion, '107');
      expect(app.additionalSettings['versionDetection'], 'pseudo');
      expect(appHasActionableUpdate(app), true);
    },
  );

  test(
    'disabled version detection keeps pseudo version when system installed version does not reconcile',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.revanced.android.youtube',
        url: 'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        author: 'LovecraftianGodsKiller',
        name: 'YouTube-Morphe',
        installedVersion: '26.06.01-de-vanced',
        latestVersion: '26.06.01-de-vanced',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'pseudo'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.revanced.android.youtube',
          versionName: '4.15.0',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNull);
      expect(app.installedVersion, '26.06.01-de-vanced');
      expect(app.latestVersion, '26.06.01-de-vanced');
      expect(app.additionalSettings['versionDetection'], 'pseudo');
    },
  );

  test(
    'system installed version that reconciles with latest is adopted (detection stays on) when installedVersion is null',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.revanced.android.youtube',
        url: 'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        author: 'LovecraftianGodsKiller',
        name: 'YouTube-Morphe',
        installedVersion: null,
        latestVersion: '26.06.01-de-vanced',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.revanced.android.youtube',
          versionName: '4.15.0',
          versionCode: 106,
        ),
      );

      // The device version '4.15.0' DOES reconcile with the latest
      // '26.06.01-de-vanced': the '26.06.01' prefix substring-matches the
      // X.Y.Z standard format, so reconcileVersionDifferences returns
      // <false, ...> ("same format, different value" - a normal update), the
      // same signal a legit '1.2.3 -> 1.2.4-beta' bump gives. Version detection
      // is therefore possible and is NOT auto-disabled: the previously-null
      // installedVersion adopts the real device version and detection stays on.
      expect(correctedApp, isNotNull);
      expect(correctedApp!.installedVersion, '4.15.0');
      expect(correctedApp.latestVersion, '26.06.01-de-vanced');
      expect(correctedApp.additionalSettings['versionDetection'], 'auto');
    },
  );

  test('f-droid regex version filter keeps newest matching release', () async {
    final details = await FDroid().getAPKUrlsFromFDroidPackagesAPIResponse(
      Response('''
{
  "packageName": "org.torproject.vpn",
  "packages": [
    {"versionName": "1.6.0Beta-x86_64", "versionCode": 204},
    {"versionName": "1.6.0Beta-x86", "versionCode": 203},
    {"versionName": "1.6.0Beta-arm64-v8a", "versionCode": 202},
    {"versionName": "1.6.0Beta-armeabi-v7a", "versionCode": 201},
    {"versionName": "1.5.0Beta-x86_64", "versionCode": 194},
    {"versionName": "1.5.0Beta-x86", "versionCode": 193},
    {"versionName": "1.5.0Beta-arm64-v8a", "versionCode": 192},
    {"versionName": "1.5.0Beta-armeabi-v7a", "versionCode": 191}
  ]
}
''', 200),
      'http://127.0.0.1:1/repo/org.torproject.vpn',
      'https://f-droid.org/packages/org.torproject.vpn/',
      'F-Droid',
      additionalSettings: {'filterVersionsByRegEx': 'arm64'},
    );

    expect(details.version, '1.6.0Beta-arm64-v8a');
    expect(
      details.apkUrls.single.value,
      'http://127.0.0.1:1/repo/org.torproject.vpn_202.apk',
    );
  });

  test('apk mirror download page size text is parsed', () async {
    expect(
      await apkSizeBytesFromApkMirrorReleasePageHtml(
        'Download APK Bundle Base APK and 3 splits, 3.06 MB',
      ),
      3208643,
    );
  });

  test('apk mirror exact byte size wins when present', () async {
    expect(
      await apkSizeBytesFromApkMirrorReleasePageHtml(
        '3.06 MB (3,212,945 bytes) File size:3.11 MB',
      ),
      3212945,
    );
  });

  test('apk mirror release page uses first file size fallback', () async {
    expect(
      await apkSizeBytesFromApkMirrorReleasePageHtml(
        'File size:7.12 MB Downloads:2,884 File size:7.36 MB',
      ),
      7465861,
    );
  });

  // The URL-pattern-guessing fallback was removed: it issued up to 20
  // speculative HTTP requests per APKMirror app per refresh and the
  // success rate was abysmal. The lazy size resolver now only walks the
  // actual download links found on the release page HTML.

  // APKMirror's Cloudflare rule allowlists HTML pages by a substring match on
  // `APKUpdater`; a browser-style UA is answered with a 403 challenge, which
  // silently disables icon/size/changelog/app-id scraping. Pin both the token
  // and the ObtainX attribution so a future header cleanup can't quietly undo
  // it.
  test('apk mirror user agent carries the allowlisted token', () async {
    expect(apkMirrorAllowlistedUserAgentToken.contains('APKUpdater'), true);
    expect(apkMirrorUserAgent('2.9.9'), contains('APKUpdater'));
    expect(apkMirrorUserAgent('2.9.9'), contains('ObtainX/2.9.9'));
    // Unknown version: still allowlisted, just without attribution.
    expect(apkMirrorUserAgent(), apkMirrorAllowlistedUserAgentToken);
    expect(apkMirrorUserAgent('  '), apkMirrorAllowlistedUserAgentToken);
    // Whatever the UA ends up being, it must not read as a browser.
    final String ua = apkMirrorUserAgent('2.9.9');
    expect(ua.contains('Mozilla'), false);
    expect(ua.contains('Safari'), false);

    final Map<String, String>? headers = await APKMirror().getRequestHeaders(
      const <String, dynamic>{},
      'https://www.apkmirror.com/apk/signal-foundation/signal-private-messenger/',
    );
    // Lowercase key on purpose: sourceRequest injects a default ObtainX UA
    // unless a case-insensitive 'user-agent' is already present.
    final String? sentUserAgent = headers?.entries
        .firstWhere((e) => e.key.toLowerCase() == 'user-agent')
        .value;
    expect(sentUserAgent, contains('APKUpdater'));
  });

  test('apk mirror app slug aliases standardize to canonical app slug', () {
    expect(
      APKMirror().sourceSpecificStandardizeURL(
        'https://www.apkmirror.com/apk/google-inc/youtube-music-wear-os',
      ),
      'https://www.apkmirror.com/apk/google-inc/youtube-music',
    );
    expect(
      APKMirror().sourceSpecificStandardizeURL(
        'https://www.apkmirror.com/apk/google-inc/youtube-music-android-automotive',
      ),
      'https://www.apkmirror.com/apk/google-inc/youtube-music',
    );
  });

  test('apk mirror release page download urls strip duplicate fragments', () async {
    expect(
      await apkMirrorDownloadPageUrlsFromReleasePageHtml(
        '''
<a href="youtube-21-18-163-3-android-apk-download/">21.18.163 APK</a>
<a href="youtube-21-18-163-3-android-apk-download/#disqus_thread">comments</a>
<a href="youtube-21-18-163-android-apk-download/">21.18.163 BUNDLE</a>
''',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/',
      ),
      [
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-3-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-android-apk-download/',
      ],
    );
  });

  test('apk mirror release page changelog extracts whats new text', () async {
    expect(
      await apkMirrorChangeLogFromReleasePageHtml('''
<html>
  <body>
    <h2>What's new in Example 2.0</h2>
    <div>
      <p>Bug fixes and stability improvements.</p>
      <ul>
        <li>Added support for new devices.</li>
        <li>Improved startup performance.</li>
      </ul>
    </div>
    <p>Verified safe to install</p>
    <h2>About Example</h2>
    <p>This app description should not be included.</p>
  </body>
</html>
'''),
      'Bug fixes and stability improvements.\n'
      '- Added support for new devices.\n'
      '- Improved startup performance.',
    );
  });

  test('apk mirror release page changelog falls back to page text', () async {
    expect(
      await apkMirrorChangeLogFromReleasePageHtml('''
What's new in Example 2.0
Fixed update tracking.
Verified safe to install
About Example
This app description should not be included.
'''),
      'Fixed update tracking.',
    );
  });

  test('apk mirror app listing without changelog returns no content', () async {
    expect(
      await apkMirrorChangeLogFromReleasePageHtml('''
<html>
  <head>
    <title>Download Markup APKs for Android - APKMirror</title>
    <meta name="description" content="Download Markup APKs" />
    <style>.appRow { display: block; }</style>
  </head>
  <body>
    <h1>Markup</h1>
    <h3>Markup variants</h3>
    <h3>All versions</h3>
  </body>
</html>
'''),
      isNull,
    );
  });

  test('app copy preserves known apk size when refreshed size is unknown', () {
    final currentApp = App(
      id: 'app-id',
      url: 'https://example.com/app',
      author: 'Author',
      name: 'Name',
      installedVersion: '1.0',
      latestVersion: '2.0',
      apkUrls: const [],
      preferredApkIndex: 0,
      additionalSettings: const {},
      lastUpdateCheck: DateTime(2026),
      pinned: false,
      apkSizeBytes: 123456,
    );

    // App is immutable and copyWith cannot reset apkSizeBytes back to null
    // (it uses `?? this.apkSizeBytes`), so model a refresh that reported an
    // unknown size by building an otherwise-identical copy with the size omitted.
    final refreshedApp = App(
      id: currentApp.id,
      url: currentApp.url,
      author: currentApp.author,
      name: currentApp.name,
      installedVersion: currentApp.installedVersion,
      latestVersion: currentApp.latestVersion,
      apkUrls: currentApp.apkUrls,
      preferredApkIndex: currentApp.preferredApkIndex,
      additionalSettings: currentApp.additionalSettings,
      lastUpdateCheck: currentApp.lastUpdateCheck,
      pinned: currentApp.pinned,
    );

    expect(refreshedApp.apkSizeBytes ?? currentApp.apkSizeBytes, 123456);
  });

  test(
    'apk mirror does not use listing page aggregate size without release url',
    () async {
      final details = await FixtureAPKMirror().getLatestAPKDetails(
        'https://www.apkmirror.com/apk/example/example',
        const {'trackOnly': true, 'fallbackToOlderReleases': true},
      );

      expect(details.version, '2.0');
      expect(details.apkSizeBytes, null);
    },
  );

  test('apk mirror prefers size candidate matching supported ABI', () async {
    final originalDeviceInfoPlatform = DeviceInfoPlatform.instance;
    DeviceInfoPlatform.instance = FakeAndroidDeviceInfoPlatform();
    addTearDown(() {
      DeviceInfoPlatform.instance = originalDeviceInfoPlatform;
    });
    expect(
      await filterApksByArch([
        const MapEntry('test armeabi-v7a', 'v7'),
        const MapEntry('test arm64-v8a', 'v8'),
      ]),
      [const MapEntry('test arm64-v8a', 'v8')],
    );

    final apkMirror = AbiAwareReleaseAPKMirror();
    const settings = {
      'trackOnly': true,
      'fallbackToOlderReleases': true,
      'autoApkFilterByArch': true,
    };
    final details = await apkMirror.getLatestAPKDetails(
      'https://www.apkmirror.com/apk/google-inc/youtube-music',
      settings,
    );

    expect(details.version, '9.17.51');
    // Size is resolved lazily (not in getLatestAPKDetails): the resolver walks
    // the release page, ABI-filters the download candidates, and probes only
    // the matching-ABI (arm64-v8a) download page. details.changeLog carries the
    // release-page URL the resolver needs.
    final apkSizeBytes = await apkMirror.resolveLatestApkSizeBytes(
      releasePageUrl: details.changeLog,
      additionalSettings: settings,
    );
    expect(apkSizeBytes, 60817408);
    expect(
      apkMirror.requestedUrls.where((url) {
        return url.contains('android-apk-download');
      }).toList(),
      [
        'https://www.apkmirror.com/apk/google-inc/youtube-music/youtube-music-9-17-51-release/youtube-music-9-17-51-5-android-apk-download/',
      ],
    );
  });

  test('version extraction rejects match groups that do not exist', () {
    expect(
      () => extractVersion(
        r'(\d+_\d+_\d+)',
        r'$1.$2.$3',
        'https://www.zdevs.ru/files/za/ZArchiver_1_0_10_arm64-v8a_release.apk',
      ),
      throwsA(isA<NoVersionError>()),
    );
  });

  test('apk mirror resolves no size when the release page is blocked', () async {
    final apkMirror = ReleasePageBlockedAPKMirror();
    const settings = {'trackOnly': true, 'fallbackToOlderReleases': true};
    final details = await apkMirror.getLatestAPKDetails(
      'https://www.apkmirror.com/apk/google-inc/youtube',
      settings,
    );

    expect(details.version, '21.18.163 beta');
    // The release page is blocked (non-200). Lazy size resolution deliberately
    // does NOT fall back to speculative per-variant URL guessing (that probed up
    // to ~20 URLs per app per refresh with an abysmal hit rate and was removed),
    // so no size is resolved and no download pages are probed.
    final apkSizeBytes = await apkMirror.resolveLatestApkSizeBytes(
      releasePageUrl: details.changeLog,
      additionalSettings: settings,
    );
    expect(apkSizeBytes, null);
    expect(
      apkMirror.requestedUrls
          .where((url) => url.contains('android-apk-download'))
          .toList(),
      <String>[],
    );
  });

  // #222: an install whose success was never recorded left the stored version
  // permanently behind whenever the device's versionName could not be related to
  // the source's version string. Both reported apps used a third-party installer
  // and were stuck across restarts and pull-to-refresh.
  group('#222 stale installed version is healed from the device', () {
    App issue222App({
      required String? installedVersion,
      required String latestVersion,
      String id = 'io.github.kichikuou.xsystem35',
      String url = 'https://github.com/kichikuou/xsystem35-sdl2',
      String author = 'kichikuou',
      String name = 'xsystem35',
      Map<String, dynamic>? additionalSettings,
    }) => App(
      id: id,
      url: url,
      author: author,
      name: name,
      installedVersion: installedVersion,
      latestVersion: latestVersion,
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings:
          additionalSettings ?? <String, dynamic>{'versionDetection': 'auto'},
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    App? correct(
      App app, {
      required String deviceVersionName,
      int deviceVersionCode = 36,
    }) => AppsProvider(isBg: true).getCorrectedInstallStatusAppIfPossible(
      app,
      FakePackageInfo(
        packageName: app.id,
        versionName: deviceVersionName,
        versionCode: deviceVersionCode,
      ),
    );

    test('manifest versionName carrying a git hash (xsystem35)', () {
      final app = issue222App(
        installedVersion: 'v2.19.0',
        latestVersion: 'v2.19.1',
      );

      final correctedApp = correct(
        app,
        deviceVersionName: '2.19.1 (git 50a6b17)',
      );

      expect(correctedApp, isNotNull);
      expect(correctedApp!.installedVersion, 'v2.19.1');
      expect(appHasActionableUpdate(correctedApp), false);
      // The device version reconciles with latest, so detection stays on.
      expect(correctedApp.additionalSettings['versionDetection'], 'auto');
    });

    test('v-prefixed tag whose segment count changed (ZipXtract)', () {
      final app = issue222App(
        url: 'https://github.com/WirelessAlien/ZipXtract',
        installedVersion: 'v7.1',
        latestVersion: 'v7.1.1',
      );

      final correctedApp = correct(
        app,
        deviceVersionName: '7.1.1',
        deviceVersionCode: 26,
      );

      expect(correctedApp, isNotNull);
      expect(correctedApp!.installedVersion, 'v7.1.1');
      expect(appHasActionableUpdate(correctedApp), false);
    });

    test(
      'shorter device version is not rewritten to a longer source tag (ZipXtract)',
      () {
        // Device is on 7.1; GitHub latest is v7.1.1. A short shared format
        // ([0-9]+\\.[0-9]+) used to match the '7.1' prefix inside 'v7.1.1' and
        // step 3 rewrote installedVersion to the source latest, which then
        // looked like a pseudo-version and hid the update forever.
        expect(reconcileVersionDifferences('7.1', 'v7.1.1')?.areEqual, false);
        expect(versionsEffectivelyEqual('7.1', 'v7.1.1'), false);

        final app = issue222App(
          id: 'com.wirelessalien.zipxtract',
          url: 'https://github.com/WirelessAlien/ZipXtract',
          author: 'WirelessAlien',
          name: 'ZipXtract',
          installedVersion: null,
          latestVersion: 'v7.1.1',
        );

        final correctedApp = correct(
          app,
          deviceVersionName: '7.1',
          deviceVersionCode: 25,
        );

        expect(correctedApp, isNotNull);
        expect(correctedApp!.installedVersion, '7.1');
        expect(correctedApp.additionalSettings['versionDetection'], 'auto');
        expect(appHasActionableUpdate(correctedApp), true);
      },
    );

    test(
      'pull-to-refresh heals a ZipXtract install wrongly pinned to source latest',
      () {
        final app = issue222App(
          id: 'com.wirelessalien.zipxtract',
          url: 'https://github.com/WirelessAlien/ZipXtract',
          author: 'WirelessAlien',
          name: 'ZipXtract',
          installedVersion: 'v7.1.1',
          latestVersion: 'v7.1.1',
        );

        final correctedApp = correct(
          app,
          deviceVersionName: '7.1',
          deviceVersionCode: 25,
        );

        expect(correctedApp, isNotNull);
        expect(correctedApp!.installedVersion, '7.1');
        expect(correctedApp.additionalSettings['versionDetection'], 'auto');
        expect(appHasActionableUpdate(correctedApp), true);
      },
    );

    test('both sides keeping the full manifest string', () {
      final app = issue222App(
        installedVersion: '2.19.0 (git a77e849)',
        latestVersion: '2.19.1 (git 50a6b17)',
      );

      final correctedApp = correct(
        app,
        deviceVersionName: '2.19.1 (git 50a6b17)',
      );

      expect(correctedApp, isNotNull);
      expect(correctedApp!.installedVersion, '2.19.1 (git 50a6b17)');
      expect(versionOrderUncertainUpdate(correctedApp), false);
    });

    test('a device genuinely behind latest is left alone', () {
      final app = issue222App(
        installedVersion: 'v2.19.0',
        latestVersion: 'v2.19.1',
      );

      final correctedApp = correct(
        app,
        deviceVersionName: '2.19.0 (git a77e849)',
      );

      expect(correctedApp?.installedVersion ?? app.installedVersion, 'v2.19.0');
      expect(appHasActionableUpdate(correctedApp ?? app), true);
    });

    test('version-code mode is never healed from a version string', () {
      final app = issue222App(
        installedVersion: '36',
        latestVersion: 'v2.19.1',
        additionalSettings: <String, dynamic>{
          'versionDetection': 'versionCode',
        },
      );

      final correctedApp = correct(
        app,
        deviceVersionName: '2.19.1 (git 50a6b17)',
      );

      // The device's version code is unchanged, so the stored version code
      // stands; it must not be replaced by the source's version string.
      expect(correctedApp?.installedVersion ?? app.installedVersion, '36');
    });

    test('corrections are written back to the app JSON', () async {
      final appsProvider = AppsProvider(isBg: true);
      final app = issue222App(
        installedVersion: 'v2.19.1',
        latestVersion: 'v2.19.1',
      );
      appsProvider.apps[app.id] = AppInMemory(app, null, null, null);

      await appsProvider.persistInstallStatusCorrections(<String>[app.id]);

      final File appFile = File(
        '${(await appsProvider.getAppsDir()).path}/${app.id}.json',
      );
      expect(appFile.existsSync(), true);
      expect(
        (jsonDecode(appFile.readAsStringSync()) as Map)['installedVersion'],
        'v2.19.1',
      );
    });

    test('nothing is written for apps that are no longer tracked', () async {
      final appsProvider = AppsProvider(isBg: true);
      final File appFile = File(
        '${(await appsProvider.getAppsDir()).path}/app.gone.json',
      );

      await appsProvider.persistInstallStatusCorrections(<String>['app.gone']);

      expect(appFile.existsSync(), false);
    });

    test('pseudo-version apps are not given the source latest', () {
      final app = issue222App(
        installedVersion: 'nightly-2026-07-20',
        latestVersion: 'nightly-2026-07-28',
        additionalSettings: <String, dynamic>{'versionDetection': 'pseudo'},
      );

      final correctedApp = correct(
        app,
        deviceVersionName: '2.19.1 (git 50a6b17)',
      );

      expect(
        correctedApp?.installedVersion ?? app.installedVersion,
        'nightly-2026-07-20',
      );
    });
  });

  group('app JSON persistence', () {
    test('later concurrent save wins for the same app ID', () async {
      final Directory appsDirectory = Directory.systemTemp.createTempSync(
        'obtainx_save_queue_',
      );
      addTearDown(() => appsDirectory.delete(recursive: true));
      final AppsProvider appsProvider = AppsProvider(isBg: true)
        ..cachedAppsDir = appsDirectory;
      addTearDown(appsProvider.dispose);
      const String appId = 'dev.example.concurrent';
      final App olderApp = _buildPersistenceTestApp(
        id: appId,
        name: 'Older',
        additionalSettings: <String, dynamic>{
          'largePayload': List<String>.filled(2 * 1024 * 1024, 'x').join(),
        },
      );
      final App newerApp = _buildPersistenceTestApp(id: appId, name: 'Newer');

      final Future<void> olderSave = appsProvider.saveApps(
        <App>[olderApp],
        onlyIfExists: false,
        updateInstalledInfo: false,
        autoExportAfterSave: false,
      );
      await Future<void>.delayed(Duration.zero);
      final Future<void> newerSave = appsProvider.saveApps(
        <App>[newerApp],
        onlyIfExists: false,
        updateInstalledInfo: false,
        autoExportAfterSave: false,
      );
      await Future.wait(<Future<void>>[olderSave, newerSave]);

      final Map<String, dynamic> savedJson =
          jsonDecode(
                File('${appsDirectory.path}/$appId.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(savedJson['name'], 'Newer');
      expect(
        appsDirectory.listSync().where(
          (FileSystemEntity entry) => entry.path.contains('.json.tmp_'),
        ),
        isEmpty,
      );
    });

    test('failed atomic replacement propagates and cleans its temp', () async {
      final Directory appsDirectory = Directory.systemTemp.createTempSync(
        'obtainx_save_failure_',
      );
      addTearDown(() => appsDirectory.delete(recursive: true));
      final AppsProvider appsProvider = AppsProvider(isBg: true)
        ..cachedAppsDir = appsDirectory;
      addTearDown(appsProvider.dispose);
      const String appId = 'dev.example.blocked';
      Directory('${appsDirectory.path}/$appId.json').createSync();
      final App app = _buildPersistenceTestApp(id: appId, name: 'Blocked');

      await expectLater(
        appsProvider.saveApps(
          <App>[app],
          onlyIfExists: false,
          updateInstalledInfo: false,
          autoExportAfterSave: false,
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(appsProvider.apps.containsKey(appId), isFalse);
      expect(
        appsDirectory.listSync().where(
          (FileSystemEntity entry) => entry.path.contains('.json.tmp_'),
        ),
        isEmpty,
      );
    });
  });

  test('commit-sha-like version update does not disable version detection', () {
    final appsProvider = AppsProvider(isBg: true);
    final app = App(
      id: 'app.example',
      url: 'https://github.com/example/example',
      author: 'example',
      name: 'example',
      installedVersion: 'debug-75094d8',
      latestVersion: 'debug-86094f9',
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: {'versionDetection': 'auto'},
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
      app,
      const FakePackageInfo(
        packageName: 'app.example',
        versionName: '1.5.3-DEV (75094D8)',
        versionCode: 106,
      ),
    );

    expect(correctedApp, isNull);
    expect(app.additionalSettings['versionDetection'], 'auto');
    expect(app.installedVersion, 'debug-75094d8');
  });

  test(
    'releaseCommitShaAsVersion setting does not disable version detection even if commit hashes differ',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.example',
        url: 'https://github.com/example/example',
        author: 'example',
        name: 'example',
        installedVersion: '75094d8',
        latestVersion: '86094f9',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {
          'versionDetection': 'auto',
          'releaseCommitShaAsVersion': true,
        },
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.example',
          versionName: '1.5.3-DEV (75094D8)',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNull);
      expect(app.additionalSettings['versionDetection'], 'auto');
      expect(app.installedVersion, '75094d8');
    },
  );

  test(
    'dot-separated hash suffix is not the same release as its numeric core',
    () {
      expect(
        reconcileVersionDifferences('26.06', '26.06.9df4c85')?.areEqual,
        false,
      );
      expect(
        reconcileVersionDifferences('26.06', '26.06-9df4c85')?.areEqual,
        true,
      );
      expect(
        reconcileVersionDifferences('2.19.1', '2.19.1 (git 50a6b17)')?.areEqual,
        true,
      );

      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.example',
        url: 'https://github.com/wxxsfxyzm/InstallerX-Revived',
        author: 'wxxsfxyzm',
        name: 'InstallerX-Revived',
        installedVersion: '26.06.9df4c85',
        latestVersion: '26.07.1a2b3c4',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.example',
          versionName: '26.06',
          versionCode: 106,
        ),
      );

      // Device 26.06 and stored 26.06.9df4c85 are related but not the same
      // release string, so the device core is adopted and detection stays on.
      expect(correctedApp, isNotNull);
      expect(correctedApp!.additionalSettings['versionDetection'], 'auto');
      expect(correctedApp.installedVersion, '26.06');
      expect(appHasActionableUpdate(correctedApp), true);
    },
  );

  test(
    'partially sha-like version update from null stored version does not disable version detection',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        id: 'app.example',
        url: 'https://github.com/wxxsfxyzm/InstallerX-Revived',
        author: 'wxxsfxyzm',
        name: 'InstallerX-Revived',
        installedVersion: null,
        latestVersion: '26.07.1a2b3c4',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.example',
          versionName: '26.06',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNotNull);
      expect(correctedApp!.additionalSettings['versionDetection'], 'auto');
      expect(correctedApp.installedVersion, '26.06');
    },
  );

  test(
    'unclear version order is resolved using lastInstalledTime and releaseDate',
    () {
      // Scenario 1: releaseDate is after lastInstalledTime (update available)
      final appUpdate = App(
        id: 'app.example',
        url: 'https://github.com/example/example',
        author: 'example',
        name: 'example',
        installedVersion: '26.06.9df4c85',
        latestVersion: '26.06.8df31d',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {
          'versionDetection': 'auto',
          'lastInstalledTime':
              1780272000000, // June 1st, 2026 in ms since epoch
        },
        lastUpdateCheck: DateTime.now(),
        pinned: false,
        releaseDate: DateTime.utc(2026, 6, 2),
      );

      expect(appHasActionableUpdate(appUpdate), true);
      expect(versionOrderUncertainUpdate(appUpdate), false);

      // Scenario 2: releaseDate is before lastInstalledTime (no update)
      final appNoUpdate = App(
        id: 'app.example',
        url: 'https://github.com/example/example',
        author: 'example',
        name: 'example',
        installedVersion: '26.06.9df4c85',
        latestVersion: '26.06.8df31d',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {
          'versionDetection': 'auto',
          'lastInstalledTime':
              1780444800000, // June 3rd, 2026 in ms since epoch
        },
        lastUpdateCheck: DateTime.now(),
        pinned: false,
        releaseDate: DateTime.utc(2026, 6, 2),
      );

      expect(appHasActionableUpdate(appNoUpdate), false);
      // Even when timestamps suggest no update, the version order is still ambiguous,
      // so the uncertain indicator must remain visible so the user can decide.
      expect(versionOrderUncertainUpdate(appNoUpdate), true);

      // Scenario 3: no lastInstalledTime (uncertain update)
      final appUncertain = App(
        id: 'app.example',
        url: 'https://github.com/example/example',
        author: 'example',
        name: 'example',
        installedVersion: '26.06.9df4c85',
        latestVersion: '26.06.8df31d',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: {'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
        releaseDate: DateTime.utc(2026, 6, 2),
      );

      expect(appHasActionableUpdate(appUncertain), false);
      expect(versionOrderUncertainUpdate(appUncertain), true);
    },
  );

  test('skip normalization removes stale and redundant skip state', () {
    final activeSkip = App(
      id: 'app.example',
      url: 'https://github.com/example/example',
      author: 'example',
      name: 'example',
      installedVersion: '1.0',
      latestVersion: '2.0',
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: const {'skippedLatestVersion': '2.0'},
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    expect(
      normalizeSkippedLatestVersion(
        activeSkip.copyWith(
          additionalSettings: const {'skippedLatestVersion': '1.5'},
        ),
      ).additionalSettings.containsKey('skippedLatestVersion'),
      false,
    );
    expect(
      normalizeSkippedLatestVersion(
        activeSkip.copyWith(installedVersion: '2.0'),
      ).additionalSettings.containsKey('skippedLatestVersion'),
      false,
    );
    expect(
      normalizeSkippedLatestVersion(
        activeSkip.copyWith(installedVersion: '3.0'),
      ).additionalSettings.containsKey('skippedLatestVersion'),
      false,
    );
    expect(
      normalizeSkippedLatestVersion(
        activeSkip,
      ).additionalSettings['skippedLatestVersion'],
      '2.0',
    );
  });

  test(
    'background candidate selection excludes skipped, on-demand, and newer apps',
    () {
      final appsProvider = AppsProvider(isBg: true);
      addTearDown(appsProvider.dispose);
      final actionable = App(
        id: 'actionable',
        url: 'https://github.com/example/actionable',
        author: 'example',
        name: 'actionable',
        installedVersion: '1.0',
        latestVersion: '2.0',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: const <String, dynamic>{},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );
      final skipped = actionable.copyWith(
        id: 'skipped',
        additionalSettings: const {'skippedLatestVersion': '2.0'},
      );
      final onDemand = actionable.copyWith(
        id: 'on-demand',
        additionalSettings: const {'onDemandOnly': true},
      );
      final installedNewer = actionable.copyWith(
        id: 'installed-newer',
        installedVersion: '3.0',
      );
      appsProvider.apps.addAll({
        actionable.id: AppInMemory(actionable, null, null, null),
        skipped.id: AppInMemory(skipped, null, null, null),
        onDemand.id: AppInMemory(onDemand, null, null, null),
        installedNewer.id: AppInMemory(installedNewer, null, null, null),
      });

      expect(
        appsProvider.findExistingUpdates(
          installedOnly: true,
          excludeOnDemandOnly: true,
        ),
        <String>['actionable'],
      );
    },
  );

  test('install status reconciliation converges to a fixed point', () {
    // getCorrectedInstallStatusAppIfPossible is applied on every load and save, so
    // it has to settle: if pass N keeps producing a different app, the JSON is
    // rewritten forever and the recorded install state depends on how many times
    // the app list happened to refresh. (It is not idempotent after one pass —
    // flipping to pseudo in step 4 legitimately lets step 1b adopt the device
    // version on the next pass — so the property is convergence, not idempotence.)
    final appsProvider = AppsProvider(isBg: true);
    addTearDown(appsProvider.dispose);

    const List<List<String>> cases = <List<String>>[
      <String>['1.2.3', '1.2.4', '1.2.3'],
      <String>['153.0', '153.0.2', '153.0'],
      <String>[
        '1.0.896819557.release',
        '1.0.915254043.release',
        '1.0.896819557.release',
      ],
      <String>['26.06.9df4c85', '26.06.8df31d', '26.06.9df4c85'],
      <String>['106', '107', '9.18.50'],
      <String>['1.2', '1.2.0', '1.2'],
      <String>['2.0', '2.1', '451'],
    ];

    for (final List<String> testCase in cases) {
      final String installed = testCase[0];
      final String latest = testCase[1];
      final String deviceVersion = testCase[2];
      for (final String mode in <String>[
        'auto',
        'standard',
        'pseudo',
        'versionCode',
      ]) {
        App app = App(
          id: 'app.example',
          url: 'https://github.com/example/example',
          author: 'example',
          name: 'example',
          installedVersion: installed,
          latestVersion: latest,
          apkUrls: const <MapEntry<String, String>>[],
          preferredApkIndex: 0,
          additionalSettings: <String, dynamic>{'versionDetection': mode},
          lastUpdateCheck: DateTime.now(),
          pinned: false,
        );
        final info = FakePackageInfo(
          packageName: 'app.example',
          versionName: deviceVersion,
          versionCode: 451,
        );

        var passes = 0;
        while (passes < 6) {
          final App? corrected = appsProvider
              .getCorrectedInstallStatusAppIfPossible(app, info);
          if (corrected == null) break;
          app = corrected;
          passes++;
        }
        expect(
          passes,
          lessThan(6),
          reason:
              'no fixed point for ($installed → $latest, device $deviceVersion) in $mode',
        );
      }
    }
  });

  // Regression: version reconciliation must have exactly one implementation.
  // A second copy used to exist as an extension member on AppsProvider, which
  // shadowed the top-level function for every production caller and lacked the
  // shape fallback, so `.release`-style versions came back unreconcilable.
  test('reconciliation relates shape-identical non-standard versions', () {
    const installed = '1.0.896819557.release';
    const latest = '1.0.915254043.release';

    final reconciled = reconcileVersionDifferences(installed, latest);
    expect(reconciled, isNotNull);
    expect(reconciled!.areEqual, false);
    expect(reconciled.version, installed);

    // Same for Google-style long release versions.
    final google = reconcileVersionDifferences(
      '2026.03.12.885261117.2-release',
      '2026.04.27.917519149.2-release',
    );
    expect(google?.areEqual, false);
  });

  test(
    'auto detection survives non-standard release suffixes instead of going pseudo',
    () {
      final appsProvider = AppsProvider(isBg: true);
      addTearDown(appsProvider.dispose);
      const installed = '1.0.896819557.release';
      const latest = '1.0.915254043.release';
      final app = App(
        id: 'com.example.release',
        // A source WITHOUT naiveStandardVersionDetection, so reconciliation is
        // the only thing keeping version detection alive.
        url: 'https://github.com/example/release-suffix',
        author: 'example',
        name: 'Release Suffix',
        installedVersion: installed,
        latestVersion: latest,
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{'versionDetection': 'auto'},
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );
      const info = FakePackageInfo(
        packageName: 'com.example.release',
        versionName: installed,
        versionCode: 896819557,
      );

      expect(
        appsProvider.isVersionDetectionPossible(
          AppInMemory(app, null, info, null),
        ),
        true,
      );
      expect(appHasActionableUpdate(app), true);

      final App? corrected = appsProvider
          .getCorrectedInstallStatusAppIfPossible(app, info);
      final App effective = corrected ?? app;

      // The pending update must survive reconciliation: no flip to pseudo, no
      // rewriting installedVersion to the release that was never installed.
      expect(effective.additionalSettings['versionDetection'], 'auto');
      expect(effective.installedVersion, installed);
      expect(appHasActionableUpdate(effective), true);
    },
  );

  test('version detection mode parses every stored encoding', () {
    expect(VersionDetectionMode.fromStored('auto'), VersionDetectionMode.auto);
    expect(
      VersionDetectionMode.fromStored('standard'),
      VersionDetectionMode.standard,
    );
    expect(
      VersionDetectionMode.fromStored('pseudo'),
      VersionDetectionMode.pseudo,
    );
    expect(
      VersionDetectionMode.fromStored('versionCode'),
      VersionDetectionMode.versionCode,
    );
    // Legacy encodings still reachable when App.fromJson falls back to
    // unmigrated JSON.
    expect(VersionDetectionMode.fromStored(null), VersionDetectionMode.auto);
    expect(VersionDetectionMode.fromStored(true), VersionDetectionMode.auto);
    expect(VersionDetectionMode.fromStored(false), VersionDetectionMode.pseudo);
    expect(
      VersionDetectionMode.fromStored('standardVersionDetection'),
      VersionDetectionMode.auto,
    );
    expect(
      VersionDetectionMode.fromStored('noVersionDetection'),
      VersionDetectionMode.pseudo,
    );
    expect(
      VersionDetectionMode.fromStored('releaseDateAsVersion'),
      VersionDetectionMode.pseudo,
    );
  });

  test(
    'version-code mode is read from either the mode or its derived bool',
    () {
      App app(Map<String, dynamic> settings) => App(
        id: 'app.example',
        url: 'https://github.com/example/example',
        author: 'example',
        name: 'example',
        installedVersion: '123',
        latestVersion: '124',
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: settings,
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      // Both signals in sync.
      expect(
        app(const {
          'versionDetection': 'versionCode',
          'useVersionCodeAsOSVersion': true,
        }).usesVersionCodeAsOsVersion,
        true,
      );
      // Out of sync in either direction still means version-code mode, so the
      // displayed version and install-status reconciliation cannot disagree.
      expect(
        app(const {
          'versionDetection': 'versionCode',
        }).usesVersionCodeAsOsVersion,
        true,
      );
      expect(
        app(const {
          'versionDetection': 'auto',
          'useVersionCodeAsOSVersion': true,
        }).usesVersionCodeAsOsVersion,
        true,
      );
      expect(
        app(const {'versionDetection': 'auto'}).usesVersionCodeAsOsVersion,
        false,
      );
    },
  );

  test(
    'normalizing version detection settings keeps the derived bool honest',
    () {
      // Stored settings: a stale boolean pulls the mode to versionCode.
      final stored = <String, dynamic>{
        'versionDetection': 'auto',
        'useVersionCodeAsOSVersion': true,
      };
      normalizeVersionDetectionSettings(stored, promoteLegacyBoolean: true);
      expect(stored['versionDetection'], 'versionCode');
      expect(stored['useVersionCodeAsOSVersion'], true);

      // Post-form-merge: the dropdown wins, so the user can leave versionCode mode
      // even though the stale boolean is still in the map.
      final edited = <String, dynamic>{
        'versionDetection': 'auto',
        'useVersionCodeAsOSVersion': true,
      };
      normalizeVersionDetectionSettings(edited);
      expect(edited['versionDetection'], 'auto');
      expect(edited['useVersionCodeAsOSVersion'], false);

      // Legacy bools are canonicalised to mode keys, never left as bools.
      final legacy = <String, dynamic>{'versionDetection': false};
      normalizeVersionDetectionSettings(legacy);
      expect(legacy['versionDetection'], 'pseudo');
    },
  );

  test(
    'version-code mode never reports a version code as newer than a version',
    () {
      App app({required String installed, required String latest}) => App(
        id: 'app.example',
        url: 'https://github.com/example/example',
        author: 'example',
        name: 'example',
        installedVersion: installed,
        latestVersion: latest,
        apkUrls: const <MapEntry<String, String>>[],
        preferredApkIndex: 0,
        additionalSettings: const <String, dynamic>{
          'versionDetection': 'versionCode',
          'useVersionCodeAsOSVersion': true,
        },
        lastUpdateCheck: DateTime.now(),
        pinned: false,
      );

      // The broken case: device versionCode 123 vs a source semver. Digit-wise
      // ordering used to make this "installed is newer" — up to date forever.
      final mismatched = app(installed: '123', latest: '1.2.4');
      expect(versionCodeModeCannotCompare(mismatched), true);
      expect(appIsUpToDateForFiltering(mismatched), false);
      // Unorderable, so: visible to the user, but never auto-installed.
      expect(versionOrderUncertainUpdate(mismatched), true);
      expect(appHasActionableUpdate(mismatched), false);
      expect(appUpdateIsUserVisible(mismatched), false);
      expect(
        appUpdateIsUserVisible(mismatched, includeVersionOrderUncertain: true),
        true,
      );

      // Correctly configured: source publishes version codes too, so ordering works.
      final ordered = app(installed: '123', latest: '124');
      expect(versionCodeModeCannotCompare(ordered), false);
      expect(appHasActionableUpdate(ordered), true);
      expect(appIsUpToDateForFiltering(ordered), false);

      final upToDate = app(installed: '124', latest: '124');
      expect(appHasActionableUpdate(upToDate), false);
      expect(appIsUpToDateForFiltering(upToDate), true);
    },
  );

  test('appUpdateIsUserVisible agrees with the list UI, not with string diffs', () {
    App app({
      String? installed = '1.2.3',
      String latest = '1.2.4',
      Map<String, dynamic> settings = const <String, dynamic>{},
    }) => App(
      id: 'app.example',
      url: 'https://github.com/example/example',
      author: 'example',
      name: 'example',
      installedVersion: installed,
      latestVersion: latest,
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: settings,
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    // Genuinely behind.
    expect(appUpdateIsUserVisible(app()), true);
    // Version string changed but denotes the same build (build-metadata suffix).
    expect(appUpdateIsUserVisible(app(latest: '1.2.3-2')), false);
    // Source published something older than what is installed.
    expect(appUpdateIsUserVisible(app(latest: '1.1.0')), false);
    // User skipped this exact release.
    expect(
      appUpdateIsUserVisible(
        app(settings: const {'skippedLatestVersion': '1.2.4'}),
      ),
      false,
    );
    // Never installed: still installable.
    expect(appUpdateIsUserVisible(app(installed: null)), true);
    // Ambiguous ordering: notifications surface it, background install must not.
    final ambiguous = app(installed: '26.06.9df4c85', latest: '26.06.8df31d');
    expect(versionOrderUncertainUpdate(ambiguous), true);
    expect(appUpdateIsUserVisible(ambiguous), false);
    expect(
      appUpdateIsUserVisible(ambiguous, includeVersionOrderUncertain: true),
      true,
    );
  });

  test('standard version matching and reconciliation ignore case', () {
    expect(
      findStandardFormatsForVersion('v2.9.9-Preview-251', false).isNotEmpty,
      true,
    );
    expect(
      reconcileVersionDifferences(
        'v2.9.9-Preview-251',
        'V2.9.9-preview-251',
      )?.areEqual,
      true,
    );
  });

  // Codeberg reuses GitHub's option list, but attestations are GitHub-only:
  // AppsProvider.verifyGitHubAttestation returns early on `source is! GitHub`,
  // and the Add-app sanitiser is gated on `pickedSource is GitHub`, so the
  // dropdown was both inert and unsanitised there.
  test('Codeberg drops the GitHub-only build verification option', () {
    final Set<String> codebergKeys = Codeberg()
        .additionalSourceAppSpecificSettingFormItems
        .expand((row) => row)
        .map((item) => item.key)
        .toSet();
    final Set<String> githubKeys = GitHub()
        .additionalSourceAppSpecificSettingFormItems
        .expand((row) => row)
        .map((item) => item.key)
        .toSet();

    expect(codebergKeys, isNot(contains(GitHub.buildVerificationModeKey)));
    expect(githubKeys, contains(GitHub.buildVerificationModeKey));
    // Everything else stays: Forgejo's release payloads carry tag_name, name,
    // body, prerelease and published_at, and it serves /releases/latest.
    expect(
      codebergKeys,
      githubKeys.difference({GitHub.buildVerificationModeKey}),
    );
    // No row is left empty by the filtering.
    for (final row in Codeberg().additionalSourceAppSpecificSettingFormItems) {
      expect(row, isNotEmpty);
    }
  });

  // Forgejo/Gitea assets expose only `created_at`, so reading `updated_at`
  // alone made "use latest asset upload as release date" a no-op on Codeberg.
  //
  // The input is deliberately in the WRONG order (newest first) so the sort has
  // to actually move something: with no usable dates every comparison returns 0
  // and the stable sort leaves the input untouched, which is how a first version
  // of this test passed against the unfixed code.
  test('asset-date sorting reads Forgejo created_at as well as updated_at', () {
    List<dynamic> newestFirst(String dateKey) => <dynamic>[
      <String, dynamic>{
        'tag_name': 'newer',
        'assets': [
          {'name': 'b.apk', dateKey: '2026-06-01T00:00:00Z'},
        ],
      },
      <String, dynamic>{
        'tag_name': 'older',
        'assets': [
          {'name': 'a.apk', dateKey: '2026-01-01T00:00:00Z'},
        ],
      },
    ];

    // Sorting is ascending, so a working asset date puts 'older' first.
    final gitHubShaped = newestFirst('updated_at');
    GitHub().sortGitHubReleases(gitHubShaped, 'date', true);
    expect(gitHubShaped.map((r) => r['tag_name']).toList(), <String>[
      'older',
      'newer',
    ]);

    final forgejoShaped = newestFirst('created_at');
    GitHub().sortGitHubReleases(forgejoShaped, 'date', true);
    expect(forgejoShaped.map((r) => r['tag_name']).toList(), <String>[
      'older',
      'newer',
    ]);

    // Guard the guard: with neither timestamp there is nothing to sort by, so
    // the original order must survive. If this ever starts reordering, the two
    // assertions above stopped proving anything.
    final undated = <dynamic>[
      <String, dynamic>{
        'tag_name': 'newer',
        'assets': [
          {'name': 'b.apk'},
        ],
      },
      <String, dynamic>{
        'tag_name': 'older',
        'assets': [
          {'name': 'a.apk'},
        ],
      },
    ];
    GitHub().sortGitHubReleases(undated, 'date', true);
    expect(undated.map((r) => r['tag_name']).toList(), <String>[
      'newer',
      'older',
    ]);
  });

  test('GitHub smart-name release sorting ignores version case', () {
    final releases = <dynamic>[
      <String, dynamic>{'tag_name': 'v2.9.9-PREVIEW-251', 'prerelease': true},
      <String, dynamic>{'tag_name': 'v2.9.9-preview-247', 'prerelease': true},
    ];

    GitHub().sortGitHubReleases(releases, 'smartname', false);

    expect(releases.map((release) => release['tag_name']).toList(), <String>[
      'v2.9.9-preview-247',
      'v2.9.9-PREVIEW-251',
    ]);
  });

  // An always-track-only source (APKMirror, RockMods) resolves a real package
  // id, so absence from the device is a reliable uninstall signal. Before the
  // fix, exempting every track-only app from step 1 pinned these to "installed
  // <old version>" permanently — pull-to-refresh could not clear it.
  test('track-only app with a real package id clears installed version '
      'once uninstalled', () {
    final appsProvider = AppsProvider(isBg: true);
    final app = App(
      id: 'com.example.trackedapp',
      url: 'https://www.apkmirror.com/apk/vendor/tracked-app',
      author: 'vendor',
      name: 'Tracked App',
      installedVersion: '1.2.3',
      latestVersion: '1.2.4',
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: {
        'trackOnly': true,
        'trackOnlyTemporaryPackageId': false,
        'trackOnlyUndeterminedInstalledVersion': false,
        'versionDetection': 'auto',
      },
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
      app,
      null,
    );

    expect(correctedApp, isNotNull);
    expect(correctedApp!.installedVersion, isNull);
    // Determined ("not installed"), so the app page's fix-the-package-id error
    // card must stay hidden.
    expect(
      correctedApp.additionalSettings['trackOnlyUndeterminedInstalledVersion'],
      false,
    );
  });

  // A temporary (sha-prefix) package id can never match an installed package,
  // so an absent lookup says nothing and the recorded version must survive.
  test('track-only app with a temporary package id keeps its installed '
      'version when absent from the device', () {
    final appsProvider = AppsProvider(isBg: true);
    final app = App(
      id: 'a1b2c3d4e5f6',
      url: 'https://www.apkmirror.com/apk/vendor/temp-id-app',
      author: 'vendor',
      name: 'Temp Id App',
      installedVersion: '1.2.3',
      latestVersion: '1.2.3',
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: {
        'trackOnly': true,
        'trackOnlyTemporaryPackageId': true,
        'trackOnlyUndeterminedInstalledVersion': true,
        'versionDetection': 'auto',
      },
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
      app,
      null,
    );

    expect(correctedApp?.installedVersion ?? app.installedVersion, '1.2.3');
  });

  // The opposite direction was always trusted for real-id track-only apps;
  // assert it still is, so the two directions stay symmetric.
  test('track-only app with a real package id adopts the device version '
      'once installed', () {
    final appsProvider = AppsProvider(isBg: true);
    final app = App(
      id: 'com.example.trackedapp',
      url: 'https://www.apkmirror.com/apk/vendor/tracked-app',
      author: 'vendor',
      name: 'Tracked App',
      installedVersion: null,
      latestVersion: '1.2.4',
      apkUrls: const <MapEntry<String, String>>[],
      preferredApkIndex: 0,
      additionalSettings: {
        'trackOnly': true,
        'trackOnlyTemporaryPackageId': false,
        'trackOnlyUndeterminedInstalledVersion': true,
        'versionDetection': 'auto',
      },
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
      app,
      const FakePackageInfo(
        packageName: 'com.example.trackedapp',
        versionName: '1.2.3',
        versionCode: 123,
      ),
    );

    expect(correctedApp, isNotNull);
    expect(correctedApp!.installedVersion, '1.2.3');
    expect(
      correctedApp.additionalSettings['trackOnlyUndeterminedInstalledVersion'],
      false,
    );
  });
}
