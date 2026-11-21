import 'dart:async';
import 'dart:math';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:sqflite/sqflite.dart';

const appRecordRevisionKey = '_recordRevision';

/// Check timestamps are small, transactional updates. The revision binds each
/// checkpoint to its JSON record so restoring/replacing a file cannot inherit
/// a stale timestamp from another release or a previously removed app.
class AppCheckStore {
  final String path;
  Future<Database>? _database;
  final Duration operationTimeout;
  final Duration readTimeout;
  final DatabaseFactory? factory;
  Object? _failure;
  DateTime? _failedAt;
  final revisions = <String, String>{};

  /// What each listing's JSON record holds besides its check time, as last
  /// read from or written to disk (see [recordFieldsBesidesCheckTime]).
  ///
  /// A timestamp-only save is safe only if the app still matches its record.
  /// The in-memory app can't stand in for the record: callers update it before
  /// saving, so comparing against it recorded only the timestamp and dropped
  /// the change itself (#307).
  final _records = <String, Map<String, Object?>>{};

  /// Reads run while the app list is still behind a spinner, so they get a
  /// tighter budget than writes - or the caller's own, when it asked for
  /// something shorter still.
  AppCheckStore(
    this.path, {
    this.operationTimeout = const Duration(seconds: 5),
    Duration? readTimeout,
    this.failureCooldown = const Duration(minutes: 2),
    this.factory,
  }) : readTimeout =
           readTimeout ??
           (operationTimeout < _defaultReadTimeout
               ? operationTimeout
               : _defaultReadTimeout);

  static const Duration _defaultReadTimeout = Duration(milliseconds: 1200);

  /// How long one stalled operation keeps the cache switched off. A lock held
  /// by another engine clears on its own, so a permanent opt-out meant a single
  /// stall degraded every later check timestamp until the process restarted.
  final Duration failureCooldown;

  bool get isAvailable => _activeFailure == null;

  /// The current failure, or null once [failureCooldown] has elapsed and the
  /// store is allowed to try the database again.
  Object? get _activeFailure {
    final failure = _failure;
    if (failure == null) return null;
    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) >= failureCooldown) {
      _failure = null;
      _failedAt = null;
      return null;
    }
    return failure;
  }

  /// [budget] overrides [operationTimeout] for calls on a latency-sensitive
  /// path: reads happen while the app list is still behind a spinner, whereas a
  /// write batch can afford to wait.
  Future<T> _run<T>(
    String operation,
    Future<T> Function(Database database) action, {
    Duration? budget,
  }) async {
    final existingFailure = _activeFailure;
    if (existingFailure != null) {
      throw existingFailure;
    }
    final Duration timeout = budget ?? operationTimeout;
    try {
      return await (() async {
        for (var reopened = false; ; reopened = true) {
          final Future<Database> connection = _connection();
          final Database database;
          try {
            database = await connection;
          } catch (_) {
            if (identical(_database, connection)) _database = null;
            rethrow;
          }
          // A timed-out open can still finish later. Do not start its queued
          // query/write after the caller has switched to durable JSON records.
          if (_failure != null) {
            throw _failure!;
          }
          try {
            return await action(database);
          } on DatabaseException catch (error) {
            // Something closed this connection under us. Holding on to it made
            // every later read fail the same way until the process restarted
            // (#317), so open a fresh one and try once more.
            if (reopened || !error.isDatabaseClosedError()) rethrow;
            if (identical(_database, connection)) _database = null;
          }
        }
      })().timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException(
            'Check timestamp database $operation',
            timeout,
          );
        },
      );
    } catch (error) {
      // Avoid repeating the same stall for each save batch or foreground load.
      // This cache is optional; JSON records remain the durable fallback.
      _failure = error;
      _failedAt = DateTime.now();
      rethrow;
    }
  }

  /// Include SQLite's WAL, when enabled, so another engine's timestamp-only
  /// saves can be noticed without scanning app files or installed packages.
  Future<DateTime?> modified() async {
    try {
      return await _run('metadata read', budget: readTimeout, (database) async {
        final stats = await Future.wait([
          File(database.path).stat(),
          File('${database.path}-wal').stat(),
        ]);
        return stats[0].modified.isAfter(stats[1].modified)
            ? stats[0].modified
            : stats[1].modified;
      });
    } catch (_) {
      return null;
    }
  }

  /// The cached connection, opened on first use.
  Future<Database> _connection() {
    return _database ??= (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        // The default single instance is one native connection per file for
        // the whole process, which every Flutter engine shares, so a
        // background engine closing its store closed the UI isolate's
        // connection too (#317). A connection of its own lets each engine
        // close it, and concurrent access is what WAL below is for.
        singleInstance: false,
        onConfigure: (database) async {
          // The UI isolate and every background WorkManager engine open this
          // same file. On the default rollback journal a background write locks
          // readers out entirely, which showed up as multi-second stalls on the
          // foreground app load; WAL lets them proceed concurrently, and the
          // busy timeout bounds whoever still loses a lock race.
          await database.rawQuery('PRAGMA journal_mode=WAL');
          await database.rawQuery('PRAGMA busy_timeout=3000');
        },
        onCreate: (database, _) async {
          await database.execute(
            'CREATE TABLE checks ('
            'id TEXT PRIMARY KEY, revision TEXT NOT NULL, checked INTEGER NOT NULL)',
          );
        },
      ),
    );
  }

  /// [singleId] reads one Android package: its own row plus a row for every
  /// further store the package is tracked from (`package@Store`). `_` and `%`
  /// are legal in package IDs and are LIKE wildcards, so they are escaped.
  Future<Map<String, Map<String, Object?>>> read({String? singleId}) async {
    return _run('read', budget: readTimeout, (database) async {
      final rows = await database.query(
        'checks',
        where: singleId == null ? null : "id = ? OR id LIKE ? ESCAPE '\\'",
        whereArgs: singleId == null
            ? null
            : [
                singleId,
                '${singleId.replaceAll('_', r'\_').replaceAll('%', r'\%')}'
                    '$appListingKeySeparator%',
              ],
      );
      return {for (final row in rows) row['id'] as String: row};
    });
  }

  void apply(
    Map<String, dynamic> json,
    Map<String, Map<String, Object?>> checks,
  ) {
    // Checkpoints are per tracked listing, not per Android package: one package
    // can be tracked from several stores, each with its own record.
    final id = (json['listingId'] ?? json['id']) as String;
    final revision = json[appRecordRevisionKey];
    if (revision is! String) {
      revisions.remove(id);
      _records.remove(id);
      return;
    }
    rememberRecord(id, revision, json);
    final checkpoint = checks[id];
    if (checkpoint?['revision'] == revision) {
      final checked = checkpoint!['checked'] as int;
      final recorded = dateTimeFromJsonValue(json['lastUpdateCheck']);
      if (recorded == null || checked > recorded.microsecondsSinceEpoch) {
        json['lastUpdateCheck'] = checked;
      }
    }
  }

  /// Notes that [id]'s JSON record, with [revision], holds [record] (the map
  /// read from or written to its file).
  void rememberRecord(String id, String revision, Map<String, dynamic> record) {
    revisions[id] = revision;
    final Map<String, Object?>? fields = recordFieldsBesidesCheckTime(record);
    if (fields == null) {
      _records.remove(id);
    } else {
      _records[id] = fields;
    }
  }

  /// Whether saving [app] under [id] can record just its check time: its JSON
  /// record already holds everything else.
  bool onlyCheckTimeDiffersFromRecord(String id, App app) {
    final Map<String, Object?>? record = _records[id];
    if (record == null || app.lastUpdateCheck == null) return false;
    final Map<String, Object?>? current = recordFieldsBesidesCheckTime(
      app.toJson(),
    );
    return current != null &&
        const DeepCollectionEquality().equals(record, current);
  }

  Future<void> save(List<Map<String, Object?>> checkpoints) async {
    if (checkpoints.isEmpty) return;
    await _run('save', (database) async {
      final batch = database.batch();
      for (final checkpoint in checkpoints) {
        batch.insert(
          'checks',
          checkpoint,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> remove(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    for (final id in ids) {
      revisions.remove(id);
      _records.remove(id);
    }
    try {
      await _run('cleanup', (database) async {
        final batch = database.batch();
        for (final id in ids) {
          batch.delete('checks', where: 'id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      });
    } catch (_) {
      // A stale checkpoint cannot match the new revision if an app is re-added.
    }
  }

  Future<void> close() async {
    final pending = _database;
    _database = null;
    if (pending != null) {
      try {
        await (() async {
          await (await pending).close();
        })().timeout(operationTimeout);
      } catch (_) {
        // Disposal must not wait indefinitely on an unresponsive native engine.
      }
    }
  }

  static String newRevision() {
    return '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  }
}

/// [record]'s fields besides its check time and revision, detached from the
/// map they came from.
///
/// Records keep their nested data JSON-encoded, so every field is a plain value
/// except the category list, which is copied. A field holding anything else (a
/// legacy record's unencoded settings, say) makes this null, which only means
/// the next save writes the whole record.
Map<String, Object?>? recordFieldsBesidesCheckTime(
  Map<String, dynamic> record,
) {
  final fields = <String, Object?>{};
  for (final MapEntry<String, dynamic> field in record.entries) {
    if (field.key == 'lastUpdateCheck' || field.key == appRecordRevisionKey) {
      continue;
    }
    final Object? value = field.value;
    if (value is List) {
      if (value.any((Object? element) => element is List || element is Map)) {
        return null;
      }
      fields[field.key] = List<Object?>.unmodifiable(value);
    } else if (value is Map) {
      return null;
    } else {
      fields[field.key] = value;
    }
  }
  return fields;
}
