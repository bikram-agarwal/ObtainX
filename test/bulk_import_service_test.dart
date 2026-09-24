import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/bulk_import_service.dart';

class _LocalStoreHttpOverrides extends HttpOverrides {
  _LocalStoreHttpOverrides(this.port, {this.host = 'tapi.pureapk.com'});
  final int port;
  final String host;
  int clientsCreated = 0;
  int clientsClosed = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clientsCreated++;
    return _LocalStoreHttpClient(super.createHttpClient(context), this);
  }
}

class _LocalStoreHttpClient implements HttpClient {
  _LocalStoreHttpClient(this.client, this.overrides);
  final HttpClient client;
  final _LocalStoreHttpOverrides overrides;

  @override
  set maxConnectionsPerHost(int? value) {
    client.maxConnectionsPerHost = value;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    expect(url.host, overrides.host);
    return client.openUrl(
      method,
      url.replace(scheme: 'http', host: '127.0.0.1', port: overrides.port),
    );
  }

  @override
  void close({bool force = false}) {
    overrides.clientsClosed++;
    client.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('APKPure scans', () {
    late HttpServer server;
    late _LocalStoreHttpOverrides overrides;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      overrides = _LocalStoreHttpOverrides(server.port);
    });
    tearDown(() async {
      await server.close(force: true);
      expect(overrides.clientsClosed, overrides.clientsCreated);
    });

    test(
      'parallel scans share the device limit and reuse connections',
      () async {
        final firstBatch = Completer<void>();
        final releaseBatch = Completer<void>();
        addTearDown(() {
          if (!releaseBatch.isCompleted) releaseBatch.complete();
        });
        final remotePorts = <int>{};
        int activeRequests = 0;
        int peakRequests = 0;
        int requests = 0;
        server.listen((request) async {
          requests++;
          activeRequests++;
          if (activeRequests > peakRequests) peakRequests = activeRequests;
          remotePorts.add(request.connectionInfo!.remotePort);
          expect(request.headers.value('Ual-Access-Businessid'), 'projecta');
          if (requests == 2) firstBatch.complete();
          await releaseBatch.future;
          request.response.write('{"version_list":[{"title":"Example App"}]}');
          activeRequests--;
          await request.response.close();
        });
        await HttpOverrides.runWithHttpOverrides(() async {
          final progress = <int>[];
          final first = BulkImportService.checkApkPure(
            ['known', 'one', 'two', 'three', 'four', 'five', 'six'],
            alreadyKnown: {'known': null},
            onProgress: (done, total) {
              expect(total, 7);
              progress.add(done);
            },
          );
          final second = BulkImportService.checkApkPure([
            'seven',
            'eight',
            'nine',
          ]);
          await firstBatch.future.timeout(const Duration(seconds: 5));
          expect(peakRequests, 2);
          releaseBatch.complete();
          final results = await Future.wait([first, second]);
          expect(results.first['known'], isNull);
          expect(results.first['six'], 'https://apkpure.com/example-app/six');
          expect(results.last['nine'], 'https://apkpure.com/example-app/nine');
          expect(progress, [1, 2, 3, 4, 5, 6, 7]);
        }, overrides);
        expect(peakRequests, 2);
        expect(requests, 9);
        expect(overrides.clientsCreated, 2);
        expect(remotePorts.length, lessThanOrEqualTo(4));
      },
    );

    test(
      'cancellation leaves unqueried candidates absent from the cache',
      () async {
        bool canceled = false;
        final queried = <String?>[];
        server.listen((request) async {
          queried.add(request.uri.queryParameters['package_name']);
          canceled = true;
          request.response.write('{"version_list":[]}');
          await request.response.close();
        });
        final result = await HttpOverrides.runWithHttpOverrides(
          () => BulkImportService.checkApkPure([
            'org.example.fdroid',
          ], shouldAbort: () => canceled),
          overrides,
        );
        expect(queried, ['org.example.fdroid']);
        expect(result, isEmpty);
      },
    );

    test(
      'missing titles stay unavailable and fallback package IDs still work',
      () async {
        server.listen((request) async {
          final packageName = request.uri.queryParameters['package_name'];
          request.response.write(
            packageName == 'org.example'
                ? '{"version_list":[{"title":"Example App"}]}'
                : '{"version_list":[{"title":""}]}',
          );
          await request.response.close();
        });
        final result = await HttpOverrides.runWithHttpOverrides(
          () => BulkImportService.checkApkPure(['org.example.fdroid', 'stub']),
          overrides,
        );
        expect(result, {
          'org.example.fdroid': 'https://apkpure.com/example-app/org.example',
          'stub': null,
        });
      },
    );

    test(
      'a failed lookup still propagates its error and closes the client',
      () async {
        server.listen((request) async {
          request.response.write('invalid JSON');
          await request.response.close();
        });
        await HttpOverrides.runWithHttpOverrides(() async {
          await expectLater(
            BulkImportService.checkApkPure(['example']),
            throwsFormatException,
          );
        }, overrides);
      },
    );
  });

  group('F-Droid scans', () {
    late HttpServer server;
    late _LocalStoreHttpOverrides overrides;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      overrides = _LocalStoreHttpOverrides(server.port, host: 'f-droid.org');
    });
    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'only a 404 is absent; a lookup that could not tell is left out',
      () async {
        server.listen((request) async {
          final String packageName = request.uri.pathSegments.last;
          switch (packageName) {
            case 'org.example.present':
              request.response.write('{}');
            case 'org.example.flaky':
              request.response.statusCode = 503;
            case 'org.example.dropped':
              // The connection dies before any answer.
              (await request.response.detachSocket()).destroy();
              return;
            default:
              // org.example.absent, and the base ID org.example that the
              // '.gh' flavor is also looked up under.
              request.response.statusCode = 404;
          }
          await request.response.close();
        });

        final result = await HttpOverrides.runWithHttpOverrides(
          () => BulkImportService.checkFDroid([
            'org.example.present',
            'org.example.absent',
            'org.example.flaky',
            'org.example.dropped',
            'org.example.gh',
          ]),
          overrides,
        );

        expect(result, {
          'org.example.present':
              'https://f-droid.org/packages/org.example.present/',
          'org.example.absent': null,
          // Its own ID and its base ID both got a 404.
          'org.example.gh': null,
        });
      },
    );

    test('a failed flavor lookup leaves the package unknown', () async {
      // The package's own ID is not on F-Droid, but its base ID couldn't be
      // checked, so there may still be a listing to show.
      server.listen((request) async {
        request.response.statusCode =
            request.uri.pathSegments.last == 'org.example.gh' ? 404 : 503;
        await request.response.close();
      });

      final result = await HttpOverrides.runWithHttpOverrides(
        () => BulkImportService.checkFDroid(['org.example.gh']),
        overrides,
      );

      expect(result, isEmpty);
    });
  });

  group('IzzyOnDroid scans', () {
    late HttpServer server;
    late _LocalStoreHttpOverrides overrides;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      overrides = _LocalStoreHttpOverrides(
        server.port,
        host: 'apt.izzysoft.de',
      );
    });
    tearDown(() async {
      await server.close(force: true);
    });

    test('the per-package fallback leaves a failed lookup out', () async {
      server.listen((request) async {
        final String last = request.uri.pathSegments.last;
        if (last == 'index.xml') {
          // Forces the per-package API fallback.
          request.response.statusCode = 503;
        } else if (last == 'org.example.present') {
          request.response.write('{"suggestedVersionCode": 5}');
        } else if (last == 'org.example.flaky') {
          request.response.statusCode = 503;
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });

      final result = await HttpOverrides.runWithHttpOverrides(
        () => BulkImportService.checkIzzyOnDroid([
          'org.example.present',
          'org.example.absent',
          'org.example.flaky',
        ]),
        overrides,
      );

      expect(result, {
        'org.example.present':
            'https://apt.izzysoft.de/fdroid/repo/org.example.present_5.apk',
        'org.example.absent': null,
      });
    });

    test('a cancelled scan records nothing for unchecked packages', () async {
      final result = await HttpOverrides.runWithHttpOverrides(
        () => BulkImportService.checkIzzyOnDroid(
          ['org.example.unchecked', 'org.example.known'],
          alreadyKnown: {'org.example.known': null},
          shouldAbort: () => true,
        ),
        overrides,
      );

      expect(result, {'org.example.known': null});
    });
  });

  group('APKMirror availability metadata', () {
    test('extracts icon URL from the existing availability response', () {
      final item = <String, dynamic>{
        'pname': 'eu.darken.sdmse',
        'exists': true,
        'app': <String, dynamic>{
          'link': '/apk/darken/sd-maid-2-se-system-cleaner/',
          'icon_url': ' https://cdn.example.com/sd-maid-se.png ',
        },
      };

      expect(
        apkMirrorIconUrlFromAvailabilityItem(item),
        'https://cdn.example.com/sd-maid-se.png',
      );
    });

    test('ignores missing or empty icon URLs', () {
      expect(
        apkMirrorIconUrlFromAvailabilityItem(<String, dynamic>{
          'app': <String, dynamic>{'icon_url': '   '},
        }),
        isNull,
      );
      expect(apkMirrorIconUrlFromAvailabilityItem(null), isNull);
    });
  });
}
