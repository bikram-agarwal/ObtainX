import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

App _app(String installed, String latest, {String mode = 'auto'}) {
  const asset = MapEntry('app.apk', 'https://example.com/app.apk');
  return App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    apkUrls: const [asset],
    preferredApkIndex: 0,
    additionalSettings: {
      'versionDetection': mode,
      observedPackageIdKey: 'org.example.app',
      observedVersionNameKey: installed,
      observedVersionCodeKey: 100,
      sourceVersionCodesKey: {
        'sourceUrl': 'https://github.com/example/app',
        'overrideSource': null,
        'version': latest,
        'codes': {asset.key: 101},
        'assetUrls': {asset.key: asset.value},
      },
    },
  );
}

void main() {
  for (final descriptor in [
    'oppo',
    'HUAWEI',
    'vivo',
    'regional',
    'foss',
    'market',
    'new-store-arm64-v8a',
    'vendor-2.3',
    '限定版',
  ]) {
    test('descriptive suffix $descriptor needs no vendor rule', () {
      for (final (version, expected) in [
        ('6.1.0', 1),
        ('6.12.36', 0),
        ('6.13.0', -1),
      ]) {
        final latest = '$version-$descriptor';
        expect(compareVersionStrings('6.12.36', latest).comparison, expected);
        expect(compareVersionStrings(latest, '6.12.36').comparison, -expected);
        for (final mode in ['auto', 'standard', 'pseudo']) {
          // No source code for the equality case: an independently higher APK
          // code can still identify a rebuild sharing an unchanged versionName.
          final app = _app(
            '6.12.36',
            latest,
            mode: mode,
          ).copyWith(additionalSettings: {'versionDetection': mode});
          expect(versionDecisionForApp(app).comparison, expected);
          expect(versionOrderUncertainUpdate(app), isFalse);
          expect(appHasActionableUpdate(app), expected < 0);
          expect(appIsUpToDateForFiltering(app), expected >= 0);
          expect(app.installedVersion, '6.12.36');
          expect(app.latestVersion, latest);
        }
      }
    });
  }

  test('generated unfamiliar labels cannot erase clear release ordering', () {
    final random = Random(940712);
    const alphabet = 'abcdefghijklmnopqrstuvwxyz';
    for (var sample = 0; sample < 256; sample++) {
      // Generated labels make this check independent of a list of supported
      // stores. The leading z distinguishes descriptions from hexadecimal hashes.
      final descriptor =
          'z${List.generate(12, (_) => alphabet[random.nextInt(alphabet.length)]).join()}';
      for (final label in [
        descriptor,
        '${descriptor}_64',
        '$descriptor-arm64-v8a',
        '$descriptor-2.3',
      ]) {
        final app = _app('6.12.36-$label', '6.1.0-$descriptor');
        final restored = App.fromJson(app.toJson());
        expect(
          versionDecisionForApp(restored).relation,
          VersionRelation.newer,
          reason: label,
        );
        expect(
          appVersionVerdictForDisplay(restored),
          AppVersionDisplayVerdict.newerOnDevice,
        );
        expect(
          appUpdateIsUserVisible(restored, includeVersionOrderUncertain: true),
          isFalse,
        );
        expect(
          compareVersionStrings(
            '6.12.36-$label',
            '6.12.36-other-description',
          ).comparison,
          0,
        );
        final next = app.copyWith(latestVersion: '6.13.0-$label');
        expect(appHasActionableUpdate(next), isTrue);
      }
    }
  });

  for (final (installed, latest, comparison) in [
    ('1.2.3-beta2-oppo', '1.2.3-beta10-huawei', -1),
    ('1.2.3-oppo-beta2', '1.2.3-novel-beta10', -1),
    ('1.2.3-rc.2-oppo', '1.2.3-rc.10-novel', -1),
    ('1.2.3-oppo-beta.alpha', '1.2.3-novel-beta.beta', -1),
    ('1.2.3-beta.a-b', '1.2.3-beta.a-c', -1),
    ('1.2.3-beta-oppo', '1.2.3-oppo', -1),
    ('1.2.3-rc1-oppo', '1.2.3-beta99-novel', 1),
    ('1.2.3-27-oppo', '1.2.3-28-novel', -1),
    ('1.2.3 (27)-oppo', '1.2.3 (28)-novel', -1),
    ('1.2.3-27.BETA-oppo', '1.2.3-27.STABLE-novel', -1),
    ('1.2.3-27-oppo', '1.2.3-novel', null),
    ('1.2.3-ab12345-oppo', '1.2.3-de45678-novel', null),
    ('1.2.3-deadbeef-oppo', '1.2.3-cafebabe-novel', null),
    ('1.2.3 (AB12345)-oppo', '1.2.3-ab12345-novel', 0),
    ('1.2.3-oppo-arm64-v8a', '1.2.3-novel-x86_64', 0),
    ('1.2.3-oppo+build.10', '1.2.3-novel+build.20', 0),
  ]) {
    test('meaningful components survive labels: $installed / $latest', () {
      expect(compareVersionStrings(installed, latest).comparison, comparison);
      expect(
        compareVersionStrings(latest, installed).comparison,
        comparison == null ? null : -comparison,
      );
    });
  }

  test('unfamiliar labels also work in source sorting', () {
    final releases = [
      {'tag_name': '6.13.0-new-store'},
      {'tag_name': '6.1.0-oppo'},
      {'tag_name': '6.12.36-never-seen-before'},
    ];
    expect(
      versionsHaveConsistentOrder(
        releases.map((release) => release['tag_name']!),
      ),
      isTrue,
    );
    GitHub().sortGitHubReleases(releases, 'smartname', false);
    expect(releases.map((release) => release['tag_name']), [
      '6.1.0-oppo',
      '6.12.36-never-seen-before',
      '6.13.0-new-store',
    ]);
  });

  test('multiple release candidates remain ambiguous', () {
    expect(
      compareVersionStrings('1.0 and 2.0', '2.0').relation,
      VersionRelation.unknown,
    );
  });
}
