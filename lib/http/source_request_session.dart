import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Connection and repository-response ownership for one update operation.
/// A new operation always starts fresh; parallel app checks share in-flight work.
class SourceRequestSession {
  static final Object _zoneKey = Object();
  final Map<bool, HttpClient> _clients = {};
  final Map<String, Future<http.Response>> _repositoryResponses = {};
  bool _closed = false;

  static SourceRequestSession? get current {
    final session = Zone.current[_zoneKey] as SourceRequestSession?;
    return session?._closed == false ? session : null;
  }

  static Future<T> run<T>(Future<T> Function() action) async {
    if (current != null) return action();
    final session = SourceRequestSession();
    try {
      return await runZoned(action, zoneValues: {_zoneKey: session});
    } finally {
      session._closed = true;
      session._repositoryResponses.clear();
      for (final client in session._clients.values) {
        client.close();
      }
      session._clients.clear();
    }
  }

  HttpClient clientFor(bool allowInsecure) {
    return _clients.putIfAbsent(allowInsecure, () {
      final client = HttpClient()..maxConnectionsPerHost = 8;
      if (allowInsecure) {
        client.badCertificateCallback = (_, _, _) => true;
      }
      return client;
    });
  }

  Future<http.Response> repositoryResponse(
    String key,
    Future<http.Response> Function() load,
  ) async {
    final pending = _repositoryResponses.putIfAbsent(key, load);
    try {
      final response = await pending;
      if (response.statusCode != HttpStatus.ok &&
          identical(_repositoryResponses[key], pending)) {
        unawaited(_repositoryResponses.remove(key));
      }
      return response;
    } catch (_) {
      if (identical(_repositoryResponses[key], pending)) {
        unawaited(_repositoryResponses.remove(key));
      }
      rethrow;
    }
  }
}
