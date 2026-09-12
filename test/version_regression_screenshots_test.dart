import 'dart:convert';
import 'dart:ui';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _screenshots = [
  (
    'Google Play Protect Service',
    'com.google.android.odad',
    'C.6.odad-stub.948481320',
    '6.playstore.pixel3.945720966',
    VersionRelation.newer,
  ),
  ('inshorts', 'com.nis.app', '6.12.36', '6.1.0-huawei', VersionRelation.newer),
  (
    'Wa Enhancer',
    'com.wmods.wppenhacer',
    '1.5.5 (4D91B33C)',
    '1.5.5-ced5040c',
    VersionRelation.unknown,
  ),
  (
    'Image Toolbox',
    'ru.tech.imageresizershrinker',
    '4.2.0-foss',
    '4.2.0',
    VersionRelation.same,
  ),
  (
    'Meet',
    'com.google.android.apps.tachyon',
    '376.0.977329897.public_beta.duo.android_20260907.02_p0',
    '375.0.976439154.duo.android_20260831.02_p4.t',
    VersionRelation.newer,
  ),
  (
    'Google Play Store',
    'com.android.vending',
    '53.0.27-34 [0] [PR] 973951861',
    '52.9.22',
    VersionRelation.newer,
  ),
  (
    'Satellite Gateway',
    'com.google.android.apps.stargate',
    'stargate.android_20260817_00_RC00.release_dynamic_universal',
    '20260817_00_RC00.release_dynamic_universal',
    VersionRelation.same,
  ),
  (
    'Android System Intelligence',
    'com.google.android.as',
    'C.6.playstore.pixel9.961955194',
    '28.playstore.oemfull.969713662',
    VersionRelation.unknown,
  ),
  (
    'Cross-Device Services',
    'com.google.ambient.streaming',
    '1.0.1283.978582931',
    '1.0.1219.947788260',
    VersionRelation.newer,
  ),
];

App _app(
  String installed,
  String latest, {
  String id = 'org.example.app',
  Object mode = 'auto',
  bool trackOnly = false,
}) {
  return App(
    id: id,
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    additionalSettings: {'versionDetection': mode, 'trackOnly': trackOnly},
  );
}

class _Provider implements AppsProvider {
  @override
  Map<String, AppInMemory> apps = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _Package extends PackageInfo {
  _Package(String versionName, {int code = 123, String id = 'org.example.app'})
    : super(
        installLocation: AndroidInstallLocation.unspecified,
        packageName: id,
        versionName: versionName,
        versionCode: code,
      );
}

class _GitHub extends GitHub {
  final String status;
  final int responseCode;
  int requests = 0;
  String? requestedUrl;
  _GitHub(this.status, {this.responseCode = 200});

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
    requests++;
    requestedUrl = url;
    return Response(
      jsonEncode({
        'status': status,
        'base_commit': {'sha': '4d91b33c0000000000000000000000000000000000'},
      }),
      responseCode,
    );
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return APKDetails('1.5.5-ced5040c', const [
      MapEntry('WaEnhancer-1.5.5.CED5040C.apk', 'https://example.com/wa.apk'),
    ], AppNames('Example', 'Example'));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  for (final fixture in _screenshots) {
    for (final trackOnly in [false, true]) {
      test('${fixture.$1}: matching decisions with trackOnly=$trackOnly', () {
        final app = _app(
          fixture.$3,
          fixture.$4,
          id: fixture.$2,
          trackOnly: trackOnly,
        );
        final decision = versionDecisionForApp(app);
        expect(decision.relation, fixture.$5);
        expect(appHasActionableUpdate(app), isFalse);
        expect(appUpdateIsUserVisible(app), isFalse);
        expect(
          appIsUpToDateForFiltering(app),
          fixture.$5 != VersionRelation.unknown,
        );
        expect(appVersionVerdictForDisplay(app), switch (fixture.$5) {
          VersionRelation.same => AppVersionDisplayVerdict.effectivelyEqual,
          VersionRelation.newer => AppVersionDisplayVerdict.newerOnDevice,
          _ => AppVersionDisplayVerdict.uncertain,
        });
        final provider = _Provider();
        provider.apps[app.id] = AppInMemory(app, null, null, null);
        expect(provider.findExistingUpdates(installedOnly: true), isEmpty);
        expect(
          provider.findExistingUpdates(
            installedOnly: true,
            includeVersionOrderUncertain: true,
          ),
          fixture.$5 == VersionRelation.unknown ? [app.id] : isEmpty,
        );
      });
    }
  }

  test(
    'a higher APKPure code cannot silently promote an older Huawei release',
    () {
      final base = _app('6.12.36', '6.1.0-huawei', id: 'com.nis.app');
      const asset = MapEntry(
        'com.nis.app-5197713.apk',
        'https://example.com/inshorts.apk',
      );
      final app = base.copyWith(
        apkUrls: const [asset],
        additionalSettings: {
          ...base.additionalSettings,
          observedPackageIdKey: base.id,
          observedVersionNameKey: base.installedVersion,
          observedVersionCodeKey: 5190000,
          sourceVersionCodesKey: {
            'sourceUrl': base.url,
            'overrideSource': base.overrideSource,
            'version': base.latestVersion,
            'codes': {asset.key: 5197713},
            'assetUrls': {asset.key: asset.value},
          },
        },
      );
      expect(versionDecisionForApp(app).relation, VersionRelation.newer);
      expect(versionDecisionForApp(app).reason, 'numericRelease');
      expect(appHasActionableUpdate(app), isFalse);
      expect(
        appVersionVerdictForDisplay(app),
        AppVersionDisplayVerdict.newerOnDevice,
      );
      for (final code in [5190000, 5197713, 5200000]) {
        final observed = app.copyWith(
          additionalSettings: {
            ...app.additionalSettings,
            observedVersionCodeKey: code,
          },
        );
        expect(
          versionDecisionForApp(App.fromJson(observed.toJson())).relation,
          VersionRelation.newer,
        );
      }
      final explicitCodeMode = app.copyWith(
        installedVersion: '5190000',
        additionalSettings: {
          ...app.additionalSettings,
          'versionDetection': 'versionCode',
        },
      );
      expect(versionDecisionForApp(explicitCodeMode).reason, 'versionCode');
      expect(appHasActionableUpdate(explicitCodeMode), isTrue);
    },
  );

  test('Huawei tags do not affect semver ordering in either direction', () {
    for (final (latest, relation) in [
      ('6.1.0-huawei', VersionRelation.newer),
      ('6.12.36-huawei', VersionRelation.same),
      ('6.13.0-huawei', VersionRelation.older),
    ]) {
      final app = _app('6.12.36', latest);
      expect(versionDecisionForApp(app).relation, relation);
      expect(
        compareVersionStrings('6.12.36', latest).comparison,
        -(compareVersionStrings(latest, '6.12.36').comparison!),
      );
      expect(appHasActionableUpdate(app), relation == VersionRelation.older);
    }
    expect(
      compareVersionStrings('6.12.36-beta', '6.12.36-huawei').relation,
      VersionRelation.older,
    );
  });

  test('Google build order survives distribution labels within one series', () {
    const installed = 'C.6.odad-stub.948481320';
    const source = '6.playstore.pixel3.945720966';
    expect(compareVersionStrings(installed, source).comparison, 1);
    expect(compareVersionStrings(source, installed).comparison, -1);
    final sameBuild = _app(
      installed,
      '6.playstore.pixel9.948481320',
      trackOnly: true,
    );
    expect(versionDecisionForApp(sameBuild).relation, VersionRelation.same);
    expect(versionOrderUncertainUpdate(sameBuild), isFalse);
    expect(
      versionDecisionForApp(_app(installed, source, trackOnly: true)).reason,
      'googleBuild',
    );
    final differentDistribution = _app(source, installed, trackOnly: true);
    expect(
      versionDecisionForApp(differentDistribution).reason,
      'differentVariants',
    );
    final marked = acknowledgeSourceRelease(differentDistribution);
    expect(marked.installedVersion, source);
    expect(versionDecisionForApp(marked).reason, 'sourceAcknowledged');
    expect(appHasActionableUpdate(marked), isFalse);
  });

  test(
    'release tags use the selected FOSS asset and detect a flavor switch',
    () {
      final app =
          _app(
            '4.2.0-foss',
            '4.2.0',
            id: 'ru.tech.imageresizershrinker',
          ).copyWith(
            apkUrls: const [
              MapEntry(
                'image-toolbox-4.2.0-foss-arm64-v8a.apk',
                'https://example.com/foss.apk',
              ),
              MapEntry(
                'image-toolbox-4.2.0-arm64-v8a.apk',
                'https://example.com/market.apk',
              ),
            ],
          );
      expect(versionDecisionForApp(app).relation, VersionRelation.same);
      final switched = app.copyWith(preferredApkIndex: 1);
      expect(versionDecisionForApp(switched).reason, 'differentVariants');
      expect(appHasActionableUpdate(switched), isFalse);
      expect(
        versionDecisionTitleKey(versionDecisionForApp(switched)),
        'version_variant_differs',
      );
      final next = app.copyWith(latestVersion: '4.3.0');
      expect(appHasActionableUpdate(next), isTrue);
      expect(
        appHasActionableUpdate(next.copyWith(preferredApkIndex: 1)),
        isFalse,
      );
    },
  );

  for (final mode in ['auto', 'standard', 'pseudo', false]) {
    test('older sources stay older under saved detection mode $mode', () {
      final app = _app('2.0', '1.0', mode: mode, trackOnly: true);
      expect(versionDecisionForApp(app).relation, VersionRelation.newer);
      expect(appHasActionableUpdate(app), isFalse);
    });
  }

  test('opaque source changes are manual events, not automatic updates', () {
    final app = _app('stable', 'nightly', mode: 'pseudo');
    expect(versionDecisionForApp(app).relation, VersionRelation.sourceChanged);
    expect(appUpdateIsUserVisible(app), isFalse);
    expect(
      appUpdateIsUserVisible(app, includeVersionOrderUncertain: true),
      isTrue,
    );
    expect(
      versionDecisionTitleKey(versionDecisionForApp(app)),
      'versionOrderUnclear',
    );
    expect(appHasActionableUpdate(acknowledgeSourceRelease(app)), isFalse);
  });

  test(
    'track-only migration keeps an acknowledgement and adopts the actual device version',
    () {
      final provider = _Provider();
      final app = _app('source alias', 'source alias', trackOnly: true);
      final info = _Package('device label');
      final corrected = provider.getCorrectedInstallStatusAppIfPossible(
        app,
        info,
      )!;
      expect(corrected.installedVersion, 'device label');
      expect(versionDecisionForApp(corrected).reason, 'sourceAcknowledged');
      final restored = App.fromJson(corrected.toJson());
      expect(
        provider.getCorrectedInstallStatusAppIfPossible(restored, info),
        isNull,
      );
      final external = provider.getCorrectedInstallStatusAppIfPossible(
        restored,
        _Package('new device label', code: 124),
      )!;
      expect(external.installedVersion, 'new device label');
      expect(
        versionDecisionForApp(external).reason,
        isNot('sourceAcknowledged'),
      );
    },
  );

  test('Mark updated keeps the real device version on track-only apps', () {
    final app = _app('device label', 'source alias', trackOnly: true);
    final marked = acknowledgeSourceRelease(app);
    expect(marked.installedVersion, 'device label');
    expect(versionDecisionForApp(marked).reason, 'sourceAcknowledged');
    expect(
      versionDecisionForApp(
        marked.copyWith(latestVersion: 'next alias'),
      ).relation,
      VersionRelation.sourceChanged,
    );
  });

  test('a newer external package supersedes a stale tracked label', () {
    final app = _app('1.0', '2.0', trackOnly: true);
    final corrected = _Provider().getCorrectedInstallStatusAppIfPossible(
      app,
      _Package('3.0'),
    )!;
    expect(corrected.installedVersion, '3.0');
    expect(versionDecisionForApp(corrected).relation, VersionRelation.newer);
    expect(appHasActionableUpdate(corrected), isFalse);
  });

  test('acknowledging a numeric release suppresses only that release', () {
    final provider = _Provider();
    final observed = provider.getCorrectedInstallStatusAppIfPossible(
      _app('1.0', '2.0', trackOnly: true),
      _Package('1.0'),
    )!;
    final marked = acknowledgeSourceRelease(observed);
    expect(marked.installedVersion, '1.0');
    expect(versionDecisionForApp(marked).reason, 'sourceAcknowledged');
    expect(appHasActionableUpdate(marked), isFalse);
    expect(
      appHasActionableUpdate(marked.copyWith(latestVersion: '3.0')),
      isTrue,
    );
    final external = provider.getCorrectedInstallStatusAppIfPossible(
      marked,
      _Package('1.5', code: 124),
    )!;
    expect(appHasActionableUpdate(external), isTrue);
  });

  test(
    'Skip survives formatting changes but expires for a different build',
    () {
      final skipped = _app('1.0', '1.5.5-ced5040c').copyWith(
        additionalSettings: {'skippedLatestVersion': 'v1.5.5 (CED5040C)'},
      );
      expect(isSkipActiveForCurrentLatest(skipped), isTrue);
      expect(
        appHasActionableUpdate(normalizeSkippedLatestVersion(skipped)),
        isFalse,
      );
      final changed = skipped.copyWith(latestVersion: '1.5.5-ab12cd34');
      expect(isSkipActiveForCurrentLatest(changed), isFalse);
      expect(
        appHasActionableUpdate(normalizeSkippedLatestVersion(changed)),
        isTrue,
      );
    },
  );

  for (final (installed, latest) in [
    ('6.playstore.pixel9.961955194', 'C.6.playstore.pixel9.969713662'),
    (
      '20260817_00_RC00.release_dynamic_universal',
      'stargate.android_20260818_00_RC00.release_dynamic_universal',
    ),
    (
      '375.0.976439154.duo.android_20260831.02_p4.t',
      '376.0.977329897.public_beta.duo.android_20260907.02_p0',
    ),
    ('52.9.22', '53.0.27-34 [0] [PR] 973951861'),
  ]) {
    test('genuinely newer compatible release remains an update: $latest', () {
      expect(
        appHasActionableUpdate(_app(installed, latest, trackOnly: true)),
        isTrue,
      );
      expect(
        appHasActionableUpdate(_app(latest, installed, trackOnly: true)),
        isFalse,
      );
    });
  }

  for (final (status, relation) in [
    ('ahead', VersionRelation.older),
    ('behind', VersionRelation.newer),
    ('diverged', VersionRelation.unknown),
  ]) {
    test(
      'GitHub establishes $status commit order and scopes its cached evidence',
      () async {
        final source = _GitHub(status);
        final app = _app('1.5.5 (4D91B33C)', '1.5.5-ced5040c');
        final resolved = await source.resolveVersionComparison(app);
        expect(versionDecisionForApp(resolved).relation, relation);
        if (status != 'diverged') {
          expect(
            versionDecisionForApp(resolved).reason,
            'sourceCommitAncestry',
          );
          expect(
            versionDecisionDetailKey(versionDecisionForApp(resolved)),
            'version_commit_ancestry_detail',
          );
        }
        expect(
          source.requestedUrl,
          endsWith('/compare/4d91b33c...ced5040c?per_page=1&page=2'),
        );
        final restored = App.fromJson(resolved.toJson());
        await source.resolveVersionComparison(restored);
        expect(source.requests, 1);
        for (final stale in [
          restored.copyWith(url: 'https://github.com/different/app'),
          restored.copyWith(latestVersion: '1.5.5-ab12cd34'),
          restored.copyWith(installedVersion: '1.5.5 (ABC12345)'),
          restored.copyWith(overrideSource: 'HTML'),
          restored.copyWith(
            additionalSettings: {
              ...restored.additionalSettings,
              'versionExtractionRegEx': 'changed',
            },
          ),
          restored.copyWith(
            apkUrls: const [
              MapEntry('other.apk', 'https://example.com/other.apk'),
            ],
          ),
        ]) {
          expect(
            versionDecisionForApp(stale).reason,
            isNot('sourceCommitAncestry'),
          );
        }
      },
    );
  }

  test(
    'normal source refresh carries the commit comparison through merge and reload',
    () async {
      final source = _GitHub('ahead');
      final current = _app('1.5.5 (4D91B33C)', '1.5.5-ab12345');
      final fetched = await SourceProvider().getApp(
        source,
        current.url,
        current.additionalSettings,
        currentApp: current,
      );
      final merged = mergeFetchedUpdateWithLiveState(
        requestedApp: current,
        liveApp: current,
        fetchedApp: fetched,
      )!;
      expect(
        versionDecisionForApp(App.fromJson(merged.toJson())).reason,
        'sourceCommitAncestry',
      );
      expect(appHasActionableUpdate(merged), isTrue);
      final installedWhileChecking = current.copyWith(
        installedVersion: '1.5.5 (FED98765)',
        additionalSettings: {
          ...current.additionalSettings,
          observedPackageIdKey: current.id,
          observedVersionNameKey: '1.5.5 (FED98765)',
          observedVersionCodeKey: 155,
        },
      );
      final stale = mergeFetchedUpdateWithLiveState(
        requestedApp: current,
        liveApp: installedWhileChecking,
        fetchedApp: fetched,
      )!;
      expect(stale.installedVersion, installedWhileChecking.installedVersion);
      expect(versionDecisionForApp(stale).reason, 'differentBuildHashes');
      expect(appHasActionableUpdate(stale), isFalse);
    },
  );

  test(
    'an unavailable GitHub comparison does not fail a refresh or imply an update',
    () async {
      for (final responseCode in [403, 404, 429, 500]) {
        final app = _app('1.5.5 (4D91B33C)', '1.5.5-ced5040c');
        final resolved = await _GitHub(
          'ahead',
          responseCode: responseCode,
        ).resolveVersionComparison(app);
        expect(versionDecisionForApp(resolved).reason, 'differentBuildHashes');
        expect(appHasActionableUpdate(resolved), isFalse);
      }
    },
  );

  test('same hash tolerates case and punctuation without a lookup', () async {
    final source = _GitHub('ahead');
    final app = _app('1.5.5 (CED5040C)', '1.5.5-ced5040c');
    expect(
      versionDecisionForApp(
        await source.resolveVersionComparison(app),
      ).relation,
      VersionRelation.same,
    );
    expect(source.requests, 0);
  });

  test('APKMirror preserves product prefixes and complete release metadata', () {
    expect(
      apkMirrorVersionFromTitle(
        'Satellite Gateway stargate.android_20260817_00_RC00.release_dynamic_universal by Google LLC',
      ),
      'stargate.android_20260817_00_RC00.release_dynamic_universal',
    );
    expect(
      apkMirrorVersionFromTitle(
        'Google Play Protect Service C.6.odad-stub.948481320 by Google LLC',
      ),
      'C.6.odad-stub.948481320',
    );
    expect(
      apkMirrorVersionFromTitle('1Password 8.12.9-28.BETA by AgileBits'),
      '8.12.9-28.BETA',
    );
  });

  test(
    'verdicts reuse existing JSON translations and preserve notification meaning',
    () async {
      final translations = (await const RootBundleAssetLoader().load(
        'assets/translations',
        const Locale('en'),
      ))!;
      for (final key in [
        'effectivelyEqual',
        'sameVersion',
        'versionOrderUnclear',
        'versionOrderUnclearSubtitle',
        'version_variant_differs',
        'version_variant_differs_detail',
        'version_commit_ancestry_detail',
      ]) {
        expect(translations[key], isA<String>());
        expect((translations[key] as String).isNotEmpty, isTrue);
      }
      Localization.load(
        const Locale('en'),
        translations: Translations(translations),
      );
      final sameRelease = versionDecisionForApp(_app('4.2.0-foss', '4.2.0'));
      expect(versionDecisionTitleKey(sameRelease), 'effectivelyEqual');
      final acknowledged = versionDecisionForApp(
        acknowledgeSourceRelease(
          _app('unrecognized', 'different', trackOnly: true),
        ),
      );
      expect(versionDecisionTitleKey(acknowledged), 'sameVersion');
      for (final app in [
        _app('1.5.5 (4D91B33C)', '1.5.5-ced5040c'),
        _app('stable', 'nightly', mode: 'pseudo'),
      ]) {
        final decision = versionDecisionForApp(app);
        expect(versionDecisionTitleKey(decision), 'versionOrderUnclear');
        expect(
          versionDecisionDetailKey(decision),
          'versionOrderUnclearSubtitle',
        );
      }
      final notification = VersionReviewNotification([
        _app('1.5.5 (4D91B33C)', '1.5.5-ced5040c'),
      ]);
      expect(notification.title, translations['versionOrderUnclear']);
      expect(notification.title, isNot(translations['updatesAvailable']));
      expect(notification.id, isNot(updateNotificationId));
      expect(notification.message, 'Example');
      final german = (await const RootBundleAssetLoader().load(
        'assets/translations',
        const Locale('de'),
      ))!;
      Localization.load(
        const Locale('de'),
        translations: Translations(german),
        fallbackTranslations: Translations(translations),
      );
      expect(tr('versionOrderUnclear'), german['versionOrderUnclear']);
      expect(
        tr('version_commit_ancestry_detail'),
        translations['version_commit_ancestry_detail'],
      );
      final localizedNotification = VersionReviewNotification([
        _app('1.5.5 (4D91B33C)', '1.5.5-ced5040c'),
      ]);
      expect(localizedNotification.title, german['versionOrderUnclear']);
    },
  );
}
