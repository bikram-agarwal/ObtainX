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
        final database = await _open();
        // A timed-out open can still finish later. Do not start its queued
        // query/write after the caller has switched to durable JSON records.
        if (_failure != null) {
          throw _failure!;
        }
        return action(database);
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

  Future<Database> _open() async {
    final pending = _database ??= (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
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
    try {
      return await pending;
    } catch (_) {
      if (identical(_database, pending)) _database = null;
      rethrow;
    }
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
      return;
    }
    revisions[id] = revision;
    final checkpoint = checks[id];
    if (checkpoint?['revision'] == revision) {
      final checked = checkpoint!['checked'] as int;
      final recorded = dateTimeFromJsonValue(json['lastUpdateCheck']);
      if (recorded == null || checked > recorded.microsecondsSinceEpoch) {
        json['lastUpdateCheck'] = checked;
      }
    }
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

bool onlyAppCheckTimeChanged(App previous, App current) {
  if (current.lastUpdateCheck == null) return false;
  final previousFields = previous.toJson(encodeNested: false)
    ..remove('lastUpdateCheck');
  final currentFields = current.toJson(encodeNested: false)
    ..remove('lastUpdateCheck');
  return const DeepCollectionEquality().equals(previousFields, currentFields);
}
