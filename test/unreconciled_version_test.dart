import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

class _VersionTestLogs implements LogsProvider {
  @override
  Future<Log> add(String message, {LogLevel level = LogLevel.info}) async {
    return Log(message, level);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

// Exercise the real lifecycle and update extensions without starting storage,
// background subscriptions, or a device lookup in the provider constructor.
class _VersionTestAppsProvider implements AppsProvider {
  @override
  final LogsProvider logs = _VersionTestLogs();

  @override
  Map<String, AppInMemory> apps = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _InstalledPackage extends PackageInfo {
  const _InstalledPackage(String versionName)
    : super(
        installLocation: AndroidInstallLocation.unspecified,
        packageName: 'org.example.app',
        versionName: versionName,
        versionCode: 106,
      );
}

App _trackedApp({
  String? installed = '106',
  String latest = '107',
  Object? mode = 'auto',
}) {
  return App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    additionalSettings: {'versionDetection': mode},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final deviceVersion in ['9.18.50', '205.4']) {
    test(
      'unmatched $deviceVersion stays installed and uncertain across consumers',
      () {
        final provider = _VersionTestAppsProvider();
        final original = _trackedApp();
        final installed = _InstalledPackage(deviceVersion);
        final corrected = provider.getCorrectedInstallStatusAppIfPossible(
          original,
          installed,
        )!;

        expect(corrected.installedVersion, deviceVersion);
        expect(corrected.latestVersion, '107');
        expect(corrected.versionDetectionMode, VersionDetectionMode.auto);
        expect(original.installedVersion, '106');
        expect(original.additionalSettings, {'versionDetection': 'auto'});
        expect(appIsUpToDateForFiltering(corrected), isFalse);
        expect(appHasActionableUpdate(corrected), isFalse);
        expect(versionOrderUncertainUpdate(corrected), isTrue);
        expect(appUpdateIsUserVisible(corrected), isFalse);
        expect(
          appUpdateIsUserVisible(corrected, includeVersionOrderUncertain: true),
          isTrue,
        );

        provider.apps[corrected.id] = AppInMemory(
          corrected,
          null,
          installed,
          null,
        );
        expect(provider.findExistingUpdates(installedOnly: true), isEmpty);
        expect(
          provider.findExistingUpdates(
            installedOnly: true,
            includeVersionOrderUncertain: true,
          ),
          [corrected.id],
        );

        // A store publication date cannot repair a failed format comparison.
        final withTimestamps = corrected.copyWith(
          releaseDate: DateTime(2026, 2),
          additionalSettings: {
            ...corrected.additionalSettings,
            'lastInstalledTime': DateTime(2026).millisecondsSinceEpoch,
          },
        );
        expect(appHasActionableUpdate(withTimestamps), isFalse);
        expect(versionOrderUncertainUpdate(withTimestamps), isTrue);
      },
    );
  }

  test(
    'unknown comparison survives serialization and settles after one pass',
    () {
      final provider = _VersionTestAppsProvider();
      const installed = _InstalledPackage('9.18.50');
      final corrected = provider.getCorrectedInstallStatusAppIfPossible(
        _trackedApp(),
        installed,
      )!;
      expect(
        provider.getCorrectedInstallStatusAppIfPossible(corrected, installed),
        isNull,
      );
      final restored = App.fromJson(corrected.toJson());
      expect(restored.installedVersion, '9.18.50');
      expect(restored.versionDetectionMode, VersionDetectionMode.auto);
      expect(versionOrderUncertainUpdate(restored), isTrue);
      expect(appHasActionableUpdate(restored), isFalse);
    },
  );

  test(
    'a comparable source version clears uncertainty and detects the real update',
    () {
      final provider = _VersionTestAppsProvider();
      const installed = _InstalledPackage('9.18.50');
      var app = provider.getCorrectedInstallStatusAppIfPossible(
        _trackedApp(),
        installed,
      )!;
      app = app.copyWith(latestVersion: '9.18.51');
      // An old failed comparison must not apply to different source metadata.
      expect(appHasActionableUpdate(app), isTrue);
      app =
          provider.getCorrectedInstallStatusAppIfPossible(app, installed) ??
          app;
      expect(app.installedVersion, '9.18.50');
      expect(app.versionDetectionMode, VersionDetectionMode.auto);
      expect(appHasActionableUpdate(app), isTrue);
      expect(versionOrderUncertainUpdate(app), isFalse);

      app =
          provider.getCorrectedInstallStatusAppIfPossible(
            app,
            const _InstalledPackage('9.18.51'),
          ) ??
          app;
      expect(app.installedVersion, '9.18.51');
      expect(appIsUpToDateForFiltering(app), isTrue);
      expect(versionOrderUncertainUpdate(app), isFalse);
    },
  );

  test(
    'skipping an unknown release survives reconciliation until latest changes',
    () {
      final provider = _VersionTestAppsProvider();
      const installed = _InstalledPackage('205.4');
      var app = provider.getCorrectedInstallStatusAppIfPossible(
        _trackedApp(),
        installed,
      )!;
      app = app.copyWith(
        additionalSettings: {
          ...app.additionalSettings,
          'skippedLatestVersion': app.latestVersion,
        },
      );
      app =
          provider.getCorrectedInstallStatusAppIfPossible(app, installed) ??
          app;
      expect(isSkipActiveForCurrentLatest(app), isTrue);
      expect(appHasActionableUpdate(app), isFalse);
      expect(versionOrderUncertainUpdate(app), isFalse);
      expect(
        appUpdateIsUserVisible(app, includeVersionOrderUncertain: true),
        isFalse,
      );

      app = app.copyWith(latestVersion: '108');
      app =
          provider.getCorrectedInstallStatusAppIfPossible(app, installed) ??
          app;
      expect(isSkipActiveForCurrentLatest(app), isFalse);
      expect(app.installedVersion, '205.4');
      expect(versionOrderUncertainUpdate(app), isTrue);
    },
  );

  for (final mode in [null, true]) {
    test('legacy Auto value $mode does not silently become Pseudo', () {
      final corrected = _VersionTestAppsProvider()
          .getCorrectedInstallStatusAppIfPossible(
            _trackedApp(installed: null, mode: mode),
            const _InstalledPackage('9.18.50'),
          )!;
      expect(corrected.installedVersion, '9.18.50');
      expect(corrected.versionDetectionMode, VersionDetectionMode.auto);
      expect(versionOrderUncertainUpdate(corrected), isTrue);
    });
  }

  test('explicit Pseudo mode continues to keep its source version', () {
    final app = _trackedApp(mode: 'pseudo');
    final corrected =
        _VersionTestAppsProvider().getCorrectedInstallStatusAppIfPossible(
          app,
          const _InstalledPackage('9.18.50'),
        ) ??
        app;
    expect(corrected.installedVersion, '106');
    expect(corrected.versionDetectionMode, VersionDetectionMode.pseudo);
    expect(appHasActionableUpdate(corrected), isTrue);
  });

  for (final mode in ['pseudo', 'versionCode']) {
    test('switching to $mode clears a previous Auto comparison failure', () {
      final provider = _VersionTestAppsProvider();
      const installed = _InstalledPackage('9.18.50');
      var app = provider.getCorrectedInstallStatusAppIfPossible(
        _trackedApp(),
        installed,
      )!;
      app = app.copyWith(
        additionalSettings: {
          ...app.additionalSettings,
          'versionDetection': mode,
        },
      );
      expect(appHasUnreconciledVersionComparison(app), isFalse);
      app =
          provider.getCorrectedInstallStatusAppIfPossible(app, installed) ??
          app;
      expect(app.additionalSettings[unreconciledVersionComparisonKey], isNull);
      expect(versionOrderUncertainUpdate(app), isFalse);
      expect(appHasActionableUpdate(app), isTrue);
      expect(app.installedVersion, mode == 'versionCode' ? '106' : '9.18.50');
    });
  }

  test('uninstalling clears both installed version and comparison failure', () {
    final provider = _VersionTestAppsProvider();
    final app = provider.getCorrectedInstallStatusAppIfPossible(
      _trackedApp(),
      const _InstalledPackage('9.18.50'),
    )!;
    final uninstalled = provider.getCorrectedInstallStatusAppIfPossible(
      app,
      null,
    )!;
    expect(uninstalled.installedVersion, isNull);
    expect(
      uninstalled.additionalSettings[unreconciledVersionComparisonKey],
      isNull,
    );
    expect(versionOrderUncertainUpdate(uninstalled), isFalse);
    expect(appIsUpToDateForFiltering(uninstalled), isFalse);
    expect(appUpdateIsUserVisible(uninstalled), isTrue);
  });
}
