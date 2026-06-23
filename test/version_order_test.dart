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

  test('release package lookup only includes debug build when requested', () {
    expect(packageNamesToTryForInstalledInfo('dev.bikram.obtainx'), const [
      'dev.bikram.obtainx',
    ]);
    expect(
      packageNamesToTryForInstalledInfo(
        'dev.bikram.obtainx',
        includeOwnDebugBuild: true,
      ),
      kDebugMode
          ? const ['dev.bikram.obtainx.debug', 'dev.bikram.obtainx']
          : const ['dev.bikram.obtainx'],
    );
  });

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
        'app.revanced.android.youtube',
        'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        'LovecraftianGodsKiller',
        'YouTube-Morphe',
        '106',
        '106',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': true},
        DateTime.now(),
        false,
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
        'app.revanced.android.youtube',
        'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        'LovecraftianGodsKiller',
        'YouTube-Morphe',
        '106',
        '107',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': false},
        DateTime.now(),
        false,
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
      expect(app.additionalSettings['versionDetection'], false);
    },
  );

  test(
    'disabled version detection sets installedVersion to latestVersion when installed version is null',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        'app.revanced.android.youtube',
        'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        'LovecraftianGodsKiller',
        'YouTube-Morphe',
        null,
        '107',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': false},
        DateTime.now(),
        false,
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
      expect(app.installedVersion, '107');
      expect(app.latestVersion, '107');
      expect(app.additionalSettings['versionDetection'], false);
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
        'app.revanced.android.youtube',
        'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        'LovecraftianGodsKiller',
        'YouTube-Morphe',
        '9.18.50',
        '107',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': false},
        DateTime.now(),
        false,
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
      expect(app.additionalSettings['versionDetection'], false);
      expect(appHasActionableUpdate(app), true);
    },
  );

  test(
    'disabled version detection keeps pseudo version when system installed version does not reconcile',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        'app.revanced.android.youtube',
        'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        'LovecraftianGodsKiller',
        'YouTube-Morphe',
        '26.06.01-de-vanced',
        '26.06.01-de-vanced',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': false},
        DateTime.now(),
        false,
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
      expect(app.additionalSettings['versionDetection'], false);
    },
  );

  test(
    'system installed version that reconciles with latest is adopted (detection stays on) when installedVersion is null',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        'app.revanced.android.youtube',
        'https://github.com/LovecraftianGodsKiller/YouTube-Morphe',
        'LovecraftianGodsKiller',
        'YouTube-Morphe',
        null,
        '26.06.01-de-vanced',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': true},
        DateTime.now(),
        false,
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
      expect(app.installedVersion, '4.15.0');
      expect(app.latestVersion, '26.06.01-de-vanced');
      expect(app.additionalSettings['versionDetection'], true);
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

  test('app copy preserves known apk size when refreshed size is unknown', () {
    final currentApp = App(
      'app-id',
      'https://example.com/app',
      'Author',
      'Name',
      '1.0',
      '2.0',
      const [],
      0,
      const {},
      DateTime(2026),
      false,
      apkSizeBytes: 123456,
    );

    final refreshedApp = currentApp.deepCopy();
    refreshedApp.apkSizeBytes = null;

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

  test('commit-sha-like version update does not disable version detection', () {
    final appsProvider = AppsProvider(isBg: true);
    final app = App(
      'app.example',
      'https://github.com/example/example',
      'example',
      'example',
      'debug-75094d8',
      'debug-86094f9',
      const <MapEntry<String, String>>[],
      0,
      {'versionDetection': true},
      DateTime.now(),
      false,
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
    expect(app.additionalSettings['versionDetection'], true);
    expect(app.installedVersion, 'debug-75094d8');
  });

  test(
    'releaseCommitShaAsVersion setting does not disable version detection even if commit hashes differ',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        'app.example',
        'https://github.com/example/example',
        'example',
        'example',
        '75094d8',
        '86094f9',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': true, 'releaseCommitShaAsVersion': true},
        DateTime.now(),
        false,
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
      expect(app.additionalSettings['versionDetection'], true);
      expect(app.installedVersion, '75094d8');
    },
  );

  test(
    'partially sha-like version updates (e.g. 26.06 to 26.07.1a2b3c4) do not disable version detection',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        'app.example',
        'https://github.com/wxxsfxyzm/InstallerX-Revived',
        'wxxsfxyzm',
        'InstallerX-Revived',
        '26.06.9df4c85',
        '26.07.1a2b3c4',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': true},
        DateTime.now(),
        false,
      );

      final correctedApp = appsProvider.getCorrectedInstallStatusAppIfPossible(
        app,
        const FakePackageInfo(
          packageName: 'app.example',
          versionName: '26.06',
          versionCode: 106,
        ),
      );

      expect(correctedApp, isNull);
      expect(app.additionalSettings['versionDetection'], true);
      expect(app.installedVersion, '26.06.9df4c85');
    },
  );

  test(
    'partially sha-like version update from null stored version does not disable version detection',
    () {
      final appsProvider = AppsProvider(isBg: true);
      final app = App(
        'app.example',
        'https://github.com/wxxsfxyzm/InstallerX-Revived',
        'wxxsfxyzm',
        'InstallerX-Revived',
        null,
        '26.07.1a2b3c4',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': true},
        DateTime.now(),
        false,
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
      expect(app.additionalSettings['versionDetection'], true);
      expect(app.installedVersion, '26.06');
    },
  );

  test(
    'unclear version order is resolved using lastInstalledTime and releaseDate',
    () {
      // Scenario 1: releaseDate is after lastInstalledTime (update available)
      final appUpdate = App(
        'app.example',
        'https://github.com/example/example',
        'example',
        'example',
        '26.06.9df4c85',
        '26.06.8df31d',
        const <MapEntry<String, String>>[],
        0,
        {
          'versionDetection': true,
          'lastInstalledTime':
              1780272000000, // June 1st, 2026 in ms since epoch
        },
        DateTime.now(),
        false,
        releaseDate: DateTime.utc(2026, 6, 2),
      );

      expect(appHasActionableUpdate(appUpdate), true);
      expect(versionOrderUncertainUpdate(appUpdate), false);

      // Scenario 2: releaseDate is before lastInstalledTime (no update)
      final appNoUpdate = App(
        'app.example',
        'https://github.com/example/example',
        'example',
        'example',
        '26.06.9df4c85',
        '26.06.8df31d',
        const <MapEntry<String, String>>[],
        0,
        {
          'versionDetection': true,
          'lastInstalledTime':
              1780444800000, // June 3rd, 2026 in ms since epoch
        },
        DateTime.now(),
        false,
        releaseDate: DateTime.utc(2026, 6, 2),
      );

      expect(appHasActionableUpdate(appNoUpdate), false);
      // Even when timestamps suggest no update, the version order is still ambiguous,
      // so the uncertain indicator must remain visible so the user can decide.
      expect(versionOrderUncertainUpdate(appNoUpdate), true);

      // Scenario 3: no lastInstalledTime (uncertain update)
      final appUncertain = App(
        'app.example',
        'https://github.com/example/example',
        'example',
        'example',
        '26.06.9df4c85',
        '26.06.8df31d',
        const <MapEntry<String, String>>[],
        0,
        {'versionDetection': true},
        DateTime.now(),
        false,
        releaseDate: DateTime.utc(2026, 6, 2),
      );

      expect(appHasActionableUpdate(appUncertain), false);
      expect(versionOrderUncertainUpdate(appUncertain), true);
    },
  );
}
