import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _matchingAsset = MapEntry(
  'NagramXF-v12.10.1-dec46b0.1250.-normal-arm64-v8a.apk',
  'https://example.com/selected.apk',
);
const _differentAsset = MapEntry(
  'Example-v12.10.1-ced5040c.1251.-normal-x86_64.apk',
  'https://example.com/other.apk',
);

App _app({List<MapEntry<String, String>> assets = const [_matchingAsset]}) {
  return App(
    id: 'fork.risin42.nagramx',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'NagramXF',
    installedVersion: '12.10.1-dec46b0',
    latestVersion: '12.10.1',
    apkUrls: assets,
    preferredApkIndex: 0,
    additionalSettings: {'versionDetection': 'auto'},
  );
}

class _GitHub extends GitHub {
  final requests = <String>[];

  @override
  Future<String> convertStandardUrlToAPIUrl(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return 'https://api.github.com/repos/example/app';
  }

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requests.add(url);
    return Response(
      jsonEncode({
        'status': 'ahead',
        'base_commit': {'sha': 'dec46b00000000000000000000000000000000000'},
      }),
      200,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  for (final (installed, latest, relation) in [
    ('12.10.1-dec46b0', '12.10.1', VersionRelation.same),
    ('12.10.1 (git DEC46B0)', 'v12.10.1', VersionRelation.same),
    ('26.03.a4d75424', '26.03', VersionRelation.same),
    ('12.10.1-foss-dec46b0', '12.10.1-oppo', VersionRelation.same),
    ('12.10.1-rc2-dec46b0', '12.10.1-rc2', VersionRelation.same),
    ('12.10.1-rc2-dec46b0', '12.10.1', VersionRelation.older),
    ('12.10.1-rc2-dec46b0', '12.10.1-rc1', VersionRelation.newer),
    ('12.10.1-dec46b0', '12.10.2', VersionRelation.older),
    ('12.10.2-dec46b0', '12.10.1', VersionRelation.newer),
    ('12.10.1-27-dec46b0', '12.10.1-28', VersionRelation.older),
    ('12.10.1-27-dec46b0', '12.10.1', VersionRelation.unknown),
    ('12.10.1-dec46b0', '12.10.1-ced5040c', VersionRelation.unknown),
    ('12.10.1 (DEC46B0)', '12.10.1-dec46b0', VersionRelation.same),
  ]) {
    test('hash completeness: $installed / $latest', () {
      final decision = compareVersionStrings(installed, latest);
      expect(decision.relation, relation);
      expect(
        compareVersionStrings(latest, installed).comparison,
        decision.comparison == null ? null : -decision.comparison!,
      );
    });
  }

  test(
    'Nagram screenshot is up to date across reload and update predicates',
    () async {
      final source = _GitHub();
      final app = App.fromJson(
        (await source.resolveVersionComparison(_app())).toJson(),
      );
      expect(selectedSourceBuildHash(app), 'dec46b0');
      expect(selectedSourceVersionCode(app), isNull);
      expect(versionDecisionForApp(app).reason, 'sameBuildHash');
      expect(
        appVersionVerdictForDisplay(app),
        AppVersionDisplayVerdict.sameVersion,
      );
      expect(appHasActionableUpdate(app), isFalse);
      expect(versionOrderUncertainUpdate(app), isFalse);
      expect(
        appUpdateIsUserVisible(app, includeVersionOrderUncertain: true),
        isFalse,
      );
      expect(appIsUpToDateForFiltering(app), isTrue);
      expect(source.requests, isEmpty);
      expect(app.installedVersion, '12.10.1-dec46b0');
      expect(app.latestVersion, '12.10.1');
    },
  );

  test(
    'a coarse label without artifact evidence is the same release',
    () async {
      final source = _GitHub();
      final app = await source.resolveVersionComparison(_app(assets: []));
      expect(versionDecisionForApp(app).reason, 'sameRelease');
      expect(versionOrderUncertainUpdate(app), isFalse);
      expect(appHasActionableUpdate(app), isFalse);
      expect(source.requests, isEmpty);
    },
  );

  for (final assetName in [
    'DifferentApp-v12.10.1-DEC46B0.apk',
    'Example-12.10.1.dec46b0-unfamiliar-store.apk',
    'Another-12.10.1 (dec46b0).apk',
    'Example-12.10.1-dec46b0.1250.-normal-x86_64.apk',
    'Example-v12.10.1-dec46b0.apks',
  ]) {
    test(
      'selected hash recovery is independent of app and label: $assetName',
      () {
        expect(releaseBuildHash('12.10.1', assetName: assetName), 'dec46b0');
      },
    );
  }

  for (final assetName in [
    'Example-v12.10.2-dec46b0.apk',
    'Example-v112.10.1-dec46b0.apk',
    'Example-v12.10.1-rc2-dec46b0.apk',
    'Example-v12.10.1-dec46b0-beta.apk',
    'Example-v12.10.1-27-dec46b0.apk',
    'Unrelated-dec46b0-v12.10.1.apk',
    'Example-v12.10.1-dec46b0-from-11.0.apk',
    'Example-v12.10.1-dec46b0-ced5040c.apk',
    'Example-v12.10.1-dec46b0.apk.sha256',
    'Example-v12.10.1-arm64-v8a.apk',
    'Example-dec46b0.apk',
  ]) {
    test('unrelated or ambiguous asset cannot supply a hash: $assetName', () {
      expect(releaseBuildHash('12.10.1', assetName: assetName), isNull);
    });
  }

  test('an explicit source hash is never replaced by the artifact name', () {
    final app = _app().copyWith(latestVersion: '12.10.1-ced5040c');
    expect(selectedSourceBuildHash(app), 'ced5040c');
    expect(versionDecisionForApp(app).reason, 'differentBuildHashes');
  });

  test(
    'only the selected asset contributes a hash and cached order follows it',
    () async {
      final source = _GitHub();
      final app = _app(assets: [_matchingAsset, _differentAsset]);
      expect(versionDecisionForApp(app).reason, 'sameBuildHash');
      final switched = app.copyWith(preferredApkIndex: 1);
      expect(versionDecisionForApp(switched).reason, 'differentBuildHashes');
      final resolved = await source.resolveVersionComparison(switched);
      expect(
        source.requests.single,
        endsWith('/compare/dec46b0...ced5040c?per_page=1&page=2'),
      );
      expect(versionDecisionForApp(resolved).reason, 'sourceCommitAncestry');
      expect(appHasActionableUpdate(resolved), isTrue);
      expect(
        versionDecisionForApp(resolved.copyWith(preferredApkIndex: 0)).reason,
        'sameBuildHash',
      );
      final changedAsset = resolved.copyWith(
        apkUrls: [
          _matchingAsset,
          const MapEntry(
            'Other-12.10.1-ab12345.apk',
            'https://example.com/third.apk',
          ),
        ],
      );
      expect(
        versionDecisionForApp(changedAsset).reason,
        'differentBuildHashes',
      );
    },
  );

  test('custom version sources do not receive selected filename metadata', () {
    for (final settings in [
      {'versionStringSource': versionStringSourceReleaseTitle},
      {'versionExtractionRegEx': r'(\d+\.\d+\.\d+)'},
    ]) {
      final app = _app(
        assets: [_differentAsset],
      ).copyWith(additionalSettings: {'versionDetection': 'auto', ...settings});
      expect(selectedSourceBuildHash(app), isNull);
      expect(versionDecisionForApp(app).reason, 'sameRelease');
    }
  });

  test(
    'source sorting cannot merge different hashes through a coarse label',
    () {
      expect(
        versionsHaveConsistentOrder([
          '12.10.1-dec46b0',
          '12.10.1',
          '12.10.1 (DEC46B0)',
        ]),
        isTrue,
      );
      for (final labels in [
        ['12.10.1-dec46b0', '12.10.1', '12.10.1-ced5040c'],
        ['12.10.1', '12.10.1-ced5040c', '12.10.1-dec46b0'],
      ]) {
        expect(versionsHaveConsistentOrder(labels), isFalse);
        expect(
          compareVersionStrings(labels[0], labels[1]).relation,
          VersionRelation.same,
        );
        expect(
          compareVersionStrings('12.10.1-dec46b0', '12.10.1-ced5040c').reason,
          'differentBuildHashes',
        );
      }
    },
  );
}
