import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/source_provider.dart';

App appWithUrl(String url, {String? overrideSource}) => App(
  id: 'org.example.app',
  url: url,
  author: 'Example',
  name: 'Example',
  latestVersion: '1.0.0',
  preferredApkIndex: 0,
  additionalSettings: const <String, dynamic>{},
  overrideSource: overrideSource,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sourceBadgeHostForApp', () {
    test('falls back to the tracked URL host for a generic HTML source', () {
      expect(
        sourceBadgeHostForApp(
          appWithUrl('https://archive.mozilla.org/pub/fenix/releases/'),
        ),
        'archive.mozilla.org',
      );
    });

    test('falls back to the tracked URL host for a direct APK link', () {
      expect(
        sourceBadgeHostForApp(
          appWithUrl(
            'https://archive.mozilla.org/pub/fenix/releases/149.0/android/'
            'fenix-149.0-android-arm64-v8a/'
            'fenix-149.0.multi.android-arm64-v8a.apk',
          ),
        ),
        'archive.mozilla.org',
      );
    });

    test('prefers the host declared by a host-based source', () {
      expect(
        sourceBadgeHostForApp(appWithUrl('https://github.com/example/app')),
        'github.com',
      );
    });

    test('uses the tracked host when a multi-host source matches it', () {
      expect(
        sourceBadgeHostForApp(
          appWithUrl('https://codefloe.com/SnappTechnology/NextCloudTalkNext'),
        ),
        'codefloe.com',
      );
    });

    test('uses the overridden host when the source is overridden', () {
      expect(
        sourceBadgeHostForApp(
          appWithUrl(
            'https://git.example.com/example/app',
            overrideSource: 'GitHub',
          ),
        ),
        'git.example.com',
      );
    });

    test('returns null when the URL carries no host', () {
      expect(sourceBadgeHostForApp(appWithUrl('not a url')), isNull);
    });
  });
}
