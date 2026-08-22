// Generic Forgejo/Gitea instance detection.
//
// ObtainX resolves sources by hostname (see [SourceProvider.getSource]) and the
// Forgejo adapter ([Codeberg]) declares exactly one host: codeberg.org. Every
// other Forgejo instance therefore fell through to the [HTML] catch-all, so
// ObtainX scraped the rendered release page instead of asking the instance's
// JSON API - heavier, more fragile, and the direct cause of the rate limiting
// CodeFloe's maintainers reported
// (https://forum.codefloe.com/t/obtainium-hitting-rate-limit/148). They asked
// for auto-detection of any Forgejo host rather than a Codeberg special case;
// this is that (issue #254).
//
// Source matching itself is synchronous and cached, so the detection cannot
// live inside it - a probe is a network round-trip. Instead it runs where a URL
// first enters the app (the Add App form and bulk URL import) and, on success,
// selects the Forgejo adapter through the existing per-app `overrideSource`
// mechanism. That is precisely what a user does by hand today with
// "Override source -> Forgejo (Codeberg)", so the result persists with the app,
// survives export/import, and stays editable in the UI - no new stored state,
// no migration, and a wrong guess is one dropdown away from being corrected.
//
// The probe is two requests, and stops at the first:
//
//   1. GET <origin>/api/v1/version
//      -> 200 {"version": "16.0.2"}
//   2. GET <origin>/api/v1/repos/<owner>/<repo>
//      -> 200 {"name": ..., "full_name": "<owner>/<repo>", "owner": {...}}
//
// Step 1 rules out virtually every non-forge host in a single request, and its
// verdict is cached per authority for the process lifetime - so importing
// twenty repos from one instance probes that instance once. Step 2 confirms the
// path really is a repository and that the API answers in the shape [Codeberg]
// needs before any URL is rewritten. Both must pass.

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/providers/source_provider.dart';

/// The [AppSource.sourceIdentifier] of the Forgejo adapter - the value
/// stored in [App.overrideSource] for a detected instance. Read off the
/// source itself so a class rename can never silently desync the two.
final String forgejoSourceIdentifier = Codeberg().sourceIdentifier;

/// A URL confirmed to point at a repository on a Forgejo/Gitea instance.
class ForgejoDetection {
  const ForgejoDetection({required this.canonicalUrl, required this.authority});

  /// The repository root: `<scheme>://<authority>/<owner>/<repo>`.
  ///
  /// [Codeberg] builds its API paths straight off the app URL's path, so a URL
  /// carrying anything extra (`/releases`, `/src/branch/main`, a `.git` suffix)
  /// would produce a nonsense API path. `standardizeUrl` cannot trim it
  /// either, because it skips source-specific standardization whenever the
  /// host has been overridden. Callers therefore replace the user's URL
  /// with this one.
  final String canonicalUrl;

  /// Host, plus port when the instance runs on a non-default one.
  final String authority;

  /// The value to pass as `overrideSource` for [canonicalUrl].
  String get sourceIdentifier => forgejoSourceIdentifier;
}

/// The `<owner>/<repo>` reading of a URL, and the endpoints it implies.
@visibleForTesting
class ForgejoRepoCandidate {
  const ForgejoRepoCandidate({
    required this.origin,
    required this.authority,
    required this.owner,
    required this.repo,
  });

  /// `<scheme>://<authority>`.
  final String origin;
  final String authority;
  final String owner;
  final String repo;

  String get canonicalUrl => '$origin/$owner/$repo';
  String get versionProbeUrl => '$origin/api/v1/version';
  String get repoProbeUrl => '$origin/api/v1/repos/$owner/$repo';
}

/// Fetches [url] and returns the response. Injected in tests; production uses
/// [ForgejoDetector.defaultProbe].
typedef ForgejoProbe = Future<http.Response> Function(String url);

class ForgejoDetector {
  ForgejoDetector._();

  static const Duration probeTimeout = Duration(seconds: 8);

  /// A Forgejo `/api/v1/version` body is a few dozen bytes and a repo payload a
  /// few kilobytes. Anything larger is some other server's response and is not
  /// worth handing to [jsonDecode].
  static const int _maxProbeBodyLength = 256 * 1024;

  /// Forgejo routes these top-level paths itself, so `/<segment>/<x>` is never
  /// `<owner>/<repo>` for them. Skipping them avoids a pointless request.
  static const Set<String> _reservedOwnerSegments = <String>{
    'admin',
    'api',
    'assets',
    'attachments',
    'avatar',
    'avatars',
    'explore',
    'issues',
    'login',
    'milestones',
    'notifications',
    'org',
    'pulls',
    'repo',
    'user',
    'users',
  };

  /// Forgejo and Gitea both report a dotted numeric version (`16.0.2`,
  /// `16.0.0-dev-694-33ae492b+gitea-1.22.0`, `1.22.0`). Requiring that shape
  /// rather than any non-empty string keeps an unrelated server that happens to
  /// answer `/api/v1/version` from being mistaken for a forge, while staying
  /// tolerant of whatever suffixes future releases add.
  static final RegExp _versionShape = RegExp(r'^\d+\.\d+');

  /// Per-authority result of step 1, for this process only. Absent means
  /// "not asked yet"; a failed request is deliberately not recorded, so
  /// being offline at the wrong moment does not blacklist an instance for
  /// the whole session.
  static final Map<String, bool> _authorityRunsForgejoApi = <String, bool>{};

  @visibleForTesting
  static void resetProbeCache() => _authorityRunsForgejoApi.clear();

  /// Detects a Forgejo repository, but only for URLs that ObtainX would
  /// otherwise hand to the generic [HTML] scraper. A URL that already resolves
  /// to a real source (github.com, codeberg.org, an F-Droid repo, ...) is left
  /// alone - this exists to rescue the fallback case, not to second-guess
  /// working matches.
  static Future<ForgejoDetection?> detectIfUnmatched(
    String url, {
    ForgejoProbe? probe,
  }) async {
    if (!fallsBackToGenericHtml(url)) return null;
    return detect(url, probe: probe);
  }

  /// Whether [url] resolves to the [HTML] catch-all (or to no source at all).
  static bool fallsBackToGenericHtml(String url) {
    try {
      return SourceProvider().getSourceTemplate(url) is HTML;
    } catch (_) {
      // Not a URL any source accepts - nothing to detect.
      return false;
    }
  }

  /// Runs the probe regardless of which source [url] currently resolves to.
  static Future<ForgejoDetection?> detect(
    String url, {
    ForgejoProbe? probe,
  }) async {
    final ForgejoRepoCandidate? candidate = candidateFromUrl(url);
    if (candidate == null) return null;
    final ForgejoProbe fetch = probe ?? defaultProbe;
    if (!await _authorityAnswersForgejoApi(candidate, fetch)) return null;
    final http.Response? repoResponse = await _probe(
      candidate.repoProbeUrl,
      fetch,
    );
    if (repoResponse == null || repoResponse.statusCode != 200) return null;
    if (!looksLikeRepoPayload(repoResponse.body)) return null;
    return ForgejoDetection(
      canonicalUrl: candidate.canonicalUrl,
      authority: candidate.authority,
    );
  }

  /// Reads [url] as `<scheme>://<authority>/<owner>/<repo>`, ignoring anything
  /// after the repo name, or returns null when it cannot possibly be one.
  @visibleForTesting
  static ForgejoRepoCandidate? candidateFromUrl(String url) {
    // Accepts scheme-less input the same way the Add App field does.
    final String? prepared = _preStandardizeOrNull(url);
    if (prepared == null) return null;
    final Uri? uri = Uri.tryParse(prepared);
    if (uri == null) return null;
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    final List<String> segments = uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList();
    if (segments.length < 2) return null;
    final String owner = segments[0];
    if (_reservedOwnerSegments.contains(owner.toLowerCase())) return null;
    String repo = segments[1];
    if (repo.length > 4 && repo.toLowerCase().endsWith('.git')) {
      repo = repo.substring(0, repo.length - 4);
    }
    if (owner.isEmpty || repo.isEmpty) return null;
    final String authority = uri.hasPort
        ? '${uri.host}:${uri.port}'
        : uri.host;
    return ForgejoRepoCandidate(
      origin: '$scheme://$authority',
      authority: authority,
      owner: owner,
      repo: repo,
    );
  }

  /// [preStandardizeUrl] throws on input that is not URL-shaped at all.
  static String? _preStandardizeOrNull(String url) {
    try {
      return preStandardizeUrl(url.trim());
    } catch (_) {
      return null;
    }
  }

  /// Step 1, memoized per authority.
  static Future<bool> _authorityAnswersForgejoApi(
    ForgejoRepoCandidate candidate,
    ForgejoProbe fetch,
  ) async {
    final bool? cached = _authorityRunsForgejoApi[candidate.authority];
    if (cached != null) return cached;
    final http.Response? response = await _probe(
      candidate.versionProbeUrl,
      fetch,
    );
    // A request that never completed (offline, DNS failure, timeout) is not a
    // verdict, so leave the authority uncached and let a later attempt decide.
    if (response == null) return false;
    final bool answers =
        response.statusCode == 200 && looksLikeVersionPayload(response.body);
    _authorityRunsForgejoApi[candidate.authority] = answers;
    return answers;
  }

  static Future<http.Response?> _probe(String url, ForgejoProbe fetch) async {
    try {
      return await fetch(url).timeout(probeTimeout);
    } catch (_) {
      // Any failure just means "not detected"; the URL still works as HTML.
      return null;
    }
  }

  /// Goes through [AppSource.sourceRequest] rather than a bare `http.get`
  /// so the probe inherits the app's redirect cap and TLS handling.
  /// [Codeberg] adds no headers of its own, so this is an unauthenticated
  /// GET.
  static Future<http.Response> defaultProbe(String url) =>
      Codeberg().sourceRequest(url, const <String, dynamic>{});

  @visibleForTesting
  static bool looksLikeVersionPayload(String body) {
    final Map<String, dynamic>? json = _decodeObject(body);
    if (json == null) return false;
    final dynamic version = json['version'];
    return version is String && _versionShape.hasMatch(version.trim());
  }

  @visibleForTesting
  static bool looksLikeRepoPayload(String body) {
    final Map<String, dynamic>? json = _decodeObject(body);
    if (json == null) return false;
    final dynamic fullName = json['full_name'];
    final dynamic owner = json['owner'];
    // The subset of the (GitHub-shaped) repo payload [Codeberg] relies on.
    return json['name'] is String &&
        fullName is String &&
        fullName.contains('/') &&
        owner is Map &&
        owner['login'] is String;
  }

  static Map<String, dynamic>? _decodeObject(String body) {
    if (body.isEmpty || body.length > _maxProbeBodyLength) return null;
    try {
      final dynamic decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
