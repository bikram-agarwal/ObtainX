import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Two-layer (memory + disk) cache for DuckDuckGo host favicons.
///
/// Memory layer: static map, lives for the process lifetime.
/// Disk layer: files under `<cacheDir>/favicons/`, survive app restarts.
class FaviconCache {
  FaviconCache._();

  static final Map<String, Uint8List> _mem = {};

  static String _fileName(String host) =>
      '${host.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}.ico';

  static Future<File> _fileFor(String host) async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/favicons');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/${_fileName(host)}');
  }

  /// Returns favicon bytes for [host], fetching and caching on first call.
  /// Returns null if the favicon is unavailable or the network request fails.
  static Future<Uint8List?> get(String host) async {
    if (_mem.containsKey(host)) return _mem[host];

    final file = await _fileFor(host);
    if (file.existsSync()) {
      final bytes = file.readAsBytesSync();
      _mem[host] = bytes;
      return bytes;
    }

    try {
      final response = await http
          .get(Uri.parse('https://icons.duckduckgo.com/ip3/$host.ico'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(response.bodyBytes);
        _mem[host] = response.bodyBytes;
        return response.bodyBytes;
      }
    } catch (_) {}
    return null;
  }
}
