import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

class _UpdateTestProvider implements AppsProvider {
  @override
  Map<String, AppInMemory> apps = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

App _app({
  String? installed = 'stable',
  String latest = 'nightly',
  String mode = 'standard',
  DateTime? releaseDate,
  DateTime? installedTime,
}) {
  return App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    releaseDate: releaseDate,
    additionalSettings: {
      'versionDetection': mode,
      if (installedTime != null)
        'lastInstalledTime': installedTime.millisecondsSinceEpoch,
    },
  );
}

void main() {
  for (final (installed, latest) in [
    ('stable', 'nightly'),
    ('nightly', 'stable'),
    ('stable', '2.0.0'),
    ('2.0.0', 'stable'),
    ('custom build', 'other build'),
  ]) {
    test('unorderable $installed versus $latest requires a user decision', () {
      expect(compareVersionsByNumericSegments(installed, latest), isNull);
      expect(versionOrderIsUnclear(installed, latest), isTrue);
      for (final mode in ['auto', 'standard']) {
        final app = _app(installed: installed, latest: latest, mode: mode);
        expect(appHasActionableUpdate(app), isFalse, reason: mode);
        expect(versionOrderUncertainUpdate(app), isTrue, reason: mode);
        expect(appIsUpToDateForFiltering(app), isFalse, reason: mode);
        expect(appUpdateIsUserVisible(app), isFalse, reason: mode);
        expect(
          appUpdateIsUserVisible(app, includeVersionOrderUncertain: true),
          isTrue,
          reason: mode,
        );
      }
    });
  }

  test('a publication date cannot order unrelated version labels', () {
    for (final mode in ['auto', 'standard']) {
      for (final releaseDate in [
        null,
        DateTime.utc(2026, 6, 1),
        DateTime.utc(2026, 6, 2),
        DateTime.utc(2026, 6, 3),
      ]) {
        final app = _app(
          mode: mode,
          releaseDate: releaseDate,
          installedTime: DateTime.utc(2026, 6, 2),
        );
        expect(appHasActionableUpdate(app), isFalse);
        expect(versionOrderUncertainUpdate(app), isTrue);
      }
    }
  });

  test(
    'update all excludes unknown order while the manual list includes it',
    () {
      final provider = _UpdateTestProvider();
      final app = _app();
      provider.apps[app.id] = AppInMemory(app, null, null, null);
      expect(provider.findExistingUpdates(installedOnly: true), isEmpty);
      expect(
        provider.findExistingUpdates(
          installedOnly: true,
          includeVersionOrderUncertain: true,
        ),
        [app.id],
      );

      final skipped = normalizeSkippedLatestVersion(
        app.copyWith(
          additionalSettings: {
            ...app.additionalSettings,
            'skippedLatestVersion': app.latestVersion,
          },
        ),
      );
      expect(isSkipActiveForCurrentLatest(skipped), isTrue);
      expect(appHasActionableUpdate(skipped), isFalse);
      expect(versionOrderUncertainUpdate(skipped), isFalse);
      expect(
        appUpdateIsUserVisible(skipped, includeVersionOrderUncertain: true),
        isFalse,
      );
      provider.apps[app.id] = AppInMemory(skipped, null, null, null);
      expect(
        provider.findExistingUpdates(
          installedOnly: true,
          includeVersionOrderUncertain: true,
        ),
        isEmpty,
      );

      final nextRelease = normalizeSkippedLatestVersion(
        skipped.copyWith(latestVersion: 'preview'),
      );
      expect(isSkipActiveForCurrentLatest(nextRelease), isFalse);
      expect(versionOrderUncertainUpdate(nextRelease), isTrue);
      expect(appHasActionableUpdate(nextRelease), isFalse);
    },
  );

  test(
    'explicit Pseudo still treats changed text labels as source updates',
    () {
      for (final releaseDate in [
        null,
        DateTime.utc(2026, 6, 1),
        DateTime.utc(2026, 6, 3),
      ]) {
        final app = _app(
          mode: 'pseudo',
          releaseDate: releaseDate,
          installedTime: DateTime.utc(2026, 6, 2),
        );
        expect(appHasActionableUpdate(app), isTrue);
        expect(versionOrderUncertainUpdate(app), isFalse);
        expect(appUpdateIsUserVisible(app), isTrue);
      }
    },
  );

  test('identical text labels remain up to date in every detection mode', () {
    for (final mode in ['auto', 'standard', 'pseudo']) {
      final app = _app(installed: 'nightly', mode: mode);
      expect(versionOrderIsUnclear('nightly', 'nightly'), isFalse);
      expect(appIsUpToDateForFiltering(app), isTrue);
      expect(appHasActionableUpdate(app), isFalse);
      expect(versionOrderUncertainUpdate(app), isFalse);
    }
  });

  test('a never installed app is still available for first installation', () {
    final app = _app(installed: null);
    expect(versionOrderUncertainUpdate(app), isFalse);
    expect(appHasActionableUpdate(app), isFalse);
    expect(appUpdateIsUserVisible(app), isTrue);
  });
}
