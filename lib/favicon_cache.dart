import 'dart:io';
import 'dart:typed_data';
import 'package:obtainium/http/response_bytes.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_distribution.dart';
import 'package:path_provider/path_provider.dart';

/// Two-layer (memory + disk) cache for source host favicons.
///
/// Memory layer: static map, lives for the process lifetime.
/// Disk layer: files under `<cacheDir>/favicons/`, survive app restarts.
class FaviconCache {
  FaviconCache._();
  static final _store = FaviconCacheStore(
    directory: () async =>
        Directory('${(await getApplicationCacheDirectory()).path}/favicons'),
  );

  static Future<Uint8List?> get(String host) {
    return _store.get(host);
  }
}

class FaviconCacheStore {
  static const maxIconBytes = 256 * 1024;
  static const maxEntries = 128;
  static const maxMemoryBytes = 4 * 1024 * 1024;
  static const failureLifetime = Duration(minutes: 5);
  static const diskLifetime = Duration(days: 7);
  final Future<Directory> Function() directory;
  final http.Client Function() clientFactory;
  final DateTime Function() now;
  final bool allowFallback;
  Future<Directory>? _directory;
  final _pending = <String, Future<Uint8List?>>{};
  final _diskFiles = <String, DateTime>{};
  final _negative = <String, DateTime>{};
  final _mem = <String, Uint8List>{};
  int _memoryBytes = 0;

  FaviconCacheStore({
    required this.directory,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    bool? allowFallback,
  }) : clientFactory = clientFactory ?? http.Client.new,
       allowFallback = allowFallback ?? AppDistribution.allowDuckDuckGoFavicons,
       now = now ?? DateTime.now;

  static String _fileName(String cacheKey) =>
      '${cacheKey.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}.ico';

  Future<Directory> _prepareDirectory() async {
    final cacheDirectory = await directory();
    await cacheDirectory.create(recursive: true);
    await for (final entry in cacheDirectory.list()) {
      if (entry is! File || !entry.path.endsWith('.ico')) continue;
      final stat = await entry.stat();
      if (stat.size > maxIconBytes ||
          now().difference(stat.modified) > diskLifetime) {
        await entry.delete();
      } else {
        _diskFiles[entry.path] = stat.modified;
      }
    }
    await _trimDisk();
    return cacheDirectory;
  }

  Future<void> _trimDisk() async {
    if (_diskFiles.length <= maxEntries) return;
    final oldest = _diskFiles.keys.toList()
      ..sort(
        (first, second) => _diskFiles[first]!.compareTo(_diskFiles[second]!),
      );
    for (final path in oldest.take(_diskFiles.length - maxEntries)) {
      _diskFiles.remove(path);
      try {
        await File(path).delete();
      } on FileSystemException {
        /* Cache eviction is best effort. */
      }
    }
  }

  void _remember(String key, Uint8List bytes) {
    _memoryBytes -= _mem.remove(key)?.length ?? 0;
    _mem[key] = bytes;
    _memoryBytes += bytes.length;
    while (_mem.length > maxEntries || _memoryBytes > maxMemoryBytes) {
      _memoryBytes -= _mem.remove(_mem.keys.first)!.length;
    }
  }

  /// Returns favicon bytes for [host], fetching and caching on first call.
  /// Returns null if the favicon is unavailable or the network request fails.
  Future<Uint8List?> get(String host) async {
    final normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty) return null;
    final failedAt = _negative[normalizedHost];
    if (failedAt != null && now().difference(failedAt) < failureLifetime) {
      return null;
    }
    _negative.remove(normalizedHost);
    final pending = _pending[normalizedHost];
    if (pending != null) return pending;
    final future = _load(normalizedHost);
    _pending[normalizedHost] = future;
    try {
      return await future;
    } finally {
      _pending.removeWhere((key, _) => key == normalizedHost);
    }
  }

  Future<Uint8List?> _load(String normalizedHost) async {
    try {
      final directBytes = await _getFromCacheOrFetch(
        'direct_$normalizedHost',
        Uri.https(normalizedHost, '/favicon.ico'),
      );
      if (directBytes != null) return directBytes;

      if (allowFallback) {
        final ddgBytes = await _getFromCacheOrFetch(
          'duckduckgo_$normalizedHost',
          Uri.parse('https://icons.duckduckgo.com/ip3/$normalizedHost.ico'),
        );
        if (ddgBytes != null) return ddgBytes;
      }

      // All resolution attempts failed; negative-cache the host so repeated
      // widget builds don't re-run the (up to two) network requests.
    } catch (_) {
      // An unavailable cache directory or malformed host must not break a row.
      _directory = null;
    }
    _negative[normalizedHost] = now();
    while (_negative.length > maxEntries) {
      _negative.remove(_negative.keys.first);
    }
    return null;
  }

  Future<Uint8List?> _getFromCacheOrFetch(String cacheKey, Uri uri) async {
    final cached = _mem.remove(cacheKey);
    if (cached != null) {
      _mem[cacheKey] = cached;
      return cached;
    }
    final cacheDirectory = await (_directory ??= _prepareDirectory());
    final file = File('${cacheDirectory.path}/${_fileName(cacheKey)}');
    // Read only a bounded prefix even if another process replaced the file.
    final modified = _diskFiles[file.path];
    if (modified != null && now().difference(modified) <= diskLifetime) {
      try {
        final bytes = await readBytePrefix(file.openRead(), maxIconBytes + 1);
        if (bytes.isNotEmpty && bytes.length <= maxIconBytes) {
          _remember(cacheKey, bytes);
          return bytes;
        }
      } on FileSystemException {
        /* Android may clear its cache independently. */
      }
    }

    final client = clientFactory();
    try {
      final streamed = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 5));
      if (streamed.statusCode < 200 ||
          streamed.statusCode >= 300 ||
          (streamed.contentLength ?? 0) > maxIconBytes) {
        return null;
      }
      final bytes = await readBytePrefix(
        streamed.stream,
        maxIconBytes + 1,
        idleTimeout: const Duration(seconds: 5),
      );
      if (bytes.length > maxIconBytes) return null;
      final response = http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
      );
      if (_isValidFaviconResponse(response)) {
        _remember(cacheKey, bytes);
        try {
          await file.writeAsBytes(bytes);
          _diskFiles[file.path] = now();
          await _trimDisk();
        } on FileSystemException {
          /* Memory caching still works without disk. */
        }
        return bytes;
      }
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
    return null;
  }

  static bool _isValidFaviconResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) return false;
    if (response.bodyBytes.isEmpty) return false;

    final contentType = response.headers[HttpHeaders.contentTypeHeader]
        ?.toLowerCase();
    if (contentType != null &&
        (contentType.startsWith('image/') ||
            contentType.contains('icon') ||
            contentType.contains('octet-stream'))) {
      return true;
    }

    final bytes = response.bodyBytes;
    if (bytes.length >= 4 &&
        bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        (bytes[2] == 0x01 || bytes[2] == 0x02) &&
        bytes[3] == 0x00) {
      return true;
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return true;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return true;
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return true;
    }
    return false;
  }
}
