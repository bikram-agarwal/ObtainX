import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/fdroid_index_cache.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('obtainium_fdroid_cache');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Response response(String body, int status, {Map<String, String>? headers}) =>
      Response(
        body,
        status,
        headers: headers ?? const {},
        request: Request('GET', Uri.parse('https://example.com/index-v2.json')),
      );

  test('caches the body and revalidates with ETag/Last-Modified', () async {
    var calls = 0;
    final cache = FdroidIndexCache(() async => dir);

    Future<Response> request(String url, Map<String, String> headers) async {
      calls++;
      if (calls == 1) {
        expect(headers, isEmpty);
        return response(
          'index-body',
          200,
          headers: {
            'etag': '"v1"',
            'last-modified': 'Mon, 01 Jan 2026 00:00:00 GMT',
          },
        );
      }
      expect(headers['If-None-Match'], '"v1"');
      expect(headers['If-Modified-Since'], 'Mon, 01 Jan 2026 00:00:00 GMT');
      return response('', 304);
    }

    final first = await cache.fetch(
      'https://example.com/index-v2.json',
      request,
    );
    expect(first.statusCode, 200);
    expect(first.body, 'index-body');

    final second = await cache.fetch(
      'https://example.com/index-v2.json',
      request,
    );
    expect(second.statusCode, 200);
    expect(second.body, 'index-body');
    expect(calls, 2);
  });

  test('does not keep a cache entry without validators', () async {
    var calls = 0;
    final cache = FdroidIndexCache(() async => dir);

    Future<Response> request(String url, Map<String, String> headers) async {
      calls++;
      expect(headers, isEmpty);
      return response('index-body', 200);
    }

    await cache.fetch('https://example.com/index-v2.json', request);
    expect(dir.listSync(), isEmpty);
    await cache.fetch('https://example.com/index-v2.json', request);
    expect(calls, 2);
  });

  test('retries without conditions when a 304 has no cached body', () async {
    var calls = 0;
    final cache = FdroidIndexCache(() async => dir);

    Future<Response> request(String url, Map<String, String> headers) async {
      calls++;
      if (calls == 1) return response('', 304);
      return response('fresh-body', 200);
    }

    final res = await cache.fetch('https://example.com/index-v2.json', request);
    expect(res.statusCode, 200);
    expect(res.body, 'fresh-body');
    expect(calls, 2);
  });

  // ObtainX (v1.7.5 sync S4): a 304 rarely carries a Content-Type, and
  // rebuilding the body from a string would fall back to latin1. The index
  // parsers read the bytes (index-v2 as UTF-8), so they must come back as
  // they were stored, with the original Content-Type.
  group('a 304 answered from the stored body', () {
    const String index = '{"repo": "Café 名前 🚀"}';

    Future<Response> Function(String, Map<String, String>) server({
      Map<String, String> contentType = const {},
    }) {
      var calls = 0;
      return (String url, Map<String, String> headers) async {
        calls++;
        if (calls == 1) {
          return Response.bytes(
            utf8.encode(index),
            200,
            headers: {'etag': '"v1"', ...contentType},
            request: Request('GET', Uri.parse(url)),
          );
        }
        expect(headers['If-None-Match'], '"v1"');
        return Response.bytes(
          const [],
          304,
          headers: {'etag': '"v1"', 'content-length': '0'},
          request: Request('GET', Uri.parse(url)),
        );
      };
    }

    test(
      'keeps non-Latin-1 UTF-8 bytes intact without a Content-Type',
      () async {
        final cache = FdroidIndexCache(() async => dir);
        final request = server();
        await cache.fetch('https://example.com/index-v2.json', request);
        final second = await cache.fetch(
          'https://example.com/index-v2.json',
          request,
        );
        expect(second.statusCode, 200);
        expect(second.bodyBytes, utf8.encode(index));
        expect(utf8.decode(second.bodyBytes), index);
        expect(second.headers.containsKey('content-length'), isFalse);
        expect(second.request?.url.path, '/index-v2.json');
      },
    );

    test('restores the stored Content-Type', () async {
      final cache = FdroidIndexCache(() async => dir);
      final request = server(
        contentType: {'content-type': 'application/xml; charset=utf-8'},
      );
      await cache.fetch('https://example.com/index.xml', request);
      final second = await cache.fetch(
        'https://example.com/index.xml',
        request,
      );
      expect(second.headers['content-type'], 'application/xml; charset=utf-8');
      expect(second.body, index);
    });
  });

  test('keeps a separate entry per cache key', () async {
    final cache = FdroidIndexCache(() async => dir);
    final seen = <Map<String, String>>[];
    Future<Response> request(String url, Map<String, String> headers) async {
      seen.add(headers);
      return response('index-body', 200, headers: {'etag': '"v1"'});
    }

    await cache.fetch(
      'https://example.com/index.xml',
      request,
      cacheKey: 'token-a',
    );
    await cache.fetch(
      'https://example.com/index.xml',
      request,
      cacheKey: 'token-b',
    );
    expect(seen, [isEmpty, isEmpty]);
    await cache.fetch(
      'https://example.com/index.xml',
      request,
      cacheKey: 'token-a',
    );
    expect(seen.last['If-None-Match'], '"v1"');
  });

  test('asks for no 304 once the stored body is gone', () async {
    final cache = FdroidIndexCache(() async => dir);
    final seen = <Map<String, String>>[];
    Future<Response> request(String url, Map<String, String> headers) async {
      seen.add(headers);
      return response('index-body', 200, headers: {'etag': '"v1"'});
    }

    await cache.fetch('https://example.com/index.xml', request);
    for (final file in dir.listSync().whereType<File>()) {
      if (file.path.endsWith('.body')) file.deleteSync();
    }
    await cache.fetch('https://example.com/index.xml', request);
    expect(seen, [isEmpty, isEmpty]);
  });

  test('leaves only the body and its metadata behind', () async {
    final cache = FdroidIndexCache(() async => dir);
    Future<Response> request(String url, Map<String, String> headers) async =>
        response('index-body', 200, headers: {'etag': '"v1"'});

    await cache.fetch('https://example.com/index.xml', request);
    await cache.fetch('https://example.com/index.xml', request);
    final names = dir.listSync().map(
      (e) => e.path.split(RegExp(r'[/\\]')).last,
    );
    expect(names.where((n) => n.endsWith('.body')), hasLength(1));
    expect(names.where((n) => n.endsWith('.meta')), hasLength(1));
    expect(names, hasLength(2));
  });

  test('falls back to a direct request when the cache dir fails', () async {
    var calls = 0;
    final cache = FdroidIndexCache(
      () async => throw const FileSystemException('no cache'),
    );

    Future<Response> request(String url, Map<String, String> headers) async {
      calls++;
      expect(headers, isEmpty);
      return response('index-body', 200);
    }

    final res = await cache.fetch('https://example.com/index-v2.json', request);
    expect(res.statusCode, 200);
    expect(res.body, 'index-body');
    expect(calls, 1);
  });
}
