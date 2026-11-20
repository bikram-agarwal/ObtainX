import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/source_provider.dart';

// Relative links in changelogs (upstream #3470, v1.7.4 sync D21 B): resolved
// against the repository's default branch, not a release tag, as the fork's
// changelog image resolver does. Upstream's own cases, adapted to HEAD.
void main() {
  const String repo = 'https://github.com/chenxiaolong/BasicSync';
  const String blob = '$repo/blob/HEAD';

  String resolve(String href, {String appUrl = repo, AppSource? source}) =>
      resolveChangeLogLink(
        href: href,
        appUrl: appUrl,
        appSource: source ?? GitHub(),
      );

  test('GitHub links resolve into the repository at HEAD', () {
    final Map<String, String> cases = {
      'CHANGELOG.md': '$blob/CHANGELOG.md',
      './README.md#verifying-digital-signatures':
          '$blob/README.md#verifying-digital-signatures',
      'docs/../CHANGELOG.md': '$blob/CHANGELOG.md',
      '../CHANGELOG.md': '$blob/CHANGELOG.md',
      './Release%20notes.md': '$blob/Release%20notes.md',
      '/docs/CHANGELOG.md?raw=1#changes':
          'https://github.com/docs/CHANGELOG.md?raw=1#changes',
      '/chenxiaolong/BasicSync/issues/42': '$repo/issues/42',
      '//example.org/notes': 'https://example.org/notes',
      '#changes': '$repo#changes',
      '?expanded=true': '$repo?expanded=true',
      'https://example.org/notes?raw=1#changes':
          'https://example.org/notes?raw=1#changes',
      'http://example.org/notes': 'http://example.org/notes',
      'mailto:dev@example.org': 'mailto:dev@example.org',
    };
    for (final MapEntry<String, String> entry in cases.entries) {
      expect(resolve(entry.key), entry.value, reason: entry.key);
    }
  });

  test('GitLab, Codeberg and a self-hosted GitHub use their own file view', () {
    expect(
      resolve(
        'CHANGELOG.md',
        appUrl: 'https://gitlab.com/owner/repo',
        source: GitLab(),
      ),
      'https://gitlab.com/owner/repo/-/blob/HEAD/CHANGELOG.md',
    );
    expect(
      resolve(
        'docs/CHANGES.md',
        appUrl: 'https://codeberg.org/owner/repo',
        source: Codeberg(),
      ),
      'https://codeberg.org/owner/repo/src/branch/HEAD/docs/CHANGES.md',
    );
    expect(
      resolve('CHANGELOG.md', appUrl: 'https://git.example.org/owner/repo'),
      'https://git.example.org/owner/repo/blob/HEAD/CHANGELOG.md',
    );
  });

  test('other sources keep the origin fallback', () {
    expect(
      resolve(
        'CHANGELOG.md',
        appUrl: 'https://example.org/app/download',
        source: HTML(),
      ),
      'https://example.org/CHANGELOG.md',
    );
    expect(
      resolve(
        '/files/notes.html',
        appUrl: 'https://example.org/app/download',
        source: HTML(),
      ),
      'https://example.org/files/notes.html',
    );
  });
}
