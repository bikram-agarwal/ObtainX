import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

class _FakePackageInfo extends Fake implements PackageInfo {
  _FakePackageInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
  });

  @override
  final String? packageName;

  @override
  final String? versionName;

  @override
  final int? versionCode;
}

PackageInfo _packageInfo({
  String packageName = 'app.rvx.android.youtube',
  String versionName = '21.30.216',
  int versionCode = 1556440320,
}) {
  return _FakePackageInfo(
    packageName: packageName,
    versionName: versionName,
    versionCode: versionCode,
  );
}

Map<String, dynamic> _assetMeta({
  String sourceUrl = 'https://github.com/user/patched-apks',
  String? overrideSource,
  String version = 'v21.30.216',
  required String assetName,
  required String assetUrl,
  String? digest,
  String? uploadedAt,
}) {
  return {
    'sourceUrl': sourceUrl,
    'overrideSource': overrideSource,
    'version': version,
    'assetUrls': {assetName: assetUrl},
    if (digest != null) 'digests': {assetName: digest},
    if (uploadedAt != null) 'uploadedAt': {assetName: uploadedAt},
  };
}

App _installedPatchedApp({
  String version = 'v21.30.216',
  String installedVersion = '21.30.216',
  String assetName = 'youtube-v21.30.216.apk',
  String assetUrl =
      'https://api.github.com/repos/user/patched-apks/releases/assets/1001',
  String? digest = 'sha256:aaaa1111',
  String? uploadedAt = '2026-11-20T10:00:00.000Z',
  Map<String, dynamic> extraSettings = const {},
}) {
  final App preInstall = App(
    id: 'app.rvx.android.youtube',
    url: 'https://github.com/user/patched-apks',
    author: 'user',
    name: 'YouTube Patched',
    installedVersion: null,
    latestVersion: version,
    apkUrls: [MapEntry(assetName, assetUrl)],
    preferredApkIndex: 0,
    additionalSettings: {
      sourceAssetMetadataKey: _assetMeta(
        version: version,
        assetName: assetName,
        assetUrl: assetUrl,
        digest: digest,
        uploadedAt: uploadedAt,
      ),
      ...extraSettings,
    },
  );
  final InstallReleaseSnapshot release = InstallReleaseSnapshot.fromApp(
    preInstall,
  ).withPackage(_packageInfo(versionName: installedVersion));
  return recordConfirmedInstall(
    preInstall,
    release,
    _packageInfo(versionName: installedVersion),
  );
}

void main() {
  tearDown(() {
    setGlobalTreatNewAssetSameVersionAsUpdateForTesting(false);
  });

  group('Treat a new asset with the same version as an update', () {
    test('default off keeps same-version rebuilt asset as up to date', () {
      final App base = _installedPatchedApp();
      final App rebuilt = base.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
          ),
        ],
        additionalSettings: {
          ...base.additionalSettings,
          sourceAssetMetadataKey: _assetMeta(
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
            digest: 'sha256:bbbb2222',
            uploadedAt: '2026-11-26T12:00:00.000Z',
          ),
        },
      );

      final VersionDecision decision = versionDecisionForApp(rebuilt);
      expect(decision.relation, VersionRelation.same);
      expect(appHasActionableUpdate(rebuilt), isFalse);
    });

    test('per-app enabled flags changed asset ID / digest as an actionable update and converges after install', () {
      final App base = _installedPatchedApp(
        extraSettings: const {treatNewAssetSameVersionAsUpdateKey: 'on'},
      );
      expect(versionDecisionForApp(base).relation, VersionRelation.same);
      expect(appHasActionableUpdate(base), isFalse);

      final App rebuilt = base.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
          ),
        ],
        additionalSettings: {
          ...base.additionalSettings,
          sourceAssetMetadataKey: _assetMeta(
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
            digest: 'sha256:bbbb2222',
            uploadedAt: '2026-11-26T12:00:00.000Z',
          ),
        },
      );

      final VersionDecision updateDecision = versionDecisionForApp(rebuilt);
      expect(updateDecision.relation, VersionRelation.older);
      expect(updateDecision.reason, 'rebuiltAsset');
      expect(appHasActionableUpdate(rebuilt), isTrue);

      // Installing the rebuilt APK (same versionName & versionCode) writes a
      // new receipt and settles back to same.
      final InstallReleaseSnapshot nextRelease = InstallReleaseSnapshot.fromApp(
        rebuilt,
      ).withPackage(_packageInfo());
      final App reinstalled = recordConfirmedInstall(
        rebuilt,
        nextRelease,
        _packageInfo(),
      );
      expect(versionDecisionForApp(reinstalled).relation, VersionRelation.same);
      expect(appHasActionableUpdate(reinstalled), isFalse);
    });

    test('global setting applies when per-app is unset, and per-app off overrides global on', () {
      final App base = _installedPatchedApp();
      final App rebuilt = base.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
          ),
        ],
        additionalSettings: {
          ...base.additionalSettings,
          sourceAssetMetadataKey: _assetMeta(
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
            digest: 'sha256:bbbb2222',
          ),
        },
      );

      setGlobalTreatNewAssetSameVersionAsUpdateForTesting(true);
      expect(versionDecisionForApp(rebuilt).relation, VersionRelation.older);
      expect(versionDecisionForApp(rebuilt).reason, 'rebuiltAsset');

      final App explicitlyDisabled = rebuilt.copyWith(
        additionalSettings: {
          ...rebuilt.additionalSettings,
          treatNewAssetSameVersionAsUpdateKey: 'off',
        },
      );
      expect(
        versionDecisionForApp(explicitlyDisabled).relation,
        VersionRelation.same,
      );
    });

    test('externally installed app without receipt or acknowledgement does not false-positive', () {
      setGlobalTreatNewAssetSameVersionAsUpdateForTesting(true);
      const App externalInstall = App(
        id: 'app.rvx.android.youtube',
        url: 'https://github.com/user/patched-apks',
        author: 'user',
        name: 'YouTube Patched',
        installedVersion: '21.30.216',
        latestVersion: 'v21.30.216',
        apkUrls: [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
          ),
        ],
        preferredApkIndex: 0,
        additionalSettings: {
          observedPackageIdKey: 'app.rvx.android.youtube',
          observedVersionNameKey: '21.30.216',
          observedVersionCodeKey: 1556440320,
        },
      );

      expect(
        versionDecisionForApp(externalInstall).relation,
        VersionRelation.same,
      );
      expect(appHasActionableUpdate(externalInstall), isFalse);
    });

    test('legacy receipt without digest or upload date still detects changed GitHub asset URL', () {
      setGlobalTreatNewAssetSameVersionAsUpdateForTesting(true);
      final Map<String, dynamic> legacyReceiptJson =
          const InstallReleaseSnapshot(
            appId: 'app.rvx.android.youtube',
            sourceUrl: 'https://github.com/user/patched-apks',
            overrideSource: null,
            version: 'v21.30.216',
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/1001',
            versionName: '21.30.216',
            versionCode: 1556440320,
            versionSettings: '["default","","0",false]',
          ).toJson();
      expect(legacyReceiptJson.containsKey('assetDigest'), isFalse);
      expect(legacyReceiptJson.containsKey('assetUploadedAt'), isFalse);

      final App legacyInstalled = App(
        id: 'app.rvx.android.youtube',
        url: 'https://github.com/user/patched-apks',
        author: 'user',
        name: 'YouTube Patched',
        installedVersion: '21.30.216',
        latestVersion: 'v21.30.216',
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
          ),
        ],
        preferredApkIndex: 0,
        additionalSettings: {
          observedPackageIdKey: 'app.rvx.android.youtube',
          observedVersionNameKey: '21.30.216',
          observedVersionCodeKey: 1556440320,
          confirmedInstallReleaseKey: legacyReceiptJson,
        },
      );

      final VersionDecision decision = versionDecisionForApp(legacyInstalled);
      expect(decision.relation, VersionRelation.older);
      expect(decision.reason, 'rebuiltAsset');
    });

    test('re-uploaded asset with identical sha256 digest is not flagged as an update', () {
      setGlobalTreatNewAssetSameVersionAsUpdateForTesting(true);
      final App base = _installedPatchedApp(digest: 'sha256:samebytes');
      final App reuploadedSameBytes = base.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/3003',
          ),
        ],
        additionalSettings: {
          ...base.additionalSettings,
          sourceAssetMetadataKey: _assetMeta(
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/3003',
            digest: 'sha256:samebytes',
            uploadedAt: '2026-11-26T15:00:00.000Z',
          ),
        },
      );

      expect(
        versionDecisionForApp(reuploadedSameBytes).relation,
        VersionRelation.same,
      );
    });

    test('rotating CDN query parameters on the same URL path do not trigger false updates', () {
      setGlobalTreatNewAssetSameVersionAsUpdateForTesting(true);
      final App base = _installedPatchedApp(
        assetUrl: 'https://cdn.example.com/apks/youtube.apk?Expires=111&Sig=aa',
        digest: null,
        uploadedAt: null,
      );
      final App rotatedToken = base.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://cdn.example.com/apks/youtube.apk?Expires=999&Sig=zz',
          ),
        ],
        additionalSettings: Map<String, dynamic>.from(base.additionalSettings)
          ..remove(sourceAssetMetadataKey),
      );

      expect(
        versionDecisionForApp(rotatedToken).relation,
        VersionRelation.same,
      );
    });

    test('skipping rebuild #2 hides rebuild #2 but surfaces rebuild #3 of the same version', () {
      setGlobalTreatNewAssetSameVersionAsUpdateForTesting(true);
      final App base = _installedPatchedApp();
      final App rebuild2 = base.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
          ),
        ],
        additionalSettings: {
          ...base.additionalSettings,
          sourceAssetMetadataKey: _assetMeta(
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
            digest: 'sha256:bbbb2222',
          ),
        },
      );

      final App skippedRebuild2 = rebuild2.copyWith(
        additionalSettings: {
          ...rebuild2.additionalSettings,
          'skippedLatestVersion': rebuild2.latestVersion,
          skippedLatestAssetKey: selectedPreferredAssetIdentity(rebuild2),
        },
      );
      expect(isSkipActiveForCurrentLatest(skippedRebuild2), isTrue);
      expect(appHasActionableUpdate(skippedRebuild2), isFalse);

      final App rebuild3 = skippedRebuild2.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/3003',
          ),
        ],
        additionalSettings: {
          ...skippedRebuild2.additionalSettings,
          sourceAssetMetadataKey: _assetMeta(
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/3003',
            digest: 'sha256:cccc3333',
          ),
        },
      );
      expect(isSkipActiveForCurrentLatest(rebuild3), isFalse);
      expect(appHasActionableUpdate(rebuild3), isTrue);
    });

    test('mergeFetchedUpdateWithLiveState clears stale malware scan status when asset changes under same version', () {
      final App live = _installedPatchedApp().copyWith(
        latestMalwareScanStatus: 'clean',
        latestMalwareScanDetail: '0/70',
      );
      final App fetched = live.copyWith(
        apkUrls: const [
          MapEntry(
            'youtube-v21.30.216.apk',
            'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
          ),
        ],
        additionalSettings: {
          ...live.additionalSettings,
          sourceAssetMetadataKey: _assetMeta(
            assetName: 'youtube-v21.30.216.apk',
            assetUrl: 'https://api.github.com/repos/user/patched-apks/releases/assets/2002',
            digest: 'sha256:bbbb2222',
          ),
        },
      );

      final App? merged = mergeFetchedUpdateWithLiveState(
        requestedApp: live,
        liveApp: live,
        fetchedApp: fetched,
      );
      expect(merged, isNotNull);
      expect(merged!.latestMalwareScanStatus, isNull);
      expect(
        merged.additionalSettings[sourceAssetMetadataKey],
        fetched.additionalSettings[sourceAssetMetadataKey],
      );
    });
  });
}
