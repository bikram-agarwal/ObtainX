import 'dart:convert';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:obtainium/providers/source_provider.dart';

const observedVersionNameKey = 'observedVersionName';
const observedVersionCodeKey = 'observedVersionCode';
const observedPackageIdKey = 'observedPackageId';
const confirmedInstallReleaseKey = 'confirmedInstallRelease';
const pendingInstallReleaseKey = 'pendingInstallRelease';
const sourceVersionCodesKey = 'sourceVersionCodes';
const sourceBuildComparisonKey = 'sourceBuildComparison';
const acknowledgedSourceReleaseKey = 'acknowledgedSourceRelease';
const trackedDeviceStateVersionKey = 'trackedDeviceStateVersion';

/// Set while the source's last answer had no release or APK matching the app's
/// settings - its filters, most often. See [appWithNoMatchingRelease]; the next
/// check that finds one drops it.
const noMatchingReleaseKey = 'noMatchingRelease';

bool appHasNoMatchingRelease(App app) =>
    app.additionalSettings[noMatchingReleaseKey] == true;

/// [app] as its source last answered, at [checkedAt]: with nothing matching.
///
/// Clears what an earlier check found. Kept, it went on showing - and offering
/// to install - a release the current filters exclude, and a new listing kept
/// its "Unknown" placeholder even though the source had been asked.
App appWithNoMatchingRelease(App app, DateTime checkedAt) {
  return app.copyWith(
    latestVersion: '',
    apkUrls: const [],
    otherAssetUrls: const [],
    lastUpdateCheck: checkedAt,
    releaseDate: null,
    changeLog: null,
    apkSizeBytes: null,
    rawLatestVersionFromSource: null,
    rawApkNamesFromSource: null,
    rawReleaseTitlesFromSource: null,
    latestIsReproducible: null,
    latestReproducibleStatus: null,
    latestReproducibleVersionCode: null,
    latestAttestationStatus: null,
    latestMalwareScanStatus: null,
    latestMalwareScanDetail: null,
    latestMalwareScanReportUrl: null,
    additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
      ..remove(sourceVersionCodesKey)
      ..remove(sourceBuildComparisonKey)
      ..[noMatchingReleaseKey] = true,
  );
}

String _versionSettingsIdentity(App app) {
  return jsonEncode([
    getVersionStringSource(app.additionalSettings),
    app.additionalSettings['versionExtractionRegEx'] ?? '',
    (app.additionalSettings['matchGroupToUse']?.toString().trim().isNotEmpty ==
            true)
        ? app.additionalSettings['matchGroupToUse'].toString().trim()
        : VersionService.defaultMatchGroup,
    app.additionalSettings['releaseCommitShaAsVersion'] == true,
  ]);
}

String _sourceContextIdentity(App app) {
  return jsonEncode([
    app.id,
    app.url,
    app.overrideSource,
    _versionSettingsIdentity(app),
  ]);
}

String _deviceObservationIdentity(App app) {
  return jsonEncode([
    app.additionalSettings[observedPackageIdKey],
    app.additionalSettings[observedVersionNameKey],
    app.additionalSettings[observedVersionCodeKey],
  ]);
}

/// Evidence from an asynchronous source request cannot outlive its exact
/// source, device observation, extraction settings, or selected artifact.
String versionEvidenceIdentity(App app) {
  return jsonEncode([
    _sourceContextIdentity(app),
    _deviceObservationIdentity(app),
    app.installedVersion,
    app.latestVersion,
    if (app.apkUrls.isNotEmpty)
      [
        app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)].key,
        app
            .apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)]
            .value,
      ],
  ]);
}

/// A manual acknowledgement is not an APK installation receipt. Keep the
/// source baseline independently so refreshes never replace a real version.
App acknowledgeSourceRelease(App app) {
  final asset = app.apkUrls.isEmpty
      ? null
      : app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)];
  return app.copyWith(
    installedVersion:
        app.usesStandardVersionDetection && app.installedVersion != null
        ? app.installedVersion
        : app.latestVersion,
    additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
      ..[acknowledgedSourceReleaseKey] = {
        'context': _sourceContextIdentity(app),
        'observation': _deviceObservationIdentity(app),
        'version': app.latestVersion,
        'assetName': asset?.key,
        'assetUrl': asset?.value,
      }
      ..remove('skippedLatestVersion'),
  );
}

Map? _sourceAcknowledgement(App app) {
  final acknowledgement = app.additionalSettings[acknowledgedSourceReleaseKey];
  if (acknowledgement is! Map ||
      acknowledgement['context'] != _sourceContextIdentity(app) ||
      acknowledgement['observation'] != _deviceObservationIdentity(app) ||
      acknowledgement['version'] is! String) {
    return null;
  }
  return acknowledgement;
}

/// Known APK flavors are artifact metadata, not a list of version suffixes.
/// This check only applies to a selected download and never orders releases.
String? _apkFlavor(String description) {
  final matches =
      RegExp(r'(?:^|[._ -])(foss|oss|fdroid|market|gplay)(?=$|[._ -])')
          .allMatches(description.toLowerCase())
          .map((match) => match.group(1)!)
          .toSet();
  return matches.length == 1 ? matches.single : null;
}

bool _selectedAssetChangesFlavor(App app) {
  if (getVersionStringSource(app.additionalSettings) !=
          versionStringSourceDefault ||
      app.apkUrls.isEmpty ||
      app.installedVersion == null) {
    return false;
  }
  final installedFlavor = _apkFlavor(
    releaseDescription(app.installedVersion!) ?? '',
  );
  if (installedFlavor == null) return false;
  final asset =
      app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)];
  var flavor = _apkFlavor(asset.key);
  // Image Toolbox publishes both flavors under one tag. The non-FOSS asset
  // has no suffix, but the repository explicitly identifies it as Market.
  if (flavor == null &&
      app.id == 'ru.tech.imageresizershrinker' &&
      asset.key.toLowerCase().startsWith('image-toolbox-')) {
    flavor = 'market';
  }
  return flavor != null && flavor != installedFlavor;
}

/// Immutable identity captured when an asset is selected, not after its download
/// or installation finishes. APK observations bind the source label to a device.
class InstallReleaseSnapshot {
  final String appId;
  final String sourceUrl;
  final String? overrideSource;
  final String version;
  final String assetName;
  final String assetUrl;
  final String? versionName;
  final int? versionCode;
  final String versionSettings;

  const InstallReleaseSnapshot({
    required this.appId,
    required this.sourceUrl,
    required this.overrideSource,
    required this.version,
    required this.assetName,
    required this.assetUrl,
    this.versionName,
    this.versionCode,
    required this.versionSettings,
  });

  factory InstallReleaseSnapshot.fromApp(App app) {
    final index = app.apkUrls.isEmpty
        ? 0
        : app.preferredApkIndex.clamp(0, app.apkUrls.length - 1);
    final asset = app.apkUrls.isEmpty ? null : app.apkUrls[index];
    return InstallReleaseSnapshot(
      appId: app.id,
      sourceUrl: app.url,
      overrideSource: app.overrideSource,
      version: app.latestVersion,
      assetName: asset?.key ?? '',
      assetUrl: asset?.value ?? '',
      versionSettings: _versionSettingsIdentity(app),
    );
  }

  InstallReleaseSnapshot withPackage(PackageInfo info) {
    return InstallReleaseSnapshot(
      appId: info.packageName ?? appId,
      sourceUrl: sourceUrl,
      overrideSource: overrideSource,
      version: version,
      assetName: assetName,
      assetUrl: assetUrl,
      versionName: info.versionName,
      versionCode: info.versionCode,
      versionSettings: versionSettings,
    );
  }

  bool belongsTo(App app) {
    return appId == app.id &&
        sourceUrl == app.url &&
        overrideSource == app.overrideSource &&
        versionSettings == _versionSettingsIdentity(app);
  }

  bool matchesPackage(PackageInfo info) {
    return appId == info.packageName &&
        versionCode != null &&
        versionCode == info.versionCode &&
        versionName == info.versionName;
  }

  bool matchesObservation(App app) {
    return belongsTo(app) &&
        app.additionalSettings[observedPackageIdKey] == appId &&
        versionCode != null &&
        app.additionalSettings[observedVersionCodeKey] == versionCode &&
        app.additionalSettings[observedVersionNameKey] == versionName;
  }

  Map<String, dynamic> toJson() {
    return {
      'appId': appId,
      'sourceUrl': sourceUrl,
      'overrideSource': overrideSource,
      'version': version,
      'assetName': assetName,
      'assetUrl': assetUrl,
      'versionName': versionName,
      'versionCode': versionCode,
      'versionSettings': versionSettings,
    };
  }

  static InstallReleaseSnapshot? fromJson(Object? value) {
    if (value is! Map ||
        value['appId'] is! String ||
        value['sourceUrl'] is! String ||
        value['version'] is! String ||
        value['assetName'] is! String ||
        value['assetUrl'] is! String ||
        value['versionSettings'] is! String ||
        (value['overrideSource'] != null &&
            value['overrideSource'] is! String) ||
        (value['versionName'] != null && value['versionName'] is! String)) {
      return null;
    }
    return InstallReleaseSnapshot(
      appId: value['appId'],
      sourceUrl: value['sourceUrl'],
      overrideSource: value['overrideSource'] as String?,
      version: value['version'],
      assetName: value['assetName'],
      assetUrl: value['assetUrl'],
      versionName: value['versionName'] as String?,
      versionCode: int.tryParse(value['versionCode']?.toString() ?? ''),
      versionSettings: value['versionSettings'],
    );
  }
}

/// Reusing a mutable download URL must not relabel an older cached APK.
String downloadReleaseCacheKey(InstallReleaseSnapshot release) {
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            release.sourceUrl,
            release.overrideSource,
            release.version,
            release.assetName,
            release.assetUrl,
            release.versionSettings,
          ]),
        ),
      )
      .toString();
}

int? selectedSourceVersionCode(App app) {
  if (getVersionStringSource(app.additionalSettings) !=
      versionStringSourceDefault) {
    return null;
  }
  final metadata = app.additionalSettings[sourceVersionCodesKey];
  if (metadata is! Map ||
      metadata['sourceUrl'] != app.url ||
      metadata['overrideSource'] != app.overrideSource ||
      metadata['version'] != app.latestVersion ||
      metadata['codes'] is! Map ||
      app.apkUrls.isEmpty) {
    return null;
  }
  final asset =
      app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)];
  if (metadata['assetUrls'] is! Map ||
      (metadata['assetUrls'] as Map)[asset.key] != asset.value) {
    return null;
  }
  return int.tryParse((metadata['codes'] as Map)[asset.key]?.toString() ?? '');
}

/// Supplement a coarse source label using only its currently selected APK.
/// Custom version extraction remains authoritative and receives no filename data.
String? selectedSourceBuildHash(App app) {
  final asset =
      app.apkUrls.isEmpty ||
          app.usesVersionCodeAsOsVersion ||
          (app.additionalSettings['versionExtractionRegEx']
                  ?.toString()
                  .trim()
                  .isNotEmpty ??
              false) ||
          getVersionStringSource(app.additionalSettings) !=
              versionStringSourceDefault
      ? null
      : app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)];
  return releaseBuildHash(app.latestVersion, assetName: asset?.key);
}

/// Keep the visible code in sync when the selected APK changes between checks.
App normalizeSelectedSourceVersion(App app) {
  final code = selectedSourceVersionCode(app);
  final metadata = app.additionalSettings[sourceVersionCodesKey];
  if (!app.usesVersionCodeAsOsVersion ||
      code == null ||
      metadata is! Map ||
      metadata['usesCodeLabel'] != true ||
      app.latestVersion == code.toString()) {
    return app;
  }
  return app.copyWith(
    latestVersion: code.toString(),
    additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
      ..[sourceVersionCodesKey] = (Map<String, dynamic>.from(metadata)
        ..['version'] = code.toString()),
  );
}

/// One decision for labels, filters, skips, notifications, and automatic updates.
/// Publication timestamps are intentionally absent: uploading is not installing.
VersionDecision versionDecisionForApp(App app) {
  final installed = app.installedVersion;
  if (installed != null && appHasNoMatchingRelease(app)) {
    // Nothing on the source matches, so there is nothing to update to: the
    // installed build is the newest this listing can offer.
    return const VersionDecision(VersionRelation.newer, 'noMatchingRelease');
  }
  if (installed == null || app.latestVersion.isEmpty) {
    return VersionDecision(
      VersionRelation.unknown,
      installed == null ? 'notInstalled' : 'missingVersion',
    );
  }
  final sourceCode = selectedSourceVersionCode(app);
  final observationMatches =
      app.additionalSettings[observedPackageIdKey] == app.id &&
      installed ==
          (app.usesVersionCodeAsOsVersion
              ? app.additionalSettings[observedVersionCodeKey]?.toString()
              : app.additionalSettings[observedVersionNameKey]);
  final deviceCode = observationMatches
      ? int.tryParse(
          app.additionalSettings[observedVersionCodeKey]?.toString() ?? '',
        )
      : null;
  if (app.usesVersionCodeAsOsVersion) {
    final latestCode = sourceCode?.toString() ?? app.latestVersion.trim();
    if (!RegExp(r'^\d+$').hasMatch(installed.trim()) ||
        !RegExp(r'^\d+$').hasMatch(latestCode)) {
      return const VersionDecision(VersionRelation.unknown, 'codeNameMismatch');
    }
    final comparison = compareDecimalIdentifiers(installed.trim(), latestCode);
    return VersionDecision(
      comparison == 0
          ? VersionRelation.same
          : comparison < 0
          ? VersionRelation.older
          : VersionRelation.newer,
      'versionCode',
    );
  }
  final direct = compareVersionStrings(
    installed,
    app.latestVersion,
    latestBuildHash: selectedSourceBuildHash(app),
  );
  final receipt = InstallReleaseSnapshot.fromJson(
    app.additionalSettings[confirmedInstallReleaseKey],
  );
  if (receipt != null &&
      observationMatches &&
      receipt.matchesObservation(app)) {
    if (receipt.version == app.latestVersion) {
      final asset = app.apkUrls.isEmpty
          ? null
          : app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)];
      if (asset?.key == receipt.assetName && asset?.value == receipt.assetUrl) {
        return const VersionDecision(
          VersionRelation.same,
          'confirmedInstalledRelease',
        );
      }
    }
  }
  final acknowledgement = _sourceAcknowledgement(app);
  final asset = app.apkUrls.isEmpty
      ? null
      : app.apkUrls[app.preferredApkIndex.clamp(0, app.apkUrls.length - 1)];
  if (acknowledgement != null &&
      acknowledgement['version'] == app.latestVersion &&
      acknowledgement['assetName'] == asset?.key &&
      acknowledgement['assetUrl'] == asset?.value &&
      direct.relation != VersionRelation.newer &&
      direct.relation != VersionRelation.same) {
    return const VersionDecision(VersionRelation.same, 'sourceAcknowledged');
  }
  // Matching Google series/build identifiers already name the same release;
  // distribution labels alone do not make another update available.
  if (direct.reason == 'googleBuild' &&
      direct.relation == VersionRelation.same) {
    return direct;
  }
  // Matching Google series/build identifiers already name the same release;
  // distribution labels alone do not make another update available.
  if (direct.reason == 'googleBuild' &&
      direct.relation == VersionRelation.same) {
    return direct;
  }
  final variantsDiffer =
      releaseVariantsDiffer(installed, app.latestVersion) ||
      _selectedAssetChangesFlavor(app);
  if (variantsDiffer && direct.relation != VersionRelation.newer) {
    return const VersionDecision(VersionRelation.unknown, 'differentVariants');
  }
  // A clear release/build order wins in name-based modes. Codes can refine
  // equal release names or resolve unorderable labels; explicitly selected
  // Version Code mode was handled above.
  if (direct.relation == VersionRelation.older ||
      direct.relation == VersionRelation.newer) {
    return direct;
  }
  if (sourceCode != null &&
      deviceCode != null &&
      app.usesStandardVersionDetection) {
    final codeRelation = sourceCode == deviceCode
        ? VersionRelation.same
        : sourceCode > deviceCode
        ? VersionRelation.older
        : VersionRelation.newer;
    if (!variantsDiffer &&
        !(direct.reason == 'differentBuildHashes' &&
            codeRelation == VersionRelation.same)) {
      return VersionDecision(codeRelation, 'selectedApkCode');
    }
  }
  if (receipt != null &&
      observationMatches &&
      receipt.matchesObservation(app) &&
      receipt.version != app.latestVersion) {
    final mapped = compareVersionStrings(receipt.version, app.latestVersion);
    if (mapped.relation != VersionRelation.unknown) {
      return VersionDecision(mapped.relation, 'confirmedSourceVersion');
    }
  }
  if (direct.relation != VersionRelation.unknown) return direct;
  final evidence = app.additionalSettings[sourceBuildComparisonKey];
  if (direct.reason == 'differentBuildHashes' &&
      evidence is Map &&
      evidence['identity'] == versionEvidenceIdentity(app)) {
    final relation = switch (evidence['status']) {
      'ahead' => VersionRelation.older,
      'behind' => VersionRelation.newer,
      'identical' => VersionRelation.same,
      _ => VersionRelation.unknown,
    };
    if (relation != VersionRelation.unknown) {
      return VersionDecision(relation, 'sourceCommitAncestry');
    }
  }
  if (!app.usesStandardVersionDetection ||
      (app.settings.getBool('trackOnly') && acknowledgement != null)) {
    return const VersionDecision(
      VersionRelation.sourceChanged,
      'sourceTracking',
    );
  }
  return direct;
}

App recordPendingInstall(App app, InstallReleaseSnapshot? release) {
  if (release == null || !release.belongsTo(app)) return app;
  return app.copyWith(
    additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
      ..[pendingInstallReleaseKey] = release.toJson(),
  );
}

App discardPendingInstall(App app, InstallReleaseSnapshot? release) {
  final pending = InstallReleaseSnapshot.fromJson(
    app.additionalSettings[pendingInstallReleaseKey],
  );
  if (pending == null ||
      release == null ||
      jsonEncode(pending.toJson()) != jsonEncode(release.toJson())) {
    return app;
  }
  return app.copyWith(
    additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
      ..remove(pendingInstallReleaseKey),
  );
}

/// Apply success only to the captured source context and the APK that landed.
/// Source refreshes keep their newer metadata while installed state uses this receipt.
App recordConfirmedInstall(
  App app,
  InstallReleaseSnapshot? release,
  PackageInfo info,
) {
  if (info.packageName != app.id) return app;
  final existingReceipt = InstallReleaseSnapshot.fromJson(
    app.additionalSettings[confirmedInstallReleaseKey],
  );
  if ((release == null ||
          !release.belongsTo(app) ||
          !release.matchesPackage(info)) &&
      existingReceipt != null &&
      existingReceipt.belongsTo(app) &&
      existingReceipt.matchesPackage(info)) {
    release = existingReceipt;
  }
  final settings = Map<String, dynamic>.from(app.additionalSettings)
    ..[observedPackageIdKey] = info.packageName
    ..[observedVersionNameKey] = info.versionName
    ..[observedVersionCodeKey] = info.versionCode
    ..remove(confirmedInstallReleaseKey)
    ..remove('unreconciledVersionComparison');
  final pending = InstallReleaseSnapshot.fromJson(
    settings[pendingInstallReleaseKey],
  );
  if (pending != null &&
      pending.matchesPackage(info) &&
      pending.belongsTo(app)) {
    settings.remove(pendingInstallReleaseKey);
  }
  final confirmed =
      release != null && release.belongsTo(app) && release.matchesPackage(info);
  if (confirmed) {
    settings[confirmedInstallReleaseKey] = release.toJson();
  }
  final sourceTracking = !app.usesStandardVersionDetection;
  return app.copyWith(
    installedVersion: app.usesVersionCodeAsOsVersion
        ? info.versionCode?.toString()
        : sourceTracking
        ? (confirmed
              ? release.version
              : app.installedVersion ?? info.versionName)
        : info.versionName,
    additionalSettings: settings,
  );
}
