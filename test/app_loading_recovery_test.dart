import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/app_check_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Settings extends SettingsProvider {
  bool failFolderRead = false;

  @override
  List<AppFolder> get appFolders {
    if (failFolderRead) throw StateError('Folder settings unavailable');
    return super.appFolders;
  }
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

class _Provider implements AppsProvider {
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
  final _Settings settingsProvider = _Settings();
  @override
  final _Logs logs = _Logs();
  final loadingSignals = <Completer<void>>[];

  @override
  Future<void> waitForAppsToLoad() async {
    while (appsLoadingCompleter != null) {
      await appsLoadingCompleter!.future;
    }
  }

  @override
  void markAppsChanged() {}
  @override
  void scheduleAutoExport() {}
  @override
  void notify() {
    if (loadingApps && appsLoadingCompleter != null) {
      loadingSignals.add(appsLoadingCompleter!);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _app = App(
  id: 'org.example.app',
  url: 'https://github.com/example/app',
  author: 'Example',
  name: 'Example',
  installedVersion: '1.0',
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: {'versionDetection': 'auto'},
);

Future<_Provider> _provider({bool hasInstalledVersion = false}) async {
  SharedPreferences.setMockInitialValues({
    'folderCriteriaMigrationVersion': 1000,
  });
  final directory = await Directory.systemTemp.createTemp(
    'obtainx-load-recovery-',
  );
  final provider = _Provider()
    ..cachedAppsDir = directory
    ..appCheckStore = AppCheckStore('${directory.path}/checks.db');
  provider.settingsProvider.prefs = await SharedPreferences.getInstance();
  await File('${directory.path}/${_app.id}.json').writeAsString(
    jsonEncode(
      (hasInstalledVersion ? _app : _app.copyWith(installedVersion: null))
          .toJson(),
    ),
  );
  addTearDown(() async {
    // Drain post-load correction writes before closing/deleting their store.
    await provider.saveApps(
      provider.apps.values.map((entry) => entry.app).toList(),
      updateInstalledInfo: false,
      autoExportAfterSave: false,
    );
    await provider.appCheckStore?.close();
    await directory.delete(recursive: true);
  });
  return provider;
}

class _Database extends Fake implements Database {
  @override
  final String path;
  final rows = <String, Map<String, Object?>>{};
  Completer<List<Map<String, Object?>>>? stalledRead;
  Completer<void>? stalledCommit;
  Completer<void>? commitStarted;
  int reads = 0;
  int commits = 0;

  _Database(this.path);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    reads++;
    return stalledRead?.future ?? rows.values.toList();
  }

  @override
  Batch batch() => _Batch(this);

  @override
  Future<void> close() async {}
}

class _Batch extends Fake implements Batch {
  final _Database database;
  final checkpoints = <Map<String, Object?>>[];
  _Batch(this.database);

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    checkpoints.add(Map.from(values));
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    database.commits++;
    database.commitStarted?.complete();
    database.commitStarted = null;
    await database.stalledCommit?.future;
    for (final row in checkpoints) {
      database.rows[row['id'] as String] = row;
    }
    return [];
  }
}

class _Factory extends Fake implements DatabaseFactory {
  final _Database database;
  Completer<Database>? stalledOpen;
  int opens = 0;
  _Factory(this.database);

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    opens++;
    return stalledOpen?.future ?? database;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('dev.imranr.obtainium/device_apps');
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'simultaneous loads serialize and every completion signal resolves',
    () async {
      final provider = await _provider();
      final firstQuery = Completer<Object?>();
      var requests = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        requests++;
        if (requests == 1) return firstQuery.future;
        return null;
      });
      final first = provider.loadApps(singleId: _app.id);
      final second = provider.loadApps(singleId: _app.id);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(requests, 1);
      } finally {
        firstQuery.complete(null);
        await Future.wait([first, second]);
      }
      expect(requests, 2);
      expect(provider.loadingApps, isFalse);
      expect(provider.appsLoadingCompleter, isNull);
      expect(
        provider.loadingSignals.every((signal) => signal.isCompleted),
        isTrue,
      );
    },
  );

  test(
    'a setup error releases the loading guard and allows another load',
    () async {
      final provider = await _provider();
      provider.settingsProvider.failFolderRead = true;
      await expectLater(provider.loadApps(singleId: _app.id), throwsStateError);
      expect(provider.loadingApps, isFalse);
      expect(provider.appsLoadingCompleter, isNull);
      provider.settingsProvider.failFolderRead = false;
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await provider.loadApps(singleId: _app.id);
      expect(provider.apps, contains(_app.id));
    },
  );

  test(
    'a stalled package service still loads saved apps without recording uninstalls',
    () async {
      final provider = await _provider(hasInstalledVersion: true);
      final stalled = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => stalled.future);
      await provider.loadApps(
        installedInfoTimeout: const Duration(milliseconds: 50),
      );
      expect(provider.apps[_app.id]!.app.installedVersion, '1.0');
      expect(provider.loadingApps, isFalse);
      expect(provider.appsLoadingCompleter, isNull);
      expect(provider.lastFullDiskLoadAt, isNull);
      expect(
        provider.logs.messages.any(
          (message) =>
              message.contains('Installed package snapshot unavailable'),
        ),
        isTrue,
      );
      stalled.complete([]);
      await Future<void>.delayed(Duration.zero);
      expect(provider.apps[_app.id]!.app.installedVersion, '1.0');
      await provider.saveApps(
        [provider.apps[_app.id]!.app.copyWith(lastUpdateCheck: DateTime.now())],
        updateInstalledInfo: false,
        autoExportAfterSave: false,
      );
      expect(provider.apps[_app.id]!.app.installedVersion, '1.0');
    },
  );

  test(
    'a stalled checkpoint read cannot block the app list or the next load',
    () async {
      final provider = await _provider();
      final database = _Database('${provider.cachedAppsDir!.path}/stalled.db')
        ..stalledRead = Completer<List<Map<String, Object?>>>();
      provider.appCheckStore = AppCheckStore(
        database.path,
        factory: _Factory(database),
        operationTimeout: const Duration(milliseconds: 50),
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await provider.loadApps(singleId: _app.id);
      expect(provider.apps, contains(_app.id));
      expect(provider.loadingApps, isFalse);
      expect(provider.appCheckStore!.isAvailable, isFalse);
      await provider.loadApps(singleId: _app.id);
      expect(database.reads, 1);
      expect(
        provider.logs.messages.any(
          (message) => message.contains('Check timestamp database read'),
        ),
        isTrue,
      );
      database.stalledRead!.complete([]);
    },
  );

  test(
    'a database open completing after timeout cannot start its abandoned query',
    () async {
      final provider = await _provider();
      final database = _Database('${provider.cachedAppsDir!.path}/late.db');
      final opening = Completer<Database>();
      final factory = _Factory(database)..stalledOpen = opening;
      final store = AppCheckStore(
        database.path,
        factory: factory,
        operationTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(store.read(), throwsA(isA<TimeoutException>()));
      opening.complete(database);
      await Future<void>.delayed(Duration.zero);
      expect(database.reads, 0);
      await expectLater(store.read(), throwsA(isA<TimeoutException>()));
      expect(factory.opens, 1);
      await store.close();
    },
  );

  test(
    'stalled final timestamp save falls back to JSON and releases later saves',
    () async {
      final provider = await _provider();
      final database = _Database('${provider.cachedAppsDir!.path}/save.db');
      final factory = _Factory(database);
      provider.appCheckStore = AppCheckStore(
        database.path,
        factory: factory,
        operationTimeout: const Duration(milliseconds: 50),
      );
      await provider.saveApps(
        [_app],
        onlyIfExists: false,
        attemptToCorrectInstallStatus: false,
        updateInstalledInfo: false,
        autoExportAfterSave: false,
      );
      final previousRevision = provider.appCheckStore!.revisions[_app.id];
      final saved = provider.apps[_app.id]!.app;
      final checked = saved.copyWith(
        lastUpdateCheck: DateTime.utc(2026, 9, 12, 10),
      );
      final started = Completer<void>();
      final stalled = Completer<void>();
      database.commitStarted = started;
      database.stalledCommit = stalled;
      final firstSave = provider.saveApps(
        [checked],
        attemptToCorrectInstallStatus: false,
        updateInstalledInfo: false,
        autoExportAfterSave: false,
      );
      await started.future;
      await firstSave.timeout(const Duration(seconds: 2));
      final file = File('${provider.cachedAppsDir!.path}/${_app.id}.json');
      final fallback =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(
        App.fromJson(fallback).lastUpdateCheck?.toUtc(),
        checked.lastUpdateCheck,
      );
      expect(fallback[appRecordRevisionKey], isNot(previousRevision));
      expect(
        provider.logs.messages.any(
          (message) => message.contains('falling back to 1 app records'),
        ),
        isTrue,
      );
      final updated = checked.copyWith(
        latestVersion: '2.0',
        lastUpdateCheck: DateTime.utc(2026, 9, 12, 11),
      );
      await provider
          .saveApps(
            [updated],
            attemptToCorrectInstallStatus: false,
            updateInstalledInfo: false,
            autoExportAfterSave: false,
          )
          .timeout(const Duration(seconds: 2));
      expect(database.commits, 1);
      stalled.complete();
      await Future<void>.delayed(Duration.zero);
      // Simulate a new process reading a late SQLite result alongside newer JSON.
      final reloadedStore = AppCheckStore(database.path, factory: factory);
      final record =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      reloadedStore.apply(record, await reloadedStore.read());
      final restored = App.fromJson(record);
      expect(restored.latestVersion, '2.0');
      expect(restored.lastUpdateCheck?.toUtc(), updated.lastUpdateCheck);
      await reloadedStore.close();
    },
  );
}
