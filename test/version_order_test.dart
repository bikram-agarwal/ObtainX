import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/fdroid.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('apk mirror fallback download urls are generated from release url', () {
    expect(
      apkMirrorFallbackDownloadPageUrlsFromReleasePageUrl(
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/',
      ).take(3).toList(),
      [
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-2-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-3-android-apk-download/',
      ],
    );
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
    final details = await apkMirror.getLatestAPKDetails(
      'https://www.apkmirror.com/apk/google-inc/youtube-music',
      const {
        'trackOnly': true,
        'fallbackToOlderReleases': true,
        'autoApkFilterByArch': true,
      },
    );

    expect(details.version, '9.17.51');
    expect(
      apkMirror.requestedUrls.where((url) {
        return url.contains('android-apk-download');
      }).toList(),
      [
        'https://www.apkmirror.com/apk/google-inc/youtube-music/youtube-music-9-17-51-release/youtube-music-9-17-51-5-android-apk-download/',
      ],
    );
    expect(details.apkSizeBytes, 60817408);
    expect(
      details.changeLog,
      'https://www.apkmirror.com/apk/google-inc/youtube-music/youtube-music-9-17-51-release/youtube-music-9-17-51-5-android-apk-download/',
    );
  });

  test('apk mirror probes download pages when release page is blocked', () async {
    final apkMirror = ReleasePageBlockedAPKMirror();
    final details = await apkMirror.getLatestAPKDetails(
      'https://www.apkmirror.com/apk/google-inc/youtube',
      const {'trackOnly': true, 'fallbackToOlderReleases': true},
    );

    expect(details.version, '21.18.163 beta');
    expect(details.apkSizeBytes, 186277274);
    expect(
      apkMirror.requestedUrls
          .where((url) => url.contains('android-apk-download'))
          .toList(),
      [
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-2-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-3-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-4-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-5-android-apk-download/',
        'https://www.apkmirror.com/apk/google-inc/youtube/youtube-21-18-163-release/youtube-21-18-163-6-android-apk-download/',
      ],
    );
  });
}
