import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/farsroid.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider_updates.dart';
import 'package:obtainium/utils/update_health.dart';

const _url = 'https://www.farsroid.com/example-app';
const _universal = 'https://dl.farsroid.com/example/Example-1.2-universal.apk';
const _arm64 = 'https://dl.farsroid.com/example/Example-1.2-arm64-v8a.apk';
const _armv7 = 'https://dl.farsroid.com/example/Example-1.2-armeabi-v7a.apk';

/// The app page as Farsroid serves it since upstream #3489: the version in
/// `h3.version-name`, the links as base64 JSON split across `data-j`
/// attributes inside `#secure-json`.
String _appPage(List<String> links, {String version = '1.2'}) {
  final String encoded = base64Encode(
    utf8.encode(
      jsonEncode([
        for (final link in links) {'url': link},
      ]),
    ),
  );
  final int half = encoded.length ~/ 2;
  return '<h3 class="version-name">Example $version</h3>'
      '<div id="secure-json">'
      '<i data-j="${encoded.substring(0, half)}"></i>'
      '<i data-j="${encoded.substring(half)}"></i>'
      '</div>';
}

/// Serves the app page with [links] (by default the three APKs above).
class _Farsroid extends Farsroid {
  final List<String> links;
  final String? page;

  _Farsroid({this.links = const [_universal, _arm64, _armv7], this.page});

  final List<String> requestedUrls = <String>[];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requestedUrls.add(url);
    if (url != _url) return Response('Not found', 404);
    return Response(
      page ?? _appPage(links),
      200,
      request: Request('GET', Uri.parse(url)),
    );
  }
}

class _BotVerificationFarsroid extends Farsroid {
  final int challengeStatus;

  _BotVerificationFarsroid({this.challengeStatus = 200});

  static const _challengeHtml = '''
<!DOCTYPE html>
<html>
<head><title>Bot Verification</title></head>
<body>
  <form id="lsrecaptcha-form" method="POST" action="/.lsrecap/recaptcha?"></form>
</body>
</html>
''';

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    return Response(_challengeHtml, challengeStatus);
  }
}

class _Arm64Device extends DeviceInfoPlatform {
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
      key: key,
    'supported32BitAbis': ['armeabi-v7a'],
    'supported64BitAbis': ['arm64-v8a'],
    'supportedAbis': ['arm64-v8a', 'armeabi-v7a'],
    'isPhysicalDevice': true,
    'freeDiskSize': 0,
    'totalDiskSize': 0,
    'isLowRamDevice': false,
    'physicalRamSize': 0,
    'availableRamSize': 0,
    'time': 0,
    'systemFeatures': <String>[],
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DeviceInfoPlatform.instance = _Arm64Device();
  });

  // v1.7.5 sync S5 (upstream #3489): everything comes from the app page.
  group('Farsroid app page', () {
    test('reads the version and the links from the page alone', () async {
      final _Farsroid source = _Farsroid();
      final details = await source.getLatestAPKDetails(_url, {
        'useFirstApkOfVersion': false,
      });
      expect(details.version, '1.2');
      expect(details.apkUrls.map((apk) => apk.value), [
        _universal,
        _arm64,
        _armv7,
      ]);
      expect(details.apkUrls.first.key, 'Example-1.2-universal.apk');
      expect(source.requestedUrls, [_url]);
    });

    test('the first APK of the version is the one named after it', () async {
      const String older =
          'https://dl.farsroid.com/example/Example-1.1-universal.apk';
      final details = await _Farsroid(links: const [older, _universal])
          .getLatestAPKDetails(_url, {'useFirstApkOfVersion': true});
      expect(details.apkUrls.map((apk) => apk.value), [_universal]);
    });

    test('resolves relative links and drops non-APK links', () async {
      final details = await _Farsroid(
        links: const ['/dl/Example-1.2.apk', 'https://www.farsroid.com/'],
      ).getLatestAPKDetails(_url, {'useFirstApkOfVersion': false});
      expect(details.apkUrls.map((apk) => apk.value), [
        'https://www.farsroid.com/dl/Example-1.2.apk',
      ]);
    });

    test('a page without the download JSON has no releases', () async {
      await expectLater(
        _Farsroid(
          page:
              '<div class="download-links" data-post-id="42" '
              'data-post-version="1.2"></div>',
        ).getLatestAPKDetails(_url, const {}),
        throwsA(isA<NoReleasesError>()),
      );
    });

    test('unreadable download JSON means no APK', () async {
      await expectLater(
        _Farsroid(
          page:
              '<h3 class="version-name">Example 1.2</h3>'
              '<div id="secure-json"><i data-j="not base64!"></i></div>',
        ).getLatestAPKDetails(_url, const {}),
        throwsA(isA<NoAPKError>()),
      );
    });
  });

  // v1.7.4 sync D12: the arch filter keeps universal APKs as alternatives
  // next to the ABI match; the single-APK paths must still pick the latter.
  group('Farsroid single-APK paths with the arch filter', () {
    const archFilter = {'autoApkFilterByArch': true};

    test('the first APK of the version is the ABI match', () async {
      final details = await _Farsroid().getLatestAPKDetails(_url, {
        ...archFilter,
        'useFirstApkOfVersion': true,
      });
      expect(details.apkUrls.map((apk) => apk.value), [_arm64]);
    });

    test('release title as version still finds exactly one APK', () async {
      final details = await _Farsroid().getLatestAPKDetails(_url, {
        ...archFilter,
        'useFirstApkOfVersion': false,
        'releaseTitleAsVersion': true,
      });
      expect(details.version, 'Example-1.2-arm64-v8a.apk');
      // The universal APK stays offered as an alternative.
      expect(details.apkUrls.map((apk) => apk.value), [_universal, _arm64]);
    });

    test('without the arch filter nothing changes', () async {
      final details = await _Farsroid().getLatestAPKDetails(_url, {
        'useFirstApkOfVersion': true,
      });
      expect(details.apkUrls.map((apk) => apk.value), [_universal]);
      await expectLater(
        _Farsroid().getLatestAPKDetails(_url, {
          'useFirstApkOfVersion': false,
          'releaseTitleAsVersion': true,
        }),
        throwsA(isA<NoVersionError>()),
      );
    });
  });

  group('Farsroid bot verification detection', () {
    test('throws BotVerificationError when app page is gated', () async {
      await expectLater(
        _BotVerificationFarsroid().getLatestAPKDetails(_url, const {}),
        throwsA(
          isA<BotVerificationError>().having(
            (e) => e.code,
            'code',
            'BOT_VERIFICATION',
          ),
        ),
      );
    });

    test('recognises a gate that does not answer 200', () async {
      await expectLater(
        _BotVerificationFarsroid(challengeStatus: 403)
            .getLatestAPKDetails(_url, const {}),
        throwsA(isA<BotVerificationError>()),
      );
    });

    // Handled like a Cloudflare challenge: waited out in the background, not
    // retried within seconds, and not counted against update health.
    test('is a rate limit, not a broken source', () {
      final BotVerificationError error = BotVerificationError('Farsroid');
      expect(error, isA<RateLimitError>());
      expect(error.code, 'BOT_VERIFICATION');
      expect(error.retryWaitMinutes, RateLimitError.defaultRetryWaitMinutes);
      expect(checkFailureIsPersistent(error), isFalse);
      expect(shouldCountFailedCheck(error), isFalse);
    });
  });
}
