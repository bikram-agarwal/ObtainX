import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/forgejo_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What codefloe.com actually answers at /api/v1/version (checked 2026-08-22).
const String _forgejoVersionBody = '{"version":"16.0.2"}';

/// What codeberg.org answers - same endpoint, longer version string.
const String _codebergVersionBody =
    '{"version":"16.0.0-dev-694-33ae492b+gitea-1.22.0"}';

String _repoBody(String host, String owner, String repo) => jsonEncode({
  'id': 1234,
  'name': repo,
  'full_name': '$owner/$repo',
  'owner': <String, dynamic>{'login': owner, 'id': 7},
  'html_url': 'https://$host/$owner/$repo',
});

/// Answers the two probe endpoints from [responses]; anything else 404s, the
/// way a host that is not a forge would. Records every URL it was asked for.
class _FakeForge {
  _FakeForge(this.responses);

  final Map<String, http.Response> responses;
  final List<String> requested = <String>[];

  Future<http.Response> probe(String url) async {
    requested.add(url);
    return responses[url] ?? http.Response('<html>Not Found</html>', 404);
  }
}

_FakeForge _workingForge({
  String host = 'forgejo.example.org',
  String owner = 'SnappTechnology',
  String repo = 'NextCloudTalkNext',
}) => _FakeForge(<String, http.Response>{
  'https://$host/api/v1/version': http.Response(_forgejoVersionBody, 200),
  'https://$host/api/v1/repos/$owner/$repo': http.Response(
    _repoBody(host, owner, repo),
    200,
  ),
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ForgejoDetector.resetProbeCache();
  });

  group('candidateFromUrl', () {
    test('reads owner and repo off a repo root', () {
      final ForgejoRepoCandidate? candidate = ForgejoDetector.candidateFromUrl(
        'https://codefloe.com/SnappTechnology/NextCloudTalkNext',
      );
      expect(candidate, isNotNull);
      expect(candidate!.authority, 'codefloe.com');
      expect(candidate.owner, 'SnappTechnology');
      expect(candidate.repo, 'NextCloudTalkNext');
      expect(
        candidate.canonicalUrl,
        'https://codefloe.com/SnappTechnology/NextCloudTalkNext',
      );
      expect(candidate.versionProbeUrl, 'https://codefloe.com/api/v1/version');
      expect(
        candidate.repoProbeUrl,
        'https://codefloe.com/api/v1/repos/SnappTechnology/NextCloudTalkNext',
      );
    });

    test('drops everything past the repo name', () {
      // The overridden source keeps the URL's path verbatim when building API
      // calls, so /releases would become .../repos/owner/repo/releases.
      for (final String url in <String>[
        'https://codefloe.com/owner/repo/releases',
        'https://codefloe.com/owner/repo/src/branch/main',
        'https://codefloe.com/owner/repo/releases/tag/v1.2.3',
      ]) {
        expect(
          ForgejoDetector.candidateFromUrl(url)?.canonicalUrl,
          'https://codefloe.com/owner/repo',
          reason: url,
        );
      }
    });

    test('strips a .git clone suffix', () {
      expect(
        ForgejoDetector.candidateFromUrl(
          'https://codefloe.com/owner/repo.git',
        )?.repo,
        'repo',
      );
      // A repo genuinely named ".git" keeps its name rather than emptying out.
      expect(
        ForgejoDetector.candidateFromUrl(
          'https://codefloe.com/owner/.git',
        )?.repo,
        '.git',
      );
    });

    test('accepts scheme-less input like the Add App field does', () {
      expect(
        ForgejoDetector.candidateFromUrl('codefloe.com/owner/repo')?.origin,
        'https://codefloe.com',
      );
    });

    test('keeps a non-default port', () {
      final ForgejoRepoCandidate? candidate = ForgejoDetector.candidateFromUrl(
        'http://git.example.com:3000/owner/repo',
      );
      expect(candidate?.authority, 'git.example.com:3000');
      expect(candidate?.origin, 'http://git.example.com:3000');
      expect(
        candidate?.versionProbeUrl,
        'http://git.example.com:3000/api/v1/version',
      );
    });

    test('rejects what cannot be a repo path', () {
      expect(ForgejoDetector.candidateFromUrl('https://codefloe.com'), isNull);
      expect(
        ForgejoDetector.candidateFromUrl('https://codefloe.com/owner'),
        isNull,
      );
      expect(ForgejoDetector.candidateFromUrl('not a url'), isNull);
      expect(ForgejoDetector.candidateFromUrl(''), isNull);
    });

    test("rejects Forgejo's own top-level routes as owners", () {
      for (final String url in <String>[
        'https://codefloe.com/explore/repos',
        'https://codefloe.com/user/settings',
        'https://codefloe.com/api/v1/version',
      ]) {
        expect(ForgejoDetector.candidateFromUrl(url), isNull, reason: url);
      }
    });
  });

  group('payload shape', () {
    test('accepts the version payloads Forgejo and Gitea actually send', () {
      expect(
        ForgejoDetector.looksLikeVersionPayload(_forgejoVersionBody),
        true,
      );
      expect(
        ForgejoDetector.looksLikeVersionPayload(_codebergVersionBody),
        true,
      );
      expect(
        ForgejoDetector.looksLikeVersionPayload('{"version":"1.22.0"}'),
        true,
      );
    });

    test('rejects anything that is not a forge version response', () {
      for (final String body in <String>[
        '',
        'not json',
        '<html><body>hi</body></html>',
        '{}',
        '{"version":""}',
        '{"version":"unknown"}',
        '{"version":123}',
        '{"api":"v1"}',
        '["16.0.2"]',
      ]) {
        expect(
          ForgejoDetector.looksLikeVersionPayload(body),
          false,
          reason: body,
        );
      }
    });

    test('accepts a repo payload in the shape Codeberg reads', () {
      expect(
        ForgejoDetector.looksLikeRepoPayload(
          _repoBody('codefloe.com', 'owner', 'repo'),
        ),
        true,
      );
    });

    test('rejects repo payloads missing the fields the source needs', () {
      for (final String body in <String>[
        '{}',
        'not json',
        '{"name":"repo"}',
        '{"name":"repo","full_name":"repo","owner":{"login":"owner"}}',
        '{"name":"repo","full_name":"owner/repo"}',
        '{"name":"repo","full_name":"owner/repo","owner":"owner"}',
        '{"full_name":"owner/repo","owner":{"login":"owner"}}',
      ]) {
        expect(ForgejoDetector.looksLikeRepoPayload(body), false, reason: body);
      }
    });
  });

  group('detect', () {
    test('confirms a Forgejo repo with one probe per endpoint', () async {
      final _FakeForge forge = _workingForge();
      final ForgejoDetection? detection = await ForgejoDetector.detect(
        'https://forgejo.example.org/SnappTechnology/NextCloudTalkNext/releases',
        probe: forge.probe,
      );
      expect(detection, isNotNull);
      expect(
        detection!.canonicalUrl,
        'https://forgejo.example.org/SnappTechnology/NextCloudTalkNext',
      );
      expect(detection.authority, 'forgejo.example.org');
      expect(detection.sourceIdentifier, Codeberg().sourceIdentifier);
      expect(forge.requested, <String>[
        'https://forgejo.example.org/api/v1/version',
        'https://forgejo.example.org/api/v1/repos/SnappTechnology/NextCloudTalkNext',
      ]);
    });

    test('stops at the version probe when the host is not a forge', () async {
      final _FakeForge forge = _FakeForge(<String, http.Response>{});
      expect(
        await ForgejoDetector.detect(
          'https://example.com/owner/repo',
          probe: forge.probe,
        ),
        isNull,
      );
      expect(forge.requested, <String>['https://example.com/api/v1/version']);
    });

    test('rejects a host answering the endpoint with something else', () async {
      final _FakeForge forge = _FakeForge(<String, http.Response>{
        'https://example.com/api/v1/version': http.Response(
          '{"status":"ok"}',
          200,
        ),
      });
      expect(
        await ForgejoDetector.detect(
          'https://example.com/owner/repo',
          probe: forge.probe,
        ),
        isNull,
      );
      expect(forge.requested.length, 1);
    });

    test('rejects a Forgejo host when the repo does not exist', () async {
      final _FakeForge forge = _FakeForge(<String, http.Response>{
        'https://forgejo.example.org/api/v1/version': http.Response(
          _forgejoVersionBody,
          200,
        ),
      });
      expect(
        await ForgejoDetector.detect(
          'https://forgejo.example.org/owner/nope',
          probe: forge.probe,
        ),
        isNull,
      );
      expect(forge.requested.length, 2);
    });

    test('probes each host only once, positive or negative', () async {
      final _FakeForge forge = _workingForge();
      forge.responses['https://forgejo.example.org/api/v1/repos/other/thing'] =
          http.Response(_repoBody('forgejo.example.org', 'other', 'thing'), 200);

      expect(
        await ForgejoDetector.detect(
          'https://forgejo.example.org/SnappTechnology/NextCloudTalkNext',
          probe: forge.probe,
        ),
        isNotNull,
      );
      expect(
        await ForgejoDetector.detect(
          'https://forgejo.example.org/other/thing',
          probe: forge.probe,
        ),
        isNotNull,
      );
      expect(
        forge.requested
            .where((String url) => url.endsWith('/api/v1/version'))
            .length,
        1,
      );

      final _FakeForge dud = _FakeForge(<String, http.Response>{});
      await ForgejoDetector.detect(
        'https://example.com/owner/repo',
        probe: dud.probe,
      );
      await ForgejoDetector.detect(
        'https://example.com/owner/other',
        probe: dud.probe,
      );
      expect(dud.requested, <String>['https://example.com/api/v1/version']);
    });

    test('does not cache a verdict when the probe itself failed', () async {
      int attempts = 0;
      Future<http.Response> flaky(String url) async {
        attempts++;
        if (attempts == 1) throw const SocketExceptionStub();
        return url.endsWith('/api/v1/version')
            ? http.Response(_forgejoVersionBody, 200)
            : http.Response(
                _repoBody('forgejo.example.org', 'owner', 'repo'),
                200,
              );
      }

      expect(
        await ForgejoDetector.detect(
          'https://forgejo.example.org/owner/repo',
          probe: flaky,
        ),
        isNull,
      );
      // The failure was not recorded as "not a forge", so a retry can succeed.
      expect(
        await ForgejoDetector.detect(
          'https://forgejo.example.org/owner/repo',
          probe: flaky,
        ),
        isNotNull,
      );
    });
  });

  group('detectIfUnmatched', () {
    test('leaves URLs that already resolve to a real source alone', () async {
      final _FakeForge forge = _workingForge(host: 'github.com');
      expect(
        await ForgejoDetector.detectIfUnmatched(
          'https://github.com/SnappTechnology/NextCloudTalkNext',
          probe: forge.probe,
        ),
        isNull,
      );
      expect(
        await ForgejoDetector.detectIfUnmatched(
          'https://codeberg.org/Freeyourgadget/Gadgetbridge',
          probe: forge.probe,
        ),
        isNull,
      );
      // A seeded Forgejo host is matched synchronously, so it must never pay
      // for a probe. This is the whole point of keeping entries in `hosts`.
      expect(
        await ForgejoDetector.detectIfUnmatched(
          'https://codefloe.com/SnappTechnology/NextCloudTalkNext',
          probe: forge.probe,
        ),
        isNull,
      );
      expect(forge.requested, isEmpty);
    });

    test('runs for a host that would otherwise be scraped as HTML', () async {
      final _FakeForge forge = _workingForge();
      final ForgejoDetection? detection =
          await ForgejoDetector.detectIfUnmatched(
            'https://forgejo.example.org/SnappTechnology/NextCloudTalkNext',
            probe: forge.probe,
          );
      expect(detection?.sourceIdentifier, Codeberg().sourceIdentifier);
      expect(forge.requested.length, 2);
    });
  });

  group('Codeberg on a non-codeberg host', () {
    test('a seeded host resolves to the Forgejo source, no override', () {
      expect(
        SourceProvider().getSourceTemplate('https://codefloe.com/owner/repo'),
        isA<Codeberg>(),
      );
    });

    test('a seeded host gets native URL standardization', () {
      // The override path cannot trim the URL (standardizeUrl skips
      // source-specific standardization once the host has been overridden),
      // which is why ForgejoDetector hands back a canonical URL instead. A
      // host in `hosts` needs no such help.
      const String url = 'https://codefloe.com/owner/repo/releases';
      expect(
        SourceProvider().getSource(url).standardizeUrl(url),
        'https://codefloe.com/owner/repo',
      );
    });

    test('infers the app ID from the app URL host, never hosts[0]', () async {
      final _RecordingCodeberg source = _RecordingCodeberg();
      // Pinned rather than relying on the shipped list: what matters is that
      // the target host is not hosts[0], whatever `hosts` grows into.
      source.hosts = <String>['codeberg.org', 'codefloe.com'];

      await source.tryInferringAppId('https://codefloe.com/owner/repo');

      expect(source.requested, isNotEmpty);
      for (final String url in source.requested) {
        expect(
          url,
          startsWith('https://codefloe.com/api/v1/repos/owner/repo/contents/'),
          reason: url,
        );
      }
    });

    test('keeps the scheme and port of a self-hosted instance', () async {
      final _RecordingCodeberg source = _RecordingCodeberg();
      await source.tryInferringAppId('http://git.example.com:3000/o/r');
      expect(
        source.requested.first,
        startsWith('http://git.example.com:3000/api/v1/repos/o/r/contents/'),
      );
    });
  });
}

/// Stands in for a transport failure without depending on dart:io in a test.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}

/// Records the URLs the source would fetch, and answers every one of them 404
/// so app-ID inference walks its whole candidate list and gives up.
class _RecordingCodeberg extends Codeberg {
  final List<String> requested = <String>[];

  @override
  Future<http.Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requested.add(url);
    return http.Response('{}', 404);
  }
}
