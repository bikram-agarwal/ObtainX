import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

const String logTable = 'logs';
const String idColumn = '_id';
const String levelColumn = 'level';
const String messageColumn = 'message';
const String timestampColumn = 'timestamp';
const String dbPath = 'logs.db';

enum LogLevels { debug, info, warning, error }

class Log {
  int? id;
  late LogLevels level;
  late String message;
  DateTime timestamp = DateTime.now();

  Map<String, Object?> toMap() {
    var map = <String, Object?>{
      idColumn: id,
      levelColumn: level.index,
      messageColumn: message,
      timestampColumn: timestamp.millisecondsSinceEpoch,
    };
    return map;
  }

  Log(this.message, this.level);

  Log.fromMap(Map<String, Object?> map) {
    id = map[idColumn] as int;
    level = LogLevels.values.elementAt(map[levelColumn] as int);
    message = map[messageColumn] as String;
    timestamp = DateTime.fromMillisecondsSinceEpoch(
      map[timestampColumn] as int,
    );
  }

  @override
  String toString() {
    return '${timestamp.toString()}: ${level.name}: $message';
  }
}

class LogsProvider {
  LogsProvider({bool runDefaultClear = true}) {
    if (runDefaultClear) {
      clear(before: DateTime.now().subtract(const Duration(days: 7)));
    }
  }

  static Future<Database>? _dbFuture;

  Future<Database> getDB() {
    _dbFuture ??= openDatabase(
      dbPath,
      version: 1,
      onCreate: (Database databaseInstance, int version) async {
        await databaseInstance.execute('''
create table if not exists $logTable ( 
  $idColumn integer primary key autoincrement, 
  $levelColumn integer not null,
  $messageColumn text not null,
  $timestampColumn integer not null)
''');
      },
      onOpen: (Database database) async {
        await database.execute(
          'create index if not exists idx_logs_timestamp on $logTable ($timestampColumn)',
        );
      },
    );
    return _dbFuture!;
  }

  Future<Log> add(String message, {LogLevels level = LogLevels.info}) async {
    Log l = Log(message, level);
    l.id = await (await getDB()).insert(logTable, l.toMap());
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
    var where = getWhereDates(before: before, after: after);
    return (await (await getDB()).query(
      logTable,
      where: where.key,
      whereArgs: where.value,
      limit: limit,
      orderBy: orderBy,
    )).map((logMap) => Log.fromMap(logMap)).toList();
  }

  Future<int> clear({DateTime? before, DateTime? after}) async {
    var where = getWhereDates(before: before, after: after);
    final database = await getDB();
    var res = await database.delete(
      logTable,
      where: where.key,
      whereArgs: where.value,
    );
    if (res > 0) {
      add(
        plural(
          'clearedNLogsBeforeXAfterY',
          res,
          namedArgs: {'before': before.toString(), 'after': after.toString()},
          name: 'n',
        ),
      );
    }
    // SQLite reclaims free pages internally on DELETE but does not shrink the
    // file. Without VACUUM, a months-old debug-log run can leave logs.db
    // multi-megabyte even though it's mostly tombstones. Run VACUUM only
    // when the delete was meaningful — VACUUM on every constructor call
    // (which fires on every app startup at minimum) would be wasted I/O.
    if (res >= 100) {
      try {
        await database.execute('VACUUM');
      } catch (_) {
        // VACUUM can fail mid-write or on an already-locked DB. Silent
        // failure is fine: the file just stays oversized until the next
        // successful prune.
      }
    }
    return res;
  }
}

MapEntry<String?, List<int>?> getWhereDates({
  DateTime? before,
  DateTime? after,
}) {
  List<String> where = [];
  List<int> whereArgs = [];
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
