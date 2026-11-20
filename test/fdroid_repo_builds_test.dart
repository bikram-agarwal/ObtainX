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
