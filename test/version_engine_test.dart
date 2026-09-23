import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/app_sources/itchio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

void main() {
  for (final (installed, latest, expected) in [
    ('1.2.3-dev', '1.2.3-beta', VersionRelation.older),
    ('1.2.3-beta2', '1.2.3-beta10', VersionRelation.older),
    ('1.2.3-beta.9', '1.2.3-rc.1', VersionRelation.older),
    ('1.2.3-alpha.1', '1.2.3-alpha.beta', VersionRelation.older),
    ('1.2.3-beta.a-b', '1.2.3-beta.a-c', VersionRelation.older),
    ('1.2.3-rc.2', '1.2.3', VersionRelation.older),
    ('1.2.3', 'Example 1.2.3 beta2 by Example', VersionRelation.newer),
    ('1.2.3 beta2', '1.2.3 beta10', VersionRelation.older),
    ('1.2.4-dev', '1.2.3', VersionRelation.newer),
    ('1.2.3+123', '1.2.3+456', VersionRelation.same),
    (
      '8.12.9-27.BETA',
      '1Password for Android 8.12.9-28.BETA',
      VersionRelation.older,
    ),
    ('8.12.9-27.BETA', '8.12.9-27.STABLE', VersionRelation.older),
    ('1.2.3-1', '1.2.3-2', VersionRelation.older),
    ('1.2.3-1', '1.2.3', VersionRelation.unknown),
    ('8.8 (88)', '8.8 (89)', VersionRelation.older),
    ('2.19.1 (git 67d1c5a)', 'v2.19.1', VersionRelation.same),
    ('2.19.0 (git 67d1c5a)', 'v2.19.1', VersionRelation.older),
    ('1.5.3-DEV (75094D8)', '1.5.4-DEV (75094D8)', VersionRelation.older),
    ('1.5.3-DEV (75094D8)', 'debug-75094d8', VersionRelation.unknown),
    ('1.2.3-ab123cd', '1.2.3-de456ff', VersionRelation.unknown),
    ('release 1.2.3 and 2.0.0', '2.0.0', VersionRelation.unknown),
    ('123', '1.2.3', VersionRelation.unknown),
    ('stable', 'nightly', VersionRelation.unknown),
    ('v1.2.3', '1.2.3.0', VersionRelation.same),
    (
      '1.9999999999999999999999999999999',
      '1.10000000000000000000000000000000',
      VersionRelation.older,
    ),
    ('2026-04-28T09:57:05.000Z', '1777370225000000', VersionRelation.same),
  ]) {
    test('$installed versus $latest gives $expected', () {
      final decision = compareVersionStrings(installed, latest);
      expect(decision.relation, expected);
      final reverse = compareVersionStrings(latest, installed);
      expect(
        reverse.comparison,
        decision.comparison == null ? null : -decision.comparison!,
      );
      expect(
        versionsEffectivelyEqual(installed, latest),
        expected == VersionRelation.same,
      );
    });
  }
  test('numeric overflow cannot turn different numbers into zero', () {
    expect(
      compareAlphaNumeric(
        'x999999999999999999999999',
        'x1000000000000000000000000',
      ),
      lessThan(0),
    );
    expect(
      numericVersionTokens('999999999999999999999999').single,
      BigInt.parse('999999999999999999999999'),
    );
    expect(
      versionsEffectivelyEqual(
        '1.999999999999999999999999',
        '1.888888888888888888888888',
      ),
      isFalse,
    );
  });
  test('regex replacement handles multi-digit references in one pass', () {
    final match = RegExp(
      r'(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)',
    ).firstMatch('abcdefghij')!;
    final service = VersionService();
    expect(service.replaceMatchGroupsInString(match, r'$1-$10-$1'), 'a-j-a');
    expect(service.replaceMatchGroupsInString(match, r'\$1/$1'), r'$1/a');
    expect(service.replaceMatchGroupsInString(match, r'\\$1'), r'\a');
    expect(service.replaceMatchGroupsInString(match, '10'), 'j');
    expect(service.replaceMatchGroupsInString(match, r'$11'), isNull);
    expect(
      service.replaceMatchGroupsInString(match, r'$999999999999999999999999'),
      isNull,
    );
    expect(service.replaceMatchGroupsInString(match, r'$0'), 'abcdefghij');
    final dollars = RegExp(r'(\$2)(foo)?').firstMatch(r'$2')!;
    expect(service.replaceMatchGroupsInString(dollars, r'$1-$2'), r'$2-');
    expect(service.replaceMatchGroupsInString(match, 'literal only'), isNull);
  });
  test('GitHub and HTML use prerelease and revision semantics', () {
    final github = GitHub();
    for (final labels in [
      ['1.2.3', '1.2.3-rc.1', '1.2.3-beta2', '1.2.3-dev'],
      ['8.12.9-28.BETA', '8.12.9-27.BETA'],
    ]) {
      final releases = labels
          .map((name) => <String, dynamic>{'tag_name': name})
          .toList();
      github.sortGitHubReleases(releases, 'smartname', false);
      expect(releases.map((release) => release['tag_name']), labels.reversed);
      for (var index = 0; index + 1 < labels.length; index++) {
        expect(
          compareReleaseNames(
            '${labels[index]}.apk',
            '${labels[index + 1]}.apk',
          ),
          greaterThan(0),
        );
      }
    }
  });
  test('Pseudo and track-only never turn an older source into an update', () {
    for (final settings in [
      {'versionDetection': 'pseudo'},
      {'versionDetection': 'auto', 'trackOnly': true},
    ]) {
      for (final (installed, latest) in [
        ('2.0', '1.0'),
        ('1', '1.0'),
        ('stable', 'nightly'),
      ]) {
        final app = App(
          id: 'org.example.app',
          url: 'https://github.com/example/app',
          author: 'Example',
          name: 'Example',
          installedVersion: installed,
          latestVersion: latest,
          preferredApkIndex: 0,
          additionalSettings: settings,
        );
        expect(appHasActionableUpdate(app), isFalse);
        expect(versionOrderUncertainUpdate(app), installed != '2.0');
        expect(appIsUpToDateForFiltering(app), installed == '2.0');
        expect(
          appHasActionableUpdate(app.copyWith(installedVersion: latest)),
          isFalse,
        );
      }
    }
  });
  test('mixed version/date source sorting cannot form comparison cycles', () {
    final releases = <dynamic>[
      {'tag_name': '2.0', 'published_at': '2026-01-01T00:00:00Z'},
      {'tag_name': '1.0', 'published_at': '2026-01-03T00:00:00Z'},
      {'tag_name': 'nightly', 'published_at': '2026-01-02T00:00:00Z'},
    ];
    for (final input in [
      releases,
      releases.reversed.toList(),
      [releases[1], releases[0], releases[2]],
    ]) {
      final sorted = List<dynamic>.from(input);
      GitHub().sortGitHubReleases(sorted, 'smartname-datefallback', false);
      expect(sorted.map((release) => release['tag_name']), [
        '2.0',
        'nightly',
        '1.0',
      ]);
    }
  });
  test(
    'itch.io preserves prerelease labels when extracting and choosing a release',
    () {
      final source = ItchIO();
      expect(
        source.parseVersion(
          html_parser.parse(
            '<div class="page_widget">Version 1.2.3-beta10</div>',
          ),
        ),
        '1.2.3-beta10',
      );
      expect(
        source.parseVersion(
          html_parser.parse(
            '<div class="page_widget">v1.2.3<br>Version 1.2.3-rc.1</div>',
          ),
        ),
        '1.2.3',
      );
    },
  );
}
