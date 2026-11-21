// HttpService redirect, body and error handling.
//
// Upstream's version of this file targets its Cronet/package:http API
// (`HttpService(clientFactory:)`, `request()`), which ObtainX doesn't adopt
// (v1.7.4 sync, D1). These are the same scenarios against the fork's dart:io
// API on loopback servers. A cross-origin redirect here is a different port,
// which is a different origin. The HTTPS → HTTP refusal needs a TLS server,
// so it isn't covered here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/services/http_service.dart';

/// flutter_test replaces HttpClient with one that answers 400; the base
/// HttpOverrides creates real clients (the fork's tests do the same).
class _RealHttp extends HttpOverrides {}

/// Echoes what the server saw as JSON.
Future<void> _echo(HttpRequest request) async {
  final body = await utf8.decoder.bind(request).join();
  request.response.headers.contentType = ContentType.json;
  request.response.write(
    jsonEncode({
      'path': request.uri.path,
      'cookie': request.headers.value('cookie'),
      'x-api-key': request.headers.value('x-api-key'),
      'accept': request.headers.value('accept'),
      'content-type': request.headers.value('content-type'),
      'body': body,
    }),
  );
  await request.response.close();
}

Future<void> _redirect(
  HttpRequest request,
  String location, {
  List<String> cookies = const [],
}) async {
  request.response.statusCode = 302;
  request.response.headers.set('location', location);
  for (final cookie in cookies) {
    request.response.headers.add('set-cookie', cookie);
  }
  await request.response.close();
}

void main() {
  late HttpServer origin;
  late HttpServer other;

  String at(HttpServer server, String path) =>
      'http://127.0.0.1:${server.port}$path';

  setUpAll(() async {
    other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    other.listen(_echo);
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      switch (request.uri.path) {
        case '/start':
          await _redirect(request, '/final', cookies: ['session=abc; Path=/']);
        case '/cross':
          await _redirect(
            request,
            at(other, '/final'),
            cookies: ['session=abc; Path=/'],
          );
        case '/badcookie':
          await _redirect(
            request,
            '/final',
            cookies: ['=x', 'session=abc; Path=/'],
          );
        case '/loop':
          await _redirect(request, '/loop');
        default:
          await _echo(request);
      }
    });
  });

  tearDownAll(() async {
    await origin.close(force: true);
    await other.close(force: true);
  });

  Future<http.Response> fetch(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? postBody,
    bool followRedirects = true,
  }) => HttpOverrides.runWithHttpOverrides(() async {
    final service = HttpService();
    final streamed = await service.sourceRequestStreamResponse(
      method,
      url,
      headers,
      const {},
      followRedirects: followRedirects,
      postBody: postBody,
      certificatePinning: false,
    );
    return service.httpClientResponseStreamToFinalResponse(
      streamed.value.key,
      method,
      streamed.key.toString(),
      streamed.value.value,
    );
  }, _RealHttp());

  Map<String, dynamic> seen(http.Response response) =>
      jsonDecode(response.body) as Map<String, dynamic>;

  group('HttpService redirects', () {
    test('follows same-origin redirects and forwards cookies', () async {
      final response = await fetch(
        'GET',
        at(origin, '/start'),
        headers: {'X-Api-Key': 'secret', 'Accept': 'application/json'},
      );

      expect(response.statusCode, 200);
      expect(response.request?.url.path, '/final');
      final echo = seen(response);
      expect(echo['x-api-key'], 'secret');
      expect(echo['accept'], 'application/json');
      expect(echo['cookie'], 'session=abc');
    });

    test(
      'strips caller headers and cookies on cross-origin redirects',
      () async {
        final response = await fetch(
          'GET',
          at(origin, '/cross'),
          headers: {'X-Api-Key': 'secret', 'Accept': 'application/json'},
        );

        final echo = seen(response);
        expect(echo['x-api-key'], isNull);
        expect(echo['cookie'], isNull);
        expect(echo['accept'], 'application/json');
      },
    );

    test('skips a malformed Set-Cookie instead of failing', () async {
      final response = await fetch('GET', at(origin, '/badcookie'));

      expect(response.statusCode, 200);
      expect(seen(response)['cookie'], 'session=abc');
    });

    test('stops after the redirect limit', () async {
      await expectLater(
        fetch('GET', at(origin, '/loop')),
        throwsA(isA<ObtainiumError>()),
      );
    });

    test('returns the redirect response when redirects are disabled', () async {
      final response = await fetch(
        'GET',
        at(origin, '/start'),
        followRedirects: false,
      );

      expect(response.statusCode, 302);
      expect(response.headers['location'], '/final');
    });
  });

  test('encodes map bodies as JSON', () async {
    final response = await fetch(
      'POST',
      at(origin, '/body'),
      postBody: {'a': 1},
    );

    final echo = seen(response);
    expect(echo['content-type'], startsWith('application/json'));
    expect(jsonDecode(echo['body'] as String), {'a': 1});
  });

  test('sends String bodies as UTF-8', () async {
    final response = await fetch(
      'POST',
      at(origin, '/body'),
      postBody: 'naïve ✓ 日本',
    );

    expect(seen(response)['body'], 'naïve ✓ 日本');
  });

  group('HttpService error mapping', () {
    test('maps 404 to NoReleasesError', () {
      final error = HttpService().getHttpError(http.Response('', 404));
      expect(error, isA<NoReleasesError>());
    });

    test('maps 429 with Retry-After to RateLimitError', () {
      final error = HttpService().getHttpError(
        http.Response('', 429, headers: {'retry-after': '120'}),
      );
      expect(error, isA<RateLimitError>());
      expect((error as RateLimitError).remainingMinutes, 2);
    });

    test('maps other statuses to a generic HTTP error', () {
      final error = HttpService().getHttpError(http.Response('', 500));
      expect(error.code, 'HTTP_ERROR');
    });
  });

  test('pinning follows the setting when the caller passes nothing', () {
    final uri = Uri.parse('https://github.com/a/b');
    HttpService.setDefaultCertificatePinning(false);
    expect(HttpService.needsDedicatedClient(uri), isFalse);
    HttpService.setDefaultCertificatePinning(true);
    expect(HttpService.needsDedicatedClient(uri), isTrue);
    expect(
      HttpService.needsDedicatedClient(uri, certificatePinning: false),
      isFalse,
    );
    HttpService.setDefaultCertificatePinning(false);
  });
}
