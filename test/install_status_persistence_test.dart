import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/app_check_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ObtainX: the reconciler runs on the fork's string-enum versionDetection;
// these call it through a provider that only answers [isBg].
class _ReconcileProvider implements AppsProvider {
  _ReconcileProvider({required this.isBg});

  @override
  final bool isBg;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Logs implements LogsProvider {
  final messages = <String>[];

  @override
  Future<Log> add(String message, {LogLevel level = LogLevel.info}) async {
    messages.add(message);
    return Log(message, level);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Runs the real loadApps against a temporary app directory, with only the
// platform channel and storage replaced (as app_loading_recovery_test does).
class _LoadProvider implements AppsProvider {
  @override
  AppListings apps = AppListings();
  @override
  Directory? cachedAppsDir;
  @override
  AppCheckStore? appCheckStore;
  @override
  DateTime? appDirectoryModifiedAt;
  @override
  DateTime? appCheckStoreModifiedAt;
  @override
  DateTime? lastFullDiskLoadAt;
  @override
  bool loadingApps = false;
  @override
  Completer<void>? appsLoadingCompleter;
  @override
  final SettingsProvider settingsProvider = SettingsProvider();
  @override
  final _Logs logs = _Logs();
  @override
  bool get isBg => false;

  @override
  void markAppsChanged() {}
  @override
  void scheduleAutoExport() {}
  @override
  void notify() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

App _app({
  String mode = 'pseudo',
  String? installed = '1.0',
  String latest = '1.0',
  bool trackOnly = false,
}) => App(
  id: 'org.example.app',
  url: 'https://github.com/example/app',
  author: 'Example',
  name: 'Example',
  installedVersion: installed,
  latestVersion: latest,
  preferredApkIndex: 0,
  additionalSettings: {
    'versionDetection': mode,
    if (mode == 'versionCode') 'useVersionCodeAsOSVersion': true,
    if (trackOnly) 'trackOnly': true,
  },
);

void main() {
  group('resolveBulkOrLookup', () {
    test('uses the bulk entry when present', () async {
      var lookedUp = false;
      final result = await resolveBulkOrLookup<String>(
        'app',
        {'app': 'bulk'},
        lookup: (_) async {
          lookedUp = true;
          return 'lookup';
        },
      );

      expect(result, 'bulk');
      expect(lookedUp, isFalse);
    });

    test(
      'confirms with a per-app lookup when the bulk list misses it',
      () async {
        var lookupKey = '';
        final result = await resolveBulkOrLookup<String>(
          'app',
          const {},
          lookup: (key) async {
            lookupKey = key;
            return 'lookup';
          },
        );

        expect(result, 'lookup');
        expect(lookupKey, 'app');
      },
    );

    test('returns null when both sources miss', () async {
      final result = await resolveBulkOrLookup<String>(
        'app',
        const {},
        lookup: (_) async => null,
      );
      expect(result, isNull);
    });
  });

  group('shouldClearInstalledVersion', () {
    bool clear({
      bool installedInfoMissing = true,
      bool trackOnly = false,
      bool isBackground = false,
      bool versionDetectionIsStandard = false,
      String? installedVersion = 'v1.0',
      String latestVersion = 'v1.0',
    }) => shouldClearInstalledVersion(
      installedInfoMissing: installedInfoMissing,
      trackOnly: trackOnly,
      isBackground: isBackground,
      versionDetectionIsStandard: versionDetectionIsStandard,
      installedVersion: installedVersion,
      latestVersion: latestVersion,
    );

    test('background load preserves a marked-updated version', () {
      expect(clear(isBackground: true), isFalse);
    });

    test('background load still clears an up-to-date standard app', () {
      expect(
        clear(isBackground: true, versionDetectionIsStandard: true),
        isTrue,
      );
    });

    test('foreground load clears a genuinely missing install', () {
      expect(clear(), isTrue);
    });

    test('background load still clears an older installed version', () {
      expect(
        clear(
          isBackground: true,
          installedVersion: '0.9',
          latestVersion: '1.0',
        ),
        isTrue,
      );
    });

    test('track-only and missing recorded versions are left alone', () {
      expect(clear(trackOnly: true), isFalse);
      expect(clear(installedVersion: null), isFalse);
    });
  });

  group('reconciler with a missing package (fork string enum)', () {
    App? reconcile(App app, {required bool isBg}) => _ReconcileProvider(
      isBg: isBg,
    ).getCorrectedInstallStatusAppIfPossible(app, null);

    test('a background load keeps a marked-updated pseudo version', () {
      expect(reconcile(_app(), isBg: true), isNull);
    });

    test('so does the legacy bool form of pseudo', () {
      final legacy = _app().copyWith(
        additionalSettings: {'versionDetection': false},
      );
      expect(legacy.usesStandardVersionDetection, isFalse);
      expect(reconcile(legacy, isBg: true), isNull);
    });

    test('a foreground load still records the uninstall', () {
      expect(reconcile(_app(), isBg: false)?.installedVersion, isNull);
    });

    for (final mode in ['auto', 'standard', 'versionCode']) {
      test('a background load still clears a missing $mode app', () {
        expect(
          reconcile(_app(mode: mode), isBg: true)?.installedVersion,
          isNull,
        );
      });
    }

    test('a background load clears a pseudo app behind its latest', () {
      expect(
        reconcile(_app(latest: '1.1'), isBg: true)?.installedVersion,
        isNull,
      );
    });

    test('track-only apps keep the fork rules', () {
      // Not short-circuited: a track-only app with a real package ID that
      // isn't on the device reads as not installed.
      final corrected = reconcile(_app(trackOnly: true), isBg: true);
      expect(corrected, isNotNull);
      expect(corrected!.installedVersion, isNull);
    });
  });

  group('loadApps with a truncated installed-package list (#3215)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('dev.imranr.obtainium/device_apps');
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    // An auto-detection app installed at 1.0, so only the package info
    // decides whether it still is.
    final App installedApp = _app(mode: 'auto');

    Future<_LoadProvider> provider({bool removeOnUninstall = false}) async {
      SharedPreferences.setMockInitialValues({
        'folderCriteriaMigrationVersion': 1000,
        'removeOnExternalUninstall': removeOnUninstall,
      });
      final directory = await Directory.systemTemp.createTemp(
        'obtainx-truncated-list-',
      );
      final p = _LoadProvider()
        ..cachedAppsDir = directory
        ..appCheckStore = AppCheckStore('${directory.path}/checks.db');
      p.settingsProvider.prefs = await SharedPreferences.getInstance();
      await File(
        '${directory.path}/${installedApp.id}.json',
      ).writeAsString(jsonEncode(installedApp.toJson()));
      addTearDown(() async {
        // Drain post-load correction writes before closing the store.
        await p.saveApps(
          p.apps.values.map((entry) => entry.app).toList(),
          updateInstalledInfo: false,
          autoExportAfterSave: false,
        );
        await p.appCheckStore?.close();
        await directory.delete(recursive: true);
      });
      return p;
    }

    // The bulk list never has the app; [lookup] answers the per-package one.
    void mockPackages(FutureOr<Object?> Function(String packageName) lookup) {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'getInstalledPackageInfos') {
          return <Object?>[
            <String, Object?>{
              'packageName': 'org.example.other',
              'versionName': '3.0',
              'versionCode': 3,
            },
          ];
        }
        if (call.method == 'getInstalledPackageInfo') {
          final arguments = call.arguments as Map<Object?, Object?>;
          return lookup(arguments['packageName']! as String);
        }
        return null;
      });
    }

    test('an app missing from the list is confirmed and kept', () async {
      final p = await provider(removeOnUninstall: true);
      final lookups = <String>[];
      mockPackages((String packageName) {
        lookups.add(packageName);
        return <String, Object?>{
          'packageName': packageName,
          'versionName': '1.0',
          'versionCode': 1,
        };
      });
      await p.loadApps();
      expect(lookups, [installedApp.id]);
      expect(p.apps[installedApp.id], isNotNull);
      expect(p.apps[installedApp.id]!.app.installedVersion, '1.0');
      expect(p.apps[installedApp.id]!.installedInfo?.versionName, '1.0');
    });

    test('a real uninstall is still recorded', () async {
      final p = await provider();
      mockPackages((_) => null);
      await p.loadApps();
      expect(p.apps[installedApp.id]!.app.installedVersion, isNull);
    });

    test('a failed lookup leaves the install state alone', () async {
      final p = await provider(removeOnUninstall: true);
      mockPackages(
        (_) => throw PlatformException(code: 'PACKAGE_QUERY_FAILED'),
      );
      await p.loadApps();
      expect(p.apps[installedApp.id]!.app.installedVersion, '1.0');
      expect(
        p.logs.messages.any(
          (String message) => message.contains('Could not confirm'),
        ),
        isTrue,
      );
    });
  });
}
