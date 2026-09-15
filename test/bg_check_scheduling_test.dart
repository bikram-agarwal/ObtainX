import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/app_check_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class _DueTestProvider implements AppsProvider {
  @override
  AppListings apps = AppListings();
  @override
  final SettingsProvider settingsProvider = SettingsProvider();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

App _app({
  required String id,
  DateTime? lastUpdateCheck,
  String? installedVersion = '1.0',
  bool onDemandOnly = false,
  bool trackOnly = false,
}) {
  return App(
    id: id,
    url: 'https://github.com/example/$id',
    author: 'Example',
    name: id,
    installedVersion: installedVersion,
    latestVersion: '1.0',
    preferredApkIndex: 0,
    lastUpdateCheck: lastUpdateCheck,
    additionalSettings: {'onDemandOnly': onDemandOnly, 'trackOnly': trackOnly},
  );
}

/// A factory whose open never completes, standing in for a database file held
/// by another engine.
class _StalledFactory implements DatabaseFactory {
  int opens = 0;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) {
    opens++;
    return Completer<Database>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

/// A factory whose open fails outright, so the store drops the cached handle
/// and a later attempt really does reopen.
class _FailingFactory implements DatabaseFactory {
  int opens = 0;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) {
    opens++;
    return Future<Database>.error(StateError('database is locked'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

/// [SettingsProvider.initializeSettings] reaches for path_provider, which has
/// no implementation in a unit test; the prefs handle is all these cases need.
Future<_DueTestProvider> _provider({
  int updateInterval = 1440,
  bool onlyInstalledOrTrackOnly = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'updateInterval': updateInterval,
    'onlyCheckInstalledOrTrackOnlyApps': onlyInstalledOrTrackOnly,
  });
  final provider = _DueTestProvider();
  provider.settingsProvider.prefs = await SharedPreferences.getInstance();
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('earliestNextUpdateCheckDue', () {
    test('returns the soonest due time across tracked apps', () async {
      final provider = await _provider();
      final soonest = DateTime.now().subtract(const Duration(hours: 2));
      provider.apps['a'] = AppInMemory(
        _app(id: 'a', lastUpdateCheck: soonest),
        null,
        null,
        null,
      );
      provider.apps['b'] = AppInMemory(
        _app(id: 'b', lastUpdateCheck: DateTime.now()),
        null,
        null,
        null,
      );

      expect(
        provider.earliestNextUpdateCheckDue(),
        soonest.add(const Duration(minutes: 1440)),
      );
    });

    test('a never-checked app means something is due now', () async {
      final provider = await _provider();
      provider.apps['a'] = AppInMemory(
        _app(id: 'a', lastUpdateCheck: DateTime.now()),
        null,
        null,
        null,
      );
      provider.apps['b'] = AppInMemory(
        _app(id: 'b', lastUpdateCheck: null),
        null,
        null,
        null,
      );

      expect(provider.earliestNextUpdateCheckDue(), isNull);
    });

    test('skips apps the check would skip anyway', () async {
      final provider = await _provider(onlyInstalledOrTrackOnly: true);
      // Both are ineligible, so neither may pull the due time forward even
      // though they have never been checked.
      provider.apps['onDemand'] = AppInMemory(
        _app(id: 'onDemand', lastUpdateCheck: null, onDemandOnly: true),
        null,
        null,
        null,
      );
      provider.apps['notInstalled'] = AppInMemory(
        _app(id: 'notInstalled', lastUpdateCheck: null, installedVersion: null),
        null,
        null,
        null,
      );
      final checked = DateTime.now();
      provider.apps['eligible'] = AppInMemory(
        _app(id: 'eligible', lastUpdateCheck: checked),
        null,
        null,
        null,
      );

      expect(
        provider.earliestNextUpdateCheckDue(),
        checked.add(const Duration(minutes: 1440)),
      );
    });

    test('a disabled interval has nothing to wait for', () async {
      final provider = await _provider(updateInterval: 0);
      provider.apps['a'] = AppInMemory(
        _app(id: 'a', lastUpdateCheck: DateTime.now()),
        null,
        null,
        null,
      );

      expect(provider.earliestNextUpdateCheckDue(), isNull);
    });
  });

  group('AppCheckStore budgets', () {
    test('reads give up sooner than writes would', () async {
      final store = AppCheckStore(
        'held.db',
        factory: _StalledFactory(),
        operationTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(milliseconds: 40),
      );
      final stopwatch = Stopwatch()..start();

      await expectLater(store.read(), throwsA(isA<TimeoutException>()));

      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a caller-set timeout shorter than the read budget still wins', () {
      final store = AppCheckStore(
        'held.db',
        operationTimeout: const Duration(milliseconds: 50),
      );

      expect(store.readTimeout, const Duration(milliseconds: 50));
    });

    test('modified() swallows the stall and reports unavailable', () async {
      final store = AppCheckStore(
        'held.db',
        factory: _StalledFactory(),
        readTimeout: const Duration(milliseconds: 40),
      );

      expect(await store.modified(), isNull);
      expect(store.isAvailable, isFalse);
    });

    test('the store retries once the cooldown has passed', () async {
      final factory = _FailingFactory();
      final store = AppCheckStore(
        'held.db',
        factory: factory,
        readTimeout: const Duration(milliseconds: 40),
        failureCooldown: const Duration(milliseconds: 80),
      );

      await expectLater(store.read(), throwsA(isA<StateError>()));
      expect(store.isAvailable, isFalse);
      // Still inside the cooldown: the cached failure is reused rather than
      // touching the database again.
      await expectLater(store.read(), throwsA(isA<StateError>()));
      expect(factory.opens, 1);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(store.isAvailable, isTrue);
      await expectLater(store.read(), throwsA(isA<StateError>()));
      expect(factory.opens, 2);
    });
  });
}
