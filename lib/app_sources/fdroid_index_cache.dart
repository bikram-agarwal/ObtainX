import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:path_provider/path_provider.dart';

typedef FdroidIndexRequest = Future<Response> Function(
  String url,
  Map<String, String> headers,
);

/// Keeps F-Droid repository index bodies on disk and revalidates them with
/// ETag/Last-Modified (upstream #3486), so an unchanged index costs a 304
/// instead of a full download.
///
/// ObtainX calls this from `AppSource.sourceRequest`, below the
/// `SourceRequestSession` dedupe, not from `FDroidRepo` as upstream does
/// (v1.7.5 sync S4): the session then shares one response, and so one
/// off-isolate parse, between every app of a repository in an update check.
/// Upstream's placement sends each later app its own conditional request and
/// re-reads and re-parses the whole index.
class FdroidIndexCache {
  final Future<Directory> Function() cacheDirProvider;

  FdroidIndexCache(this.cacheDirProvider);

  /// The cache under the app's cache directory.
  static final FdroidIndexCache shared = FdroidIndexCache(() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/fdroid_index_cache');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  });

  /// Loads [url] through [request], answering a 304 from the stored body.
  ///
  /// [cacheKey] names the entry (default: [url]). Callers pass everything
  /// that changes the response besides the URL (credentials, TLS policy), so
  /// two configurations never share a body.
  Future<Response> fetch(
    String url,
    FdroidIndexRequest request, {
    String? cacheKey,
  }) async {
    Directory? dir;
    try {
      dir = await cacheDirProvider();
    } catch (_) {}
    if (dir == null) return request(url, const {});

    final key = sha256.convert(utf8.encode(cacheKey ?? url)).toString();
    final bodyFile = File('${dir.path}/$key.body');
    final metaFile = File('${dir.path}/$key.meta');
    final meta = _readMeta(metaFile);
    final headers = <String, String>{};
    // Only ask for a 304 when there is a body to answer it with.
    if (bodyFile.existsSync()) {
      if (meta.etag != null) headers['If-None-Match'] = meta.etag!;
      if (meta.lastModified != null) {
        headers['If-Modified-Since'] = meta.lastModified!;
      }
    }

    final res = await request(url, headers);
    if (res.statusCode == 304) {
      if (bodyFile.existsSync()) {
        try {
          final bytes = await bodyFile.readAsBytes();
          _writeMeta(metaFile, res.headers, contentType: meta.contentType);
          // The stored bytes as they came, with the original Content-Type: a
          // 304 usually carries none, and rebuilding the body from a string
          // would fall back to latin1, which breaks the UTF-8 index parsers
          // (and decoding the whole index here would block the UI isolate).
          final responseHeaders = Map<String, String>.from(res.headers)
            ..remove('content-length');
          if (meta.contentType != null) {
            responseHeaders['content-type'] = meta.contentType!;
          }
          return Response.bytes(
            bytes,
            200,
            request: res.request ?? Request('GET', Uri.parse(url)),
            headers: responseHeaders,
          );
        } catch (e) {
          AppLogger.warn('Failed to read cached F-Droid index: $e');
          return request(url, const {});
        }
      }
      return request(url, const {});
    }

    if (res.statusCode == 200) {
      try {
        final etag = res.headers['etag'];
        final lastModified = res.headers['last-modified'];
        if ((etag == null || etag.isEmpty) &&
            (lastModified == null || lastModified.isEmpty)) {
          if (bodyFile.existsSync()) bodyFile.deleteSync();
          if (metaFile.existsSync()) metaFile.deleteSync();
        } else {
          await _replaceBody(bodyFile, metaFile, res.bodyBytes);
          _writeMeta(
            metaFile,
            res.headers,
            contentType: res.headers['content-type'],
          );
        }
      } catch (e) {
        AppLogger.warn('Failed to cache F-Droid index: $e');
      }
    }
    return res;
  }

  /// Writes [bytes] to a temporary file and renames it over [bodyFile], so a
  /// crash or a concurrent fetch never leaves a truncated body behind. The
  /// old metadata goes first: a body without metadata is never revalidated.
  Future<void> _replaceBody(
    File bodyFile,
    File metaFile,
    List<int> bytes,
  ) async {
    if (metaFile.existsSync()) metaFile.deleteSync();
    final temp = File(
      '${bodyFile.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(bodyFile.path);
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
  }

  _IndexMeta _readMeta(File file) {
    if (!file.existsSync()) return const _IndexMeta();
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return const _IndexMeta();
      String? nonEmpty(Object? value) =>
          value is String && value.isNotEmpty ? value : null;
      return _IndexMeta(
        etag: nonEmpty(decoded['etag']),
        lastModified: nonEmpty(decoded['lastModified']),
        contentType: nonEmpty(decoded['contentType']),
      );
    } catch (_) {
      return const _IndexMeta();
    }
  }

  void _writeMeta(
    File file,
    Map<String, String> headers, {
    String? contentType,
  }) {
    final etag = headers['etag'];
    final lastModified = headers['last-modified'];
    if ((etag == null || etag.isEmpty) &&
        (lastModified == null || lastModified.isEmpty)) {
      return;
    }
    try {
      file.writeAsStringSync(
        jsonEncode({
          'etag': etag,
          'lastModified': lastModified,
          'contentType': contentType,
        }),
      );
    } catch (e) {
      AppLogger.warn('Failed to write F-Droid index metadata: $e');
    }
  }
}

class _IndexMeta {
  final String? etag;
  final String? lastModified;
  final String? contentType;

  const _IndexMeta({this.etag, this.lastModified, this.contentType});
}
