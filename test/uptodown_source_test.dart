import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/uptodown.dart';

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

    test('uptodownAjaxDownloadUrl builds the endpoint, or null on missing ids', () {
      expect(
        uptodownAjaxDownloadUrl(
          'https://vlc.en.uptodown.com',
          '19600',
          '1184763632',
        ),
        equals(
          'https://vlc.en.uptodown.com/ajax/app/19600/file/1184763632/download-url',
        ),
      );
      expect(
        uptodownAjaxDownloadUrl(
          'https://vlc.en.uptodown.com/',
          '19600',
          '1184763632',
        ),
        equals(
          'https://vlc.en.uptodown.com/ajax/app/19600/file/1184763632/download-url',
        ),
      );
      expect(
        uptodownAjaxDownloadUrl('https://vlc.en.uptodown.com', null, '118'),
        isNull,
      );
      expect(
        uptodownAjaxDownloadUrl('https://vlc.en.uptodown.com', '19600', ''),
        isNull,
      );
    });

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
