import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/http/source_request_session.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/services/store_icon_resolver.dart';
import 'package:obtainium/version/partial_download_version.dart';

// ── Bounded update-check parallelism (device-tuned) ─────────────────────────
// Start fast on capable devices, but keep a bounded worker pool so a large app
// list does not fan out unbounded HTTP + parse work.
// [AppsProviderUpdates._maxParallelUpdateChecksForDevice] lowers this on low-end
// devices using Android's low-RAM flag and total physical RAM.
const int _defaultParallelUpdateChecks = 8;
const int _modestDeviceParallelUpdateChecks = 4;
const int _lowEndDeviceParallelUpdateChecks = 2;
const int _lowEndRamThresholdMb = 3072;
const int _modestRamThresholdMb = 6144;

// ── Version-reasoning helpers (update detection) ────────────────────────────
// App-level update verdicts. The pure string primitives they build on (equality,
// ordering, reconciliation) live in lib/version/version_strings.dart.

// Kept for reading older records; new decisions are derived from observations.
const unreconciledVersionComparisonKey = 'unreconciledVersionComparison';

bool appHasUnreconciledVersionComparison(App app) {
  return app.installedVersion != null &&
      app.latestVersion.isNotEmpty &&
      app.versionDetectionMode == VersionDetectionMode.auto &&
      !app.usesVersionCodeAsOsVersion &&
      !app.settings.getBool('trackOnly') &&
      versionDecisionForApp(app).relation == VersionRelation.unknown;
}

bool versionCodeModeCannotCompare(App app) {
  return versionDecisionForApp(app).reason == 'codeNameMismatch';
}

bool isSkipActiveForCurrentLatest(App app) {
  final skipped = app.additionalSettings['skippedLatestVersion'];
  return skipped is String &&
      skipped.isNotEmpty &&
      (skipped == app.latestVersion ||
          compareVersionStrings(skipped, app.latestVersion).relation ==
              VersionRelation.same);
}

bool appIsUpToDateForFiltering(App app) {
  if (app.installedVersion == null) return false;
  if (isSkipActiveForCurrentLatest(app)) return true;
  final decision = versionDecisionForApp(app);
  return decision.relation == VersionRelation.same ||
      decision.relation == VersionRelation.newer;
}

App normalizeSkippedLatestVersion(App app) {
  final skipped = app.additionalSettings['skippedLatestVersion'];
  if (skipped is! String || skipped.isEmpty) return app;
  final decision = versionDecisionForApp(app);
  if (isSkipActiveForCurrentLatest(app) &&
      (app.installedVersion == null ||
          (decision.relation != VersionRelation.same &&
              decision.relation != VersionRelation.newer))) {
    return app;
  }
  return app.copyWith(
    additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
      ..remove('skippedLatestVersion'),
  );
}

bool appHasActionableUpdate(App app) {
  if (app.installedVersion == null ||
      app.latestVersion.isEmpty ||
      isSkipActiveForCurrentLatest(app)) {
    return false;
  }
  return versionDecisionForApp(app).relation == VersionRelation.older;
}

bool versionOrderUncertainUpdate(App app) {
  if (app.installedVersion == null ||
      app.latestVersion.isEmpty ||
      isSkipActiveForCurrentLatest(app)) {
    return false;
  }
  final relation = versionDecisionForApp(app).relation;
  return relation == VersionRelation.unknown ||
      relation == VersionRelation.sourceChanged;
}

bool appUpdateIsUserVisible(
  App app, {
  bool includeVersionOrderUncertain = false,
}) {
  if (isSkipActiveForCurrentLatest(app)) return false;
  if (app.installedVersion == null) return app.latestVersion.isNotEmpty;
  return appHasActionableUpdate(app) ||
      (includeVersionOrderUncertain && versionOrderUncertainUpdate(app));
}

bool installedVersionIsNewerOrEqual(String? installed, String latest) {
  if (installed == null) return false;
  final decision = compareVersionStrings(installed, latest);
  return decision.relation == VersionRelation.same ||
      decision.relation == VersionRelation.newer;
}

/// Track-only open URL: RSS release page when [App.changeLog] is http(s), else
/// [App.url].
String trackOnlyDownloadPageUrl(App app) {
  final changeLogValue = app.changeLog;
  if (changeLogValue != null &&
      (changeLogValue.startsWith('http://') ||
          changeLogValue.startsWith('https://'))) {
    final appUrl = Uri.tryParse(app.url);
    final changeLogUrl = Uri.tryParse(changeLogValue);
    if (appUrl?.host.contains('apkmirror.com') == true &&
        changeLogUrl?.host.contains('apkmirror.com') == true) {
      final trackedPath = appUrl!.path.endsWith('/')
          ? appUrl.path
          : '${appUrl.path}/';
      if (!changeLogUrl!.path.startsWith(trackedPath)) {
        return app.url;
      }
    }
    return changeLogValue;
  }
  return app.url;
}

/// Returns the exact apps visible in the list surface being manually refreshed.
/// Passing these IDs to [AppsProviderUpdates.checkUpdates] bypasses the normal
/// freshness interval while preserving the fork's on-demand-only boundary.
List<String> appIdsForManualRefresh({
  required Iterable<App> apps,
  required bool onDemandOnlyList,
  required String? folderId,
  required bool showFolderedAppsOnMainPage,
  required Set<String> existingFolderIds,
}) {
  return apps
      .where((App app) {
        final bool onDemandOnly = app.settings.getBool('onDemandOnly');
        if (onDemandOnlyList) {
          return onDemandOnly;
        }
        if (onDemandOnly) {
          return false;
        }
        if (folderId != null) {
          return folderIdsForApp(app).contains(folderId);
        }
        if (showFolderedAppsOnMainPage) {
          return true;
        }
        return folderIdsForApp(app).where(existingFolderIds.contains).isEmpty;
      })
      .map((App app) => app.listingKey)
      .toList();
}

/// Applies source-owned update fields to the latest live app row.
///
/// User-owned fields stay on [liveApp], so changes made while a network check
/// is running are not overwritten. A result is discarded when the URL or
/// source changed after the request started because it belongs to stale input.
App? mergeFetchedUpdateWithLiveState({
  required App requestedApp,
  required App? liveApp,
  required App fetchedApp,
}) {
  if (liveApp == null ||
      liveApp.url != requestedApp.url ||
      liveApp.overrideSource != requestedApp.overrideSource) {
    return null;
  }
  final int preferredApkIndex =
      liveApp.preferredApkIndex < fetchedApp.apkUrls.length
      ? liveApp.preferredApkIndex
      : fetchedApp.preferredApkIndex;
  final bool malwareScanStillMatchesRelease =
      liveApp.latestVersion == fetchedApp.latestVersion;
  final settings = Map<String, dynamic>.from(liveApp.additionalSettings)
    ..remove(sourceVersionCodesKey)
    // This answer found a release.
    ..remove(noMatchingReleaseKey);
  if (fetchedApp.additionalSettings[sourceVersionCodesKey] != null) {
    settings[sourceVersionCodesKey] =
        fetchedApp.additionalSettings[sourceVersionCodesKey];
  }
  settings.remove(sourceBuildComparisonKey);
  if (fetchedApp.additionalSettings[sourceBuildComparisonKey] != null) {
    settings[sourceBuildComparisonKey] =
        fetchedApp.additionalSettings[sourceBuildComparisonKey];
  }
  settings.remove('rawSelectedReleaseTitle');
  if (fetchedApp.additionalSettings['rawSelectedReleaseTitle'] != null) {
    settings['rawSelectedReleaseTitle'] =
        fetchedApp.additionalSettings['rawSelectedReleaseTitle'];
  }
  settings.remove(partialDownloadFingerprintKey);
  if (fetchedApp.additionalSettings[partialDownloadFingerprintKey] != null) {
    settings[partialDownloadFingerprintKey] =
        fetchedApp.additionalSettings[partialDownloadFingerprintKey];
  }
  return normalizeSelectedSourceVersion(
    liveApp.copyWith(
      additionalSettings: settings,
      author: fetchedApp.author,
      name: fetchedApp.name,
      latestVersion: fetchedApp.latestVersion,
      apkUrls: fetchedApp.apkUrls,
      otherAssetUrls: fetchedApp.otherAssetUrls,
      preferredApkIndex: preferredApkIndex,
      lastUpdateCheck: fetchedApp.lastUpdateCheck,
      releaseDate: fetchedApp.releaseDate,
      changeLog: fetchedApp.changeLog,
      pendingRepoRenameUrl: fetchedApp.pendingRepoRenameUrl,
      iconUrl: fetchedApp.iconUrl,
      apkSizeBytes: fetchedApp.apkSizeBytes,
      rawLatestVersionFromSource: fetchedApp.rawLatestVersionFromSource,
      rawApkNamesFromSource: fetchedApp.rawApkNamesFromSource,
      rawReleaseTitlesFromSource: fetchedApp.rawReleaseTitlesFromSource,
      latestIsReproducible: fetchedApp.latestIsReproducible,
      latestReproducibleStatus: fetchedApp.latestReproducibleStatus,
      latestReproducibleVersionCode: fetchedApp.latestReproducibleVersionCode,
      latestAttestationStatus: fetchedApp.latestAttestationStatus,
      latestMalwareScanStatus: malwareScanStillMatchesRelease
          ? liveApp.latestMalwareScanStatus
          : null,
      latestMalwareScanDetail: malwareScanStillMatchesRelease
          ? liveApp.latestMalwareScanDetail
          : null,
      latestMalwareScanReportUrl: malwareScanStillMatchesRelease
          ? liveApp.latestMalwareScanReportUrl
          : null,
    ),
  );
}

/// Alternate store names from [BulkScanCache] that may become the tracked source.
/// Play Store is intentionally excluded.
const Set<String> swappableAlternateStoreNames = {
  'F-Droid',
  'APKPure',
  'APKMirror',
  'GitHub',
};

bool isSwappableGitHubRepoUrl(String url) {
  final Uri? parsed = Uri.tryParse(url.trim());
  if (parsed == null) return false;
  final String host = parsed.host.toLowerCase();
  if (host != 'github.com' && !host.endsWith('.github.com')) {
    return false;
  }
  final List<String> segments = parsed.pathSegments
      .where((String segment) => segment.isNotEmpty)
      .toList();
  if (segments.length < 2) return false;
  return segments[0].isNotEmpty && segments[1].isNotEmpty;
}

/// Persists a known GitHub repository URL as an alternate source without
/// running GitHub code search.
Future<void> preserveAlternateGitHubSourceInCache({
  required String packageId,
  required String githubUrl,
}) async {
  if (!isSwappableGitHubRepoUrl(githubUrl)) return;
  final String standardizedUrl = GitHub().standardizeUrl(githubUrl);
  await BulkScanCache.mergeStoreAndSave(
    <String, Map<String, String>>{},
    'GitHub',
    <String, String?>{packageId: standardizedUrl},
  );
}

bool isApkMirrorStoreSearchUrl(String url) {
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null) return false;
  return parsed.host.toLowerCase().contains('apkmirror.com') &&
      parsed.queryParameters['searchtype'] == 'apk';
}

/// Resolves a concrete listing URL for a store swap. Returns null when the app
/// cannot be found on that store.
Future<String?> resolveSwappableStoreListingUrl({
  required String storeName,
  required String packageId,
  String? candidateUrl,
}) async {
  if (!swappableAlternateStoreNames.contains(storeName)) {
    return null;
  }
  switch (storeName) {
    case 'APKMirror':
      if (candidateUrl != null &&
          candidateUrl.isNotEmpty &&
          !isApkMirrorStoreSearchUrl(candidateUrl)) {
        return candidateUrl;
      }
      return (await BulkImportService.checkApkMirror([packageId]))[packageId];
    case 'APKPure':
      if (candidateUrl != null &&
          candidateUrl.isNotEmpty &&
          isWellFormedApkPureUrl(candidateUrl)) {
        return candidateUrl;
      }
      return (await BulkImportService.checkApkPure([packageId]))[packageId];
    case 'F-Droid':
      if (candidateUrl != null && candidateUrl.isNotEmpty) {
        return candidateUrl;
      }
      return (await BulkImportService.checkFDroid([packageId]))[packageId] ??
          'https://f-droid.org/packages/$packageId/';
    case 'GitHub':
      if (candidateUrl != null &&
          candidateUrl.isNotEmpty &&
          isSwappableGitHubRepoUrl(candidateUrl)) {
        return GitHub().standardizeUrl(candidateUrl);
      }
      final Map<String, String>? cachedStores = await BulkScanCache.loadForApp(
        packageId,
      );
      final String? cachedGitHubUrl = cachedStores?['GitHub'];
      if (cachedGitHubUrl != null &&
          cachedGitHubUrl.isNotEmpty &&
          isSwappableGitHubRepoUrl(cachedGitHubUrl)) {
        return GitHub().standardizeUrl(cachedGitHubUrl);
      }
      return null;
    default:
      return null;
  }
}

/// Settings whose values are written against one store's file and release
/// names, so they cannot survive a move to another store.
///
/// A filter like `foss` picks the right asset out of a GitHub release and
/// matches nothing at all among APKPure's `<package>-<versionCode>-<arch>.apk`
/// names. An empty APK list after filtering is not a fallback - it is the
/// "no APK found" failure the user sees - so these are dropped and the
/// destination's defaults apply, exactly as when adding the app from that
/// store by hand.
const Set<String> storeShapedAppSettingKeys = {
  'apkFilterRegEx',
  'invertAPKFilter',
  'zippedApkFilterRegEx',
  'tarballedApkFilterRegEx',
  'versionExtractionRegEx',
  'matchGroupToUse',
};

App prepareAppForTrackedSourceSwap({
  required App app,
  required AppSource previousSource,
  required AppSource destinationSource,
  required String standardizedDestinationUrl,
}) {
  final Map<String, dynamic> settings = Map<String, dynamic>.from(
    app.additionalSettings,
  );
  for (final String metadataKey in <String>[
    sourceVersionCodesKey,
    sourceBuildComparisonKey,
    acknowledgedSourceReleaseKey,
    'rawSelectedReleaseTitle',
    partialDownloadFingerprintKey,
    'skippedLatestVersion',
    unreconciledVersionComparisonKey,
    ...storeShapedAppSettingKeys,
  ]) {
    settings.remove(metadataKey);
  }
  // Options the previous store owns are meaningless at the destination, and one
  // store's key can mean something different at another. Keys both stores offer
  // stay (same option, same semantics), as do keys that belong to neither form
  // - notably 'appId', which identifies the package rather than the store.
  final Set<String> destinationSettingKeys = destinationSource
      .flatCombinedFormItemsReadOnly
      .map((GeneratedFormItem item) => item.key)
      .toSet();
  for (final GeneratedFormItem previousSourceItem
      in previousSource.additionalSourceAppSpecificSettingFormItems.expand(
        (List<GeneratedFormItem> row) => row,
      )) {
    if (!destinationSettingKeys.contains(previousSourceItem.key)) {
      settings.remove(previousSourceItem.key);
    }
  }
  // Whatever the destination offers and the previous store never set has to
  // arrive at its default, not absent: APKPure's 'useFirstApkOfVersion'
  // defaults to on, and reading a missing key as off makes a swapped listing
  // behave unlike the same app added directly from APKPure.
  getDefaultValuesFromFormItems(
    destinationSource.combinedAppSpecificSettingFormItems,
  ).forEach((String key, dynamic defaultValue) {
    settings.putIfAbsent(key, () => defaultValue);
  });
  if (destinationSource.enforceTrackOnly) {
    settings['trackOnly'] = true;
  } else if (previousSource.enforceTrackOnly) {
    settings.remove('trackOnly');
  }
  syncVersionStringSourceSettings(settings);
  final List<MapEntry<String, String>> versionSourceOptions =
      destinationSource.versionStringSourceOptions;
  final String? selectedVersionSource = settings['versionStringSource']
      ?.toString();
  if (versionSourceOptions.length <= 1 ||
      selectedVersionSource == null ||
      !versionSourceOptions.any(
        (MapEntry<String, String> option) =>
            option.key == selectedVersionSource,
      )) {
    settings.remove('versionStringSource');
    syncVersionStringSourceSettings(settings);
  }
  return app.copyWith(
    url: standardizedDestinationUrl,
    overrideSource: null,
    pendingRepoRenameUrl: null,
    iconUrl: null,
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
    additionalSettings: settings,
  );
}

/// Merges a fetched release after a tracked-source swap. Unlike
/// [mergeFetchedUpdateWithLiveState], the live row still points at the previous
/// source until this merge commits the new URL and override.
App? mergeTrackedSourceSwap({
  required String originalUrl,
  required String? originalOverrideSource,
  required App? liveApp,
  required App requestedApp,
  required App fetchedApp,
}) {
  if (liveApp == null ||
      liveApp.url != originalUrl ||
      liveApp.overrideSource != originalOverrideSource) {
    return null;
  }
  final int preferredApkIndex =
      liveApp.preferredApkIndex < fetchedApp.apkUrls.length
      ? liveApp.preferredApkIndex
      : fetchedApp.preferredApkIndex;
  final Map<String, dynamic> settings =
      Map<String, dynamic>.from(requestedApp.additionalSettings)
        ..remove(sourceVersionCodesKey)
        // The new source found a release.
        ..remove(noMatchingReleaseKey);
  if (fetchedApp.additionalSettings[sourceVersionCodesKey] != null) {
    settings[sourceVersionCodesKey] =
        fetchedApp.additionalSettings[sourceVersionCodesKey];
  }
  settings.remove(sourceBuildComparisonKey);
  if (fetchedApp.additionalSettings[sourceBuildComparisonKey] != null) {
    settings[sourceBuildComparisonKey] =
        fetchedApp.additionalSettings[sourceBuildComparisonKey];
  }
  settings.remove('rawSelectedReleaseTitle');
  if (fetchedApp.additionalSettings['rawSelectedReleaseTitle'] != null) {
    settings['rawSelectedReleaseTitle'] =
        fetchedApp.additionalSettings['rawSelectedReleaseTitle'];
  }
  settings.remove(partialDownloadFingerprintKey);
  if (fetchedApp.additionalSettings[partialDownloadFingerprintKey] != null) {
    settings[partialDownloadFingerprintKey] =
        fetchedApp.additionalSettings[partialDownloadFingerprintKey];
  }
  return normalizeSelectedSourceVersion(
    liveApp.copyWith(
      url: requestedApp.url,
      overrideSource: requestedApp.overrideSource,
      pendingRepoRenameUrl: null,
      additionalSettings: settings,
      author: fetchedApp.author,
      name: fetchedApp.name,
      latestVersion: fetchedApp.latestVersion,
      apkUrls: fetchedApp.apkUrls,
      otherAssetUrls: fetchedApp.otherAssetUrls,
      preferredApkIndex: preferredApkIndex,
      lastUpdateCheck: fetchedApp.lastUpdateCheck,
      releaseDate: fetchedApp.releaseDate,
      changeLog: fetchedApp.changeLog,
      iconUrl: fetchedApp.iconUrl,
      apkSizeBytes: fetchedApp.apkSizeBytes,
      rawLatestVersionFromSource: fetchedApp.rawLatestVersionFromSource,
      rawApkNamesFromSource: fetchedApp.rawApkNamesFromSource,
      rawReleaseTitlesFromSource: fetchedApp.rawReleaseTitlesFromSource,
      latestIsReproducible: fetchedApp.latestIsReproducible,
      latestReproducibleStatus: fetchedApp.latestReproducibleStatus,
      latestReproducibleVersionCode: fetchedApp.latestReproducibleVersionCode,
      latestAttestationStatus: fetchedApp.latestAttestationStatus,
      latestMalwareScanStatus: null,
      latestMalwareScanDetail: null,
      latestMalwareScanReportUrl: null,
    ),
  );
}

typedef _FetchedAppUpdate = ({App requestedApp, App fetchedApp});

/// Whether [error] means the source was reached and answered, just with
/// nothing usable: no release, APK or version matching the app's settings.
///
/// That still counts as a check, so it moves the app's check time. A network
/// failure, rate limit or anything unclassified doesn't: the source was never
/// heard from, and leaving the time alone keeps the app first in line for the
/// next check.
bool sourceAnsweredWithoutUpdate(Object error) =>
    error is NoReleasesError || error is NoAPKError || error is NoVersionError;

/// [app] as saved after its source answered with [error] (one that
/// [sourceAnsweredWithoutUpdate] accepts) at [checkedAt].
App appAfterAnswerWithoutUpdate(App app, Object error, DateTime checkedAt) {
  // A release exists and only its version couldn't be read, so keep what is
  // known instead of claiming the source has nothing.
  if (error is NoVersionError) return app.copyWith(lastUpdateCheck: checkedAt);
  return appWithNoMatchingRelease(app, checkedAt);
}

/// Update checking and pending-update bookkeeping for [AppsProvider].
extension AppsProviderUpdates on AppsProvider {
  /// Fetches the latest [App] metadata from its source WITHOUT persisting it.
  /// Returns null if the app is missing or has a pending repo rename.
  ///
  /// Keeping fetch and save separate lets [checkUpdates] batch many checks into
  /// a few [saveApps] calls instead of saving (and triggering a full UI
  /// rebuild) once per app.
  Future<_FetchedAppUpdate?> _fetchUpdateSnapshot(String appId) async {
    final App? currentApp = apps[appId]?.app;
    // Pause update checks until the user resolves a pending repo rename.
    if (currentApp == null || currentApp.hasPendingRepoRename) {
      return null;
    }
    final SourceProvider sourceProvider = SourceProvider();
    final AppSource source = sourceProvider.getSource(
      currentApp.url,
      overrideSource: currentApp.overrideSource,
    );
    App fetchedApp = await sourceProvider.getApp(
      source,
      currentApp.url,
      currentApp.additionalSettings,
      currentApp: currentApp,
    );
    fetchedApp = await _fillDownloadSizeIfUpdatePending(
      source,
      currentApp,
      fetchedApp,
    );
    return (requestedApp: currentApp, fetchedApp: fetchedApp);
  }

  /// For sources that don't publish an APK size in their metadata (GitLab,
  /// SourceForge, SourceHut, direct-APK links, HTML), probe the preferred APK's
  /// Content-Length so the update button can still show a size — but ONLY when
  /// an update is actually pending. GitHub/stores/F-Droid already fill
  /// [APKDetails.apkSizeBytes], and getApp carries a known size across
  /// same-version checks, so this adds at most one request per new release and
  /// never fires for up-to-date or track-only apps.
  Future<App> _fillDownloadSizeIfUpdatePending(
    AppSource source,
    App currentApp,
    App fetchedApp,
  ) async {
    if (fetchedApp.apkSizeBytes != null) return fetchedApp;
    if (currentApp.settings.getBool('trackOnly')) return fetchedApp;
    // Only when there's something to download. Raw string inequality here probed
    // a Content-Length on every check for versions that merely reformat, and for
    // releases the user already skipped.
    if (!appUpdateIsUserVisible(
      fetchedApp,
      includeVersionOrderUncertain: true,
    )) {
      return fetchedApp;
    }
    if (fetchedApp.apkUrls.isEmpty) return fetchedApp;
    final int idx =
        (fetchedApp.preferredApkIndex >= 0 &&
            fetchedApp.preferredApkIndex < fetchedApp.apkUrls.length)
        ? fetchedApp.preferredApkIndex
        : 0;
    final String url = fetchedApp.apkUrls[idx].value;
    if (url.isEmpty) return fetchedApp;
    try {
      // Resolve the real download URL first: sources like GitLab and Uptodown
      // rewrite the asset URL in assetUrlPrefetchModifier, so probing the
      // unresolved URL returns a wrong or missing Content-Length. The install
      // path already resolves before downloading; do the same here. (#3104)
      final String resolvedUrl = await source.assetUrlPrefetchModifier(
        url,
        currentApp.url,
        currentApp.additionalSettings,
      );
      if (resolvedUrl.isEmpty) return fetchedApp;
      final Map<String, String>? headers = await source.getRequestHeaders(
        currentApp.additionalSettings,
        resolvedUrl,
        forAPKDownload: true,
      );
      final int? size = await getDownloadSize(
        resolvedUrl,
        headers: headers,
        allowInsecure: currentApp.settings.getBool('allowInsecure'),
      );
      if (size != null && size > 0) {
        return fetchedApp.copyWith(apkSizeBytes: size);
      }
    } catch (_) {
      // Best-effort: leave the size unknown on any failure.
    }
    return fetchedApp;
  }

  Future<App?> fetchUpdate(String appId) async {
    return SourceRequestSession.run(() => _fetchUpdateInSession(appId));
  }

  Future<App?> _fetchUpdateInSession(String appId) async {
    final _FetchedAppUpdate? update = await _fetchUpdateSnapshot(appId);
    if (update == null) return null;
    return mergeFetchedUpdateWithLiveState(
      requestedApp: update.requestedApp,
      liveApp: apps[appId]?.app,
      fetchedApp: update.fetchedApp,
    );
  }

  Future<App?> checkUpdate(String appId) async {
    return SourceRequestSession.run(() => _checkUpdateInSession(appId));
  }

  Future<App?> _checkUpdateInSession(String appId) async {
    final _FetchedAppUpdate? update;
    try {
      update = await _fetchUpdateSnapshot(appId);
    } catch (error) {
      if (sourceAnsweredWithoutUpdate(error)) {
        final App? app = apps[appId]?.app;
        if (app != null) {
          await saveApps([
            appAfterAnswerWithoutUpdate(app, error, DateTime.now()),
          ], updateInstalledInfo: false);
        }
      }
      rethrow;
    }
    if (update == null) return null;
    final App? mergedApp = mergeFetchedUpdateWithLiveState(
      requestedApp: update.requestedApp,
      liveApp: apps[appId]?.app,
      fetchedApp: update.fetchedApp,
    );
    if (mergedApp == null) return null;
    await saveApps([mergedApp]);
    return mergedApp.latestVersion != update.requestedApp.latestVersion
        ? mergedApp
        : null;
  }

  /// Moves [appId] to [storeName] using [candidateUrl] when known, refreshes
  /// metadata from the destination source, and persists only after a successful
  /// fetch. Returns null when the app is missing or a concurrent edit wins.
  Future<App?> swapTrackedSource({
    required String appId,
    required String storeName,
    String? candidateUrl,
  }) {
    return SourceRequestSession.run(
      () => _swapTrackedSourceInSession(
        appId: appId,
        storeName: storeName,
        candidateUrl: candidateUrl,
      ),
    );
  }

  Future<App?> _swapTrackedSourceInSession({
    required String appId,
    required String storeName,
    String? candidateUrl,
  }) async {
    if (!swappableAlternateStoreNames.contains(storeName)) {
      throw ObtainiumError(tr('swapTrackedSourceUnsupportedStore'));
    }
    final AppInMemory? entry = apps[appId];
    if (entry == null) {
      return null;
    }
    if (entry.downloadProgress != null) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    final App currentApp = entry.app;
    // [appId] identifies the listing being swapped, which is not the Android
    // package ID once a package is tracked from more than one store. The
    // store-availability cache is keyed by package, so it needs this.
    final String packageId = currentApp.id;
    final String originalUrl = currentApp.url;
    final String? originalOverrideSource = currentApp.overrideSource;
    final SourceProvider sourceProvider = SourceProvider();
    final AppSource previousSource = sourceProvider.getSource(
      currentApp.url,
      overrideSource: currentApp.overrideSource,
    );
    if (previousSource.sourceIdentifier == 'GitHub' ||
        isSwappableGitHubRepoUrl(originalUrl)) {
      await preserveAlternateGitHubSourceInCache(
        packageId: packageId,
        githubUrl: previousSource.standardizeUrl(originalUrl),
      );
    }
    final String? resolvedUrl = await resolveSwappableStoreListingUrl(
      storeName: storeName,
      packageId: packageId,
      candidateUrl: candidateUrl,
    );
    if (resolvedUrl == null || resolvedUrl.isEmpty) {
      throw NoAPKError()..url = candidateUrl ?? storeName;
    }
    final AppSource destinationSource = sourceProvider.getSource(resolvedUrl);
    final String standardizedUrl = destinationSource.standardizeUrl(
      resolvedUrl,
    );
    final App requestedApp = prepareAppForTrackedSourceSwap(
      app: currentApp,
      previousSource: previousSource,
      destinationSource: destinationSource,
      standardizedDestinationUrl: standardizedUrl,
    );
    // Swapping stores must obey the same rule as adding an app: one listing per
    // package per store. Without this, swapping a package's GitHub listing onto
    // F-Droid while it is already tracked from F-Droid leaves it tracked twice
    // from the same store. Checked before the fetch so it costs no request.
    if (sameStoreListingIn(apps, requestedApp, ignoreKey: entry.listingKey) !=
        null) {
      throw ObtainiumError(tr('appAlreadyAdded'));
    }
    App fetchedApp = await sourceProvider.getApp(
      destinationSource,
      standardizedUrl,
      requestedApp.additionalSettings,
      currentApp: requestedApp,
    );
    fetchedApp = await _fillDownloadSizeIfUpdatePending(
      destinationSource,
      requestedApp,
      fetchedApp,
    );
    final App? mergedApp = mergeTrackedSourceSwap(
      originalUrl: originalUrl,
      originalOverrideSource: originalOverrideSource,
      liveApp: apps[appId]?.app,
      requestedApp: requestedApp,
      fetchedApp: fetchedApp,
    );
    if (mergedApp == null) {
      return null;
    }
    // saveApps re-resolves the store from the app's new URL, so the listing
    // already reports the destination store here.
    await saveApps([mergedApp]);
    return mergedApp;
  }

  /// Returns app IDs sorted by last update check time, oldest first.
  /// When [forceAll] is false, only includes apps whose per-app lastUpdateCheck
  /// is older than the configured update interval (or null — never checked).
  /// When [forceAll] is true, includes all apps regardless of interval.
  List<String> getAppsSortedByUpdateCheckTime({
    bool onlyCheckInstalledOrTrackOnlyApps = false,
    bool forceAll = false,
  }) {
    final minAge = DateTime.now().subtract(
      Duration(minutes: settingsProvider.updateInterval),
    );
    final List<String> appIds = apps.values
        .where((app) => !app.app.settings.getBool('onDemandOnly'))
        .where(
          (app) =>
              forceAll ||
              app.app.lastUpdateCheck == null ||
              app.app.lastUpdateCheck!.isBefore(minAge),
        )
        .where((app) {
          if (!onlyCheckInstalledOrTrackOnlyApps) {
            return true;
          } else {
            return app.app.installedVersion != null ||
                app.app.settings.getBool('trackOnly');
          }
        })
        .map((e) => e.listingKey)
        .toList();
    appIds.sort(
      (a, b) =>
          (apps[a]!.app.lastUpdateCheck ??
                  DateTime.fromMicrosecondsSinceEpoch(0))
              .compareTo(
                apps[b]!.app.lastUpdateCheck ??
                    DateTime.fromMicrosecondsSinceEpoch(0),
              ),
    );
    return appIds;
  }

  /// Earliest moment any tracked app becomes due for a check, or null when
  /// something is due already (or checking is disabled). Applies the same
  /// eligibility filters as [getAppsSortedByUpdateCheckTime], so a background
  /// wake-up can trust it to decide whether loading the app records is worth
  /// it at all.
  DateTime? earliestNextUpdateCheckDue() {
    final int intervalMinutes = settingsProvider.updateInterval;
    if (intervalMinutes <= 0) return null;
    final Duration interval = Duration(minutes: intervalMinutes);
    DateTime? earliest;
    for (final listing in apps.values) {
      final App app = listing.app;
      if (app.settings.getBool('onDemandOnly')) continue;
      if (settingsProvider.onlyCheckInstalledOrTrackOnlyApps &&
          app.installedVersion == null &&
          !app.settings.getBool('trackOnly')) {
        continue;
      }
      final DateTime? checked = app.lastUpdateCheck;
      // Never checked means due now, which leaves nothing to wait for.
      if (checked == null) return null;
      final DateTime due = checked.add(interval);
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    return earliest;
  }

  /// Runs update checks and returns the apps whose source [App.latestVersion]
  /// CHANGED during this run.
  ///
  /// That is deliberately not the same as "these apps have an update available":
  /// a version-string reformat, a re-tagged release or a source downgrade all
  /// change the string without putting the device behind. Callers that surface
  /// this to the user (notifications) or act on it (background install) must
  /// filter with [appUpdateIsUserVisible] so they agree with the app list.
  Future<List<App>> checkUpdates({
    bool throwErrorsForRetry = false,
    List<String>? specificIds,
    bool forceAll = false,
    SettingsProvider? sp,
  }) {
    return SourceRequestSession.run(
      () => _checkUpdatesInSession(
        throwErrorsForRetry: throwErrorsForRetry,
        specificIds: specificIds,
        forceAll: forceAll,
        sp: sp,
      ),
    );
  }

  Future<List<App>> _checkUpdatesInSession({
    bool throwErrorsForRetry = false,
    List<String>? specificIds,
    bool forceAll = false,
    SettingsProvider? sp,
  }) async {
    final SettingsProvider settingsProvider = sp ?? this.settingsProvider;
    if (updateCheckCompleter != null) {
      return updateCheckCompleter!.future;
    }
    final completer = updateCheckCompleter = Completer<List<App>>();
    var completed = 0;
    var total = 0;
    DateTime lastProgressNotification = DateTime.fromMillisecondsSinceEpoch(0);
    refreshProgress = 0.0;
    void reportProgress({bool force = false}) {
      final DateTime now = DateTime.now();
      if (force ||
          now.difference(lastProgressNotification) >=
              const Duration(milliseconds: 250)) {
        lastProgressNotification = now;
        refreshProgress = total > 0 ? completed / total : 0.0;
      }
    }

    try {
      final List<App> updates = [];
      final MultiAppMultiError errors = MultiAppMultiError();
      List<String> appIds;
      if (specificIds != null) {
        // Keep only IDs that resolve to exactly one listing, so an ambiguous
        // package ID (tracked from two stores) can't null-crash below.
        appIds = specificIds.where((id) => apps[id] != null).toSet().toList();
        if (settingsProvider.onlyCheckInstalledOrTrackOnlyApps) {
          appIds.removeWhere((id) {
            final App app = apps[id]!.app;
            return app.installedVersion == null &&
                !app.settings.getBool('trackOnly');
          });
        }
        appIds.sort(
          (a, b) =>
              (apps[a]!.app.lastUpdateCheck ??
                      DateTime.fromMicrosecondsSinceEpoch(0))
                  .compareTo(
                    apps[b]!.app.lastUpdateCheck ??
                        DateTime.fromMicrosecondsSinceEpoch(0),
                  ),
        );
      } else {
        appIds = getAppsSortedByUpdateCheckTime(
          onlyCheckInstalledOrTrackOnlyApps:
              settingsProvider.onlyCheckInstalledOrTrackOnlyApps,
          forceAll: forceAll,
        );
      }
      total = appIds.length;
      final List<_FetchedAppUpdate> pendingResults = [];
      // Checked, but the source had nothing usable (see
      // sourceAnsweredWithoutUpdate), keyed to that answer. Saved with the
      // next flush, the same as a found release.
      final Map<String, Object> pendingAnswered = {};
      DateTime lastSaveTime = DateTime.now();
      bool saveInProgress = false;
      const Duration saveInterval = Duration(seconds: 3);
      int nextIndex = 0;
      final int workerCount = min(
        total,
        await maxParallelUpdateChecksForDevice(),
      );

      Future<_FetchedAppUpdate?> fetchUpdateWithHandshakeRetry(
        String appId,
      ) async {
        try {
          return await _fetchUpdateSnapshot(appId);
        } on HandshakeException {
          // Concurrent TLS handshakes to the same host can fail on certain
          // devices or networks. Keep retries inside the bounded worker so
          // they cannot bypass the device-tuned concurrency limit.
          const int maxRetries = 5;
          final Random random = Random();
          for (int attempt = 0; attempt < maxRetries; attempt++) {
            await Future.delayed(
              Duration(milliseconds: 250 + random.nextInt(501)),
            );
            try {
              return await _fetchUpdateSnapshot(appId);
            } on HandshakeException {
              if (attempt == maxRetries - 1) rethrow;
            }
          }
          return null;
        }
      }

      Future<void> flushFetchedResults({bool force = false}) async {
        if (saveInProgress ||
            (pendingResults.isEmpty && pendingAnswered.isEmpty)) {
          return;
        }
        final DateTime now = DateTime.now();
        if (!force && now.difference(lastSaveTime) < saveInterval) return;

        saveInProgress = true;
        final List<_FetchedAppUpdate> batch = List.from(pendingResults);
        pendingResults.clear();
        final Map<String, Object> answered = Map.from(pendingAnswered);
        pendingAnswered.clear();
        try {
          final List<App> fetched = [];
          answered.forEach((String appId, Object error) {
            final App? liveApp = apps[appId]?.app;
            if (liveApp != null) {
              fetched.add(appAfterAnswerWithoutUpdate(liveApp, error, now));
            }
          });
          for (final _FetchedAppUpdate result in batch) {
            final App? mergedApp = mergeFetchedUpdateWithLiveState(
              requestedApp: result.requestedApp,
              liveApp: apps[result.requestedApp.listingKey]?.app,
              fetchedApp: result.fetchedApp,
            );
            if (mergedApp == null) continue;
            fetched.add(mergedApp);
            if (mergedApp.latestVersion != result.requestedApp.latestVersion) {
              updates.add(mergedApp);
            }
          }
          if (fetched.isNotEmpty) {
            // Reuse cached install info: this flush runs every few seconds for
            // the whole update check, and a refresh here costs a device-wide
            // package enumeration per flush (also in the background isolate).
            // Install state is refreshed by loadApps on launch and on every
            // foreground resume, which is where external installs get picked up.
            await saveApps(fetched, updateInstalledInfo: false);
          }
        } finally {
          lastSaveTime = DateTime.now();
          saveInProgress = false;
        }
      }

      Future<void> runWorker() async {
        while (nextIndex < total) {
          final String appId = appIds[nextIndex++];
          try {
            final _FetchedAppUpdate? update =
                await fetchUpdateWithHandshakeRetry(appId);
            if (update != null) {
              pendingResults.add(update);
            }
          } catch (e) {
            if ((e is RateLimitError ||
                    e is SocketException ||
                    e is HandshakeException) &&
                throwErrorsForRetry) {
              rethrow;
            }
            if (e is RepositoryRenamedError) {
              await updatePendingRepoRename(appId, e.newUrl);
            } else {
              errors.add(appId, e, appName: apps[appId]?.name);
              if (sourceAnsweredWithoutUpdate(e)) pendingAnswered[appId] = e;
            }
          } finally {
            completed++;
            reportProgress();
          }
          await flushFetchedResults();
        }
      }

      await Future.wait(List.generate(workerCount, (_) => runWorker()));
      reportProgress(force: true);
      await flushFetchedResults(force: true);
      if (errors.idsByErrorString.isNotEmpty) {
        final ex = CheckUpdatesException(updates, errors);
        completer.completeError(ex);
        throw ex;
      }
      completer.complete(updates);
      return updates;
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
      rethrow;
    } finally {
      updateCheckCompleter = null;
      finishPendingAutoExport();
      refreshProgress = null;
    }
  }

  /// Returns app ids with an installable or attention-needed update.
  ///
  /// When [includeVersionOrderUncertain] is false (default), only
  /// [appHasActionableUpdate] counts for installed apps so "update all" and
  /// background install do not treat ambiguous ordering as a known
  /// behind-latest case. When true, [versionOrderUncertainUpdate] apps are
  /// included too (e.g. the tab badge).
  List<String> findExistingUpdates({
    bool installedOnly = false,
    bool nonInstalledOnly = false,
    bool excludeOnDemandOnly = false,
    bool includeVersionOrderUncertain = false,
  }) {
    if (installedOnly && nonInstalledOnly) {
      return [];
    }
    final List<String> updateAppIds = [];
    for (final appInMemory in apps.values) {
      final app = appInMemory.app;
      if (excludeOnDemandOnly && app.settings.getBool('onDemandOnly')) {
        continue;
      }
      final installed = app.installedVersion;

      if (installed == null) {
        if (!(nonInstalledOnly || !installedOnly)) continue;
        // Never installed → always installable.
        updateAppIds.add(appInMemory.listingKey);
      } else {
        if (!(installedOnly || !nonInstalledOnly)) continue;
        if (appHasActionableUpdate(app) ||
            (includeVersionOrderUncertain &&
                versionOrderUncertainUpdate(app))) {
          updateAppIds.add(appInMemory.listingKey);
        }
      }
    }
    return updateAppIds;
  }

  /// Device-tuned upper bound on how many update checks run in parallel. Low-RAM
  /// devices fan out less to avoid thrashing; capable devices keep the default.
  Future<int> maxParallelUpdateChecksForDevice() async {
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.isLowRamDevice ||
          (androidInfo.physicalRamSize > 0 &&
              androidInfo.physicalRamSize <= _lowEndRamThresholdMb)) {
        return _lowEndDeviceParallelUpdateChecks;
      }
      if (androidInfo.physicalRamSize > 0 &&
          androidInfo.physicalRamSize <= _modestRamThresholdMb) {
        return _modestDeviceParallelUpdateChecks;
      }
    } catch (_) {
      // If device info is unavailable, prefer speed and keep the bounded
      // default rather than silently falling back to the slowest path.
    }
    return _defaultParallelUpdateChecks;
  }

  void _pruneStaleDetailPageAutoCheckStarts(DateTime now, Duration cooldown) {
    lastDetailPageAutoCheckStartedAt.removeWhere(
      (String appId, DateTime startedAt) =>
          !detailPageAutoChecksInFlight.contains(appId) &&
          now.difference(startedAt) >= cooldown,
    );
  }

  /// Reserves an auto-check slot for the detail page of [appId], returning true
  /// only when a check should actually start now (not recently run/started and
  /// not already in flight).
  bool tryBeginDetailPageAutoCheck({
    required String appId,
    required DateTime now,
    required Duration cooldown,
    required DateTime? lastUpdateCheckAt,
  }) {
    _pruneStaleDetailPageAutoCheckStarts(now, cooldown);
    final DateTime? lastStartedAt = lastDetailPageAutoCheckStartedAt[appId];
    final bool recentlyCompleted =
        lastUpdateCheckAt != null &&
        now.difference(lastUpdateCheckAt) < cooldown;
    final bool recentlyStarted =
        lastStartedAt != null && now.difference(lastStartedAt) < cooldown;
    if (recentlyCompleted ||
        recentlyStarted ||
        detailPageAutoChecksInFlight.contains(appId)) {
      return false;
    }
    detailPageAutoChecksInFlight.add(appId);
    lastDetailPageAutoCheckStartedAt[appId] = now;
    return true;
  }

  void finishDetailPageAutoCheck(String appId) {
    detailPageAutoChecksInFlight.remove(appId);
  }
}
