import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/app_check_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// v1.7.5 sync D-01 (upstream #3527, with the assertions of its import
// integration test): what the app-record store writes, loads and deletes, on
// a real temporary folder.

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
  _Provider(this.root);

  final Directory root;

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
  Directory get apkDir => Directory('${root.path}/apks');
  @override
  Directory get iconsCacheDir => Directory('${root.path}/icons');
  @override
  Directory get deducedAppIconsDir => Directory('${root.path}/deduced_icons');
  @override
  Directory get userAppIconsDir => Directory('${root.path}/user_icons');

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
  void notify() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _app = App(
  id: 'org.example.app',
  url: 'https://github.com/example/app',
  author: 'Example',
  name: 'Example',
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: {'versionDetection': 'auto'},
);

Future<_Provider> _provider() async {
  SharedPreferences.setMockInitialValues({
    'folderCriteriaMigrationVersion': 1000,
  });
  final root = await Directory.systemTemp.createTemp('obtainx-record-ids-');
  final appsDir = Directory('${root.path}/app_data')..createSync();
  for (final String name in ['apks', 'icons', 'deduced_icons', 'user_icons']) {
    Directory('${root.path}/$name').createSync();
  }
  final provider = _Provider(root)
    ..cachedAppsDir = appsDir
    ..appCheckStore = AppCheckStore('${root.path}/checks.db');
  provider.settingsProvider.prefs = await SharedPreferences.getInstance();
  addTearDown(() async {
    await provider.appCheckStore?.close();
    await root.delete(recursive: true);
  });
  return provider;
}

Future<void> _saveNew(_Provider provider, App app) => provider.saveApps(
  [app],
  onlyIfExists: false,
  attemptToCorrectInstallStatus: false,
  updateInstalledInfo: false,
  autoExportAfterSave: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const deviceApps = MethodChannel('dev.imranr.obtainium/device_apps');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  // loadApps announces the apps a load error removes: let that notification
  // reach a mocked plugin channel rather than an unregistered platform.
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  setUp(() {
    // Nothing installed.
    messenger.setMockMethodCallHandler(deviceApps, (MethodCall call) async {
      return call.method == 'getInstalledPackageInfos' ? <Object?>[] : null;
    });
    messenger.setMockMethodCallHandler(notifications, (_) async => true);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(deviceApps, null);
    messenger.setMockMethodCallHandler(notifications, null);
  });

  group('writing a record', () {
    test('a safe ID is written under its listing key', () async {
      final provider = await _provider();
      await _saveNew(provider, _app);
      await _saveNew(provider, _app.copyWith(listingId: '${_app.id}@FDroid'));
      expect(
        File('${provider.cachedAppsDir!.path}/${_app.id}.json').existsSync(),
        isTrue,
      );
      final saved = File(
        '${provider.cachedAppsDir!.path}/${_app.id}@FDroid.json',
      );
      expect(jsonDecode(await saved.readAsString()), isA<Map>());
    });

    test('an unsafe package ID is refused and nothing is written', () async {
      final provider = await _provider();
      final escaped = File('${provider.root.path}/escape.json');
      await expectLater(
        _saveNew(provider, _app.copyWith(id: '../escape')),
        throwsA(isA<ObtainiumError>()),
      );
      expect(escaped.existsSync(), isFalse);
      expect(provider.apps.containsKey('../escape'), isFalse);
    });

    test('an unsafe listing key is refused and nothing is written', () async {
      final provider = await _provider();
      final escaped = File('${provider.root.path}/escape.json');
      await expectLater(
        _saveNew(
          provider,
          _app.copyWith(listingId: '${_app.id}@x/../../escape'),
        ),
        throwsA(isA<ObtainiumError>()),
      );
      expect(escaped.existsSync(), isFalse);
      expect(provider.apps, isEmpty);
    });
  });

  group('loading records', () {
    test('a record whose package ID could escape is set aside', () async {
      final provider = await _provider();
      final String appsPath = provider.cachedAppsDir!.path;
      await File('$appsPath/bad.json')
          .writeAsString(jsonEncode(_app.copyWith(id: '../escape').toJson()));
      await File('$appsPath/${_app.id}.json')
          .writeAsString(jsonEncode(_app.toJson()));
      await provider.loadApps();
      expect(provider.apps.keys, [_app.id]);
      expect(File('$appsPath/bad.json').existsSync(), isFalse);
      expect(File('$appsPath/bad.json.corrupt').existsSync(), isTrue);
    });
  });

  group('removing records', () {
    test('an unsafe ID deletes nothing outside the folder', () async {
      final provider = await _provider();
      final File outside = File('${provider.root.path}/escape.json')
        ..writeAsStringSync('{}');
      await provider.removeApps(['../escape']);
      expect(outside.existsSync(), isTrue);
      await provider.deleteObtainiumAppDiskData(['../escape']);
      expect(outside.existsSync(), isTrue);
    });

    test('a safe ID still deletes its record', () async {
      final provider = await _provider();
      await _saveNew(provider, _app);
      final File record = File(
        '${provider.cachedAppsDir!.path}/${_app.id}.json',
      );
      expect(record.existsSync(), isTrue);
      await provider.removeApps([_app.id]);
      expect(record.existsSync(), isFalse);
      expect(provider.apps, isEmpty);
    });
  });
}
