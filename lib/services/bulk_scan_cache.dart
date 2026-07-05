import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists package → store → page URL mappings from bulk scans under app
/// storage (not the cache directory), so Android "clear cache" does not
/// remove it.
///
/// All writes go through a single-writer queue ([_enqueueWrite]) that:
///
///   1. Serializes concurrent writes from the three flows that touch the
///      cache - [_performBulkScan] in bulk_add_widget,
///      [backgroundScanStoreAvailability] in apps.dart, and
///      [_maybeCheckAndCacheAllStores] in app.dart - so two flows can no
///      longer overlap their load → modify → save windows and clobber
///      each other's writes.
///   2. Re-reads the disk inside the lock, merges the caller's diff onto
///      the freshest copy, and writes that. Eliminates the
///      last-writer-wins data loss that was wiping store-availability
///      entries when an AppPage save raced a [backgroundScanStoreAvailability].
///   3. Writes via tmp-file + atomic rename so a kill or crash mid-write
///      can never leave a half-written JSON file. Previously a truncated
///      file would fail JSON parse on next load and the catch block
///      returned an empty map, silently wiping the entire cache.
class BulkScanCache {
  static const String _relativeDir = 'bulk_scan_data';
  static const String _fileName = 'store_url_map.json';

  static Map<String, Map<String, String>>? _cache;

  static Map<String, Map<String, String>> _deepCopy(
    Map<String, Map<String, String>> source,
  ) {
    return source.map(
      (key, val) => MapEntry(key, Map<String, String>.from(val)),
    );
  }

  // Single-writer queue. Each [_enqueueWrite] call chains its work onto
  // this future; all writes therefore run strictly sequentially in the
  // order they were enqueued. Errors from one write don't break the
  // chain - they're swallowed by the [catchError] below so subsequent
  // writes still see a resolved future to await.
  static Future<void> _writeChainTail = Future<void>.value();

  static Future<Directory> _rootDir() async {
    Directory base;
    try {
      final Directory? externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        await externalDir.create(recursive: true);
        base = externalDir;
      } else {
        base = await getApplicationDocumentsDirectory();
      }
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
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
    if (_cache != null) {
      return _deepCopy(_cache!);
    }
    try {
      final File file = await _file();
      if (!file.existsSync()) {
        _cache = {};
        return {};
      }
      final String content = await file.readAsString();
      if (content.trim().isEmpty) {
        _cache = {};
        return {};
      }
      final Object? decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        _cache = {};
        return {};
      }
      final Map<String, Map<String, String>> out = {};
      for (final MapEntry<String, dynamic> entry in decoded.entries) {
        final Object? inner = entry.value;
        if (inner is Map<String, dynamic>) {
          out[entry.key] = inner.map(
            (String storeKey, dynamic urlValue) =>
                MapEntry(storeKey, urlValue is String ? urlValue : ''),
          );
        }
      }
      _cache = _deepCopy(out);
      return out;
    } catch (_) {
      _cache = {};
      return {};
    }
  }

  /// Enqueues an atomic, mutation-merging disk write.
  ///
  /// Behaviour inside the lock:
  ///   - Reload the cache from disk so we incorporate any writes made by
  ///     other flows since the caller's snapshot was loaded.
  ///   - Hand the fresh disk copy to [merger] for in-place mutation.
  ///   - Serialize the result to a `.tmp` file beside the cache file.
  ///   - Atomically rename the `.tmp` over the cache file. POSIX rename is
  ///     atomic on the filesystems Android uses (ext4 / F2FS), so a kill
  ///     between writeAsString and rename leaves the previous good file
  ///     intact instead of producing a half-written destination.
  static Future<void> _enqueueWrite(
    void Function(Map<String, Map<String, String>> diskCopy) merger,
  ) {
    final Future<void> work = _writeChainTail.then((_) async {
      final Map<String, Map<String, String>> fresh = await load();
      merger(fresh);
      _cache = _deepCopy(fresh);
      final File file = await _file();
      final File tmp = File('${file.path}.tmp');
      final String json = const JsonEncoder.withIndent('  ').convert(fresh);
      await tmp.writeAsString(json);
      await tmp.rename(file.path);
    });
    // Swallow errors on the chain itself so one failed write doesn't poison
    // every subsequent enqueue. The original caller still gets the error
    // through the returned future.
    _writeChainTail = work.catchError((Object _) {});
    return work;
  }

  /// Persists [data]. Semantics changed from a blind file overwrite to a
  /// disk-merging save: any keys present on disk but absent in [data] are
  /// preserved. This is the fix for the cross-flow last-writer-wins race
  /// - if another flow wrote between this caller's [load] and [save],
  /// their data survives.
  ///
  /// Within an app-id's store map, [data]'s value wins for any conflicting
  /// store key (the caller's data is presumed fresher than what was on
  /// disk before they queued the write).
  static Future<void> save(Map<String, Map<String, String>> data) {
    return _enqueueWrite((Map<String, Map<String, String>> disk) {
      data.forEach((String appId, Map<String, String> callerStoreMap) {
        final Map<String, String> diskStoreMap = disk.putIfAbsent(
          appId,
          () => <String, String>{},
        );
        callerStoreMap.forEach((String storeKey, String urlValue) {
          diskStoreMap[storeKey] = urlValue;
        });
      });
    });
  }

  static Future<void> clear() async {
    try {
      // Drain the queue first so any in-flight writes don't ghost-resurrect
      // the file after the delete.
      await _enqueueWrite((Map<String, Map<String, String>> disk) {
        disk.clear();
      });
      // Also remove the (now-empty) file so a subsequent load short-circuits
      // on `existsSync == false`.
      final File file = await _file();
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      // ignore
    }
  }

  /// Removes cached entries for the given stores only, leaving other
  /// stores intact.
  static Future<void> clearStores(Set<String> storeNames) async {
    if (storeNames.isEmpty) return;
    try {
      await _enqueueWrite((Map<String, Map<String, String>> disk) {
        for (final Map<String, String> storeMap in disk.values) {
          for (final String store in storeNames) {
            storeMap.remove(store);
          }
        }
      });
    } catch (_) {
      // ignore
    }
  }

  /// Returns the set of store names that have at least one cached entry.
  static Future<Set<String>> cachedStores() async {
    final Map<String, Map<String, String>> cache = await load();
    final Set<String> stores = {};
    for (final Map<String, String> storeMap in cache.values) {
      stores.addAll(storeMap.keys);
    }
    return stores;
  }

  /// Merges [storeResults] into [cache] (the caller's in-memory snapshot,
  /// preserved for backwards compatibility with the bulk-scan flow which
  /// reads back from this map between stores) AND persists by enqueuing a
  /// disk-merging atomic write.
  static Future<void> mergeStoreAndSave(
    Map<String, Map<String, String>> cache,
    String storeName,
    Map<String, String?> storeResults,
  ) async {
    // Update the caller's in-memory cache so the bulk-scan flow's
    // [_persistedStoreColumn] queries see accumulated results between
    // stores without an extra disk reload.
    for (final MapEntry<String, String?> entry in storeResults.entries) {
      cache.putIfAbsent(entry.key, () => <String, String>{})[storeName] =
          entry.value ?? '';
    }
    // Persist: queued atomic write that re-reads the disk so concurrent
    // writers' contributions aren't clobbered.
    return _enqueueWrite((Map<String, Map<String, String>> disk) {
      for (final MapEntry<String, String?> entry in storeResults.entries) {
        disk.putIfAbsent(entry.key, () => <String, String>{})[storeName] =
            entry.value ?? '';
      }
    });
  }
}
