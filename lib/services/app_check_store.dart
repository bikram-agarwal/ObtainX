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
  final revisions = <String, String>{};

  AppCheckStore(this.path);

  /// Include SQLite's WAL, when enabled, so another engine's timestamp-only
  /// saves can be noticed without scanning app files or installed packages.
  Future<DateTime?> modified() async {
    try {
      final database = await _open();
      final stats = await Future.wait([
        File(database.path).stat(),
        File('${database.path}-wal').stat(),
      ]);
      return stats[0].modified.isAfter(stats[1].modified)
          ? stats[0].modified
          : stats[1].modified;
    } catch (_) {
      return null;
    }
  }

  Future<Database> _open() async {
    final pending = _database ??= openDatabase(
      path,
      version: 1,
      onCreate: (database, _) async {
        await database.execute(
          'CREATE TABLE checks ('
          'id TEXT PRIMARY KEY, revision TEXT NOT NULL, checked INTEGER NOT NULL)',
        );
      },
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_database, pending)) _database = null;
      rethrow;
    }
  }

  Future<Map<String, Map<String, Object?>>> read({String? singleId}) async {
    final database = await _open();
    final rows = await database.query(
      'checks',
      where: singleId == null ? null : 'id = ?',
      whereArgs: singleId == null ? null : [singleId],
    );
    return {for (final row in rows) row['id'] as String: row};
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
    final batch = (await _open()).batch();
    for (final checkpoint in checkpoints) {
      batch.insert(
        'checks',
        checkpoint,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> remove(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final batch = (await _open()).batch();
    for (final id in ids) {
      revisions.remove(id);
      batch.delete('checks', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> close() async {
    final pending = _database;
    _database = null;
    if (pending != null) await (await pending).close();
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
