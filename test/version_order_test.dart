import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/providers/apps_provider.dart';

void main() {
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
}
