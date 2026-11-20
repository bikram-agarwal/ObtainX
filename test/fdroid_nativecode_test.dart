// Upstream's F-Droid ABI/date tests (edd3e51a, 1cce81fa), adapted to the
// fork's pipeline (v1.7.4 sync SRCF-12/13/16): the fork parses every
// `<code class="package-nativecode">` of a version block, treats a version
// code missing from the page as unknown (not universal), narrows by ABI
// whatever autoApkFilterByArch says, and reads the page at
// `https://f-droid.org/packages/<id>/`. Upstream's `filterReleasesByNativecode`
// and `getApkAbisByUrl` were not adopted, so their cases are gone.
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/models/app.dart';

const _appId = 'org.proninyaroslav.libretorrent';
const _apiUrl = 'https://f-droid.org/api/v1/packages/$_appId';
const _pageUrl = 'https://f-droid.org/packages/$_appId/';
const _standardUrl = 'https://f-droid.org/packages/$_appId';

const _apiResponse =
    '''
{
  "packageName": "$_appId",
  "suggestedVersionCode": 9000354,
  "packages": [
    {"versionName": "4.1.1", "versionCode": 9000354},
    {"versionName": "4.1.1", "versionCode": 9000353},
    {"versionName": "4.1.1", "versionCode": 9000352},
    {"versionName": "4.1.1", "versionCode": 9000351}
  ]
}
''';

const _singleResponse =
    '''
{
  "packageName": "$_appId",
  "suggestedVersionCode": 9000354,
  "packages": [
    {"versionName": "4.1.1", "versionCode": 9000354}
  ]
}
''';

/// One `li.package-version` block as f-droid.org renders it: one
/// `<code class="package-nativecode">` per ABI.
String _versionBlock(
  String versionName,
  int versionCode,
  List<String>? nativecodes, {
  String? addedOn,
}) =>
    '''
<li class="package-version">
  <div class="package-version-header">
    <a name="$versionName"></a>
    <a name="$versionCode"></a>
    <b>Version $versionName</b> ($versionCode)
    ${addedOn == null ? '' : 'Added on $addedOn'}
  </div>
  ${nativecodes == null ? '' : '<p class="package-version-nativecode">${nativecodes.map((abi) => '<code class="package-nativecode">$abi</code>').join(' ')}</p>'}
  <p class="package-version-download">
    <b><a href="https://f-droid.org/repo/${_appId}_$versionCode.apk">Download APK</a></b>
    <a href="https://f-droid.org/repo/${_appId}_$versionCode.apk.asc">PGP Signature</a>
  </p>
</li>
''';

final _page =
    '''
<html><body><ul>
${_versionBlock('4.1.1', 9000354, ['x86_64'])}
${_versionBlock('4.1.1', 9000353, ['x86'])}
${_versionBlock('4.1.1', 9000352, ['arm64-v8a'])}
${_versionBlock('4.1.1', 9000351, ['armeabi-v7a'])}
${_versionBlock('4.1', 9000344, ['x86_64'])}
</ul></body></html>
''';

class _TestFDroid extends FDroid {
  final Map<String, String> responses;
  final List<String> abis;
  final List<String> requestedUrls = [];

  _TestFDroid(this.responses, this.abis);

  @override
  Future<List<String>> getSupportedAbis() async => abis;

  @override
  Future<http.Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requestedUrls.add(url);
    final body = responses[url];
    if (body == null) {
      return http.Response('Not found', 404);
    }
    return http.Response(
      body,
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }
}

const _defaultSettings = {'trySelectingSuggestedVersionCode': true};

String _apkUrl(int versionCode) =>
    'https://f-droid.org/repo/${_appId}_$versionCode.apk';

void main() {
  group('package page parsing', () {
    test('maps each version code to its native architectures', () {
      expect(fdroidNativecodeByVersionCode(parse(_page)), {
        9000354: ['x86_64'],
        9000353: ['x86'],
        9000352: ['arm64-v8a'],
        9000351: ['armeabi-v7a'],
        9000344: ['x86_64'],
      });
    });

    test('reads every ABI of a multi-ABI APK', () {
      final doc = parse(
        _versionBlock('0.7.69', 276, [
          'arm64-v8a',
          'armeabi-v7a',
          'x86',
          'x86_64',
        ]),
      );
      expect(fdroidNativecodeByVersionCode(doc), {
        276: ['arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'],
      });
    });

    test('maps versions without a nativecode note to an empty list', () {
      expect(
        fdroidNativecodeByVersionCode(parse(_versionBlock('1.0', 1234, null))),
        {1234: <String>[]},
      );
    });

    test('parses the Added on date for each version code', () {
      final doc = parse(
        _versionBlock('1.0', 1234, ['arm64-v8a'], addedOn: 'Oct 12, 2026'),
      );
      expect(fdroidAddedOnByVersionCode(doc), {1234: DateTime(2026, 10, 12)});
    });

    test('ignores blocks without version anchors', () {
      final doc = parse(
        '<li class="package-version">'
        '<div class="package-version-header">Version 1.0 (1) Added on '
        'Oct 12, 2026</div>'
        '</li>',
      );
      expect(fdroidNativecodeByVersionCode(doc), isEmpty);
      expect(fdroidAddedOnByVersionCode(doc), isEmpty);
    });

    test('parseAddedOnDate accepts the formats F-Droid uses', () {
      expect(FDroid.parseAddedOnDate('Oct 29, 2026'), DateTime(2026, 10, 29));
      expect(
        FDroid.parseAddedOnDate(' Oct  9,\n 2026 '),
        DateTime(2026, 10, 9),
      );
      expect(FDroid.parseAddedOnDate('2026-10-29'), DateTime(2026, 10, 29));
      expect(FDroid.parseAddedOnDate('soon'), isNull);
      expect(FDroid.parseAddedOnDate(null), isNull);
    });
  });

  group('FDroid architecture selection (#2529)', () {
    test('prefers the device ABI over the suggested APK', () async {
      final source = _TestFDroid(
        {_apiUrl: _apiResponse, _pageUrl: _page},
        ['arm64-v8a', 'armeabi-v7a'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls, hasLength(1));
      expect(details.apkUrls.single.value, _apkUrl(9000352));
      expect(details.version, '4.1.1');
      expect(source.requestedUrls, contains(_pageUrl));
    });

    test('uses the device ABI order as preference order', () async {
      final source = _TestFDroid(
        {_apiUrl: _apiResponse, _pageUrl: _page},
        ['armeabi-v7a'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls, hasLength(1));
      expect(details.apkUrls.single.value, _apkUrl(9000351));
    });

    test('keeps the suggested APK when it matches the device', () async {
      final source = _TestFDroid(
        {_apiUrl: _apiResponse, _pageUrl: _page},
        ['x86_64', 'x86'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls, hasLength(1));
      expect(details.apkUrls.single.value, _apkUrl(9000354));
    });

    test('narrows by ABI even with autoApkFilterByArch off', () async {
      final source = _TestFDroid(
        {_apiUrl: _apiResponse, _pageUrl: _page},
        ['arm64-v8a', 'armeabi-v7a'],
      );
      final details = await source.getLatestAPKDetails(_standardUrl, {
        ..._defaultSettings,
        'autoApkFilterByArch': false,
      });
      expect(details.apkUrls.single.value, _apkUrl(9000352));
    });

    test('keeps a multi-ABI APK that lists the device ABI second', () async {
      const response =
          '''
{
  "packageName": "$_appId",
  "suggestedVersionCode": 9000360,
  "packages": [
    {"versionName": "4.2", "versionCode": 9000360},
    {"versionName": "4.2", "versionCode": 9000359}
  ]
}
''';
      final page =
          '''
<html><body><ul>
${_versionBlock('4.2', 9000360, ['x86_64'])}
${_versionBlock('4.2', 9000359, ['arm64-v8a', 'armeabi-v7a', 'x86'])}
</ul></body></html>
''';
      final source = _TestFDroid(
        {_apiUrl: response, _pageUrl: page},
        ['armeabi-v7a'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls.single.value, _apkUrl(9000359));
    });

    test('leaves every architecture when the page cannot be read', () async {
      // Unknown is not universal: the suggested code may be an x86_64
      // build, so the choice is left to the APK picker.
      final source = _TestFDroid(
        {_apiUrl: _apiResponse},
        ['arm64-v8a', 'armeabi-v7a'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls, hasLength(4));
    });

    test(
      'leaves every architecture when the page lacks this version',
      () async {
        final olderPage =
            '''
<html><body><ul>
${_versionBlock('4.1', 9000344, ['x86_64'])}
${_versionBlock('4.1', 9000343, ['x86'])}
</ul></body></html>
''';
        final source = _TestFDroid(
          {_apiUrl: _apiResponse, _pageUrl: olderPage},
          ['arm64-v8a', 'armeabi-v7a'],
        );
        final details = await source.getLatestAPKDetails(
          _standardUrl,
          _defaultSettings,
        );
        expect(details.apkUrls, hasLength(4));
      },
    );

    test('keeps the suggested APK when the version is universal', () async {
      final universalPage =
          '''
<html><body><ul>
${_versionBlock('4.1.1', 9000354, null)}
${_versionBlock('4.1.1', 9000353, null)}
</ul></body></html>
''';
      final source = _TestFDroid(
        {_apiUrl: _apiResponse, _pageUrl: universalPage},
        ['arm64-v8a', 'armeabi-v7a'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls, hasLength(1));
      expect(details.apkUrls.single.value, _apkUrl(9000354));
    });

    test(
      'supports page metadata when the official host was overridden',
      () async {
        final source = _TestFDroid(
          {_apiUrl: _apiResponse, _pageUrl: _page},
          ['arm64-v8a'],
        );
        source.hostChanged = true;
        source.hostIdenticalDespiteAnyChange = true;
        final details = await source.getLatestAPKDetails(
          _standardUrl,
          _defaultSettings,
        );
        expect(source.requestedUrls, contains(_pageUrl));
        expect(details.apkUrls, hasLength(1));
      },
    );
  });

  group('F-Droid release dates', () {
    final singlePage = _versionBlock('4.1.1', 9000354, [
      'x86_64',
    ], addedOn: 'Oct 12, 2026');

    App previousCheck({DateTime? releaseDate}) => App(
      id: _appId,
      url: _standardUrl,
      author: 'F-Droid',
      name: 'LibreTorrent',
      latestVersion: '4.1.1',
      apkUrls: [MapEntry('${_appId}_9000354.apk', _apkUrl(9000354))],
      preferredApkIndex: 0,
      additionalSettings: const {},
      rawLatestVersionFromSource: '4.1.1',
      releaseDate: releaseDate,
    );

    test('fetches the page for a date even with a single APK', () async {
      final source = _TestFDroid(
        {_apiUrl: _singleResponse, _pageUrl: singlePage},
        ['arm64-v8a'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls, hasLength(1));
      expect(source.requestedUrls, contains(_pageUrl));
      expect(details.releaseDate, DateTime(2026, 10, 12));
    });

    test('uses the selected build date of a multi-ABI version', () async {
      final page =
          '''
<html><body><ul>
${_versionBlock('4.1.1', 9000354, ['x86_64'], addedOn: 'Oct 13, 2026')}
${_versionBlock('4.1.1', 9000352, ['arm64-v8a'], addedOn: 'Oct 12, 2026')}
</ul></body></html>
''';
      final source = _TestFDroid(
        {_apiUrl: _apiResponse, _pageUrl: page},
        ['arm64-v8a'],
      );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(details.apkUrls.single.value, _apkUrl(9000352));
      expect(details.releaseDate, DateTime(2026, 10, 12));
    });

    test('an unchanged version keeps its date without the page', () async {
      final source =
          _TestFDroid(
              {_apiUrl: _singleResponse, _pageUrl: singlePage},
              ['arm64-v8a'],
            )
            ..previouslyCheckedApp = previousCheck(
              releaseDate: DateTime(2026, 9, 1),
            );
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(source.requestedUrls, isNot(contains(_pageUrl)));
      expect(details.releaseDate, DateTime(2026, 9, 1));
    });

    test('an unchanged version without a date reads it once', () async {
      final source = _TestFDroid(
        {_apiUrl: _singleResponse, _pageUrl: singlePage},
        ['arm64-v8a'],
      )..previouslyCheckedApp = previousCheck();
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _defaultSettings,
      );
      expect(source.requestedUrls, contains(_pageUrl));
      expect(details.releaseDate, DateTime(2026, 10, 12));
    });
  });
}
