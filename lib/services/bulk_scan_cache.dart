import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists package → store → page URL mappings from bulk scans under app
/// storage (not the cache directory), so Android "clear cache" does not remove it.
class BulkScanCache {
  static const String _relativeDir = 'bulk_scan_data';
  static const String _fileName = 'store_url_map.json';

  static Future<Directory> _rootDir() async {
    final Directory base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${base.path}/$_relativeDir');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static Future<File> _file() async {
    return File('${(await _rootDir()).path}/$_fileName');
  }

  /// Outer key: package name. Inner key: store name (e.g. APKMirror).
  /// Empty string value means "looked up, not found" for that store.
  static Future<Map<String, Map<String, String>>> load() async {
    try {
      final File file = await _file();
      if (!file.existsSync()) return {};
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return {};
      final Map<String, Map<String, String>> out = {};
      for (final MapEntry<String, dynamic> entry in decoded.entries) {
        final Object? inner = entry.value;
        if (inner is Map<String, dynamic>) {
          out[entry.key] = inner.map(
            (String storeKey, dynamic urlValue) => MapEntry(
              storeKey,
              urlValue is String ? urlValue : '',
            ),
          );
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Map<String, Map<String, String>> data) async {
    final File file = await _file();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  static Future<void> clear() async {
    try {
      final File file = await _file();
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      // ignore
    }
  }

  /// Merges [storeResults] into [cache] and persists.
  static Future<void> mergeStoreAndSave(
    Map<String, Map<String, String>> cache,
    String storeName,
    Map<String, String?> storeResults,
  ) async {
    for (final MapEntry<String, String?> entry in storeResults.entries) {
      cache.putIfAbsent(entry.key, () => <String, String>{})[storeName] =
          entry.value ?? '';
    }
    await save(cache);
  }
}
