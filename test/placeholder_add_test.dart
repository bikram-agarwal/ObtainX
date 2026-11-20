import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NamedSource extends AppSource {
  _NamedSource({bool trackOnly = false}) {
    enforceTrackOnly = trackOnly;
  }

  @override
  String sourceSpecificStandardizeURL(
    String url, {
    bool forSelection = false,
  }) => url;

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async => APKDetails('2.0', const [
    MapEntry('app.apk', 'https://example.com/app.apk'),
  ], const AppNames('Example Dev', 'Example App'));
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('rethrowOrWrapError', () {
    test('flags wrapped raw errors as unexpected', () {
      expect(
        () => rethrowOrWrapError(const SocketException('no route to host')),
        throwsA(
          isA<ObtainiumError>()
              .having((e) => e.unexpected, 'unexpected', isTrue)
              .having((e) => e.code, 'code', 'UNEXPECTED'),
        ),
      );
    });

    test('passes typed errors through unchanged', () {
      expect(
        () => rethrowOrWrapError(NoReleasesError()),
        throwsA(
          isA<NoReleasesError>().having(
            (e) => e.unexpected,
            'unexpected',
            isFalse,
          ),
        ),
      );
    });
  });

  group('buildPlaceholderApp', () {
    final sourceProvider = SourceProvider();
    final source = sourceProvider.getSource('https://github.com/gz83/thorium');

    test('builds a placeholder entry with URL name and source author', () {
      final app = sourceProvider.buildPlaceholderApp(
        source,
        'https://github.com/gz83/thorium',
        const {'trackOnly': false},
      );
      expect(app.url, 'https://github.com/gz83/thorium');
      expect(app.name, app.url);
      expect(app.author, source.name);
      expect(app.apkUrls, const [MapEntry('placeholder', 'placeholder')]);
      expect(app.preferredApkIndex, 0);
      expect(app.lastUpdateCheck, isNull);
      expect(app.latestVersion, isNotEmpty);
      expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(app.id), isTrue);
      expect(app.overrideSource, isNull);
    });

    test('temp ID is deterministic per URL and settings', () {
      final a = sourceProvider.buildPlaceholderApp(
        source,
        'https://github.com/gz83/thorium',
        const {'trackOnly': false},
      );
      final b = sourceProvider.buildPlaceholderApp(
        source,
        'https://github.com/gz83/thorium',
        const {'trackOnly': false},
      );
      final c = sourceProvider.buildPlaceholderApp(
        source,
        'https://github.com/gz83/thorium',
        const {'trackOnly': true},
      );
      expect(a.id, b.id);
      expect(a.id, isNot(c.id));
    });

    test('a placeholder may change its ID once an APK is found', () {
      final app = sourceProvider.buildPlaceholderApp(
        source,
        'https://github.com/gz83/thorium',
        const {},
      );
      expect(app.allowIdChange, isTrue);
      expect(hasOnlyPlaceholderApks(app), isTrue);
    });

    test('a track-only source makes the placeholder track-only', () {
      final app = sourceProvider.buildPlaceholderApp(
        _NamedSource(trackOnly: true),
        'https://example.com/app',
        const {},
      );
      expect(app.settings.getBool('trackOnly'), isTrue);
    });

    test('trackOnlyOverride makes the placeholder track-only', () {
      final app = sourceProvider.buildPlaceholderApp(
        _NamedSource(),
        'https://example.com/app',
        const {},
        trackOnlyOverride: true,
      );
      expect(app.settings.getBool('trackOnly'), isTrue);
    });

    test('records an override source', () {
      final app = sourceProvider.buildPlaceholderApp(
        source,
        'https://github.com/gz83/thorium',
        const {},
        sourceIsOverriden: true,
      );
      expect(app.overrideSource, source.sourceIdentifier);
    });
  });

  group('first real check of a placeholder', () {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({});
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        (_) async => Directory.systemTemp.path,
      );
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      );
    });

    test('takes the source name and real APKs', () async {
      final provider = SourceProvider();
      final fake = _NamedSource();
      final placeholder = provider.buildPlaceholderApp(
        fake,
        'https://example.com/app',
        const {'autoApkFilterByArch': false},
      );

      final checked = await provider.getApp(
        fake,
        placeholder.url,
        placeholder.additionalSettings,
        currentApp: placeholder,
      );

      expect(checked.name, 'Example App');
      expect(checked.latestVersion, '2.0');
      expect(hasOnlyPlaceholderApks(checked), isFalse);
    });
  });

  group('allowAddingAppsWithoutCheck setting', () {
    test('defaults to false and round-trips', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      settings.prefs = await SharedPreferences.getInstance();
      expect(settings.allowAddingAppsWithoutCheck, isFalse);
      settings.allowAddingAppsWithoutCheck = true;
      expect(settings.allowAddingAppsWithoutCheck, isTrue);
    });
  });
}
