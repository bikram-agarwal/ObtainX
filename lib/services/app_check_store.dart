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
  final DatabaseFactory? factory;
  Object? _failure;
  final revisions = <String, String>{};

  AppCheckStore(
    this.path, {
    this.operationTimeout = const Duration(seconds: 5),
    this.factory,
  });

  bool get isAvailable => _failure == null;

  Future<T> _run<T>(
    String operation,
    Future<T> Function(Database database) action,
  ) async {
    if (_failure != null) {
      throw _failure!;
    }
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
        operationTimeout,
        onTimeout: () {
          throw TimeoutException(
            'Check timestamp database $operation',
            operationTimeout,
          );
        },
      );
    } catch (error) {
      // Avoid repeating the same stall for each save batch or foreground load.
      // This cache is optional; JSON records remain the durable fallback.
      _failure = error;
      rethrow;
    }
  }

  /// Include SQLite's WAL, when enabled, so another engine's timestamp-only
  /// saves can be noticed without scanning app files or installed packages.
  Future<DateTime?> modified() async {
    try {
      return await _run('metadata read', (database) async {
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

  Future<Map<String, Map<String, Object?>>> read({String? singleId}) async {
    return _run('read', (database) async {
      final rows = await database.query(
        'checks',
        where: singleId == null ? null : 'id = ?',
        whereArgs: singleId == null ? null : [singleId],
      );
      return {for (final row in rows) row['id'] as String: row};
    });
  }

  void apply(
    Map<String, dynamic> json,
    Map<String, Map<String, Object?>> checks,
  ) {
    final id = json['id'] as String;
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
