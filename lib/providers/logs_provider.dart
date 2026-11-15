import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

const String logTable = 'logs';
const String idColumn = '_id';
const String levelColumn = 'level';
const String messageColumn = 'message';
const String timestampColumn = 'timestamp';
const String dbPath = 'logs.db';

enum LogLevel { debug, info, warning, error }

class Log {
  int? id;
  late LogLevel level;
  late String message;
  DateTime timestamp = DateTime.now();

  Map<String, Object?> toMap() {
    final map = <String, Object?>{
      idColumn: id,
      levelColumn: level.index,
      messageColumn: message,
      timestampColumn: timestamp.millisecondsSinceEpoch,
    };
    return map;
  }

  Log(this.message, this.level);

  /// Tolerant of a malformed row (bad level index, null message or timestamp),
  /// so one bad entry can't hide the whole log window (upstream bcf37107).
  Log.fromMap(Map<String, Object?> map) {
    id = map[idColumn] as int?;
    final Object? rawLevel = map[levelColumn];
    level =
        rawLevel is int && rawLevel >= 0 && rawLevel < LogLevel.values.length
        ? LogLevel.values[rawLevel]
        : LogLevel.info;
    message = map[messageColumn]?.toString() ?? '';
    final Object? rawTimestamp = map[timestampColumn];
    timestamp = DateTime.fromMillisecondsSinceEpoch(
      rawTimestamp is int ? rawTimestamp : 0,
    );
  }

  @override
  String toString() {
    return '${timestamp.toString()}: ${level.name}: $message';
  }
}

/// Singleton sqflite-backed logger with automatic 7-day cleanup.
///
/// Use `LogsProvider().add(msg)` to log; the factory returns a shared instance.
/// Old entries (>7 days) are cleaned up once per process lifetime.
class LogsProvider {
  static final LogsProvider _instance = LogsProvider._();
  static Database? _db;
  static bool _defaultClearScheduled = false;

  // Shared singleton: many call sites construct LogsProvider() ad-hoc just to
  // log a line. A factory avoids doing DB work (the 7-day cleanup DELETE) on
  // every such construction - the cleanup runs at most once per process.
  factory LogsProvider({bool runDefaultClear = true}) {
    if (runDefaultClear && !_defaultClearScheduled) {
      _defaultClearScheduled = true;
      _instance
          .clear(before: DateTime.now().subtract(const Duration(days: 7)))
          .catchError((e) {
            debugPrint('Failed to clear old logs: $e');
            return 0;
          });
    }
    return _instance;
  }

  LogsProvider._();

  Future<Database> getDB() async {
    _db ??= await openDatabase(
      dbPath,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
create table if not exists $logTable ( 
  $idColumn integer primary key autoincrement, 
  $levelColumn integer not null,
  $messageColumn text not null,
  $timestampColumn integer not null)
''');
      },
      onOpen: (Database db) async {
        // Index the timestamp column so the logs-viewer date-range queries
        // don't full-scan (parity with fork main).
        await db.execute(
          'create index if not exists idx_logs_timestamp on $logTable ($timestampColumn)',
        );
      },
    );
    return _db!;
  }

  Future<Log> add(String message, {LogLevel level = LogLevel.info}) async {
    final Log l = Log(message, level);
    try {
      l.id = await (await getDB()).insert(logTable, l.toMap());
    } catch (e) {
      // A failed logging write must not reach the global error handler: that
      // handler logs, which would attempt the same failing write again and
      // loop (upstream bc4a37e5).
      debugPrint('Failed to persist log entry: $e');
    }
    if (kDebugMode) {
      debugPrint(l.toString());
    }
    return l;
  }

  Future<List<Log>> get({
    DateTime? before,
    DateTime? after,
    int? limit,
    String? orderBy,
  }) async {
    final where = getWhereDates(before: before, after: after);
    return (await (await getDB()).query(
      logTable,
      where: where.key,
      whereArgs: where.value,
      limit: limit,
      orderBy: orderBy,
    )).map((e) => Log.fromMap(e)).toList();
  }

  Future<int> clear({DateTime? before, DateTime? after}) async {
    final where = getWhereDates(before: before, after: after);
    final database = await getDB();
    final res = await database.delete(
      logTable,
      where: where.key,
      whereArgs: where.value,
    );
    if (res > 0) {
      unawaited(
        add(
          plural(
            'clearedNLogsBeforeXAfterY',
            res,
            namedArgs: {
              'before': before?.toIso8601String() ?? '...',
              'after': after?.toIso8601String() ?? '...',
            },
            name: 'n',
          ),
        ),
      );
    }
    // SQLite reclaims free pages on DELETE but doesn't shrink the file; without
    // VACUUM a large debug-log run leaves logs.db multi-megabyte even when it's
    // mostly tombstones. Only VACUUM on a meaningful delete — running it on the
    // every-startup constructor cleanup would be wasted I/O. Parity with main.
    if (res >= 100) {
      try {
        await database.execute('VACUUM');
      } catch (_) {
        // VACUUM can fail on a locked/mid-write DB; the file just stays
        // oversized until the next successful prune.
      }
    }
    return res;
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

MapEntry<String?, List<int>?> getWhereDates({
  DateTime? before,
  DateTime? after,
}) {
  final List<String> where = [];
  final List<int> whereArgs = [];
  if (before != null) {
    where.add('$timestampColumn < ?');
    whereArgs.add(before.millisecondsSinceEpoch);
  }
  if (after != null) {
    where.add('$timestampColumn > ?');
    whereArgs.add(after.millisecondsSinceEpoch);
  }
  return whereArgs.isEmpty
      ? const MapEntry(null, null)
      : MapEntry(where.join(' and '), whereArgs);
}
