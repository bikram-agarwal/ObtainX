import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';

App _app({
  String id = 'com.example.app',
  String? listingId,
  String? installedVersion,
  Map<String, dynamic> additionalSettings = const {},
  bool allowIdChange = false,
}) => App(
  id: id,
  listingId: listingId,
  url: 'https://github.com/example/app',
  author: 'Author',
  name: 'App',
  installedVersion: installedVersion,
  latestVersion: '2.0.0',
  preferredApkIndex: 0,
  additionalSettings: additionalSettings,
  allowIdChange: allowIdChange,
);

/// Only [parseBackupContent] is called, which reads nothing from the provider.
class _ImportProvider implements AppsProvider {
  @override
  AppListings apps = AppListings();
  @override
  final SettingsProvider settingsProvider = SettingsProvider();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Upstream #3531. Its cases store `versionDetection` as the legacy bool,
  // which ObtainX still reads (true = auto, false = pseudo); the string-enum
  // cases are ObtainX's (v1.7.5 sync D-02).
  group('resolveImportedInstalledVersion', () {
    test('uses the version installed on this device', () {
      final app = _app(
        installedVersion: '1.0.0',
        additionalSettings: const {'trackOnly': true, 'versionDetection': true},
      );
      expect(resolveImportedInstalledVersion(app, '1.0.0'), '1.0.0');
      expect(resolveImportedInstalledVersion(app, '0.9.0'), '0.9.0');
    });

    test('keeps the exported version for track-only apps', () {
      final app = _app(
        installedVersion: '1.2.3',
        additionalSettings: const {'trackOnly': true, 'versionDetection': true},
      );
      expect(resolveImportedInstalledVersion(app, null), '1.2.3');
    });

    test('keeps the exported version when version detection is disabled', () {
      final app = _app(
        installedVersion: '2.3.4',
        additionalSettings: const {'versionDetection': false},
      );
      expect(resolveImportedInstalledVersion(app, null), '2.3.4');
    });

    test(
      'drops the exported version for regular apps that are not installed',
      () {
        final app = _app(
          installedVersion: '3.4.5',
          additionalSettings: const {'versionDetection': true},
        );
        expect(resolveImportedInstalledVersion(app, null), isNull);
      },
    );

    test(
      'returns null when a pseudo-versioned app has no exported version',
      () {
        final app = _app(
          additionalSettings: const {
            'trackOnly': true,
            'versionDetection': true,
          },
        );
        expect(resolveImportedInstalledVersion(app, null), isNull);
      },
    );

    test('reads the version-detection string enum, never a bool', () {
      for (final String mode in ['auto', 'standard', 'versionCode']) {
        final app = _app(
          installedVersion: '3.4.5',
          additionalSettings: {'versionDetection': mode},
        );
        expect(
          resolveImportedInstalledVersion(app, null),
          isNull,
          reason: mode,
        );
      }
      final pseudo = _app(
        installedVersion: '3.4.5',
        additionalSettings: const {'versionDetection': 'pseudo'},
      );
      expect(resolveImportedInstalledVersion(pseudo, null), '3.4.5');
    });

    test('never imports allowIdChange', () {
      final app = _app(installedVersion: '1.0.0', allowIdChange: true);
      expect(prepareImportedApp(app, null).allowIdChange, isFalse);
    });

    test('prepareImportedApp takes the resolved installed version', () {
      final tracked = _app(
        installedVersion: '1.2.3',
        additionalSettings: const {'trackOnly': true},
        allowIdChange: true,
      );
      final regular = _app(
        installedVersion: '3.4.5',
        additionalSettings: const {'versionDetection': 'auto'},
      );
      expect(prepareImportedApp(tracked, null).installedVersion, '1.2.3');
      expect(prepareImportedApp(regular, null).installedVersion, isNull);
      expect(prepareImportedApp(regular, '3.0').installedVersion, '3.0');
    });
  });

  // Upstream #3527 (v1.7.5 sync D-01, also the assertions of upstream's
  // import integration test): an ID that could name a path outside the apps
  // folder rejects the backup when it is read, before anything is saved or a
  // restore wipes the library. ObtainX also names files after the listing key,
  // which a backup carries as `listingId`.
  group('parseBackupContent rejects unsafe IDs', () {
    final provider = _ImportProvider();

    String backupOf(List<App> apps) =>
        jsonEncode({'apps': apps.map((App app) => app.toJson()).toList()});

    test('reads safe IDs, temporary IDs and listing keys', () {
      final content = provider.parseBackupContent(
        backupOf([
          _app(),
          _app(id: 'a1b2c3d4e5f6'),
          _app(id: 'com.example.app', listingId: 'com.example.app@FDroid'),
        ]),
      );
      expect(content.apps.map((App app) => app.listingKey), [
        'com.example.app',
        'a1b2c3d4e5f6',
        'com.example.app@FDroid',
      ]);
    });

    test('a package ID that escapes the folder', () {
      expect(
        () => provider.parseBackupContent(
          backupOf([_app(), _app(id: '../obtainium_path_traversal_poc')]),
        ),
        throwsA(isA<ObtainiumError>()),
      );
    });

    test('a listing ID that escapes the folder', () {
      expect(
        () => provider.parseBackupContent(
          backupOf([_app(listingId: 'com.example.app@x/../../escape')]),
        ),
        throwsA(isA<ObtainiumError>()),
      );
    });

    test('an old list-format backup and a link payload alike', () {
      expect(
        () => provider.parseBackupContent(
          jsonEncode([_app(id: 'sub\\dir').toJson()]),
        ),
        throwsA(isA<ObtainiumError>()),
      );
      expect(
        () => provider.parseBackupContent(
          '{ "apps": [${jsonEncode(_app(id: '..').toJson())}] }',
        ),
        throwsA(isA<ObtainiumError>()),
      );
    });

    // Phase C: in a link or pasted app JSON the ID is only a hint, and a
    // missing one means "infer it", as before v1.7.5. A backup still needs one.
    test('a link app with no ID is read when IDs are hints, and only then', () {
      const String noId =
          '[{"url":"https://github.com/a/b","author":"a","name":"b",'
          '"additionalSettings":"{}"}]';
      final content = provider.parseBackupContent(noId, idsAreHints: true);
      expect(content.apps.single.id, isEmpty);
      expect(
        () => provider.parseBackupContent(noId),
        throwsA(isA<ObtainiumError>()),
      );
      // A given ID must still be safe, hints or not.
      expect(
        () => provider.parseBackupContent(
          jsonEncode([_app(id: '../escape').toJson()]),
          idsAreHints: true,
        ),
        throwsA(isA<ObtainiumError>()),
      );
    });
  });
}
