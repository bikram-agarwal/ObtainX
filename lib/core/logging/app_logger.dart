// Static logging API shared with upstream Obtainium.
//
// Upstream replaced LogsProvider with a static AppLogger backed by its own
// AppLogDb (1b0810c4, 883f8584). ObtainX keeps LogsProvider as the only log
// engine (VACUUM on large clears, the timestamp index, limit/orderBy reads,
// LogsSheet, performance recording, and logging from every isolate without an
// init call) and exposes upstream's static API on top of it, so upstream call
// sites compile unchanged. Don't add a second database or a console logger.

import 'dart:async';

import 'package:obtainium/providers/logs_provider.dart';

class AppLogger {
  AppLogger._();

  /// No-op: [LogsProvider] opens logs.db lazily in whichever isolate logs
  /// first and prunes entries older than 7 days once per process.
  static Future<void> init() async {}

  static Future<List<Log>> getLogs({DateTime? before, DateTime? after}) =>
      LogsProvider().get(before: before, after: after);

  static Future<int> clearLogs({DateTime? before, DateTime? after}) =>
      LogsProvider().clear(before: before, after: after);

  static void debug(String message, {Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.debug, message, error: error, stackTrace: stackTrace);
  }

  static void info(String message, {Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.info, message, error: error, stackTrace: stackTrace);
  }

  static void warn(String message, {Object? error, StackTrace? stackTrace}) {
    _log(LogLevel.warning, message, error: error, stackTrace: stackTrace);
  }

  static void error(Object error, {StackTrace? stackTrace, String? message}) {
    _log(
      LogLevel.error,
      message ?? 'Unexpected error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    // LogsProvider.add never throws, so a failing write can't re-enter the
    // global error handler.
    unawaited(
      LogsProvider().add(
        _formatPersistedMessage(level, message, error, stackTrace),
        level: level,
      ),
    );
  }

  /// Avoids repeating the error when its text equals the message (upstream
  /// 545e871f), and keeps stack traces for warnings and errors.
  static String _formatPersistedMessage(
    LogLevel level,
    String message,
    Object? error,
    StackTrace? stackTrace,
  ) {
    final StringBuffer buffer = StringBuffer(message);
    if (error != null && error.toString() != message) {
      buffer.write(': $error');
    }
    if (stackTrace != null &&
        (level == LogLevel.warning || level == LogLevel.error)) {
      buffer.write('\n$stackTrace');
    }
    return buffer.toString();
  }
}
