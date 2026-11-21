import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';

// The test binding (flutter_test_config.dart) answers every HttpClient
// request with a 400; these talk to a local server.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  late HttpOverrides? previousOverrides;
  setUpAll(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
  });
  tearDownAll(() => HttpOverrides.global = previousOverrides);

  // Header probes read only the headers of a GET. They must drop the
  // connection instead of leaving the body unread on an open socket (#3413).
  group('header probes', () {
    const size = 64 * 1024 * 1024;
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        response.headers.set(HttpHeaders.etagHeader, '"abc"');
        response.contentLength = size;
        final chunk = List<int>.filled(64 * 1024, 0);
        try {
          for (var sent = 0; sent < size; sent += chunk.length) {
            response.add(chunk);
            await response.flush();
          }
          await response.close();
        } catch (_) {
          // The client dropped the connection, which is what the probes do.
        }
      });
    });

    tearDown(() => server.close(force: true));

    String url() => 'http://127.0.0.1:${server.port}/app.apk';

    Future<void> expectConnectionClosed() async {
      for (var i = 0; i < 50 && server.connectionsInfo().total > 0; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      expect(server.connectionsInfo().total, 0);
    }

    test('getDownloadSize closes its connection', () async {
      expect(await getDownloadSize(url()), size);
      await expectConnectionClosed();
    });

    // ObtainX's probes take the URL directly, not upstream's settings map.
    test('checkETagHeader closes its connection', () async {
      expect(await checkETagHeader(url()), isNotNull);
      await expectConnectionClosed();
    });

    test('probeDownloadResponseMetadata closes its connection', () async {
      expect(await probeDownloadResponseMetadata(url()), isNotNull);
      await expectConnectionClosed();
    });
  });
}
