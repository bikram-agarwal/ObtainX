import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:obtainium/services/json_file_work.dart';
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
///   2. Merges the caller's diff onto the latest committed snapshot inside
///      the queue, then writes that. Eliminates the
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
  static Future<Map<String, Map<String, String>>>? _pendingLoad;

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
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> _file() async {
    return File('${(await _rootDir()).path}/$_fileName');
  }

  /// Replaces the in-memory cache without touching disk, for widget tests,
  /// where file and isolate work never settles under the fake clock.
  @visibleForTesting
  static void setCacheForTesting(Map<String, Map<String, String>> data) {
    _cache = _deepCopy(data);
    _pendingLoad = null;
  }

  /// Outer key: package name. Inner key: store name (e.g. APKMirror).
  /// Empty string value means "looked up, not found" for that store.
  static Future<Map<String, Map<String, String>>> load() async {
    return _deepCopy(await _readCache());
  }

  /// Reads one app without cloning every other app's store mappings.
  static Future<Map<String, String>?> loadForApp(String appId) async {
    final entry = (await _readCache())[appId];
    return entry == null ? null : Map<String, String>.from(entry);
  }

  static Future<Map<String, Map<String, String>>> _readCache() async {
    if (_cache != null) {
      return _cache!;
    }
    final pending = _pendingLoad ??= _loadFromDisk();
    try {
      return await pending;
    } finally {
      if (identical(_pendingLoad, pending)) _pendingLoad = null;
    }
  }

  static Future<Map<String, Map<String, String>>> _loadFromDisk() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        _cache = {};
        return _cache!;
      }
      final Object? decoded = await readJsonFileOffIsolate(file.path);
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
      _cache = out;
      return out;
    } catch (_) {
      _cache = {};
      return {};
    }
  }

  /// Enqueues an atomic, mutation-merging disk write.
  ///
  /// Behaviour inside the lock:
  ///   - Copy the latest committed cache so writes made by other flows since
  ///     the caller loaded its snapshot are preserved.
  ///   - Hand that copy to [merger], which reports whether anything changed.
  ///   - Serialize the result to a `.tmp` file beside the cache file.
  ///   - Atomically rename the `.tmp` over the cache file. POSIX rename is
  ///     atomic on the filesystems Android uses (ext4 / F2FS), so a kill
  ///     between writeAsString and rename leaves the previous good file
  ///     intact instead of producing a half-written destination.
  static Future<void> _enqueueWrite(
    bool Function(Map<String, Map<String, String>> diskCopy) merger, {
    bool deleteFile = false,
  }) {
    final Future<void> work = _writeChainTail.then((_) async {
      final fresh = _deepCopy(await _readCache());
      if (!merger(fresh)) return;
      final File file = await _file();
      if (deleteFile) {
        if (await file.exists()) await file.delete();
      } else {
        await writeJsonFileOffIsolate(file.path, fresh);
      }
      _cache = fresh;
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
    final snapshot = _deepCopy(data);
    return _enqueueWrite((Map<String, Map<String, String>> disk) {
      var changed = false;
      snapshot.forEach((String appId, Map<String, String> callerStoreMap) {
        if (!disk.containsKey(appId)) changed = true;
        final Map<String, String> diskStoreMap = disk.putIfAbsent(
          appId,
          () => <String, String>{},
        );
        callerStoreMap.forEach((String storeKey, String urlValue) {
          if (diskStoreMap[storeKey] != urlValue) changed = true;
          diskStoreMap[storeKey] = urlValue;
        });
      });
      return changed;
    });
  }

  static Future<void> clear() async {
    try {
      // Keep the deletion inside the queue too, so it cannot erase a newer save.
      await _enqueueWrite((Map<String, Map<String, String>> disk) {
        disk.clear();
        return true;
      }, deleteFile: true);
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
        var changed = false;
        for (final Map<String, String> storeMap in disk.values) {
          for (final String store in storeNames) {
            if (storeMap.remove(store) != null) changed = true;
          }
        }
        return changed;
      });
    } catch (_) {
      // ignore
    }
  }

  /// Returns the set of store names that have at least one cached entry.
  static Future<Set<String>> cachedStores() async {
    final Map<String, Map<String, String>> cache = await _readCache();
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
    // Persist only this store's results, rather than the caller's full snapshot.
    return save({
      for (final entry in storeResults.entries)
        entry.key: {storeName: entry.value ?? ''},
    });
  }
}

/// Waits for per-store lookups of [packageId] (store name -> a lookup
/// returning package -> URL, null when the store says it isn't there) and
/// returns only the stores that answered.
///
/// Each lookup settles on its own. One that throws, or whose result has no
/// entry for [packageId], couldn't tell either way, so it is left out rather
/// than reported as absent - caching that as the `''` sentinel would hide a
/// store the package may well be on. [onError] hears about each throw.
/// Waiting on the lookups with a bare `Future.wait` instead let one failure
/// discard every other store's answer.
Future<Map<String, String?>> settleStoreLookups(
  String packageId,
  Map<String, Future<Map<String, String?>>> lookups, {
  void Function(String store, Object error)? onError,
}) async {
  final List<MapEntry<String, String?>?> answers = await Future.wait(
    lookups.entries.map((
      MapEntry<String, Future<Map<String, String?>>> lookup,
    ) async {
      try {
        final Map<String, String?> result = await lookup.value;
        return result.containsKey(packageId)
            ? MapEntry<String, String?>(lookup.key, result[packageId])
            : null;
      } catch (error) {
        onError?.call(lookup.key, error);
        return null;
      }
    }),
  );
  return Map<String, String?>.fromEntries(answers.nonNulls);
}
