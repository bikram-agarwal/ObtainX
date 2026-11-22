import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/fdroidrepo.dart';

const _repo = 'https://cdn.kde.org/android/stable-releases/fdroid/repo';
const _appId = 'org.kde.itinerary';

Map<String, dynamic> _version(int code, String apk, String abi) => {
  'added': 1792000000000,
  'file': {'name': '/$apk'},
  'manifest': {
    'versionName': '26.08.2',
    'versionCode': code,
    'nativecode': [abi],
  },
};

// Shaped like the KDE repo's index-v2.json: two builds of 26.08.2, each split
// per architecture.
final _index = jsonEncode({
  'packages': {
    _appId: {
      'metadata': {
        'name': {'en-US': 'KDE Itinerary'},
      },
      'versions': {
        'a': _version(
          1792604176,
          'itinerary-20261021-arm64-v8a.apk',
          'arm64-v8a',
        ),
        'b': _version(1792604175, 'itinerary-20261021-x86_64.apk', 'x86_64'),
        'c': _version(
          1792168061,
          'itinerary-20261016-arm64-v8a.apk',
          'arm64-v8a',
        ),
        'd': _version(1792168060, 'itinerary-20261016-x86_64.apk', 'x86_64'),
      },
    },
  },
});

String _package(int code, String apk, String abi) =>
    '<package><version>26.08.2</version><versioncode>$code</versioncode>'
    '<apkname>$apk</apkname><nativecode>$abi</nativecode>'
    '<added>2026-10-21</added></package>';

// The same builds in a v1 index.xml (the fork's other selection pipeline).
final _indexXml =
    '<?xml version="1.0" encoding="utf-8"?><fdroid>'
    '<repo name="KDE Android Stable Releases"></repo>'
    '<application id="$_appId"><name>KDE Itinerary</name>'
    '${_package(1792604176, 'itinerary-20261021-arm64-v8a.apk', 'arm64-v8a')}'
    '${_package(1792604175, 'itinerary-20261021-x86_64.apk', 'x86_64')}'
    '${_package(1792168061, 'itinerary-20261016-arm64-v8a.apk', 'arm64-v8a')}'
    '${_package(1792168060, 'itinerary-20261016-x86_64.apk', 'x86_64')}'
    '</application></fdroid>';

class _TestFDroidRepo extends FDroidRepo {
  final List<String> abis;
  final bool servesIndexXml;

  _TestFDroidRepo(this.abis, {this.servesIndexXml = false});

  @override
  Future<List<String>> getSupportedAbis() async => abis;

  @override
  Future<http.Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    final String? body = servesIndexXml
        ? (url == '$_repo/index.xml' ? _indexXml : null)
        : (url == '$_repo/index-v2.json' ? _index : null);
    if (body == null) return http.Response('Not found', 404);
    return http.Response(
      body,
      200,
      request: http.Request('GET', Uri.parse(url)),
    );
  }
}

class _CustomFDroidRepo extends FDroidRepo {
  final List<String> abis;
  final String? indexXml;
  final String? indexV2;

  _CustomFDroidRepo(this.abis, {this.indexXml, this.indexV2});

  @override
  Future<List<String>> getSupportedAbis() async => abis;

  @override
  Future<http.Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    final String? body = url == '$_repo/index.xml'
        ? indexXml
        : (url == '$_repo/index-v2.json' ? indexV2 : null);
    if (body == null) return http.Response('Not found', 404);
    return http.Response(
      body,
      200,
      request: http.Request('GET', Uri.parse(url)),
    );
  }
}

void main() {
  for (final bool v1 in [false, true]) {
    group(v1 ? 'index.xml' : 'index-v2.json', () {
      test(
        'only the newest build of a version name is offered per ABI',
        () async {
          final details =
              await _TestFDroidRepo([
                'arm64-v8a',
              ], servesIndexXml: v1).getLatestAPKDetails(
                '$_repo?appId=$_appId',
                {'trySelectingSuggestedVersionCode': true},
              );
          expect(details.version, '26.08.2');
          expect(details.apkUrls.map((e) => e.value), [
            '$_repo/itinerary-20261021-arm64-v8a.apk',
          ]);
        },
      );

      test(
        'without a matching ABI, each ABI still gets its newest build',
        () async {
          final details =
              await _TestFDroidRepo([
                'armeabi-v7a',
              ], servesIndexXml: v1).getLatestAPKDetails(
                '$_repo?appId=$_appId',
                {'trySelectingSuggestedVersionCode': true},
              );
          expect(details.apkUrls.map((e) => e.value), [
            '$_repo/itinerary-20261021-arm64-v8a.apk',
            '$_repo/itinerary-20261021-x86_64.apk',
          ]);
        },
      );

      test(
        'prioritizes arm64-v8a over armeabi-v7a when both are supported',
        () async {
          final multiAbiIndexV2 = jsonEncode({
            'packages': {
              _appId: {
                'metadata': {
                  'name': {'en-US': 'Notesnook'},
                },
                'versions': {
                  'd': _version(15594, 'app_15594.apk', 'x86_64'),
                  'c': _version(15593, 'app_15593.apk', 'arm64-v8a'),
                  'b': _version(15592, 'app_15592.apk', 'x86'),
                  'a': _version(15591, 'app_15591.apk', 'armeabi-v7a'),
                },
              },
            },
          });
          const multiAbiIndexXml =
              '<?xml version="1.0" encoding="utf-8"?><fdroid>'
              '<repo name="Test Repo"></repo>'
              '<application id="$_appId"><name>Notesnook</name>'
              '<package><version>3.4.12</version><versioncode>15594</versioncode>'
              '<apkname>app_15594.apk</apkname><nativecode>x86_64</nativecode></package>'
              '<package><version>3.4.12</version><versioncode>15593</versioncode>'
              '<apkname>app_15593.apk</apkname><nativecode>arm64-v8a</nativecode></package>'
              '<package><version>3.4.12</version><versioncode>15592</versioncode>'
              '<apkname>app_15592.apk</apkname><nativecode>x86</nativecode></package>'
              '<package><version>3.4.12</version><versioncode>15591</versioncode>'
              '<apkname>app_15591.apk</apkname><nativecode>armeabi-v7a</nativecode></package>'
              '</application></fdroid>';
          final repo = _CustomFDroidRepo(
            ['arm64-v8a', 'armeabi-v7a', 'armeabi'],
            indexXml: v1 ? multiAbiIndexXml : null,
            indexV2: v1 ? null : multiAbiIndexV2,
          );
          final details = await repo.getLatestAPKDetails(
            '$_repo?appId=$_appId',
            {
              'trySelectingSuggestedVersionCode': false,
              'autoSelectHighestVersionCode': false,
            },
          );
          expect(details.apkUrls.map((e) => e.value), ['$_repo/app_15593.apk']);
        },
      );

      test('falls back to universal only when no explicit ABI matches', () async {
        final universalIndexV2 = jsonEncode({
          'packages': {
            _appId: {
              'metadata': {
                'name': {'en-US': 'Test App'},
              },
              'versions': {
                'b': _version(200, 'app_200.apk', 'x86_64'),
                'a': {
                  'added': 1792000000000,
                  'file': {'name': '/app_100.apk'},
                  'manifest': {'versionName': '26.08.2', 'versionCode': 100},
                },
              },
            },
          },
        });
        const universalIndexXml =
            '<?xml version="1.0" encoding="utf-8"?><fdroid>'
            '<repo name="Test Repo"></repo>'
            '<application id="$_appId"><name>Test App</name>'
            '<package><version>26.08.2</version><versioncode>200</versioncode>'
            '<apkname>app_200.apk</apkname><nativecode>x86_64</nativecode></package>'
            '<package><version>26.08.2</version><versioncode>100</versioncode>'
            '<apkname>app_100.apk</apkname></package>'
            '</application></fdroid>';
        final repo = _CustomFDroidRepo(
          ['arm64-v8a', 'armeabi-v7a'],
          indexXml: v1 ? universalIndexXml : null,
          indexV2: v1 ? null : universalIndexV2,
        );
        final details = await repo.getLatestAPKDetails('$_repo?appId=$_appId', {
          'trySelectingSuggestedVersionCode': false,
          'autoSelectHighestVersionCode': false,
        });
        expect(details.apkUrls.map((e) => e.value), ['$_repo/app_100.apk']);
      });
    });
  }

  test('newestBuildPerNativecode keeps order and the highest code', () {
    final releases = [
      (abis: ['x86_64'], code: 2),
      (abis: ['arm64-v8a'], code: 3),
      (abis: <String>[], code: 1),
      (abis: ['x86_64'], code: 4),
      (abis: ['arm64-v8a'], code: 1),
    ];
    expect(
      FDroidRepo.newestBuildPerNativecode(
        releases,
        nativecodeOf: (release) => release.abis,
        versionCodeOf: (release) => release.code,
      ).map((release) => release.code),
      [3, 1, 4],
    );
  });
}
