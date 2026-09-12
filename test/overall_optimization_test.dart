import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/favicon_cache.dart';
import 'package:obtainium/app_sources/direct_apk_link.dart';
import 'package:obtainium/http/response_bytes.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/app_check_store.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:obtainium/version/partial_download_version.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _StorageProvider implements AppsProvider {
  @override
  Map<String, AppInMemory> apps = {};
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
  final settingsProvider = SettingsProvider();
  @override
  LogsProvider logs = LogsProvider(runDefaultClear: false);
  @override
  Future<void> waitForAppsToLoad() async {}
  @override
  void markAppsChanged() {}
  @override
  void notify() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

App _app() {
  return App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    latestVersion: '1.0',
    preferredApkIndex: 0,
    additionalSettings: {
      'nested': {
        'value': [1, 2],
      },
    },
    lastUpdateCheck: DateTime.utc(2026, 1, 1),
  );
}

Future<Directory> _tempDirectory() async {
  final directory = await Directory.systemTemp.createTemp(
    'obtainx-optimization-',
  );
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.imranr.obtainium/power'),
    (_) async => true,
  );

  test(
    'byte prefix is independent of chunks and cancels at the byte limit',
    () async {
      bool canceled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          canceled = true;
        },
      );
      final result = readBytePrefix(stream.stream, 4);
      stream.add([1, 2]);
      stream.add([3, 4, 5, 6, 7]);
      expect(await result, [1, 2, 3, 4]);
      expect(canceled, isTrue);
      await stream.close();
      expect(await readBytePrefix(Stream.value([1, 2, 3, 4, 5]), 4), [
        1,
        2,
        3,
        4,
      ]);
      expect(await readBytePrefix(Stream.value([1]), 4), [1]);
    },
  );

  test(
    'a stalled prefix reader times out and releases its subscription',
    () async {
      bool canceled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          canceled = true;
        },
      );
      await expectLater(
        readBytePrefix(
          stream.stream,
          4,
          idleTimeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(canceled, isTrue);
      await stream.close();
    },
  );

  test(
    'APK hash ignores transport layout and servers that ignore Range',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final ranges = <String?>[];
        server.listen((request) async {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          request.response.add(List.generate(10000, (index) => index % 256));
          await request.response.close();
        });
        final hash = await checkPartialDownloadHash(
          'http://127.0.0.1:${server.port}/app.apk',
          16,
        );
        expect(ranges, ['bytes=0-15']);
        expect(
          hash,
          'sha256:16:${sha256.convert(List.generate(16, (index) => index))}',
        );
      }, _RealHttpOverrides());
    },
  );

  test('legacy hash migration retains labels, then detects a byte change', () {
    final settings = <String, dynamic>{};
    String resolve(String hash, {String url = 'https://example.com/app.apk'}) {
      return resolvePartialDownloadVersion(
        fingerprint: hash,
        downloadUrl: url,
        settings: settings,
        previousVersion: 'abc12345',
        samePreviousDownload: true,
      );
    }

    expect(resolve('sha256:1024:first'), 'abc12345');
    expect(resolve('sha256:1024:first'), 'abc12345');
    expect(resolve('sha256:1024:second'), 'sha256:1024:second');
    expect(resolve('sha256:1024:first'), 'sha256:1024:first');
    expect(
      resolve('sha256:1024:first', url: 'https://example.com/new.apk'),
      'sha256:1024:first',
    );
    final newSettings = <String, dynamic>{};
    expect(
      resolvePartialDownloadVersion(
        fingerprint: 'new',
        downloadUrl: 'new-url',
        settings: newSettings,
        previousVersion: 'abc12345',
      ),
      'new',
    );
  });

  test(
    'direct APK sources preserve the migration baseline through their HTML delegate',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        int contentByte = 1;
        server.listen((request) async {
          request.response.add(List.filled(3000, contentByte));
          await request.response.close();
        });
        final url = 'http://127.0.0.1:${server.port}/app.apk';
        final settings = <String, dynamic>{
          'defaultPseudoVersioningMethod': 'partialAPKHash',
        };
        final source = DirectAPKLink()
          ..previouslyCheckedApp = _app().copyWith(
            url: url,
            latestVersion: 'abc12345',
            installedVersion: 'abc12345',
            apkUrls: [MapEntry('app.apk', url)],
            additionalSettings: settings,
          );
        final first = await source.getLatestAPKDetails(url, settings);
        expect(first.version, 'abc12345');
        expect(settings[partialDownloadFingerprintKey], isA<Map>());
        final second = await source.getLatestAPKDetails(url, settings);
        expect(second.version, first.version);
        contentByte = 2;
        final changed = await source.getLatestAPKDetails(url, settings);
        expect(changed.version, isNot(first.version));
        final live = source.previouslyCheckedApp!;
        final merged = mergeFetchedUpdateWithLiveState(
          requestedApp: live,
          liveApp: live,
          fetchedApp: live.copyWith(
            latestVersion: changed.version,
            additionalSettings: settings,
          ),
        )!;
        expect(
          merged.additionalSettings[partialDownloadFingerprintKey],
          settings[partialDownloadFingerprintKey],
        );
        expect(merged.installedVersion, 'abc12345');
      }, _RealHttpOverrides());
    },
  );

  test('optimized version-list policy matches all-pairs compatibility', () {
    final labels = [
      '',
      ' ',
      'nightly',
      ' NIGHTLY ',
      '1',
      '01',
      '1.0',
      '1.0.0',
      '1.00.0+metadata',
      '1.0 (2)',
      '1.0-02',
      '1.0-3',
      '1.0-beta',
      '1.0-beta.0',
      '1.0-beta.00',
      '1.0-beta.1',
      '1.0-beta.alpha',
      '1.0-rc.1',
      '2.0',
      '1.0-a4d75424',
      '1.0-9df4c85',
      '2.0-a4d75424',
      '1.0-foss',
      '2.0-foss',
      '2026-01-01',
      '2026-02-01',
      '1777370225000000',
      'App 1.0',
      'App 1.0 and 2.0',
    ];
    final random = Random(532);
    for (int sample = 0; sample < 1500; sample++) {
      final selection = List.generate(
        1 + random.nextInt(8),
        (_) => labels[random.nextInt(labels.length)],
      ).toSet().toList();
      bool comparable = true;
      for (int firstIndex = 0; firstIndex < selection.length; firstIndex++) {
        for (
          int secondIndex = firstIndex + 1;
          secondIndex < selection.length;
          secondIndex++
        ) {
          comparable &=
              compareVersionStrings(
                selection[firstIndex],
                selection[secondIndex],
              ).relation !=
              VersionRelation.unknown;
        }
      }
      expect(
        versionsHaveConsistentOrder(selection),
        comparable,
        reason: selection.toString(),
      );
    }
    expect(
      versionsHaveConsistentOrder(
        List.generate(10000, (index) => '1.$index.0'),
      ),
      isTrue,
    );
  });

  test(
    'fresh downloads reuse the first GET and keep the exact file bytes',
    () async {
      final directory = await _tempDirectory();
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        int requests = 0;
        final content = List.generate(100000, (index) => index % 256);
        server.listen((request) async {
          requests++;
          request.response.contentLength = content.length;
          request.response.add(content);
          await request.response.close();
        });
        final downloaded = await downloadFile(
          'http://127.0.0.1:${server.port}/app.apk',
          'app.apk',
          true,
          null,
          directory.path,
        );
        expect(await downloaded.readAsBytes(), content);
        expect(requests, 1);
        expect(await File('${downloaded.path}.part').exists(), isFalse);
      }, _RealHttpOverrides());
    },
  );

  test('cancel interrupts a download waiting for response headers', () async {
    final directory = await _tempDirectory();
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requested = Completer<void>();
      server.listen((request) {
        requested.complete();
      });
      final token = CancellationToken();
      final download = downloadFile(
        'http://127.0.0.1:${server.port}/app.apk',
        'app.apk',
        true,
        null,
        directory.path,
        cancellationToken: token,
      );
      final assertion = expectLater(
        download,
        throwsA(isA<CancellationException>()),
      );
      await requested.future;
      token.cancel();
      await assertion.timeout(const Duration(seconds: 2));
    }, _RealHttpOverrides());
  });

  test('shared HTTP service has bounded header and body waits', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/body') {
          request.response.write('prefix');
          await request.response.flush();
        }
      });
      final service = HttpService(
        responseTimeout: const Duration(milliseconds: 80),
      );
      final url = 'http://127.0.0.1:${server.port}';
      await expectLater(
        service.sourceRequestStreamResponse('GET', '$url/headers', null, {}),
        throwsA(isA<TimeoutException>()),
      );
      final streamed = await service.sourceRequestStreamResponse(
        'GET',
        '$url/body',
        null,
        {},
      );
      await expectLater(
        service.httpClientResponseStreamToFinalResponse(
          streamed.value.key,
          'GET',
          '$url/body',
          streamed.value.value,
        ),
        throwsA(isA<TimeoutException>()),
      );
    }, _RealHttpOverrides());
  });

  test(
    'cancel releases a download waiting on an existing partial file',
    () async {
      final directory = await _tempDirectory();
      final partial = await File(
        '${directory.path}/app.apk.part',
      ).writeAsBytes([1, 2]);
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final served = Completer<void>();
        server.listen((request) async {
          request.response.add(List.filled(10, 1));
          await request.response.close();
          served.complete();
        });
        final token = CancellationToken();
        final download = downloadFile(
          'http://127.0.0.1:${server.port}/app.apk',
          'app.apk',
          true,
          null,
          directory.path,
          cancellationToken: token,
        );
        final assertion = expectLater(
          download,
          throwsA(isA<CancellationException>()),
        );
        await served.future;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        token.cancel();
        await assertion.timeout(const Duration(seconds: 2));
        expect(await partial.readAsBytes(), [1, 2]);
      }, _RealHttpOverrides());
    },
  );

  test(
    'HTTP-compressed downloads validate the decoded artifact correctly',
    () async {
      final directory = await _tempDirectory();
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final content = List.filled(10000, 42);
        final compressed = gzip.encode(content);
        server.listen((request) async {
          request.response.headers.set(
            HttpHeaders.contentEncodingHeader,
            'gzip',
          );
          request.response.contentLength = compressed.length;
          request.response.add(compressed);
          await request.response.close();
        });
        final file = await downloadFile(
          'http://127.0.0.1:${server.port}/app.apk',
          'app.apk',
          true,
          null,
          directory.path,
        );
        expect(await file.readAsBytes(), content);
      }, _RealHttpOverrides());
    },
  );

  test('only timestamp changes qualify for compact persistence', () {
    final original = _app();
    final checked = original.copyWith(
      lastUpdateCheck: DateTime.utc(2026, 2, 1),
    );
    expect(onlyAppCheckTimeChanged(original, checked), isTrue);
    for (final changed in [
      checked.copyWith(latestVersion: '2.0'),
      checked.copyWith(installedVersion: '1.0'),
      checked.copyWith(pinned: true),
      checked.copyWith(
        additionalSettings: {
          'nested': {
            'value': [1, 3],
          },
        },
      ),
      checked.copyWith(
        apkUrls: [const MapEntry('new.apk', 'https://example.com/new')],
      ),
      checked.copyWith(lastUpdateCheck: null),
    ]) {
      expect(onlyAppCheckTimeChanged(original, changed), isFalse);
    }
  });

  test(
    'saving a check keeps JSON untouched and targeted reload sees the timestamp',
    () async {
      SharedPreferences.setMockInitialValues({
        'folderCriteriaMigrationVersion': 1000,
      });
      final directory = await _tempDirectory();
      final provider = _StorageProvider()
        ..cachedAppsDir = directory
        ..appCheckStore = AppCheckStore('${directory.path}/checks.db');
      provider.settingsProvider.prefs = await SharedPreferences.getInstance();
      addTearDown(() async {
        await provider.appCheckStore?.close();
      });
      final calls = <MethodCall>[];
      const channel = MethodChannel('dev.imranr.obtainium/device_apps');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'getInstalledPackageInfo') return null;
        throw StateError('A targeted load must not enumerate installed apps');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await provider.saveApps(
        [_app()],
        onlyIfExists: false,
        attemptToCorrectInstallStatus: false,
        updateInstalledInfo: false,
        autoExportAfterSave: false,
      );
      final file = File('${directory.path}/${_app().id}.json');
      final originalJson = await file.readAsString();
      final originalStat = await file.stat();
      final timestamp = DateTime.utc(2026, 3, 1);
      final checked = provider.apps[_app().id]!.app.copyWith(
        lastUpdateCheck: timestamp,
      );
      await provider.saveApps(
        [checked],
        attemptToCorrectInstallStatus: false,
        updateInstalledInfo: false,
        autoExportAfterSave: false,
      );
      expect(await file.readAsString(), originalJson);
      expect((await file.stat()).modified, originalStat.modified);
      provider.apps.clear();
      await provider.loadApps(singleId: _app().id, silent: true);
      expect(provider.apps[_app().id]!.app.lastUpdateCheck?.toUtc(), timestamp);
      expect(calls.map((call) => call.method), ['getInstalledPackageInfo']);
      // Restoring an older record must also restore its own timestamp.
      final restored = jsonDecode(originalJson) as Map<String, dynamic>;
      restored[appRecordRevisionKey] = 'restored-record';
      await file.writeAsString(jsonEncode(restored));
      await provider.loadApps(singleId: _app().id, silent: true);
      expect(
        provider.apps[_app().id]!.app.lastUpdateCheck?.toUtc(),
        _app().lastUpdateCheck,
      );
      final beforeFailure = provider.apps[_app().id];
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'PACKAGE_QUERY_FAILED');
      });
      await expectLater(
        provider.loadApps(singleId: _app().id, silent: true),
        throwsA(isA<PlatformException>()),
      );
      expect(identical(provider.apps[_app().id], beforeFailure), isTrue);
    },
  );

  test(
    'resume reloads only changed tracked packages with a full-scan fallback',
    () {
      final now = DateTime.utc(2026, 3, 1, 12);
      List<String>? plan({
        DateTime? lastFull,
        bool diskChanged = false,
        bool backgroundSaved = false,
        List<String>? changes = const [],
      }) {
        return appIdsForResumeReload(
          now: now,
          lastFullLoad: lastFull ?? now,
          diskChanged: diskChanged,
          backgroundSaved: backgroundSaved,
          changedPackages: changes,
          trackedIds: {'tracked', 'second'},
        );
      }

      expect(plan(), isEmpty);
      expect(plan(changes: ['untracked', 'tracked', 'tracked']), ['tracked']);
      expect(plan(diskChanged: true), isNull);
      expect(plan(backgroundSaved: true), isNull);
      expect(plan(changes: null), isNull);
      expect(plan(lastFull: now.subtract(const Duration(minutes: 5))), isNull);
    },
  );

  for (final behavior in [
    'resume',
    'ignore-range',
    'wrong-range',
    'failed-resume',
  ]) {
    test(
      'partial download handles $behavior without corrupting the APK',
      () async {
        final directory = await _tempDirectory();
        final content = List.generate(200, (index) => index);
        final partial = await File(
          '${directory.path}/app.apk.part',
        ).writeAsBytes(content.take(40).toList());
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final ranges = <String?>[];
          server.listen((request) async {
            final range = request.headers.value(HttpHeaders.rangeHeader);
            ranges.add(range);
            request.response.headers.set(
              HttpHeaders.acceptRangesHeader,
              'bytes',
            );
            if (range != null && behavior == 'failed-resume') {
              request.response.statusCode = HttpStatus.serviceUnavailable;
              await request.response.close();
              return;
            }
            if (range != null && behavior != 'ignore-range') {
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                HttpHeaders.contentRangeHeader,
                behavior == 'wrong-range'
                    ? 'bytes 0-159/200'
                    : 'bytes 40-199/200',
              );
              request.response.contentLength = 160;
              request.response.add(content.sublist(40));
            } else {
              request.response.contentLength = content.length;
              request.response.add(content);
            }
            await request.response.close();
          });
          final download = downloadFile(
            'http://127.0.0.1:${server.port}/app.apk',
            'app.apk',
            true,
            null,
            directory.path,
          );
          if (behavior == 'wrong-range' || behavior == 'failed-resume') {
            await expectLater(
              download,
              throwsA(
                isA<ObtainiumError>().having(
                  (error) => error.code,
                  'code',
                  behavior == 'wrong-range'
                      ? 'INVALID_CONTENT_RANGE'
                      : 'HTTP_ERROR',
                ),
              ),
            );
            expect(await partial.readAsBytes(), content.take(40).toList());
            expect(await File('${directory.path}/app.apk').exists(), isFalse);
          } else {
            expect(await (await download).readAsBytes(), content);
          }
          expect(ranges, [null, 'bytes=40-199']);
        }, _RealHttpOverrides());
      },
    );
  }

  test(
    'check timestamps survive restart without leaking across record revisions',
    () async {
      final directory = await _tempDirectory();
      final path = '${directory.path}/checks.db';
      final store = AppCheckStore(path);
      final timestamp = DateTime.utc(2026, 2, 1).microsecondsSinceEpoch;
      await store.save([
        {'id': 'org.example.app', 'revision': 'first', 'checked': timestamp},
      ]);
      await store.close();
      final reopened = AppCheckStore(path);
      addTearDown(reopened.close);
      final checkpoints = await reopened.read();
      final matching = _app().toJson()..[appRecordRevisionKey] = 'first';
      reopened.apply(matching, checkpoints);
      expect(matching['lastUpdateCheck'], timestamp);
      final replaced = _app().toJson()..[appRecordRevisionKey] = 'second';
      reopened.apply(replaced, checkpoints);
      expect(
        replaced['lastUpdateCheck'],
        _app().lastUpdateCheck!.microsecondsSinceEpoch,
      );
      final legacy = _app().toJson();
      reopened.apply(legacy, checkpoints);
      expect(
        legacy['lastUpdateCheck'],
        _app().lastUpdateCheck!.microsecondsSinceEpoch,
      );
    },
  );

  test(
    'favicons share pending work and retry temporary failures after expiry',
    () async {
      final directory = await _tempDirectory();
      var time = DateTime.now();
      int requests = 0;
      final gate = Completer<http.Response>();
      final store = FaviconCacheStore(
        directory: () async => directory,
        now: () => time,
        allowFallback: false,
        clientFactory: () => MockClient((_) async {
          requests++;
          return requests == 1
              ? gate.future
              : http.Response.bytes(
                  [1, 2, 3],
                  200,
                  headers: {'content-type': 'image/png'},
                );
        }),
      );
      final first = store.get('example.com');
      final second = store.get(' EXAMPLE.COM ');
      gate.complete(http.Response('', 503));
      expect(await first, isNull);
      expect(await second, isNull);
      expect(requests, 1);
      expect(await store.get('example.com'), isNull);
      time = time.add(const Duration(minutes: 6));
      expect(await store.get('example.com'), [1, 2, 3]);
      expect(await store.get('example.com'), [1, 2, 3]);
      expect(requests, 2);
    },
  );

  test('oversized favicons are rejected instead of cached', () async {
    final directory = await _tempDirectory();
    final store = FaviconCacheStore(
      directory: () async => directory,
      allowFallback: false,
      clientFactory: () => MockClient(
        (_) async => http.Response.bytes(
          Uint8List(FaviconCacheStore.maxIconBytes + 1),
          200,
          headers: {'content-type': 'image/png'},
        ),
      ),
    );
    expect(await store.get('example.com'), isNull);
    expect(await directory.list().toList(), isEmpty);
  });

  test('favicon disk cache stays bounded and evicts expired files', () async {
    final directory = await _tempDirectory();
    final expired = await File(
      '${directory.path}/expired.ico',
    ).writeAsString('old');
    await expired.setLastModified(
      DateTime.now().subtract(const Duration(days: 8)),
    );
    final store = FaviconCacheStore(
      directory: () async => directory,
      allowFallback: false,
      clientFactory: () => MockClient(
        (_) async => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/png'},
        ),
      ),
    );
    for (int index = 0; index < 140; index++) {
      expect(await store.get('host$index.example.com'), isNotNull);
    }
    expect(await expired.exists(), isFalse);
    expect(
      (await directory.list().toList()).length,
      FaviconCacheStore.maxEntries,
    );
  });
}
