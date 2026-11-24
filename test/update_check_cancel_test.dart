// Platform test doubles use the interfaces supplied by the existing plugins.
// ignore_for_file: depend_on_referenced_packages

// v1.7.5 sync U1 (upstream #698's cancel): the Stop on the "checking for
// updates" notification cancels the running check. The apps already being
// checked finish and are saved; the rest keep their lastUpdateCheck for the
// next check, and the check returns normally, so runUpdateCheckKeptAlive's
// finally releases the keep-alive service.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/app_check_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// A low-RAM device, so the check runs two workers at a time.
class _Device extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    return BaseDeviceInfo({
      'version': {
        'sdkInt': 35,
        'release': '15',
        'codename': 'REL',
        'incremental': '1',
        'previewSdkInt': 0,
        'securityPatch': '',
        'baseOS': '',
      },
      for (final key in [
        'board',
        'bootloader',
        'brand',
        'device',
        'display',
        'fingerprint',
        'hardware',
        'host',
        'id',
        'manufacturer',
        'model',
        'product',
        'tags',
      ])
        key: '',
      'type': 'user',
      'supported32BitAbis': ['armeabi-v7a'],
      'supported64BitAbis': ['arm64-v8a'],
      'supportedAbis': ['arm64-v8a', 'armeabi-v7a'],
      'isPhysicalDevice': true,
      'freeDiskSize': 1,
      'totalDiskSize': 1,
      'physicalRamSize': 2048,
      'availableRamSize': 1024,
      'time': 0,
      'isLowRamDevice': true,
      'systemFeatures': <String>[],
    });
  }
}

class _Logs extends Fake implements LogsProvider {
  @override
  Future<Log> add(String message, {LogLevel level = LogLevel.info}) async {
    return Log(message, level);
  }
}

class _LocalSources extends HttpOverrides {
  _LocalSources(this.port);
  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _LocalClient(super.createHttpClient(context), port);
  }
}

class _LocalClient extends Fake implements HttpClient {
  _LocalClient(this.client, this.port);
  final HttpClient client;
  final int port;

  @override
  set connectionTimeout(Duration? value) {
    client.connectionTimeout = value;
  }

  @override
  set maxConnectionsPerHost(int? value) {
    client.maxConnectionsPerHost = value;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    expect(url.host, 'api.github.com');
    return client.openUrl(
      method,
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) {
    client.close(force: force);
  }
}

class _Apps extends ChangeNotifier implements AppsProvider {
  _Apps(this.settingsProvider, Directory directory)
    : cachedAppsDir = directory,
      appCheckStore = AppCheckStore('${directory.path}/checks.db');

  @override
  final AppListings apps = AppListings();
  @override
  final SettingsProvider settingsProvider;
  @override
  Directory? cachedAppsDir;
  @override
  AppCheckStore? appCheckStore;
  @override
  DateTime? appDirectoryModifiedAt;
  @override
  DateTime? appCheckStoreModifiedAt;
  @override
  final LogsProvider logs = _Logs();
  @override
  Completer<List<App>>? updateCheckCompleter;
  @override
  CancellationToken? updateCheckCancellation;
  @override
  double? refreshProgress;

  /// As [AppsProvider.cancelUpdateCheck].
  @override
  void cancelUpdateCheck() => updateCheckCancellation?.cancel();

  @override
  void markAppsChanged() => notifyListeners();

  @override
  void notify() => notifyListeners();

  @override
  void scheduleAutoExport() {}

  @override
  void finishPendingAutoExport() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A GitHub API stand-in. Release lists of the repos in [hold] wait for
/// [release]; [held] completes once all of them have been asked for.
class _Server {
  _Server._(this._server, this.hold) {
    _server.listen(_answer);
  }

  static Future<_Server> start({Set<String> hold = const {}}) async {
    return _Server._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      hold,
    );
  }

  final HttpServer _server;
  final Set<String> hold;
  final List<String> releaseRequests = [];
  final Completer<void> held = Completer<void>();
  final Completer<void> _release = Completer<void>();

  int get port => _server.port;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _answer(HttpRequest request) async {
    final String repo = request.uri.path.split('/')[3];
    final bool releases = request.uri.path.contains('/releases');
    if (releases) {
      releaseRequests.add(repo);
      if (hold.contains(repo)) {
        if (releaseRequests.toSet().containsAll(hold) && !held.isCompleted) {
          held.complete();
        }
        await _release.future;
      }
    }
    final release = {
      'tag_name': '2.0',
      'name': '2.0',
      'prerelease': false,
      'draft': false,
      'body': '',
      'published_at': '2026-11-01T00:00:00Z',
      'assets': [
        {
          'name': '$repo.apk',
          'size': 1024,
          'browser_download_url':
              'https://github.com/example/$repo/releases/download/2.0/$repo.apk',
        },
      ],
    };
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(
        releases
            ? (request.uri.path.endsWith('/latest') ? release : [release])
            : {'full_name': 'example/$repo', 'name': repo},
      ),
    );
    await request.response.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SettingsProvider settings;
  late _Apps provider;
  late PathProviderPlatform previousPaths;
  late DeviceInfoPlatform previousDevice;
  final DateTime checkedBefore = DateTime.utc(2026, 11, 1);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('obtainx-cancel-check-');
    previousPaths = PathProviderPlatform.instance;
    previousDevice = DeviceInfoPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    DeviceInfoPlatform.instance = _Device();
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _Apps(settings, directory);
    // Checked oldest first: a0, a1, then a2, a3, then b0.
    for (final (int order, String repo) in [
      (0, 'a0'),
      (1, 'a1'),
      (2, 'a2'),
      (3, 'a3'),
      (4, 'b0'),
    ]) {
      final App app = App(
        id: 'org.example.$repo',
        url: 'https://github.com/example/$repo',
        author: 'Example',
        name: repo,
        installedVersion: '1.0',
        latestVersion: '1.0',
        preferredApkIndex: 0,
        additionalSettings: {'trackOnly': true, 'versionDetection': 'auto'},
        lastUpdateCheck: checkedBefore.add(Duration(minutes: order)),
      );
      provider.apps[app.listingKey] = AppInMemory(app, null, null, null);
    }
  });

  tearDown(() async {
    await provider.appCheckStore?.close();
    provider.dispose();
    settings.dispose();
    PathProviderPlatform.instance = previousPaths;
    DeviceInfoPlatform.instance = previousDevice;
    await directory.delete(recursive: true);
  });

  DateTime? lastCheck(String repo) =>
      provider.apps['org.example.$repo']!.app.lastUpdateCheck;

  test('a Stop lets the apps in flight finish and leaves the rest', () async {
    final _Server server = await _Server.start(hold: {'a0', 'a1'});
    addTearDown(server.close);
    await HttpOverrides.runWithHttpOverrides(() async {
      final Future<List<App>> check = provider.checkUpdates(
        specificIds: [
          for (final r in ['a0', 'a1', 'a2', 'a3']) 'org.example.$r',
        ],
      );
      // Both workers are waiting on a0 and a1.
      await server.held.future;
      expect(provider.updateCheckCancellation, isNotNull);
      provider.cancelUpdateCheck();
      server.release();

      // Returns normally: no error for the apps it didn't get to.
      final List<App> updates = await check;
      expect(updates.map((App a) => a.name).toSet(), {'a0', 'a1'});
    }, _LocalSources(server.port));

    expect(server.releaseRequests.toSet(), {'a0', 'a1'});
    expect(
      lastCheck('a0')!.isAfter(checkedBefore.add(const Duration(hours: 1))),
      isTrue,
    );
    expect(provider.apps['org.example.a1']!.app.latestVersion, '2.0');
    expect(lastCheck('a2'), checkedBefore.add(const Duration(minutes: 2)));
    expect(lastCheck('a3'), checkedBefore.add(const Duration(minutes: 3)));
    expect(provider.apps['org.example.a3']!.app.latestVersion, '1.0');
    expect(provider.updateCheckCancellation, isNull);
    expect(provider.updateCheckCompleter, isNull);
    expect(provider.refreshProgress, isNull);

    // A late Stop (the notification still on screen) has nothing to cancel.
    provider.cancelUpdateCheck();
  });

  test(
    'a Stop cancels only the running check, not one queued behind it',
    () async {
      final _Server server = await _Server.start(hold: {'a0', 'a1'});
      addTearDown(server.close);
      await HttpOverrides.runWithHttpOverrides(() async {
        final Future<List<App>> running = provider.checkUpdates(
          specificIds: [
            for (final r in ['a0', 'a1', 'a2']) 'org.example.$r',
          ],
        );
        await server.held.future;
        final CancellationToken? runningToken =
            provider.updateCheckCancellation;
        // Queued: waits for the running check, then checks its own apps.
        final Future<List<App>> queued = provider.checkUpdates(
          specificIds: ['org.example.b0'],
        );
        provider.cancelUpdateCheck();
        server.release();
        await running;
        expect(runningToken!.isCancelled, isTrue);

        final List<App> queuedUpdates = await queued;
        expect(queuedUpdates.map((App a) => a.name), ['b0']);
      }, _LocalSources(server.port));

      expect(server.releaseRequests.toSet(), {'a0', 'a1', 'b0'});
      expect(lastCheck('a2'), checkedBefore.add(const Duration(minutes: 2)));
      expect(provider.apps['org.example.b0']!.app.latestVersion, '2.0');
      expect(provider.updateCheckCancellation, isNull);
    },
  );
}
