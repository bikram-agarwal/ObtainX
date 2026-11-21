import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/services/host_request_gate.dart';

void main() {
  group('HostRequestGate', () {
    test('caps per-host concurrency', () async {
      final gate = HostRequestGate();
      var active = 0;
      var maxActive = 0;
      await Future.wait(
        List.generate(6, (_) {
          return gate.run('host-a', 'host-a|api', 2, () async {
            active++;
            maxActive = max(maxActive, active);
            await Future.delayed(const Duration(milliseconds: 20));
            active--;
          });
        }),
      );
      expect(maxActive, 2);
    });

    test('blocks one request class on challenge, not others', () async {
      var now = DateTime.utc(2026, 1, 1);
      final gate = HostRequestGate(now: () => now);
      gate.observe('host-b|html', 403, {'cf-mitigated': 'challenge'});
      expect(
        () => gate.run('host-b', 'host-b|html', 2, () async {}),
        throwsA(isA<RateLimitError>()),
      );
      await gate.run('host-b', 'host-b|api', 2, () async {});
      now = now.add(const Duration(minutes: 6));
      await gate.run('host-b', 'host-b|html', 2, () async {});
    });

    test('honors Retry-After and defaults to 60s', () async {
      var now = DateTime.utc(2026, 1, 1);
      final gate = HostRequestGate(now: () => now);
      gate.observe('host-c|api', 429, {'retry-after': '2'});
      expect(
        () => gate.run('host-c', 'host-c|api', 2, () async {}),
        throwsA(isA<RateLimitError>()),
      );
      now = now.add(const Duration(seconds: 3));
      await gate.run('host-c', 'host-c|api', 2, () async {});

      gate.observe('host-d|feed', 503, {});
      expect(
        () => gate.run('host-d', 'host-d|feed', 2, () async {}),
        throwsA(isA<RateLimitError>()),
      );
      now = now.add(const Duration(seconds: 61));
      await gate.run('host-d', 'host-d|feed', 2, () async {});
    });

    test('plain 403 does not block', () async {
      var now = DateTime.utc(2026, 1, 1);
      final gate = HostRequestGate(now: () => now);
      gate.observe('host-e|api', 403, {});
      await gate.run('host-e', 'host-e|api', 2, () async {});
      now = now.add(const Duration(seconds: 1));
      await gate.run('host-e', 'host-e|api', 2, () async {});
    });
  });

  // ObtainX additions (v1.7.4 sync, #339).
  group('HostRequestGate (ObtainX)', () {
    test('www and bare hosts share one key', () {
      expect(
        HostRequestGate.hostKeyFor(Uri.parse('https://www.apkmirror.com/a/')),
        'apkmirror.com',
      );
      expect(
        HostRequestGate.hostKeyFor(Uri.parse('https://apkmirror.com/a/')),
        'apkmirror.com',
      );
    });

    test('request classes', () {
      String classOf(String url) =>
          HostRequestGate.requestClassFor(Uri.parse(url));
      expect(classOf('https://www.apkmirror.com/wp-json/apkm/v1/x'), 'api');
      expect(classOf('https://www.apkmirror.com/apk/a/b/feed/'), 'feed');
      expect(classOf('https://www.apkmirror.com/apk/a/b/feed'), 'feed');
      expect(classOf('https://www.apkmirror.com/apk/a/b/'), 'html');
    });

    test('requests with a minimum interval start that far apart', () async {
      final gate = HostRequestGate();
      const interval = Duration(milliseconds: 60);
      final starts = <DateTime>[];
      await Future.wait(
        List.generate(3, (_) {
          return gate.run('host-f', 'host-f|html', 2, () async {
            starts.add(DateTime.now());
          }, minInterval: interval);
        }),
      );
      expect(starts, hasLength(3));
      for (var i = 1; i < starts.length; i++) {
        expect(
          starts[i].difference(starts[i - 1]).inMilliseconds,
          greaterThanOrEqualTo(interval.inMilliseconds - 10),
        );
      }
    });

    test('a page challenge blocks pages but not the feed', () async {
      final gate = HostRequestGate();
      var sent = 0;
      Future<http.Response> challenge() async {
        sent++;
        return http.Response('', 403, headers: {'cf-mitigated': 'challenge'});
      }

      Future<http.Response> ok() async {
        sent++;
        return http.Response('', 200);
      }

      await gate.runResponse(
        Uri.parse('https://www.apkmirror.com/apk/a/b/'),
        2,
        challenge,
      );
      expect(
        () => gate.runResponse(
          Uri.parse('https://apkmirror.com/apk/a/b/c/'),
          2,
          ok,
        ),
        throwsA(isA<RateLimitError>()),
      );
      final feed = await gate.runResponse(
        Uri.parse('https://www.apkmirror.com/apk/a/b/feed/'),
        2,
        ok,
      );
      expect(feed.statusCode, 200);
      expect(sent, 2);
    });
  });
}
