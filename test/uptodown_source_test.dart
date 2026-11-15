import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/uptodown.dart';

/// A JWT whose `exp` claim is [exp] (unix seconds).
String _jwt(int exp) {
  String part(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'exp': exp})}.signature';
}

/// Serves a download page plus the app API, rejecting the first token.
class _ApiFixtureUptodown extends Uptodown {
  // Already expired, so every lookup logs in and the request order doesn't
  // depend on a session left over from another test.
  final String token = _jwt(0);
  final List<String> paths = [];
  final List<Map<String, String>?> headers = [];
  int downloadUrlRequests = 0;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    final uri = Uri.parse(url);
    paths.add(uri.path);
    headers.add(await getRequestHeaders(additionalSettings, url));
    if (uri.host == 'vlc.en.uptodown.com') {
      return Response(
        '<button id="detail-download-button" data-app-id="19600" '
        'data-file-id="1184763632"></button>',
        200,
      );
    }
    if (uri.path == '/eapi/auth/token') {
      expect(postBody, contains('id_plataforma=13'));
      return Response(jsonEncode({'token': token}), 200);
    }
    if (uri.path == '/eapi/apps/19600/file/1184763632/downloadUrl') {
      if (++downloadUrlRequests == 1) return Response('', 401);
      return Response(
        jsonEncode({
          'success': 1,
          'data': {'downloadURL': 'https://dw.uptodown.com/dwn/abc/vlc.apk'},
        }),
        200,
      );
    }
    return Response('', 404);
  }
}

void main() {
  group('Uptodown Source Tests', () {
    final uptodown = Uptodown();

    test('parseUptodownDate parses standard English date formats', () {
      expect(parseUptodownDate('Aug 11, 2026'), equals(DateTime(2026, 8, 11)));
      expect(
        parseUptodownDate('August 11, 2026'),
        equals(DateTime(2026, 8, 11)),
      );
      expect(parseUptodownDate('Aug 1, 2026'), equals(DateTime(2026, 8, 1)));
      expect(parseUptodownDate(null), isNull);
    });

    test(
      'sourceSpecificStandardizeURL normalizes subdomains to .en.uptodown.',
      () {
        expect(
          uptodown.sourceSpecificStandardizeURL(
            'https://gamehub.br.uptodown.com/android',
          ),
          equals('https://gamehub.en.uptodown.com/android/download'),
        );
        expect(
          uptodown.sourceSpecificStandardizeURL(
            'https://vlc.es.uptodown.com/android/download',
          ),
          equals('https://vlc.en.uptodown.com/android/download'),
        );
        expect(
          uptodown.sourceSpecificStandardizeURL(
            'https://whatsapp-messenger.en.uptodown.com/android',
          ),
          equals('https://whatsapp-messenger.en.uptodown.com/android/download'),
        );
      },
    );

    test('parseUptodownTechnicalFields reads fields by content', () {
      // Cell order as served for a GameHub-like app, including the sha256 row
      // that Uptodown added after the original fixed-offset scrape was written.
      final fields = parseUptodownTechnicalFields([
        '3.6.5',
        'Aug 11, 2026',
        'apk',
        '58.2 MB',
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'com.xiaoji.egggame',
      ]);
      expect(fields.appId, equals('com.xiaoji.egggame'));
      expect(fields.dateStr, equals('Aug 11, 2026'));
      expect(fields.extension, equals('apk'));
    });

    test(
      'parseUptodownTechnicalFields handles the real full-page cell list',
      () {
        // Verbatim non-empty `#technical-information td` texts served for VLC on
        // 2026-08-12. `#technical-information` is a container of several tables
        // (basic info, distribution model, system requirements, then the file
        // details), so the real list is much longer than the file rows alone.
        // The old fixed offsets pick 'APK' as the date and '45.77 MB' as the
        // extension here, which is why fields are matched by content instead.
        final fields = parseUptodownTechnicalFields([
          'VideoLabs',
          'Video',
          '+3',
          'English 46 more',
          'Free',
          'GPL 2.0',
          '(More information)',
          'Android',
          'arm64-v8a',
          'See 30 permissions',
          '511fea1a22a7b62ebc01950c167c0406',
          '14,949,927',
          'Jul 1, 2026',
          'APK',
          '45.77 MB',
          'c493c167de52724dbdd727fd6e20ec43d89200a847fb7b7d88da850faf336bcd',
          'Matches the published version',
          'org.videolan.vlc',
        ]);
        expect(fields.appId, equals('org.videolan.vlc'));
        expect(fields.dateStr, equals('Jul 1, 2026'));
        expect(fields.extension, equals('apk'));
      },
    );

    test(
      'parseUptodownTechnicalFields ignores versions and digests as ids',
      () {
        final fields = parseUptodownTechnicalFields([
          '1.2.3',
          'September 4, 2025',
          'XAPK',
          '12.0 MB',
          'org.videolan.vlc',
        ]);
        expect(fields.appId, equals('org.videolan.vlc'));
        expect(fields.dateStr, equals('September 4, 2025'));
        expect(fields.extension, equals('xapk'));
      },
    );

    test('uptodownDirectApkUrl expands paths and passes absolute URLs', () {
      expect(
        uptodownDirectApkUrl(dataUrl: 'abc123/vlc.apk'),
        equals('https://dw.uptodown.com/dwn/abc123/vlc.apk'),
      );
      expect(
        uptodownDirectApkUrl(dataUrl: 'https://dw.uptodown.com/dwn/abc123'),
        equals('https://dw.uptodown.com/dwn/abc123'),
      );
      expect(
        uptodownDirectApkUrl(dataUrlExt: 'https://example.com/direct.apk'),
        equals('https://example.com/direct.apk'),
      );
      // A relative data-url-ext points at a store wrapper, not a file.
      expect(uptodownDirectApkUrl(dataUrlExt: '/android/download'), isNull);
      expect(uptodownDirectApkUrl(), isNull);
      expect(uptodownDirectApkUrl(dataUrl: '   '), isNull);
    });

    test('parseUptodownTechnicalFields prefers valid <th>-labelled rows', () {
      const cells = [
        'Jul 1, 2026',
        'APK',
        '45.77 MB',
        'org.videolan.vlc',
        'com.example.other',
      ];
      final labelled = parseUptodownTechnicalFields(
        cells,
        labelledCells: const {
          'package name': 'org.videolan.vlc',
          'date': 'Jul 1, 2026',
          'file type': 'XAPK',
        },
      );
      expect(labelled.appId, equals('org.videolan.vlc'));
      expect(labelled.dateStr, equals('Jul 1, 2026'));
      expect(labelled.extension, equals('xapk'));

      // Labels whose values don't look right fall back to content matching.
      final mislabelled = parseUptodownTechnicalFields(
        cells,
        labelledCells: const {
          'package name': '45.77 MB',
          'date': 'yesterday',
          'file type': 'Android',
        },
      );
      expect(mislabelled.appId, equals('com.example.other'));
      expect(mislabelled.dateStr, equals('Jul 1, 2026'));
      expect(mislabelled.extension, equals('apk'));
    });

    test('parseUptodownTechnicalFields copes with a short table', () {
      final fields = parseUptodownTechnicalFields(['org.example.app']);
      expect(fields.appId, equals('org.example.app'));
      expect(fields.dateStr, isNull);
      expect(fields.extension, isNull);
      expect(parseUptodownTechnicalFields(const []).appId, isNull);
    });

    test('uptodownSessionFromAuthBody reads the token and its expiry', () {
      final token = _jwt(1767225600);
      final session = uptodownSessionFromAuthBody(jsonEncode({'token': token}));
      expect(session?.token, equals(token));
      expect(session?.expiresAt, equals(1767225600));
      expect(uptodownSessionFromAuthBody('{"token":"not-a-jwt"}'), isNull);
      expect(uptodownSessionFromAuthBody('{"token":"a.b.c"}'), isNull);
      expect(uptodownSessionFromAuthBody('<html>'), isNull);
    });

    test(
      'downloads resolve through the app API, logging in again once on 401',
      () async {
        final source = _ApiFixtureUptodown();
        final url = await source.assetUrlPrefetchModifier(
          'https://vlc.en.uptodown.com/android/download/1184763632-x',
          'https://vlc.en.uptodown.com/android/download',
          {},
        );
        expect(url, equals('https://dw.uptodown.com/dwn/abc/vlc.apk'));
        expect(source.paths, [
          '/android/download/1184763632-x',
          '/eapi/auth/token',
          '/eapi/apps/19600/file/1184763632/downloadUrl',
          '/eapi/auth/token',
          '/eapi/apps/19600/file/1184763632/downloadUrl',
        ]);
        // Pages get the browser UA; the API gets the app's headers and token.
        expect(source.headers[0]?['User-Agent'], contains('Mozilla'));
        expect(
          source.headers[1]?['Content-Type'],
          equals('application/x-www-form-urlencoded'),
        );
        expect(source.headers[1]?.containsKey('Authorization'), isFalse);
        expect(
          source.headers[4]?['Authorization'],
          equals('Bearer ${source.token}'),
        );
        expect(source.headers[4]?['Identificador'], equals('Uptodown_Android'));
        expect(
          (await source.getRequestHeaders(
            {},
            url,
            forAPKDownload: true,
          ))?['User-Agent'],
          startsWith('Dalvik/'),
        );
      },
    );

    test('uptodownDownloadUrlFromAjaxBody reads nested and top-level keys', () {
      expect(
        uptodownDownloadUrlFromAjaxBody(
          '{"data":{"downloadURL":"1184763632/vlc.apk"}}',
        ),
        equals('https://dw.uptodown.com/dwn/1184763632/vlc.apk'),
      );
      expect(
        uptodownDownloadUrlFromAjaxBody('{"downloadURL":"abc/def.apk"}'),
        equals('https://dw.uptodown.com/dwn/abc/def.apk'),
      );
      expect(
        uptodownDownloadUrlFromAjaxBody(
          '{"data":{"downloadURL":"https://dw.uptodown.com/dwn/already"}}',
        ),
        equals('https://dw.uptodown.com/dwn/already'),
      );
      // The error shape Uptodown returns when the bot-check token is missing.
      expect(
        uptodownDownloadUrlFromAjaxBody(
          '{"success":0,"errorCode":-51,"errorMsg":"Bad Request"}',
        ),
        isNull,
      );
      expect(uptodownDownloadUrlFromAjaxBody('not json'), isNull);
      expect(uptodownDownloadUrlFromAjaxBody('[]'), isNull);
    });
  });
}
