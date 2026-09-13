import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

class _CodeTestProvider implements AppsProvider {
  @override
  AppListings apps = AppListings();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _InstalledCodePackage extends PackageInfo {
  const _InstalledCodePackage()
    : super(
        installLocation: AndroidInstallLocation.unspecified,
        packageName: 'org.example.app',
        versionName: '9.18.50',
        versionCode: 123,
      );
}

App _codeApp({
  String? installed = '123',
  String latest = '1.2.4',
  Map<String, dynamic> settings = const {'versionDetection': 'versionCode'},
}) {
  return App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    additionalSettings: settings,
  );
}

void main() {
  for (final (installed, latest) in [
    ('123', '1.2.4'),
    ('123', '123.0'),
    ('123', '123.0.0'),
    ('123', '123-beta'),
    ('1.2.4', '124'),
    ('1.2.4', '1.2.4'),
  ]) {
    test(
      'code comparison $installed versus $latest is uncertain everywhere',
      () {
        final app = _codeApp(installed: installed, latest: latest);
        expect(versionCodeModeCannotCompare(app), isTrue);
        expect(appIsUpToDateForFiltering(app), isFalse);
        expect(versionOrderUncertainUpdate(app), isTrue);
        expect(appHasActionableUpdate(app), isFalse);
        expect(appUpdateIsUserVisible(app), isFalse);
        expect(
          appUpdateIsUserVisible(app, includeVersionOrderUncertain: true),
          isTrue,
        );
        expect(
          appVersionVerdictForDisplay(app),
          AppVersionDisplayVerdict.uncertain,
        );
        final provider = _CodeTestProvider();
        provider.apps[app.id] = AppInMemory(app, null, null, null);
        expect(provider.findExistingUpdates(installedOnly: true), isEmpty);
        expect(
          provider.findExistingUpdates(
            installedOnly: true,
            includeVersionOrderUncertain: true,
          ),
          [app.id],
        );
      },
    );
  }

  test(
    'an active Skip survives a code/name mismatch and repeated correction',
    () {
      final provider = _CodeTestProvider();
      const installedInfo = _InstalledCodePackage();
      for (final latest in ['1.2.4', '123.0']) {
        var app = _codeApp(
          latest: latest,
          settings: {
            'versionDetection': 'versionCode',
            'skippedLatestVersion': latest,
          },
        );
        app = normalizeSkippedLatestVersion(app);
        expect(isSkipActiveForCurrentLatest(app), isTrue);
        app =
            provider.getCorrectedInstallStatusAppIfPossible(
              app,
              installedInfo,
            ) ??
            app;
        expect(app.installedVersion, '123');
        expect(isSkipActiveForCurrentLatest(app), isTrue);
        expect(appHasActionableUpdate(app), isFalse);
        expect(versionOrderUncertainUpdate(app), isFalse);
        expect(appIsUpToDateForFiltering(app), isTrue);
        expect(
          appVersionVerdictForDisplay(app),
          AppVersionDisplayVerdict.uncertain,
        );
        expect(
          provider.getCorrectedInstallStatusAppIfPossible(app, installedInfo),
          isNull,
        );

        final changed = normalizeSkippedLatestVersion(
          app.copyWith(latestVersion: '1.2.5'),
        );
        expect(isSkipActiveForCurrentLatest(changed), isFalse);
        expect(versionOrderUncertainUpdate(changed), isTrue);
        expect(appHasActionableUpdate(changed), isFalse);
      }
    },
  );

  test('a later publication date cannot make code and name comparable', () {
    final app = _codeApp(latest: '123.0').copyWith(
      releaseDate: DateTime.utc(2026, 6, 3),
      additionalSettings: {
        'versionDetection': 'versionCode',
        'lastInstalledTime': DateTime.utc(2026, 6, 2).millisecondsSinceEpoch,
      },
    );
    expect(appHasActionableUpdate(app), isFalse);
    expect(versionOrderUncertainUpdate(app), isTrue);
    expect(
      appVersionVerdictForDisplay(app),
      AppVersionDisplayVerdict.uncertain,
    );
  });

  test('legacy version-code flag gets the same guard as the dropdown', () {
    for (final mode in ['auto', 'standard', 'pseudo']) {
      final app = _codeApp(
        latest: '123.0',
        settings: {'versionDetection': mode, 'useVersionCodeAsOSVersion': true},
      );
      expect(app.usesVersionCodeAsOsVersion, isTrue);
      expect(appIsUpToDateForFiltering(app), isFalse);
      expect(appHasActionableUpdate(app), isFalse);
      expect(versionOrderUncertainUpdate(app), isTrue);
      expect(
        appVersionVerdictForDisplay(app),
        AppVersionDisplayVerdict.uncertain,
      );
    }
  });

  test(
    'a source that supplies codes still compares older, equal, and newer',
    () {
      for (final (latest, verdict, actionable, upToDate) in [
        ('122', AppVersionDisplayVerdict.newerOnDevice, false, true),
        ('123', AppVersionDisplayVerdict.sameVersion, false, true),
        ('124', AppVersionDisplayVerdict.updateAvailable, true, false),
      ]) {
        final app = _codeApp(latest: latest);
        expect(versionCodeModeCannotCompare(app), isFalse);
        expect(versionOrderUncertainUpdate(app), isFalse);
        expect(appHasActionableUpdate(app), actionable);
        expect(appIsUpToDateForFiltering(app), upToDate);
        expect(appVersionVerdictForDisplay(app), verdict);
      }
    },
  );

  test(
    'normal version names retain their existing display and update meaning',
    () {
      for (final (installed, latest, verdict) in [
        ('1.2.3', '1.2.3', AppVersionDisplayVerdict.sameVersion),
        ('123', '123.0', AppVersionDisplayVerdict.uncertain),
        ('1.2', '1.2.0', AppVersionDisplayVerdict.effectivelyEqual),
        ('1.2.4', '1.2.3', AppVersionDisplayVerdict.newerOnDevice),
        ('1.2.3', '1.2.4', AppVersionDisplayVerdict.updateAvailable),
        ('stable', 'nightly', AppVersionDisplayVerdict.uncertain),
        (null, '1.2.4', AppVersionDisplayVerdict.notInstalled),
      ]) {
        final app = _codeApp(
          installed: installed,
          latest: latest,
          settings: const {'versionDetection': 'auto'},
        );
        expect(appVersionVerdictForDisplay(app), verdict);
      }
      expect(
        appVersionVerdictForDisplay(null),
        AppVersionDisplayVerdict.notInstalled,
      );
    },
  );
}
