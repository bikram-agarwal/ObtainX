// Per-host request limiting for metadata requests: bounds concurrency and
// short-circuits requests to hosts that recently challenged or rate-limited us.
//
// Upstream added this for APKMirror after ObtainX#339. ObtainX additions
// (v1.7.4 sync): hosts are keyed by their root domain, so `www.` and bare
// requests share one budget ([hostKeyFor]); page (html) requests are also
// spaced at least [htmlMinInterval] apart, because APKMirror challenges more
// than 20 page requests in 15 s; and [runResponse] wraps run + observe for
// request paths outside `AppSource.sourceRequest`. A challenge blocks only
// the request class that got it (D18 a): throttled pages stop, while the
// allowlisted feed keeps working.

import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:obtainium/custom_errors.dart';

class HostRequestGate {
  HostRequestGate({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final HostRequestGate instance = HostRequestGate();

  static const Duration challengeBlockDuration = Duration(minutes: 5);
  static const Duration defaultRateLimitBlockDuration = Duration(seconds: 60);

  /// Minimum spacing between two page (html) requests to one host.
  static const Duration htmlMinInterval = Duration(seconds: 1);

  final DateTime Function() _now;
  final Map<String, _HostState> _hosts = {};
  final Map<String, DateTime> _blockedUntil = {};
  final Map<String, DateTime> _nextSlot = {};

  /// The key a request to [uri] is counted under: its root domain, so
  /// `www.apkmirror.com` and `apkmirror.com` share one budget.
  static String hostKeyFor(Uri uri) {
    final parts = uri.host.toLowerCase().split('.');
    return parts.length > 2
        ? parts.sublist(parts.length - 2).join('.')
        : uri.host.toLowerCase();
  }

  /// The request class of [uri]: `api`, `feed` or `html`.
  static String requestClassFor(Uri uri) {
    final path = uri.path;
    if (path.contains('/wp-json/')) return 'api';
    if (path.endsWith('/feed/') || path.endsWith('/feed')) return 'feed';
    return 'html';
  }

  /// [run] then [observe] for one HTTP request to [uri], keyed with
  /// [hostKeyFor] and [requestClassFor]. Page requests are spaced by
  /// [htmlMinInterval].
  Future<http.Response> runResponse(
    Uri uri,
    int maxConcurrent,
    Future<http.Response> Function() action,
  ) async {
    final host = hostKeyFor(uri);
    final requestClass = requestClassFor(uri);
    final blockKey = '$host|$requestClass';
    final response = await run(
      host,
      blockKey,
      maxConcurrent,
      action,
      minInterval: requestClass == 'html' ? htmlMinInterval : null,
    );
    observe(blockKey, response.statusCode, response.headers);
    return response;
  }

  _HostState _state(String host) => _hosts.putIfAbsent(host, _HostState.new);

  int? _remainingBlockMinutes(String blockKey) {
    final until = _blockedUntil[blockKey];
    if (until == null) return null;
    final now = _now();
    if (!now.isBefore(until)) {
      _blockedUntil.remove(blockKey);
      return null;
    }
    return max(1, (until.difference(now).inSeconds / 60).ceil());
  }

  /// Runs [action] honoring [host]'s concurrency limit. [blockKey] identifies
  /// the request class (e.g. api/feed/html) so a challenge on one class does
  /// not suppress the others. Throws [RateLimitError] without invoking
  /// [action] while the class is blocked. With [minInterval], requests of one
  /// [blockKey] start at least that far apart (waited for before taking a
  /// concurrency slot, so other classes on the host aren't held up).
  Future<T> run<T>(
    String host,
    String blockKey,
    int maxConcurrent,
    Future<T> Function() action, {
    Duration? minInterval,
  }) {
    final remainingMinutes = _remainingBlockMinutes(blockKey);
    if (remainingMinutes != null) {
      throw RateLimitError(remainingMinutes);
    }
    if (minInterval == null) {
      return _state(host).run(maxConcurrent, action);
    }
    return _waitForSlot(blockKey, minInterval).then((_) {
      final remaining = _remainingBlockMinutes(blockKey);
      if (remaining != null) {
        throw RateLimitError(remaining);
      }
      return _state(host).run(maxConcurrent, action);
    });
  }

  Future<void> _waitForSlot(String blockKey, Duration interval) async {
    final now = _now();
    final next = _nextSlot[blockKey];
    final start = next == null || next.isBefore(now) ? now : next;
    _nextSlot[blockKey] = start.add(interval);
    final wait = start.difference(now);
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
    }
  }

  /// Records a completed response and blocks that request class when it
  /// carries a Cloudflare challenge or a rate-limit signal.
  void observe(String blockKey, int statusCode, Map<String, String> headers) {
    if (statusCode != 403 && statusCode != 429 && statusCode != 503) return;
    final challenge =
        headers['cf-mitigated']?.toLowerCase().trim() == 'challenge';
    if (challenge) {
      _blockUntil(blockKey, _now().add(challengeBlockDuration));
      return;
    }
    if (statusCode == 429 || statusCode == 503) {
      final retryAfter = int.tryParse(headers['retry-after']?.trim() ?? '');
      _blockUntil(
        blockKey,
        _now().add(
          retryAfter != null && retryAfter > 0
              ? Duration(seconds: retryAfter)
              : defaultRateLimitBlockDuration,
        ),
      );
    }
  }

  void _blockUntil(String blockKey, DateTime until) {
    final current = _blockedUntil[blockKey];
    if (current == null || until.isAfter(current)) {
      _blockedUntil[blockKey] = until;
    }
  }
}

class _HostState {
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<T> run<T>(int maxConcurrent, Future<T> Function() action) async {
    while (_active >= maxConcurrent) {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }
    _active++;
    try {
      return await action();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
  }
}
