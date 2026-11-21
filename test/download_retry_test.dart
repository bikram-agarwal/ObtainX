import 'dart:async';
import 'dart:io';

import 'package:flutter_fgbg/flutter_fgbg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';

// ObtainX keeps upstream #2894's retry hold only as a fallback for downloads
// running without the native download foreground service, so
// downloadFileWithRetry takes a plain `holdRetry` flag and the wait itself is
// waitForForegroundBeforeRetry.
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

  group('downloadFileWithRetry', () {
    late HttpServer server;
    late Directory destDir;
    late int requests;
    final body = List<int>.generate(4096, (i) => i % 256);

    setUp(() async {
      requests = 0;
      destDir = await Directory.systemTemp.createTemp('download_retry_test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        if (requests == 1) {
          // Drop the first connection, like a download cut off when Android
          // blocks network access for a backgrounded app (#2894). dart:io
          // reports it as an HttpException or SocketException.
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        request.response.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await destDir.delete(recursive: true);
    });

    Future<File> download({required bool holdRetry}) => downloadFileWithRetry(
      'http://127.0.0.1:${server.port}/app.apk',
      'app',
      false,
      null,
      destDir.path,
      holdRetry: holdRetry,
    );

    test('retries a dropped connection', () async {
      final file = await download(holdRetry: false);
      expect(await file.readAsBytes(), body);
      expect(requests, greaterThan(1));
    });

    test('a held retry goes ahead at once while in the foreground', () async {
      // flutter_fgbg starts out in the foreground.
      expect(FGBGEvents.last, FGBGType.foreground);
      final file = await download(holdRetry: true);
      expect(await file.readAsBytes(), body);
      expect(requests, greaterThan(1));
    });
  });

  group('waitForForegroundBeforeRetry', () {
    test('does not wait while in the foreground', () async {
      expect(
        await waitForForegroundBeforeRetry(
          isForeground: () => true,
          events: const Stream<FGBGType>.empty(),
        ),
        isTrue,
      );
    });

    test('holds until the app returns to the foreground', () async {
      final events = StreamController<FGBGType>.broadcast();
      addTearDown(events.close);
      var released = false;
      final wait =
          waitForForegroundBeforeRetry(
            isForeground: () => false,
            events: events.stream,
          ).then((bool retry) {
            released = true;
            return retry;
          });

      await Future<void>.delayed(const Duration(milliseconds: 50));
      events.add(FGBGType.background);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(released, isFalse);

      events.add(FGBGType.foreground);
      expect(await wait, isTrue);
    });

    test('reports the error when the app stays away', () async {
      expect(
        await waitForForegroundBeforeRetry(
          isForeground: () => false,
          events: const Stream<FGBGType>.empty(),
          timeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });

    test('retries when the app is back by the time the wait ends', () async {
      var foreground = false;
      final events = StreamController<FGBGType>.broadcast();
      addTearDown(events.close);
      final wait = waitForForegroundBeforeRetry(
        isForeground: () => foreground,
        events: events.stream,
        timeout: const Duration(milliseconds: 100),
      );
      // Back, but the event was never delivered (a frozen process).
      foreground = true;
      expect(await wait, isTrue);
    });

    test('a cancellation ends the wait at once', () async {
      final events = StreamController<FGBGType>.broadcast();
      addTearDown(events.close);
      final token = CancellationToken();
      final wait = waitForForegroundBeforeRetry(
        cancellationToken: token,
        isForeground: () => false,
        events: events.stream,
      );
      token.cancel();
      await expectLater(
        wait.timeout(const Duration(seconds: 5)),
        throwsA(isA<CancellationException>()),
      );
    });
  });
}
