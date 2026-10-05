// Minimum update age resolution and suppression helpers.
//
// Sources may skip releases younger than the configured minimum update age
// (supply-chain delay); sources that cannot look back rely on the fetch
// suppression below and on the add-time check in [SourceProvider.getApp].

import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/version/app_version.dart'
    show sourceBuildComparisonKey;
import 'package:obtainium/version/partial_download_version.dart'
    show partialDownloadFingerprintKey;
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves the effective minimum update age (in days) for an app: the
/// per-app override when set, otherwise the global setting.
Future<int> effectiveMinUpdateAgeDays(
  Map<String, dynamic> additionalSettings, {
  SettingsProvider? settingsProvider,
}) async {
  final raw = additionalSettings['minimumUpdateAgeDays'];
  if (raw is String && raw.isNotEmpty) {
    final parsed = int.tryParse(raw);
    if (parsed != null) {
      return parsed;
    }
  }
  // Only a stored value is read, so skip SettingsProvider's one-time init
  // (migrations and native lookups): this runs on every update check.
  final sp = settingsProvider ?? SettingsProvider();
  sp.prefs ??= await SharedPreferences.getInstance();
  return sp.minimumUpdateAgeDays;
}

/// Whether [releaseDate] is younger than [minAgeDays] as of [now].
bool isReleaseTooYoung(DateTime? releaseDate, int minAgeDays, {DateTime? now}) {
  if (releaseDate == null || minAgeDays <= 0) return false;
  return (now ?? DateTime.now()).difference(releaseDate) <
      Duration(days: minAgeDays);
}

/// `additionalSettings` entries that describe the fetched release rather than
/// the user's configuration, so they move with the release.
const List<String> _releaseScopedSettingKeys = [
  'sourceVersionCodes',
  'rawSelectedReleaseTitle',
  sourceBuildComparisonKey,
  partialDownloadFingerprintKey,
];

/// Replaces every release-specific field of [fetchedApp] with [currentApp]'s,
/// so the update stays suppressed until the fetched release is old enough.
/// The APK URLs must move with the version, otherwise an update made during
/// the suppression window would silently download the fresh release; so must
/// the size, version codes, RegEx-assist snapshots and verification results,
/// which all describe that one release. Settings and identity still come from
/// the fetch.
App applyMinAgeSuppression(App currentApp, App fetchedApp) {
  final Map<String, dynamic> additionalSettings = Map<String, dynamic>.from(
    fetchedApp.additionalSettings,
  );
  for (final String key in _releaseScopedSettingKeys) {
    if (currentApp.additionalSettings.containsKey(key)) {
      additionalSettings[key] = currentApp.additionalSettings[key];
    } else {
      additionalSettings.remove(key);
    }
  }
  return fetchedApp.copyWith(
    latestVersion: currentApp.latestVersion,
    releaseDate: currentApp.releaseDate,
    changeLog: currentApp.changeLog,
    apkUrls: currentApp.apkUrls,
    otherAssetUrls: currentApp.otherAssetUrls,
    preferredApkIndex: currentApp.apkUrls.isEmpty
        ? 0
        : currentApp.preferredApkIndex.clamp(0, currentApp.apkUrls.length - 1),
    additionalSettings: additionalSettings,
    apkSizeBytes: currentApp.apkSizeBytes,
    rawLatestVersionFromSource: currentApp.rawLatestVersionFromSource,
    rawApkNamesFromSource: currentApp.rawApkNamesFromSource,
    rawReleaseTitlesFromSource: currentApp.rawReleaseTitlesFromSource,
    latestIsReproducible: currentApp.latestIsReproducible,
    latestReproducibleStatus: currentApp.latestReproducibleStatus,
    latestReproducibleVersionCode: currentApp.latestReproducibleVersionCode,
    latestAttestationStatus: currentApp.latestAttestationStatus,
    latestMalwareScanStatus: currentApp.latestMalwareScanStatus,
    latestMalwareScanDetail: currentApp.latestMalwareScanDetail,
    latestMalwareScanReportUrl: currentApp.latestMalwareScanReportUrl,
  );
}
