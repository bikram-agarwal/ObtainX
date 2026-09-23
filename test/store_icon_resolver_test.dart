import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/store_icon_resolver.dart';

void main() {
  group('iconUrlFromStoreListingHtml', () {
    test('resolves F-Droid og:image against the listing URL', () {
      expect(
        iconUrlFromStoreListingHtml('''
<html><head>
<meta property="og:image" content="/repo/icons-640/org.example.app.png" />
</head></html>
''', 'https://f-droid.org/packages/org.example.app/'),
        'https://f-droid.org/repo/icons-640/org.example.app.png',
      );
    });

    test('prefers og:image over later img fallbacks', () {
      expect(
        iconUrlFromStoreListingHtml('''
<html><head>
<meta property="og:image" content="https://cdn.example.com/og.png" />
</head><body>
<img class="package-icon" src="https://cdn.example.com/fallback.png" />
</body></html>
''', 'https://f-droid.org/packages/org.example.app/'),
        'https://cdn.example.com/og.png',
      );
    });

    test('reads Play Store icon image when og:image is missing', () {
      expect(
        iconUrlFromStoreListingHtml('''
<html><body>
<img alt="Icon image" src="https://play-lh.googleusercontent.com/icon.png" />
</body></html>
''', 'https://play.google.com/store/apps/details?id=org.example.app'),
        'https://play-lh.googleusercontent.com/icon.png',
      );
    });

    test('returns null when the page has no icon', () {
      expect(
        iconUrlFromStoreListingHtml(
          '<html><body><p>No icon</p></body></html>',
          'https://apkpure.net/example/org.example.app',
        ),
        isNull,
      );
    });

    test('reads the APKPure app icon, ignoring the screenshot og:image and the '
        'site-logo img.icon', () {
      expect(
        iconUrlFromStoreListingHtml('''
<html><head>
<meta property="og:image" content="https://image.winudf.com/v2/image1/screen-0.jpg" />
</head><body>
<img class="icon" src="https://image.winudf.com/v2/image/site-logo.png" alt="APKPure icon" />
<div class="app-info"><span class="app-icon"><img alt="Example icon" src="https://image.winudf.com/v2/image1/app-icon.png?w=140" /></span></div>
<img class="apk-unit-image app-icon lazy" src="data:image/gif;base64,x" data-original="https://image.winudf.com/v2/image1/other-app-icon.png" alt="Other App APK" />
</body></html>
''', 'https://apkpure.com/example/org.example.app'),
        'https://image.winudf.com/v2/image1/app-icon.png?w=140',
      );
    });
  });

  group('normalizeApkPureHost', () {
    test('rewrites apkpure.net to apkpure.com, keeping the path', () {
      expect(
        normalizeApkPureHost(
          Uri.parse('https://apkpure.net/example/org.example.app'),
        ).toString(),
        'https://apkpure.com/example/org.example.app',
      );
    });

    test('leaves apkpure.com and unrelated hosts unchanged', () {
      expect(
        normalizeApkPureHost(
          Uri.parse('https://apkpure.com/example/org.example.app'),
        ).toString(),
        'https://apkpure.com/example/org.example.app',
      );
      expect(
        normalizeApkPureHost(
          Uri.parse('https://f-droid.org/packages/org.example.app/'),
        ).toString(),
        'https://f-droid.org/packages/org.example.app/',
      );
    });
  });

  group('isWellFormedApkPureUrl', () {
    test('accepts the required <slug>/<package> shape', () {
      expect(
        isWellFormedApkPureUrl(
          'https://apkpure.com/sealplus/com.maheshtechnicals.sealplus',
        ),
        isTrue,
      );
    });

    test('rejects a slug-less single-segment URL (the empty-title bug)', () {
      expect(
        isWellFormedApkPureUrl('https://apkpure.com/com.xc3fff0e.xmanager'),
        isFalse,
      );
    });

    test('rejects garbage input', () {
      expect(isWellFormedApkPureUrl(''), isFalse);
      expect(isWellFormedApkPureUrl('not a url'), isFalse);
    });
  });

  group('resolveIconUrlFromOtherStores', () {
    test(
      'returns the APKMirror API icon without fetching listing pages',
      () async {
        final List<String> fetchedUrls = <String>[];
        final String? iconUrl = await resolveIconUrlFromOtherStores(
          apkMirrorIconUrl: ' https://www.apkmirror.com/icon.png ',
          apkMirrorListingUrl: 'https://www.apkmirror.com/apk/example/',
          fdroidListingUrl: 'https://f-droid.org/packages/org.example.app/',
          fetchListingIconUrl: (String listingUrl) async {
            fetchedUrls.add(listingUrl);
            return 'https://should-not-be-used.png';
          },
        );
        expect(iconUrl, 'https://www.apkmirror.com/icon.png');
        expect(fetchedUrls, isEmpty);
      },
    );

    test(
      'walks listing pages in preference order and stops at the first icon',
      () async {
        final List<String> fetchedUrls = <String>[];
        final String? iconUrl = await resolveIconUrlFromOtherStores(
          apkMirrorListingUrl: 'https://www.apkmirror.com/apk/example/',
          fdroidListingUrl: 'https://f-droid.org/packages/org.example.app/',
          apkPureListingUrl: 'https://apkpure.net/example/org.example.app',
          playStoreListingUrl:
              'https://play.google.com/store/apps/details?id=org.example.app',
          fetchListingIconUrl: (String listingUrl) async {
            fetchedUrls.add(listingUrl);
            if (listingUrl.contains('f-droid.org')) {
              return 'https://f-droid.org/repo/icons-640/org.example.app.png';
            }
            return null;
          },
        );
        expect(
          iconUrl,
          'https://f-droid.org/repo/icons-640/org.example.app.png',
        );
        expect(fetchedUrls, <String>[
          'https://www.apkmirror.com/apk/example/',
          'https://f-droid.org/packages/org.example.app/',
        ]);
      },
    );

    test('skips blank listing URLs', () async {
      final List<String> fetchedUrls = <String>[];
      final String? iconUrl = await resolveIconUrlFromOtherStores(
        apkMirrorListingUrl: '',
        fdroidListingUrl: '   ',
        apkPureListingUrl: 'https://apkpure.net/example/org.example.app',
        playStoreListingUrl: null,
        fetchListingIconUrl: (String listingUrl) async {
          fetchedUrls.add(listingUrl);
          return 'https://apkpure.net/icon.png';
        },
      );
      expect(iconUrl, 'https://apkpure.net/icon.png');
      expect(fetchedUrls, <String>[
        'https://apkpure.net/example/org.example.app',
      ]);
    });
  });
}
