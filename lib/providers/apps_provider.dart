// Manages state related to the list of Apps tracked by Obtainium,
// Exposes related functions such as those used to add, remove, download, and install Apps.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:obtainium/app_sources/app_package_formats.dart';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:battery_plus/battery_plus.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';

import 'package:android_intent_plus/flag.dart';
import 'package:android_package_installer/android_package_installer.dart';
import 'package:android_package_manager/android_package_manager.dart'
    hide LaunchMode;
import 'package:background_fetch/background_fetch.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kDebugMode, listEquals;
import 'package:flutter/material.dart';
import 'package:http/io_client.dart';
import 'package:obtainium/app_sources/apkmirror.dart' show apkMirrorSizeDebug;
import 'package:obtainium/app_sources/direct_apk_link.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/app_sources/izzyondroid.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/theme/app_dialog_theme.dart';
import 'package:obtainium/providers/native_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_fgbg/flutter_fgbg.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/providers/virustotal_provider.dart';
import 'package:http/http.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:archive/archive.dart' as archive;
import 'package:obtainium/providers/installer_provider.dart' as installer;
import 'package:share_plus/share_plus.dart';
import 'package:shared_storage/shared_storage.dart' as saf;
import 'package:shizuku_apk_installer/shizuku_apk_installer.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:url_launcher/url_launcher_string.dart';

final pm = AndroidPackageManager();
// Full flags — includes signing certs needed for cert-hash display/verification.
final packageInfoFlags = PackageInfoFlags({PMFlag.getSigningCertificates});
// Light flags — omits signing certs; safe for foreground version-reconciliation
// because getCorrectedInstallStatusAppIfPossible only reads versionName/versionCode.
// Skipping getSigningCertificates makes getInstalledPackages ~10× faster and keeps
// the Android platform thread free to dispatch touch events during the foreground load.
final packageInfoFlagsLight = PackageInfoFlags({});

/// MANUAL TEST HOOK - flip to `true` to force every VirusTotal scan to
/// resolve as `flagged` (fake detail/report URL, no network call), so the
/// flagged dialog/skip/notification paths can be exercised without a real
/// API key or a real flagged APK. Gated on [kDebugMode] as a safety net in
/// case this is ever left on by mistake. Revert to `false` when done testing.
const bool debugForceFlaggedMalwareScan = false;

List<String> packageNamesToTryForInstalledInfo(
  String packageName, {
  bool includeOwnDebugBuild = false,
}) {
  final List<String> packageNamesToTry = <String>[packageName];
  if (kDebugMode && includeOwnDebugBuild && packageName == obtainiumId) {
    packageNamesToTry.insert(0, '$obtainiumId.debug');
  }
  return packageNamesToTry;
}

final RegExp _androidApplicationIdPattern = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
);

String formatBytesForDisplay(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  } else if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  } else if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  } else {
    return '$bytes B';
  }
}

bool reproducibleBuildVerificationApplies(AppSource source) {
  return source is FDroid || source is FDroidRepo || source is IzzyOnDroid;
}

bool reproducibleBuildEnforcementApplies(App app, AppSource source) {
  return app.additionalSettings['enforceReproducibleBuilds'] == true &&
      reproducibleBuildVerificationApplies(source);
}

String reproducibleBuildStatusForEnforcement(App app) {
  return app.latestReproducibleStatus ??
      reproducibleBuildStatusFromBool(app.latestIsReproducible);
}

bool reproducibleBuildEnforcementBlocksInstall(App app, AppSource source) {
  return reproducibleBuildEnforcementApplies(app, source) &&
      reproducibleBuildStatusForEnforcement(app) !=
          reproducibleBuildStatusVerified;
}

String reproducibleBuildEnforcedBlockedMessage() {
  return tr('reproducibleBuildEnforcedButBlocked');
}

bool githubAttestationEnforcementBlocksInstall(
  App app,
  AppSource source,
  SettingsProvider settingsProvider,
) {
  return source is GitHub &&
      source.shouldEnforceAttestations(
        app.additionalSettings,
        settingsProvider,
      ) &&
      app.latestAttestationStatus != githubAttestationStatusVerified;
}

String githubAttestationEnforcedBlockedMessage(String? attestationStatus) {
  return tr(
    attestationStatus == githubAttestationStatusUnsupported
        ? 'githubAttestationEnforcedButUnsupported'
        : 'githubAttestationEnforcedButFailed',
  );
}

bool buildVerificationEnforcementBlocksInstall(
  App app,
  AppSource source,
  SettingsProvider settingsProvider,
) {
  return reproducibleBuildEnforcementBlocksInstall(app, source) ||
      githubAttestationEnforcementBlocksInstall(app, source, settingsProvider);
}

String buildVerificationEnforcedBlockedMessage(
  App app,
  AppSource source,
  SettingsProvider settingsProvider,
) {
  if (reproducibleBuildEnforcementBlocksInstall(app, source)) {
    return reproducibleBuildEnforcedBlockedMessage();
  }
  return githubAttestationEnforcedBlockedMessage(app.latestAttestationStatus);
}

/// True if both versions are equal or one is a prefix of the other with a
/// non-digit next (e.g. 50.5.19 and 50.5.19-31 [0] [PR] 879778031), or both
/// contain the same commit-hash-like token (6+ hex chars), e.g. 1.5.3-DEV (75094D8) vs debug-75094d8.
/// Avoids false match of 1.0 in 10.0 by requiring boundary after the shorter.
bool versionsEffectivelyEqual(String installed, String latest) {
  if (installed == latest) return true;
  if (installed.isEmpty || latest.isEmpty) return false;
  final int? releaseDateVersionComparison = compareReleaseDateVersionStrings(
    installed,
    latest,
  );
  if (releaseDateVersionComparison == 0) {
    return true;
  }
  final installedLen = installed.length;
  final latestLen = latest.length;
  if (latest.startsWith(installed) &&
      (installedLen == latestLen ||
          (latestLen > installedLen &&
              !_isDigit(latest.codeUnitAt(installedLen))))) {
    return true;
  }
  if (installed.startsWith(latest) &&
      (installedLen == latestLen ||
          (installedLen > latestLen &&
              !_isDigit(installed.codeUnitAt(latestLen))))) {
    return true;
  }
  if (_oneVersionStringContainsOtherAsBoundedSubstring(installed, latest)) {
    return true;
  }
  // Same build when both contain the same commit-hash-like token (e.g. OS version "1.5.3-DEV (75094D8)" vs release "debug-75094d8").
  // Omit plausible YYYYMMDD date tokens so shared calendar segments (e.g. 20260205) are not treated as commit hashes.
  final installedHashes = _commitHashLikeTokensFromVersion(installed);
  final latestHashes = _commitHashLikeTokensFromVersion(latest);
  if (installedHashes.intersection(latestHashes).isNotEmpty) {
    return true;
  }
  return false;
}

String? reconciledInstalledVersionFromLatest(
  String installedVersion,
  String latestVersion,
) {
  if (installedVersion == latestVersion ||
      versionsEffectivelyEqual(installedVersion, latestVersion)) {
    return latestVersion;
  }
  final reconciled = reconcileVersionDifferences(
    installedVersion,
    latestVersion,
  );
  if (reconciled == null) {
    return null;
  }
  return reconciled.key ? reconciled.value : installedVersion;
}

String? reconciledInstalledVersionForDisabledVersionDetection(
  String realInstalledVersion,
  String reportedInstalledVersion,
  String latestVersion,
) {
  final reconciledLatest = reconcileVersionDifferences(
    realInstalledVersion,
    latestVersion,
  );
  if (reconciledLatest?.key == true) {
    return reconciledLatest!.value;
  }
  final reconciledInstalled = reconcileVersionDifferences(
    realInstalledVersion,
    reportedInstalledVersion,
  );
  if (reconciledInstalled?.key == true) {
    return reconciledInstalled!.value;
  }
  // Detect external upgrade/downgrade when both versions strictly share a standard format.
  // The guard prevents false positives where non-strict substring matching makes an
  // incompatible pair (e.g. "4.15.0" vs "26.06.01-de-vanced") appear reconcilable.
  final realFormats = findStandardFormatsForVersion(realInstalledVersion, true);
  if (realFormats.isNotEmpty) {
    if (reconciledLatest?.key == false &&
        realFormats
            .intersection(findStandardFormatsForVersion(latestVersion, true))
            .isNotEmpty) {
      return realInstalledVersion;
    }
    if (reconciledInstalled?.key == false &&
        realFormats
            .intersection(
              findStandardFormatsForVersion(reportedInstalledVersion, true),
            )
            .isNotEmpty) {
      return realInstalledVersion;
    }
  }
  return null;
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39; // '0'..'9'

DateTime? _dateFromReleaseDateVersionString(String version) {
  final String trimmedVersion = version.trim();
  if (trimmedVersion.isEmpty) {
    return null;
  }
  if (RegExp(r'^\d{15,17}$').hasMatch(trimmedVersion)) {
    try {
      return DateTime.fromMicrosecondsSinceEpoch(int.parse(trimmedVersion));
    } catch (_) {
      return null;
    }
  }
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}(?:[T ].*)?$').hasMatch(trimmedVersion)) {
    return null;
  }
  return DateTime.tryParse(trimmedVersion);
}

int? compareReleaseDateVersionStrings(String installed, String latest) {
  final DateTime? installedDate = _dateFromReleaseDateVersionString(installed);
  final DateTime? latestDate = _dateFromReleaseDateVersionString(latest);
  if (installedDate == null || latestDate == null) {
    return null;
  }
  return installedDate.toUtc().compareTo(latestDate.toUtc()).sign;
}

/// True when [needle] appears in [longer] as a contiguous substring with
/// boundaries so we do not treat [2.0] as inside [12.0] or [.0] as inside [8.0].
bool _boundedVersionSubstringInHaystack(
  String longer,
  String needle,
  int startIndex,
) {
  final int needleLen = needle.length;
  if (needleLen == 0 ||
      startIndex < 0 ||
      startIndex + needleLen > longer.length) {
    return false;
  }
  if (longer.substring(startIndex, startIndex + needleLen) != needle) {
    return false;
  }
  final int endIndex = startIndex + needleLen;
  final int firstUnit = needle.codeUnitAt(0);
  if (startIndex > 0) {
    final int prevUnit = longer.codeUnitAt(startIndex - 1);
    if (_isDigit(firstUnit) && _isDigit(prevUnit)) {
      return false;
    }
    if (firstUnit == 0x2E && _isDigit(prevUnit)) {
      // ".0" inside "8.0" must not match as a standalone version.
      return false;
    }
  }
  if (endIndex < longer.length) {
    final int lastUnit = needle.codeUnitAt(needleLen - 1);
    final int nextUnit = longer.codeUnitAt(endIndex);
    if (_isDigit(lastUnit) && _isDigit(nextUnit)) {
      return false;
    }
  }
  return true;
}

/// True when the shorter of [a]/[b] appears inside the longer as a bounded
/// substring (covers [1.6.5-rc0] in [v1.6.5-rc0], build ids embedded in carrier
/// strings, and titles like [1Password: ... 8.12.8-27.BETA]).
bool _oneVersionStringContainsOtherAsBoundedSubstring(String a, String b) {
  if (a.isEmpty || b.isEmpty || a == b) {
    return false;
  }
  final String shorter = a.length <= b.length ? a : b;
  final String longer = a.length <= b.length ? b : a;
  if (shorter.length == longer.length) {
    return false;
  }
  int searchFrom = 0;
  while (true) {
    final int foundAt = longer.indexOf(shorter, searchFrom);
    if (foundAt < 0) {
      return false;
    }
    if (_boundedVersionSubstringInHaystack(longer, shorter, foundAt)) {
      return true;
    }
    searchFrom = foundAt + 1;
  }
}

/// True for 8-digit all-decimal tokens that look like YYYYMMDD (excludes them
/// from commit-hash intersection so shared build dates do not imply same build).
bool isPlausibleVersionDateTokenYYYYMMDD(String token) {
  if (token.length != 8) return false;
  if (!RegExp(r'^\d{8}$').hasMatch(token)) return false;
  final year = int.tryParse(token.substring(0, 4));
  final month = int.tryParse(token.substring(4, 6));
  final day = int.tryParse(token.substring(6, 8));
  if (year == null || month == null || day == null) return false;
  if (year < 1990 || year > 2100) return false;
  if (month < 1 || month > 12) return false;
  if (day < 1 || day > 31) return false;
  return true;
}

final RegExp _digitsOnlySegmentPattern = RegExp(r'^\d+$');

Set<String> _commitHashLikeTokensFromVersion(String version) {
  final hexPattern = RegExp(r'[0-9a-fA-F]{6,}');
  final result = <String>{};
  for (final Match match in hexPattern.allMatches(version)) {
    final String token = match.group(0)!.toLowerCase();
    if (isPlausibleVersionDateTokenYYYYMMDD(token)) continue;
    // Decimal-only runs are Android versionCode / build numbers, not git hex.
    if (_digitsOnlySegmentPattern.hasMatch(token)) continue;
    result.add(token);
  }
  return result;
}

/// True when dot-separated segments match numerically through the shared prefix,
/// and the first differing part involves commit-hash-like material on at least
/// one side so [compareVersionsByNumericSegments] must not decide order (e.g.
/// [26.03.a4d75424] vs [26.03.0264c0ba]).
bool _dotSeparatedNumericPrefixThenIncomparableHashRemainder(
  String installed,
  String latest,
) {
  final installedParts = installed.split('.');
  final latestParts = latest.split('.');
  final int pairCount = installedParts.length <= latestParts.length
      ? installedParts.length
      : latestParts.length;
  for (int index = 0; index < pairCount; index++) {
    final String installedSegment = installedParts[index];
    final String latestSegment = latestParts[index];
    if (installedSegment == latestSegment) continue;
    final bool installedNumeric = _digitsOnlySegmentPattern.hasMatch(
      installedSegment,
    );
    final bool latestNumeric = _digitsOnlySegmentPattern.hasMatch(
      latestSegment,
    );
    if (installedNumeric && latestNumeric) {
      if (int.parse(installedSegment) != int.parse(latestSegment)) {
        return false;
      }
      continue;
    }
    if (installedNumeric != latestNumeric) {
      final bool hashInstalled = _commitHashLikeTokensFromVersion(
        installedSegment,
      ).isNotEmpty;
      final bool hashLatest = _commitHashLikeTokensFromVersion(
        latestSegment,
      ).isNotEmpty;
      if (hashInstalled || hashLatest) return true;
      return false;
    }
    final bool hashInstalled = _commitHashLikeTokensFromVersion(
      installedSegment,
    ).isNotEmpty;
    final bool hashLatest = _commitHashLikeTokensFromVersion(
      latestSegment,
    ).isNotEmpty;
    if (hashInstalled || hashLatest) return true;
    return false;
  }
  if (installedParts.length == latestParts.length) return false;
  final List<String> longerParts = installedParts.length > latestParts.length
      ? installedParts
      : latestParts;
  final int shorterLen = installedParts.length <= latestParts.length
      ? installedParts.length
      : latestParts.length;
  for (int index = shorterLen; index < longerParts.length; index++) {
    final String tailSegment = longerParts[index];
    if (tailSegment.isEmpty) continue;
    if (_digitsOnlySegmentPattern.hasMatch(tailSegment) &&
        int.parse(tailSegment) == 0) {
      continue;
    }
    if (_commitHashLikeTokensFromVersion(tailSegment).isNotEmpty) return true;
  }
  return false;
}

/// True when ordering is ambiguous: [compareVersionsByNumericSegments] ties on
/// digit groups, or dot segments disagree in a hash-like way that overrides
/// that compare. Not [versionsEffectivelyEqual].
bool versionOrderIsUnclear(String installed, String latest) {
  if (installed.isEmpty || latest.isEmpty) return false;
  if (installed == latest) return false;
  if (versionsEffectivelyEqual(installed, latest)) return false;
  if (compareReleaseDateVersionStrings(installed, latest) != null) {
    return false;
  }
  if (compareVersionsByNumericSegments(installed, latest) == 0) {
    return true;
  }
  return _dotSeparatedNumericPrefixThenIncomparableHashRemainder(
    installed,
    latest,
  );
}

/// User skipped the current [App.latestVersion]; nagging and update badges are suppressed.
bool isSkipActiveForCurrentLatest(App app) {
  final dynamic skipped = app.additionalSettings['skippedLatestVersion'];
  if (skipped is! String || skipped.isEmpty) return false;
  return skipped == app.latestVersion;
}

/// Remove [skippedLatestVersion] when it no longer matches [App.latestVersion].
void clearStaleSkippedLatestVersionInPlace(App app) {
  final dynamic skipped = app.additionalSettings['skippedLatestVersion'];
  if (skipped is! String || skipped.isEmpty) return;
  if (skipped != app.latestVersion) {
    app.additionalSettings.remove('skippedLatestVersion');
  }
}

/// Clears skip when the device is clearly at or ahead of source (no misleading skip flag).
/// Returns true if [app.additionalSettings] was changed.
bool clearRedundantSkippedLatestForApp(App app) {
  if (!isSkipActiveForCurrentLatest(app)) return false;
  final String? installed = app.installedVersion;
  final String latest = app.latestVersion;
  if (installed == null || installed.isEmpty) return false;
  if (installed == latest || versionsEffectivelyEqual(installed, latest)) {
    app.additionalSettings.remove('skippedLatestVersion');
    return true;
  }
  if (compareVersionsByNumericSegments(installed, latest) == 1) {
    app.additionalSettings.remove('skippedLatestVersion');
    return true;
  }
  return false;
}

/// Installed app should show update affordances and count in update lists (unless skipped).
bool appHasActionableUpdate(App app) {
  final String? installed = app.installedVersion;
  final String latest = app.latestVersion;
  if (installed == null || latest.isEmpty) return false;
  if (isSkipActiveForCurrentLatest(app)) return false;
  if (installed == latest) return false;
  if (versionsEffectivelyEqual(installed, latest)) return false;

  if (versionOrderIsUnclear(installed, latest)) {
    final dynamic lastInstalledTimeRaw =
        app.additionalSettings['lastInstalledTime'];
    if (lastInstalledTimeRaw is int && app.releaseDate != null) {
      final DateTime installedTime = DateTime.fromMillisecondsSinceEpoch(
        lastInstalledTimeRaw,
      );
      return app.releaseDate!.isAfter(installedTime);
    }
    // Pseudo-mode apps can't reliably compare versions; any difference is a potential
    // update regardless of ordering ambiguity.
    return app.additionalSettings['versionDetection'] == 'pseudo' ||
        app.additionalSettings['versionDetection'] == false;
  }

  final int? cmp = compareVersionsByNumericSegments(installed, latest);
  if (cmp == 1) return false;
  if (cmp == 0) return true;
  return true;
}

/// Installed app where installed vs latest differs but ordering is ambiguous (user must decide).
/// Mutually exclusive with [appHasActionableUpdate] for normal version strings.
bool versionOrderUncertainUpdate(App app) {
  final String? installed = app.installedVersion;
  final String latest = app.latestVersion;
  if (installed == null || latest.isEmpty) return false;
  if (isSkipActiveForCurrentLatest(app)) return false;
  if (installed == latest) return false;
  if (versionsEffectivelyEqual(installed, latest)) return false;

  if (versionOrderIsUnclear(installed, latest)) {
    final dynamic lastInstalledTimeRaw =
        app.additionalSettings['lastInstalledTime'];
    if (lastInstalledTimeRaw is int && app.releaseDate != null) {
      final DateTime installedTime = DateTime.fromMillisecondsSinceEpoch(
        lastInstalledTimeRaw,
      );
      // Suppress uncertain indicator only when timestamps confirm the release IS newer
      // than the last install (appHasActionableUpdate already covers that case).
      // When release is not after install, the order is still ambiguous — the user
      // should be able to decide.
      return !app.releaseDate!.isAfter(installedTime);
    }
    return true;
  }
  return false;
}

/// Compare version strings by numeric segments (e.g. 2.0.0 vs 1.9.9).
/// Returns -1 if [installed] < [latest], 0 if equal, 1 if [installed] > [latest], null if not comparable.
int? compareVersionsByNumericSegments(String installed, String latest) {
  final int? releaseDateVersionComparison = compareReleaseDateVersionStrings(
    installed,
    latest,
  );
  if (releaseDateVersionComparison != null) {
    return releaseDateVersionComparison;
  }
  final installedSegments = RegExp(
    r'\d+',
  ).allMatches(installed).map((m) => int.tryParse(m.group(0)!) ?? 0).toList();
  final latestSegments = RegExp(
    r'\d+',
  ).allMatches(latest).map((m) => int.tryParse(m.group(0)!) ?? 0).toList();
  if (installedSegments.isEmpty || latestSegments.isEmpty) return null;
  final maxLen = installedSegments.length > latestSegments.length
      ? installedSegments.length
      : latestSegments.length;
  for (int i = 0; i < maxLen; i++) {
    final inst = i < installedSegments.length ? installedSegments[i] : 0;
    final lat = i < latestSegments.length ? latestSegments[i] : 0;
    if (inst < lat) return -1;
    if (inst > lat) return 1;
  }
  return 0;
}

/// True if we should not show "update available" because installed is newer than or equal to latest by version math.
bool installedVersionIsNewerOrEqual(String? installed, String latest) {
  if (installed == null || installed.isEmpty || latest.isEmpty) return false;
  if (installed == latest || versionsEffectivelyEqual(installed, latest)) {
    return true;
  }
  final cmp = compareVersionsByNumericSegments(installed, latest);
  return cmp == null ? false : cmp >= 0;
}

/// Track-only open URL: RSS release page when [App.changeLog] is http(s), else [App.url].
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

class AppInMemory {
  late App app;
  double? downloadProgress;

  /// Total download size in bytes, available once the HTTP Content-Length header
  /// is received (may remain null if the server doesn't report it).
  int? downloadTotalBytes;
  PackageInfo? installedInfo;
  Uint8List? icon;

  AppInMemory(this.app, this.downloadProgress, this.installedInfo, this.icon);
  AppInMemory deepCopy() =>
      AppInMemory(app.deepCopy(), downloadProgress, installedInfo, icon);

  String get name => app.overrideName ?? app.finalName;
  String get author => app.overrideAuthor ?? app.finalAuthor;

  bool get hasMultipleSigners {
    return installedInfo?.signingInfo?.hasMultipleSigners ?? false;
  }

  List<String> get certificateHashes {
    // https://developer.android.com/reference/android/content/pm/SigningInfo#getApkContentsSigners()
    final signatures = hasMultipleSigners
        ? installedInfo?.signingInfo?.apkContentSigners
        : installedInfo?.signingInfo?.signingCertificateHistory;

    return signatures?.map((signature) {
          final digest = sha256.convert(signature);
          return digest.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
              .join(':');
        }).toList() ??
        [];
  }
}

class DownloadedApk {
  String appId;
  File file;
  DownloadedApk(this.appId, this.file);
}

enum DownloadedDirType { xApk, zip }

class DownloadedDir {
  String appId;
  File file;
  Directory extracted;
  DownloadedDirType type;
  DownloadedDir(this.appId, this.file, this.extracted, this.type);
}

List<String> generateStandardVersionRegExStrings() {
  var basics = [
    '[0-9]+',
    '[0-9]+\\.[0-9]+',
    '[0-9]+\\.[0-9]+\\.[0-9]+',
    '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+',
  ];
  var preSuffixes = ['-', '\\+'];
  var suffixes = ['alpha', 'beta', 'ose', '[0-9]+'];
  var finals = ['\\+[0-9]+', '[0-9]+'];
  List<String> results = [];
  for (var b in basics) {
    results.add(b);
    for (var p in preSuffixes) {
      for (var s in suffixes) {
        results.add('$b$s');
        results.add('$b$p$s');
        for (var f in finals) {
          results.add('$b$s$f');
          results.add('$b$p$s$f');
        }
      }
    }
  }
  return results;
}

List<String> standardVersionRegExStrings =
    generateStandardVersionRegExStrings();

Set<String> findStandardFormatsForVersion(String version, bool strict) {
  // If !strict, even a substring match is valid
  Set<String> results = {};
  for (var pattern in standardVersionRegExStrings) {
    if (RegExp(
      '${strict ? '^' : ''}$pattern${strict ? '\$' : ''}',
    ).hasMatch(version)) {
      results.add(pattern);
    }
  }
  return results;
}

MapEntry<bool, String>? reconcileVersionDifferences(
  String templateVersion,
  String comparisonVersion,
) {
  // Returns null if the versions don't share a common standard format
  // Returns <true, comparisonVersion> if they share a common format and are equal
  // Returns <false, templateVersion> if they share a common format but are not equal
  // templateVersion must fully match a standard format, while comparisonVersion can have a substring match
  var templateVersionFormats = findStandardFormatsForVersion(
    templateVersion,
    true,
  );
  var comparisonVersionFormats = findStandardFormatsForVersion(
    comparisonVersion,
    true,
  );
  if (comparisonVersionFormats.isEmpty) {
    comparisonVersionFormats = findStandardFormatsForVersion(
      comparisonVersion,
      false,
    );
  }
  var commonStandardFormats = templateVersionFormats.intersection(
    comparisonVersionFormats,
  );
  if (commonStandardFormats.isEmpty) {
    return reconcileVersionDifferencesByShape(
      templateVersion,
      comparisonVersion,
    );
  }
  for (String pattern in commonStandardFormats) {
    if (doStringsMatchUnderRegEx(pattern, comparisonVersion, templateVersion)) {
      return MapEntry(true, comparisonVersion);
    }
  }
  return MapEntry(false, templateVersion);
}

MapEntry<bool, String>? reconcileVersionDifferencesByShape(
  String templateVersion,
  String comparisonVersion,
) {
  final String templateShape = versionShapeForReconciliation(templateVersion);
  final String comparisonShape = versionShapeForReconciliation(
    comparisonVersion,
  );
  if (templateShape.isEmpty || templateShape != comparisonShape) {
    return null;
  }
  final templateTokens = numericVersionTokens(templateVersion);
  final comparisonTokens = numericVersionTokens(comparisonVersion);
  if (templateTokens.isEmpty ||
      templateTokens.length != comparisonTokens.length) {
    return null;
  }
  if (listEquals(templateTokens, comparisonTokens)) {
    return MapEntry(true, comparisonVersion);
  }
  return MapEntry(false, templateVersion);
}

String versionShapeForReconciliation(String version) {
  return version.trim().toLowerCase().replaceAll(RegExp(r'\d+'), '#');
}

List<int> numericVersionTokens(String version) {
  return RegExp(
    r'\d+',
  ).allMatches(version).map((m) => int.tryParse(m.group(0)!) ?? 0).toList();
}

bool doStringsMatchUnderRegEx(String pattern, String value1, String value2) {
  var r = RegExp(pattern);
  var m1 = r.firstMatch(value1);
  var m2 = r.firstMatch(value2);
  return m1 != null && m2 != null
      ? value1.substring(m1.start, m1.end) == value2.substring(m2.start, m2.end)
      : false;
}

List<String> moveStrToEnd(List<String> arr, String str, {String? strB}) {
  String? temp;
  arr.removeWhere((element) {
    bool res = element == str || element == strB;
    if (res) {
      temp = element;
    }
    return res;
  });
  if (temp != null) {
    arr = [...arr, temp!];
  }
  return arr;
}

bool isObtainiumAppId(String appId) {
  return appId == obtainiumId || appId == obtainiumTempId;
}

List<MapEntry<String, int>> moveStrToEndMapEntryWithCount(
  List<MapEntry<String, int>> arr,
  MapEntry<String, int> str, {
  MapEntry<String, int>? strB,
}) {
  MapEntry<String, int>? temp;
  arr.removeWhere((element) {
    bool resA = element.key == str.key;
    bool resB = element.key == strB?.key;
    if (resA) {
      temp = str;
    } else if (resB) {
      temp = strB;
    }
    return resA || resB;
  });
  if (temp != null) {
    arr = [...arr, temp!];
  }
  return arr;
}

class DownloadCancelToken {
  bool _isCancelled = false;
  final Set<HttpClient> _activeClients = <HttpClient>{};

  bool get isCancelled {
    return _isCancelled;
  }

  void attachClient(HttpClient client) {
    if (_isCancelled) {
      client.close(force: true);
      return;
    }
    _activeClients.add(client);
  }

  void detachClient(HttpClient client) {
    _activeClients.remove(client);
  }

  void cancel() {
    _isCancelled = true;
    final activeClientsSnapshot = _activeClients.toList();
    _activeClients.clear();
    for (final client in activeClientsSnapshot) {
      client.close(force: true);
    }
  }

  void throwIfCancelled() {
    if (!_isCancelled) {
      return;
    }
    throw DownloadCancelledError();
  }
}

Future<File> downloadFileWithRetry(
  String url,
  String fileName,
  bool fileNameHasExt,
  Function? onProgress,
  String destDir, {
  void Function(int?)? onContentLength,
  bool useExisting = true,
  Map<String, String>? headers,
  int retries = 3,
  bool allowInsecure = false,
  LogsProvider? logs,
  DownloadCancelToken? cancelToken,
}) async {
  try {
    return await downloadFile(
      url,
      fileName,
      fileNameHasExt,
      onProgress,
      destDir,
      onContentLength: onContentLength,
      useExisting: useExisting,
      headers: headers,
      allowInsecure: allowInsecure,
      logs: logs,
      cancelToken: cancelToken,
    );
  } catch (e) {
    if (cancelToken?.isCancelled == true) {
      throw DownloadCancelledError();
    }
    if (retries > 0 && e is ClientException) {
      await Future.delayed(const Duration(seconds: 5));
      return await downloadFileWithRetry(
        url,
        fileName,
        fileNameHasExt,
        onProgress,
        destDir,
        onContentLength: onContentLength,
        useExisting: useExisting,
        headers: headers,
        retries: (retries - 1),
        allowInsecure: allowInsecure,
        logs: logs,
        cancelToken: cancelToken,
      );
    } else {
      rethrow;
    }
  }
}

String hashListOfLists(List<List<int>> data) {
  var bytes = utf8.encode(jsonEncode(data));
  var digest = sha256.convert(bytes);
  var hash = digest.toString();
  return hash.hashCode.toString();
}

Future<String> checkPartialDownloadHashDynamic(
  String url, {
  int startingSize = 1024,
  int lowerLimit = 128,
  Map<String, String>? headers,
  bool allowInsecure = false,
}) async {
  for (int i = startingSize; i >= lowerLimit; i -= 256) {
    List<String> ab = await Future.wait([
      checkPartialDownloadHash(
        url,
        i,
        headers: headers,
        allowInsecure: allowInsecure,
      ),
      checkPartialDownloadHash(
        url,
        i,
        headers: headers,
        allowInsecure: allowInsecure,
      ),
    ]);
    if (ab[0] == ab[1]) {
      return ab[0];
    }
  }
  throw NoVersionError();
}

Future<String> checkPartialDownloadHash(
  String url,
  int bytesToGrab, {
  Map<String, String>? headers,
  bool allowInsecure = false,
}) async {
  var req = Request('GET', Uri.parse(url));
  if (headers != null) {
    req.headers.addAll(headers);
  }
  req.headers[HttpHeaders.rangeHeader] = 'bytes=0-$bytesToGrab';
  var client = IOClient(createHttpClient(allowInsecure));
  try {
    var response = await client.send(req);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw ObtainiumError(response.reasonPhrase ?? tr('unexpectedError'));
    }
    final bytesBuilder = BytesBuilder(copy: false);
    var remainingBytes = bytesToGrab + 1;
    await for (final chunk in response.stream) {
      if (remainingBytes <= 0) {
        break;
      }
      if (chunk.length <= remainingBytes) {
        bytesBuilder.add(chunk);
        remainingBytes -= chunk.length;
      } else {
        bytesBuilder.add(chunk.sublist(0, remainingBytes));
        remainingBytes = 0;
      }
    }
    return hashListOfLists([bytesBuilder.takeBytes()]);
  } finally {
    client.close();
  }
}

Future<String?> checkETagHeader(
  String url, {
  Map<String, String>? headers,
  bool allowInsecure = false,
}) async {
  // Send the initial request but cancel it as soon as you have the headers
  var reqHeaders = headers ?? {};
  var req = Request('GET', Uri.parse(url));
  req.headers.addAll(reqHeaders);
  var client = IOClient(createHttpClient(allowInsecure));
  StreamedResponse response = await client.send(req);
  var resHeaders = response.headers;
  client.close();
  return resHeaders[HttpHeaders.etagHeader]
      ?.replaceAll('"', '')
      .hashCode
      .toString();
}

void deleteFile(File file) {
  try {
    file.deleteSync(recursive: true);
  } on PathAccessException catch (e) {
    throw ObtainiumError(
      tr('fileDeletionError', args: [e.path ?? tr('unknown')]),
    );
  }
}

String sanitizeApkSaveDisplayName(String raw) {
  var name = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  if (name.isEmpty) {
    return 'download.apk';
  }
  return name;
}

/// Same label as release assets (e.g. GitHub attachment filename) when possible.
String storeFacingDownloadDisplayNameForApp(App app) {
  if (app.apkUrls.isEmpty) {
    return 'download.apk';
  }
  final int preferredIdx =
      app.preferredApkIndex >= 0 && app.preferredApkIndex < app.apkUrls.length
      ? app.preferredApkIndex
      : 0;
  String key = app.apkUrls[preferredIdx].key.trim();
  if (key.isEmpty) {
    try {
      final Uri uri = Uri.parse(app.apkUrls[preferredIdx].value);
      if (uri.pathSegments.isNotEmpty) {
        key = uri.pathSegments.last;
      }
    } catch (_) {
      key = 'download.apk';
    }
  }
  if (key.isEmpty) {
    key = 'download.apk';
  }
  return sanitizeApkSaveDisplayName(key);
}

String _downloadProgressNotificationMessage(
  int progressPercent,
  int? totalBytes,
) {
  final progressMessage = tr(
    'percentProgress',
    args: [progressPercent.toString()],
  );
  if (totalBytes == null) {
    return progressMessage;
  }
  final downloadedBytes = (progressPercent.clamp(0, 100) / 100 * totalBytes)
      .round();
  return '$progressMessage - ${formatBytesForDisplay(downloadedBytes)} / ${formatBytesForDisplay(totalBytes)}';
}

Future<File> downloadFile(
  String url,
  String fileName,
  bool fileNameHasExt,
  Function? onProgress,
  String destDir, {
  void Function(int?)? onContentLength,
  bool useExisting = true,
  Map<String, String>? headers,
  bool allowInsecure = false,
  LogsProvider? logs,
  DownloadCancelToken? cancelToken,
}) async {
  final bool releaseDownloadKeepAwake =
      await NativeFeatures.acquireDownloadKeepAwake();
  try {
    return await _downloadFile(
      url,
      fileName,
      fileNameHasExt,
      onProgress,
      destDir,
      onContentLength: onContentLength,
      useExisting: useExisting,
      headers: headers,
      allowInsecure: allowInsecure,
      logs: logs,
      cancelToken: cancelToken,
    );
  } finally {
    if (releaseDownloadKeepAwake) {
      await NativeFeatures.releaseDownloadKeepAwake();
    }
  }
}

Future<File> _downloadFile(
  String url,
  String fileName,
  bool fileNameHasExt,
  Function? onProgress,
  String destDir, {
  void Function(int?)? onContentLength,
  bool useExisting = true,
  Map<String, String>? headers,
  bool allowInsecure = false,
  LogsProvider? logs,
  DownloadCancelToken? cancelToken,
}) async {
  // Send the initial request but cancel it as soon as you have the headers
  cancelToken?.throwIfCancelled();
  var reqHeaders = headers ?? {};
  var req = Request('GET', Uri.parse(url));
  req.headers.addAll(reqHeaders);
  final headersHttpClient = createHttpClient(allowInsecure);
  cancelToken?.attachClient(headersHttpClient);
  var headersClient = IOClient(headersHttpClient);
  StreamedResponse headersResponse = await headersClient.send(req);
  cancelToken?.detachClient(headersHttpClient);
  cancelToken?.throwIfCancelled();
  var resHeaders = headersResponse.headers;

  // Use the headers to decide what the file extension is, and
  // whether it supports partial downloads (range request), and
  // what the total size of the file is (if provided)
  String ext = resHeaders['content-disposition']?.split('.').last ?? 'apk';
  if (ext.endsWith('"') || ext.endsWith("other")) {
    ext = ext.substring(0, ext.length - 1);
  }
  if ((isApk(Uri.tryParse(url)?.path ?? url) || ext == 'attachment') &&
      ext != kApkExt) {
    ext = kApkExt;
  }
  fileName = fileNameHasExt
      ? fileName
      : fileName.split('/').last; // Ensure the fileName is a file name
  File downloadedFile = File('$destDir/$fileName.$ext');
  if (fileNameHasExt) {
    // If the user says the filename already has an ext, ignore whatever you inferred from above
    downloadedFile = File('$destDir/$fileName');
  }

  bool rangeFeatureEnabled = false;
  if (resHeaders['accept-ranges']?.isNotEmpty == true) {
    rangeFeatureEnabled =
        resHeaders['accept-ranges']?.trim().toLowerCase() == 'bytes';
  }
  headersClient.close();

  // If you have an existing file that is usable,
  // decide whether you can use it (either return full or resume partial)
  var fullContentLength = headersResponse.contentLength;
  onContentLength?.call(fullContentLength);
  if (useExisting && downloadedFile.existsSync()) {
    var length = downloadedFile.lengthSync();
    if (fullContentLength == null || !rangeFeatureEnabled) {
      // If there is no content length reported, assume it the existing file is fully downloaded
      // Also if the range feature is not supported, don't trust the content length if any (#1542)
      return downloadedFile;
    } else {
      // Check if resume needed/possible
      if (length == fullContentLength) {
        return downloadedFile;
      }
      if (length > fullContentLength) {
        useExisting = false;
      }
    }
  }

  // Download to a '.temp' file (to distinguish btn. complete/incomplete files)
  File tempDownloadedFile = File('${downloadedFile.path}.part');

  // If there is already a temp file, a download may already be in progress - account for this (see #2073)
  bool tempFileExists = tempDownloadedFile.existsSync();
  if (tempFileExists && useExisting) {
    logs?.add(
      'Partial download exists - will wait: ${tempDownloadedFile.uri.pathSegments.last}',
    );
    bool isDownloading = true;
    int currentTempFileSize = await tempDownloadedFile.length();
    bool shouldReturn = false;
    while (isDownloading) {
      cancelToken?.throwIfCancelled();
      await Future.delayed(const Duration(seconds: 7));
      cancelToken?.throwIfCancelled();
      if (tempDownloadedFile.existsSync()) {
        int newTempFileSize = await tempDownloadedFile.length();
        if (newTempFileSize > currentTempFileSize) {
          currentTempFileSize = newTempFileSize;
          logs?.add(
            'Existing partial download still in progress: ${tempDownloadedFile.uri.pathSegments.last}',
          );
        } else {
          logs?.add(
            'Ignoring existing partial download: ${tempDownloadedFile.uri.pathSegments.last}',
          );
          break;
        }
      } else {
        shouldReturn = downloadedFile.existsSync();
      }
    }
    if (shouldReturn) {
      logs?.add(
        'Existing partial download completed - not repeating: ${tempDownloadedFile.uri.pathSegments.last}',
      );
      return downloadedFile;
    } else {
      logs?.add(
        'Existing partial download not in progress: ${tempDownloadedFile.uri.pathSegments.last}',
      );
    }
  }

  // If the range feature is not available (or you need to start a ranged req from 0),
  // complete the already-started request, else cancel it and start a ranged request,
  // and open the file for writing in the appropriate mode
  var targetFileLength = useExisting && tempDownloadedFile.existsSync()
      ? tempDownloadedFile.lengthSync()
      : null;
  int rangeStart = targetFileLength ?? 0;
  IOSink? sink;
  req = Request('GET', Uri.parse(url));
  req.headers.addAll(reqHeaders);
  if (rangeFeatureEnabled && fullContentLength != null && rangeStart > 0) {
    reqHeaders.addAll({'range': 'bytes=$rangeStart-${fullContentLength - 1}'});
    sink = tempDownloadedFile.openWrite(mode: FileMode.writeOnlyAppend);
  } else if (tempDownloadedFile.existsSync()) {
    deleteFile(tempDownloadedFile);
  }
  var responseWithClient = await sourceRequestStreamResponse(
    'GET',
    url,
    reqHeaders,
    {},
  );
  HttpClient responseClient = responseWithClient.value.key;
  HttpClientResponse response = responseWithClient.value.value;
  cancelToken?.attachClient(responseClient);
  cancelToken?.throwIfCancelled();
  sink ??= tempDownloadedFile.openWrite(mode: FileMode.writeOnly);

  // Perform the download
  var received = 0;
  double? progress;
  DateTime? lastProgressUpdate; // Track last progress update time
  if (rangeStart > 0 && fullContentLength != null) {
    received = rangeStart;
  }
  const downloadUIUpdateInterval = Duration(milliseconds: 500);
  const downloadBufferSize = 32 * 1024; // 32KB
  final downloadBuffer = BytesBuilder();
  try {
    await response
        .asBroadcastStream()
        .map((chunk) {
          cancelToken?.throwIfCancelled();
          received += chunk.length;
          final now = DateTime.now();
          if (onProgress != null &&
              (lastProgressUpdate == null ||
                  now.difference(lastProgressUpdate!) >=
                      downloadUIUpdateInterval)) {
            progress = fullContentLength != null
                ? clampDouble((received / fullContentLength) * 100, 0, 100)
                : 30;
            onProgress(progress);
            lastProgressUpdate = now;
          }
          return chunk;
        })
        .transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (List<int> data, EventSink<List<int>> eventSink) {
              downloadBuffer.add(data);
              if (downloadBuffer.length >= downloadBufferSize) {
                eventSink.add(downloadBuffer.takeBytes());
              }
            },
            handleDone: (EventSink<List<int>> eventSink) {
              if (downloadBuffer.isNotEmpty) {
                eventSink.add(downloadBuffer.takeBytes());
              }
              eventSink.close();
            },
          ),
        )
        .pipe(sink);
  } catch (_) {
    responseClient.close(force: true);
    if (cancelToken?.isCancelled == true) {
      if (tempDownloadedFile.existsSync()) {
        deleteFile(tempDownloadedFile);
      }
      throw DownloadCancelledError();
    }
    rethrow;
  } finally {
    cancelToken?.detachClient(responseClient);
  }
  await sink.close();
  progress = null;
  if (onProgress != null) {
    onProgress(progress);
  }
  if (response.statusCode < 200 || response.statusCode > 299) {
    deleteFile(tempDownloadedFile);
    throw response.reasonPhrase;
  }
  if (tempDownloadedFile.existsSync()) {
    tempDownloadedFile.renameSync(downloadedFile.path);
  }
  responseClient.close();
  return downloadedFile;
}

Future<List<PackageInfo>> getAllInstalledInfo({bool light = false}) async {
  return await pm.getInstalledPackages(
        flags: light ? packageInfoFlagsLight : packageInfoFlags,
      ) ??
      [];
}

Future<PackageInfo?> getInstalledInfo(
  String? packageName, {
  bool printErr = true,
  bool light = true,
  bool includeOwnDebugBuild = false,
}) async {
  if (packageName != null) {
    final List<String> packageNamesToTry = packageNamesToTryForInstalledInfo(
      packageName,
      includeOwnDebugBuild: includeOwnDebugBuild,
    );

    Set<String>? installedPackageNames;
    try {
      final List<PackageInfo> installed =
          await pm.getInstalledPackages(flags: packageInfoFlagsLight) ?? [];
      installedPackageNames = installed
          .map((p) => p.packageName)
          .whereType<String>()
          .toSet();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to list installed packages: $e');
      }
    }

    for (final String packageNameToTry in packageNamesToTry) {
      if (installedPackageNames != null &&
          !installedPackageNames.contains(packageNameToTry)) {
        continue;
      }
      try {
        return await pm.getPackageInfo(
          packageName: packageNameToTry,
          flags: light ? packageInfoFlagsLight : packageInfoFlags,
        );
      } catch (e) {
        if (printErr && packageNameToTry == packageNamesToTry.last) {
          debugPrint(e.toString()); // OK
        }
      }
    }
  }
  return null;
}

Future<Directory> getAppStorageDir() async {
  try {
    final Directory? externalDir = await getExternalStorageDirectory();
    if (externalDir != null) {
      await externalDir.create(recursive: true);
      return externalDir;
    }
  } catch (_) {}
  return await getApplicationDocumentsDirectory();
}

/// Outcome of [AppsProvider.removeAppsWithModal].
class RemoveAppsWithModalResult {
  const RemoveAppsWithModalResult._({
    required this.confirmed,
    this.deferredUndoAppIds = const <String>{},
    this.removedFromObtainiumImmediately = false,
    this.obtainiumEntryRemovedOrScheduled = false,
  });

  /// User dismissed the dialog with Cancel, or left both toggles off.
  static const RemoveAppsWithModalResult cancelled =
      RemoveAppsWithModalResult._(confirmed: false);

  final bool confirmed;

  /// When non-empty, those apps were removed from the UI and Obtainium data is
  /// deleted after 5 seconds unless [AppsProvider.undoDeferredObtainiumRemovals] runs.
  final Set<String> deferredUndoAppIds;

  /// True when [removeApps] ran in the same step (remove from Obtainium + uninstall).
  final bool removedFromObtainiumImmediately;

  /// True when the app should disappear from the list (deferred or immediate).
  final bool obtainiumEntryRemovedOrScheduled;

  bool get shouldShowSnackBar =>
      deferredUndoAppIds.isNotEmpty || removedFromObtainiumImmediately;
}

class AppsProvider with ChangeNotifier {
  // Start fast on capable devices, but keep a bounded worker pool so a large
  // app list does not fan out unbounded HTTP + parse work like upstream
  // Obtainium. [_maxParallelUpdateChecksForDevice] lowers this on low-end
  // devices using Android's low-RAM flag and total physical RAM.
  static const int _defaultParallelUpdateChecks = 8;
  static const int _modestDeviceParallelUpdateChecks = 4;
  static const int _lowEndDeviceParallelUpdateChecks = 2;
  static const int _lowEndRamThresholdMb = 3072;
  static const int _modestRamThresholdMb = 6144;

  // In memory App state (should always be kept in sync with local storage versions)
  Map<String, AppInMemory> apps = {};
  final Map<String, ({String? title, String message})> appPageErrors = {};
  bool loadingApps = false;
  Completer<void>? _loadingCompleter;
  bool gettingUpdates = false;
  LogsProvider logs = LogsProvider();

  // Cached result of findExistingUpdates() for the home-tab badge.
  // Recomputed lazily: only when _pendingUpdateCountDirty is true, which is
  // set at the data-change sites (loadApps, saveApps, removeApps, install
  // events). Download-progress ticks and icon updates leave the flag false so
  // the O(n) scan does not run 4×/sec during downloads.
  int _cachedPendingUpdateCount = 0;
  bool _pendingUpdateCountDirty = true;

  int get pendingUpdateCount {
    if (_pendingUpdateCountDirty) {
      _cachedPendingUpdateCount = findExistingUpdates(
        installedOnly: true,
        excludeOnDemandOnly: true,
        includeVersionOrderUncertain: true,
      ).length;
      _pendingUpdateCountDirty = false;
    }
    return _cachedPendingUpdateCount;
  }

  final Set<String> _detailPageAutoChecksInFlight = <String>{};
  final Map<String, DateTime> _lastDetailPageAutoCheckStartedAt =
      <String, DateTime>{};

  // Debounce timer for download-progress notifications so widgets that watch
  // the whole provider (e.g. AppPage) don't get hammered on every byte chunk.
  Timer? _progressNotifyTimer;
  final Map<String, DownloadCancelToken> _downloadCancelTokens = {};

  // ── Auto-export debounce ──────────────────────────────────────────────────
  // [export] is called with `isAuto: true` after every saveApps and at the end
  // of every checkUpdates run. Each invocation does an SAF listFiles + delete
  // + JsonEncoder.withIndent + utf8.encode + SAF createFile - non-trivial
  // wall-clock work, much of it on the UI isolate. Coalesce a burst of calls
  // (e.g. the 50 saveApps that fire as a refresh completes) into a single
  // trailing-edge run via this timer so the user only pays the cost once.
  Timer? _autoExportTimer;
  static const Duration _autoExportDebounce = Duration(seconds: 2);

  /// Remove-from-Obtainium was confirmed without uninstall: JSON is stashed, UI updates,
  /// and disk is purged after 5s unless the user undoes.
  final Map<String, Timer> _deferredObtainiumTimers = {};
  final Map<String, AppInMemory> _deferredObtainiumSnapshots = {};

  // Variables to keep track of the app foreground status (installs can't run in the background)
  bool isForeground = true;
  late Stream<FGBGType>? foregroundStream;
  late StreamSubscription<FGBGType>? foregroundSubscription;

  // Throttle foreground-triggered loadApps: getInstalledPackages enumerates
  // every package with signing certs, which is the most expensive single call
  // in the app. Skip a foreground reload if one completed recently.
  static const Duration _foregroundLoadCooldown = Duration(seconds: 5);
  DateTime? _lastForegroundLoadAt;

  // Watermark for [loadApps]' incremental JSON parse. A full load (singleId ==
  // null) stamps this with the time the load started. On a subsequent full
  // load, any app JSON whose file mtime predates the watermark is reused from
  // memory instead of being re-read + re-decoded — so a foreground resume with
  // a large library doesn't re-run hundreds of synchronous jsonDecode /
  // App.fromJson calls on the UI isolate. Files written since the watermark
  // (e.g. by the background update task) advance their mtime and are re-parsed.
  DateTime? _lastFullDiskLoadAt;
  late Directory apkDir;
  late Directory iconsCacheDir;

  /// User-chosen PNG overrides; under app storage, not [iconsCacheDir], so they
  /// survive Android "clear cache".
  late Directory userAppIconsDir;
  late SettingsProvider settingsProvider;
  bool _receivesThirdPartyInstallEvents = false;

  Iterable<AppInMemory> getAppValues() => apps.values.map((a) => a.deepCopy());

  Future<String?> verifyGitHubAttestation(App app, File file) async {
    final AppSource source = SourceProvider().getSource(
      app.url,
      overrideSource: app.overrideSource,
    );
    if (source is! GitHub) {
      return null;
    }
    try {
      final String standardizedUrl = source.standardizeUrl(app.url);
      final hash = await sha256.bind(file.openRead()).first;
      final String sha256Digest = hash.toString();
      return await source.getAttestationStatusForSha256Digest(
        standardizedUrl,
        sha256Digest,
        app.additionalSettings,
      );
    } catch (e) {
      logs.add('Error verifying GitHub attestation: ${e.toString()}');
    }
    return githubAttestationStatusError;
  }

  /// Whether a VirusTotal scan will actually run for the next install -
  /// toggle on and a validated API key present. Shared with [downloadApp] so
  /// its post-download progress sentinel can say "Scanning" instead of
  /// flashing "Installing" first when a scan is about to happen.
  bool willScanApkWithVirusTotal() {
    if (kDebugMode && debugForceFlaggedMalwareScan) {
      return true;
    }
    if (!settingsProvider.enableVirusTotalScanning) {
      return false;
    }
    final String? apiKey = settingsProvider.getSettingString(
      virusTotalApiKeyKey,
    );
    return apiKey != null &&
        apiKey.isNotEmpty &&
        hasValidatedApiKey(apiKey, settingsProvider);
  }

  /// Scans a downloaded APK with VirusTotal, if scanning is enabled and an
  /// API key is configured. Returns null (no scan attempted, no state
  /// change) when the feature is off or unconfigured - callers must treat
  /// that as "no-op", distinct from a real [malwareScanStatusError] result.
  /// Sets [app.latestMalwareScanDetail]/[app.latestMalwareScanReportUrl] as a
  /// side effect (mirrors how [verifyGitHubAttestation] mutates app fields);
  /// the caller is responsible for setting [app.latestMalwareScanStatus]
  /// itself, same as it does for the attestation status.
  Future<String?> scanApkWithVirusTotal(App app, File file) async {
    if (kDebugMode && debugForceFlaggedMalwareScan) {
      app.latestMalwareScanDetail =
          '3/70 security vendors flagged this file (TEST result - '
          'debugForceFlaggedMalwareScan is on)';
      final hash = await sha256.bind(file.openRead()).first;
      app.latestMalwareScanReportUrl =
          'https://www.virustotal.com/gui/file/$hash';
      return malwareScanStatusFlagged;
    }
    if (!willScanApkWithVirusTotal()) {
      return null;
    }
    final String apiKey = settingsProvider.getSettingString(
      virusTotalApiKeyKey,
    )!;
    try {
      final hash = await sha256.bind(file.openRead()).first;
      final result = await VirusTotalScanner().scan(
        file,
        hash.toString(),
        apiKey,
      );
      app.latestMalwareScanDetail = result.detail;
      app.latestMalwareScanReportUrl = result.reportUrl;
      return result.status;
    } catch (e) {
      logs.add('Error scanning APK with VirusTotal: ${e.toString()}');
      app.latestMalwareScanDetail = tr(
        'virusTotalErrorGeneric',
        args: [e.toString()],
      );
      app.latestMalwareScanReportUrl = null;
    }
    return malwareScanStatusError;
  }

  /// Acts on a [scanApkWithVirusTotal] result per the rules decided for this
  /// feature: `clean` never interrupts anything; `flagged`/`error` always
  /// pause with a decision dialog when someone's watching
  /// ([malwareScanContext] != null), or skip the app (throwing
  /// [MalwareScanBlockedError] for the caller to catch and notify on) when
  /// there's no one to ask. [cleanupOnSkip] deletes whatever was downloaded -
  /// callers provide it because the exact files/dirs to delete differ between
  /// [installApk] and [installApkDir].
  ///
  /// Returns `true` if the install should proceed, `false` if the person
  /// looking at the dialog chose not to install - that's a deliberate,
  /// already-explained decision, not a failure, so callers must return
  /// quietly on `false` rather than throwing (throwing would route it through
  /// the generic per-app error pipeline and surface a persistent "Error
  /// checking for updates" banner for something the user explicitly chose).
  Future<bool> _handleMalwareScanResult({
    required App app,
    required String status,
    required BuildContext? malwareScanContext,
    required void Function() cleanupOnSkip,
  }) async {
    if (status == malwareScanStatusClean) {
      if (malwareScanContext != null && malwareScanContext.mounted) {
        Fluttertoast.showToast(
          msg: tr('malwareScanCleanToast', args: [app.finalName]),
        );
      }
      return true;
    }
    if (malwareScanContext != null) {
      if (!malwareScanContext.mounted) {
        return true;
      }
      final bool? proceed = await showDialog<bool>(
        // ignore: use_build_context_synchronously
        context: malwareScanContext,
        barrierDismissible: false,
        builder: (BuildContext ctx) => Theme(
          data: Theme.of(malwareScanContext),
          child: MalwareScanWarningDialog(
            appName: app.finalName,
            status: status,
            detail: app.latestMalwareScanDetail,
            reportUrl: app.latestMalwareScanReportUrl,
          ),
        ),
      );
      if (proceed == true) {
        return true;
      }
      cleanupOnSkip();
      return false;
    }
    cleanupOnSkip();
    throw MalwareScanBlockedError(
      status,
      app.latestMalwareScanDetail,
      appName: app.finalName,
    );
  }

  void _pruneStaleDetailPageAutoCheckStarts(DateTime now, Duration cooldown) {
    _lastDetailPageAutoCheckStartedAt.removeWhere(
      (String appId, DateTime startedAt) =>
          !_detailPageAutoChecksInFlight.contains(appId) &&
          now.difference(startedAt) >= cooldown,
    );
  }

  bool tryBeginDetailPageAutoCheck({
    required String appId,
    required DateTime now,
    required Duration cooldown,
    required DateTime? lastUpdateCheckAt,
  }) {
    _pruneStaleDetailPageAutoCheckStarts(now, cooldown);
    final DateTime? lastStartedAt = _lastDetailPageAutoCheckStartedAt[appId];
    final bool recentlyCompleted =
        lastUpdateCheckAt != null &&
        now.difference(lastUpdateCheckAt) < cooldown;
    final bool recentlyStarted =
        lastStartedAt != null && now.difference(lastStartedAt) < cooldown;
    if (recentlyCompleted ||
        recentlyStarted ||
        _detailPageAutoChecksInFlight.contains(appId)) {
      return false;
    }
    _detailPageAutoChecksInFlight.add(appId);
    _lastDetailPageAutoCheckStartedAt[appId] = now;
    return true;
  }

  void finishDetailPageAutoCheck(String appId) {
    _detailPageAutoChecksInFlight.remove(appId);
  }

  Future<int> _maxParallelUpdateChecksForDevice() async {
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

  void cancelDownload(String appId) {
    _downloadCancelTokens[appId]?.cancel();
  }

  AppsProvider({bool isBg = false, SettingsProvider? sharedSettings}) {
    settingsProvider = sharedSettings ?? SettingsProvider();
    if (!isBg) {
      NativeFeatures.registerDownloadCancelHandler(cancelDownload);
      registerDownloadNotificationCancelHandler(cancelDownload);
      installer.registerThirdPartyInstallPackageChangedCallback(
        _handleThirdPartyInstallPackageChanged,
      );
      _receivesThirdPartyInstallEvents = true;
    }
    // Subscribe to changes in the app foreground status
    foregroundStream = FGBGEvents.instance.stream.asBroadcastStream();
    foregroundSubscription = foregroundStream?.listen((event) async {
      isForeground = event == FGBGType.foreground;
      if (isForeground) {
        final now = DateTime.now();
        final last = _lastForegroundLoadAt;
        if (last == null || now.difference(last) >= _foregroundLoadCooldown) {
          // Stamp the cooldown immediately to prevent a second foreground event
          // from queuing a concurrent load during the delay below.
          _lastForegroundLoadAt = now;
          // Yield for one event-loop turn so Flutter can paint the first
          // post-resume frame and register the user's first touch gesture before
          // the getInstalledPackages platform call occupies the Android platform
          // thread. Without this delay the first swipe after returning to the app
          // is reliably missed.
          await Future.delayed(const Duration(milliseconds: 300));
          if (!isForeground) {
            // User switched away within the delay window; reset the stamp so
            // the next real foreground return triggers a load.
            _lastForegroundLoadAt = last;
            return;
          }
          await loadApps(silent: true, lightInstalledInfoFetch: true);
        }
      }
    });
    () async {
      if (sharedSettings == null) {
        await settingsProvider.initializeSettings();
      }
      var cacheDirs = await getExternalCacheDirectories();
      final Directory appStorageRoot = await getAppStorageDir();
      userAppIconsDir = Directory('${appStorageRoot.path}/user_icons');
      if (!await userAppIconsDir.exists()) {
        await userAppIconsDir.create(recursive: true);
      }
      // The external cache dir lives under /Android/data/<pkg>/cache, whose
      // /Android/data/<pkg> parent some devices (e.g. Xiaomi/HyperOS) fail to
      // provision — getExternalCacheDirectories() still returns the path, but
      // creating it throws PathAccessException (errno 13). Verify it's actually
      // creatable before committing to it; otherwise fall back to internal
      // storage like getAppStorageDir() does.
      Directory? usableCacheDir;
      if (cacheDirs?.isNotEmpty ?? false) {
        try {
          await cacheDirs!.first.create(recursive: true);
          usableCacheDir = cacheDirs.first;
        } catch (_) {}
      }
      if (usableCacheDir != null) {
        apkDir = usableCacheDir;
        iconsCacheDir = Directory('${usableCacheDir.path}/icons');
        if (!await iconsCacheDir.exists()) {
          await iconsCacheDir.create(recursive: true);
        }
      } else {
        apkDir = Directory('${appStorageRoot.path}/apks');
        if (!await apkDir.exists()) {
          await apkDir.create(recursive: true);
        }
        iconsCacheDir = Directory('${appStorageRoot.path}/icons');
        if (!await iconsCacheDir.exists()) {
          await iconsCacheDir.create(recursive: true);
        }
      }
      await _migrateUserIconsFromLegacyCacheDir();
      if (!isBg) {
        // Load Apps into memory (in background processes, this is done later instead of in the constructor)
        await loadApps();
        // Delete any partial APKs (if safe to do so)
        var cutoff = DateTime.now().subtract(const Duration(days: 7));
        for (final element in await apkDir.list().toList()) {
          final stat = await element.stat();
          if (stat.modified.isBefore(cutoff) && !areDownloadsRunning()) {
            await element.delete(recursive: true);
          }
        }
      }
    }();
  }

  Future<void> _handleThirdPartyInstallPackageChanged(
    String packageName,
  ) async {
    final AppInMemory? appInMemory = apps[packageName];
    if (appInMemory == null) return;
    final PackageInfo? installedInfo = await getInstalledInfo(
      packageName,
      printErr: false,
    );
    if (installedInfo == null) return;
    final App app = appInMemory.app.deepCopy();
    app.installedVersion = app.latestVersion;
    final correctedApp =
        getCorrectedInstallStatusAppIfPossible(app, installedInfo) ?? app;
    apps[packageName] = AppInMemory(
      correctedApp,
      appInMemory.downloadProgress,
      installedInfo,
      appInMemory.icon,
    );
    _pendingUpdateCountDirty = true;
    notifyListeners();
    unawaited(updateAppIcon(packageName));
  }

  Future<File> handleAPKIDChange(
    App app,
    PackageInfo newInfo,
    File downloadedFile,
    String downloadUrl,
  ) async {
    // If the APK package ID is different from the App ID, it is either new (using a placeholder ID) or the ID has changed
    // The former case should be handled (give the App its real ID), the latter is a security issue
    var isTempIdBool = isTempId(app);
    if (app.id != newInfo.packageName) {
      if (apps[app.id] != null && !isTempIdBool && !app.allowIdChange) {
        throw IDChangedError(newInfo.packageName!);
      }
      var idChangeWasAllowed = app.allowIdChange;
      app.allowIdChange = false;
      var originalAppId = app.id;
      app.id = newInfo.packageName!;
      downloadedFile = downloadedFile.renameSync(
        '${downloadedFile.parent.path}/${app.id}-${downloadUrl.hashCode}.${downloadedFile.path.split('.').last}',
      );
      if (apps[originalAppId] != null) {
        await removeApps([originalAppId]);
        await saveApps([
          app,
        ], onlyIfExists: !isTempIdBool && !idChangeWasAllowed);
      }
    }
    return downloadedFile;
  }

  Future<void> updatePendingRepoRename(String appId, String? newUrl) async {
    if (apps.containsKey(appId)) {
      apps[appId]!.app.pendingRepoRenameUrl = newUrl;
      await saveApps([apps[appId]!.app], updateInstalledInfo: false);
    }
  }

  Future<void> acceptRepoRename(String appId, String newUrl) async {
    if (apps.containsKey(appId)) {
      apps[appId]!.app.url = newUrl;
      apps[appId]!.app.pendingRepoRenameUrl = null;
      await saveApps([apps[appId]!.app], updateInstalledInfo: false);
    }
  }

  Future<Object> downloadApp(
    App app,
    BuildContext? context, {
    NotificationsProvider? notificationsProvider,
    bool useExisting = true,

    /// When true, successful completion leaves [AppInMemory.downloadProgress] at
    /// `-1` so the app page stays on the installing UI until [installFn] clears
    /// it. Avoids a flash of the normal button between download and install.
    bool retainInstallPhaseProgressForHandoff = false,
  }) async {
    final initialDownloadNotification = DownloadNotification(
      app.finalName,
      0,
      appId: app.id,
    );
    var notifId = initialDownloadNotification.id;
    await NativeFeatures.startDownloadForegroundService(
      id: initialDownloadNotification.id,
      appId: app.id,
      title: initialDownloadNotification.title,
      message: initialDownloadNotification.message,
      channelCode: initialDownloadNotification.channelCode,
      channelName: initialDownloadNotification.channelName,
      channelDescription: initialDownloadNotification.channelDescription,
      cancelLabel: tr('cancel'),
    );
    if (apps[app.id] != null) {
      apps[app.id]!.downloadProgress = 0;
      notifyListeners();
    }
    bool downloadSucceeded = false;
    final cancelToken = DownloadCancelToken();
    _downloadCancelTokens[app.id]?.cancel();
    _downloadCancelTokens[app.id] = cancelToken;
    try {
      AppSource source = SourceProvider().getSource(
        app.url,
        overrideSource: app.overrideSource,
      );
      var additionalSettingsPlusSourceConfig = {
        ...app.additionalSettings,
        ...(await source.getSourceConfigValues(
          app.additionalSettings,
          settingsProvider,
        )),
      };
      String downloadUrl = await source.assetUrlPrefetchModifier(
        await source.generalReqPrefetchModifier(
          app.apkUrls[app.preferredApkIndex].value,
          additionalSettingsPlusSourceConfig,
        ),
        app.url,
        additionalSettingsPlusSourceConfig,
      );
      if (context != null &&
          context.mounted &&
          downloadUrl.toLowerCase().startsWith('http://')) {
        bool proceed = false;
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: Text(tr('insecureDownloadUrl')),
              contentPadding: appDialogContentPadding,
              content: Text(tr('cleartextDownloadWarningExplanation')),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                  },
                  child: Text(tr('cancel')),
                ),
                TextButton(
                  onPressed: () {
                    proceed = true;
                    Navigator.of(dialogContext).pop();
                  },
                  child: Text(tr('continue')),
                ),
              ],
            );
          },
        );
        if (!proceed) {
          throw ObtainiumError(tr('cancelled'));
        }
      }
      var notif = DownloadNotification(app.finalName, 100);
      notificationsProvider?.cancel(notif.id);
      int? prevProg;
      var fileNameNoExt = '${app.id}-${downloadUrl.hashCode}';
      if (source.urlsAlwaysHaveExtension) {
        fileNameNoExt =
            '$fileNameNoExt.${app.apkUrls[app.preferredApkIndex].key.split('.').last}';
      }
      var headers = await source.getRequestHeaders(
        app.additionalSettings,
        downloadUrl,
        forAPKDownload: true,
      );
      var downloadedFile = await downloadFileWithRetry(
        downloadUrl,
        fileNameNoExt,
        source.urlsAlwaysHaveExtension,
        headers: headers,
        onContentLength: (int? bytes) {
          if (apps[app.id] != null) {
            apps[app.id]!.downloadTotalBytes = bytes;
          }
        },
        (double? progress) {
          int? prog = progress?.ceil();
          final totalBytes = apps[app.id]?.downloadTotalBytes;
          final notificationMessage = prog != null
              ? _downloadProgressNotificationMessage(prog, totalBytes)
              : null;
          if (apps[app.id] != null) {
            apps[app.id]!.downloadProgress = progress;
            // Throttle UI notifications to ~250 ms so AppPage's progress
            // indicator stays smooth without flooding the widget tree.
            _progressNotifyTimer?.cancel();
            _progressNotifyTimer = Timer(
              const Duration(milliseconds: 250),
              notifyListeners,
            );
          }
          notif = DownloadNotification(
            app.finalName,
            prog ?? 100,
            appId: app.id,
            message: notificationMessage,
          );
          if (prog != null && prevProg != prog) {
            unawaited(
              NativeFeatures.showDownloadProgressNotification(
                id: notif.id,
                appId: app.id,
                title: notif.title,
                message: notif.message,
                channelCode: notif.channelCode,
                progressPercent: prog,
                indeterminate: false,
                cancelLabel: tr('cancel'),
                shortCriticalText: '$prog%',
              ),
            );
          }
          prevProg = prog;
        },
        apkDir.path,
        useExisting: useExisting,
        allowInsecure: app.additionalSettings['allowInsecure'] == true,
        logs: logs,
        cancelToken: cancelToken,
      );
      // Set to 90 for remaining steps, will make null in 'finally'
      if (apps[app.id] != null) {
        // If a VirusTotal scan is about to run, say so from the moment the
        // download finishes - otherwise this briefly shows "Installing"
        // before installApk/installApkDir overwrite it with "Scanning".
        final progressSentinel = willScanApkWithVirusTotal() ? -2 : -1;
        apps[app.id]!.downloadProgress = progressSentinel.toDouble();
        notifyListeners();
        notif = DownloadNotification(
          app.finalName,
          progressSentinel,
          appId: app.id,
        );
        unawaited(
          NativeFeatures.showDownloadProgressNotification(
            id: notif.id,
            appId: app.id,
            title: notif.title,
            message: notif.message,
            channelCode: notif.channelCode,
            progressPercent: progressSentinel,
            indeterminate: true,
            cancelLabel: tr('cancel'),
          ),
        );
      }
      PackageInfo? newInfo;
      var isAPK = isApk(downloadedFile.path);
      var isXAPK = isXapk(downloadedFile.path);
      var isTar = isTarball(downloadedFile.path);
      Directory? extractedDir;
      if (isAPK) {
        newInfo = await pm.getPackageArchiveInfo(
          archiveFilePath: downloadedFile.path,
        );
      } else {
        // Assume XAPK/ZIP (zip-based) or a tarball (.tar.gz/.tgz/.tar.bz2/.tar.xz).
        String apkDirPath = '${downloadedFile.path}-dir';
        if (isTar) {
          await extractTarballFile(downloadedFile.path, apkDirPath);
        } else {
          await unzipFile(downloadedFile.path, apkDirPath);
        }
        extractedDir = Directory(apkDirPath);
        // Tarballs often nest APKs inside a top-level directory, so recurse for them.
        var apks = extractedDir
            .listSync(recursive: isTar)
            .where((e) => isApk(e.path))
            .toList();

        FileSystemEntity? temp;
        apks.removeWhere((element) {
          bool res = element.uri.pathSegments.last.startsWith(app.id);
          if (res) {
            temp = element;
          }
          return res;
        });
        if (temp != null) {
          apks = [temp!, ...apks];
        }

        var filterRegEx = isTar
            ? app.additionalSettings['tarballedApkFilterRegEx']
            : app.additionalSettings['zippedApkFilterRegEx'];
        if (filterRegEx?.isNotEmpty == true) {
          var reg = RegExp(filterRegEx);
          apks.removeWhere((apk) {
            // Tarballs nest, so filter on the path relative to the extract dir;
            // zips keep the historical filename-only match.
            var target = isTar
                ? apk.path.substring(extractedDir!.path.length + 1)
                : apk.uri.pathSegments.last;
            var shouldDelete = !reg.hasMatch(target);
            if (shouldDelete) {
              apk.delete();
            }
            return shouldDelete;
          });
        }

        if (apks.isEmpty) {
          throw NoAPKError();
        }

        for (var i = 0; i < apks.length; i++) {
          try {
            newInfo = await pm.getPackageArchiveInfo(
              archiveFilePath: apks[i].path,
            );
            if (newInfo != null) {
              break;
            }
          } catch (e) {
            if (i == apks.length - 1) {
              rethrow;
            }
          }
        }
      }
      if (newInfo == null) {
        downloadedFile.delete();
        throw ObtainiumError('Could not get ID from APK');
      }
      downloadedFile = await handleAPKIDChange(
        app,
        newInfo,
        downloadedFile,
        downloadUrl,
      );
      // Delete older versions of the file if any
      for (var file in downloadedFile.parent.listSync()) {
        var fn = file.path.split('/').last;
        if (fn.startsWith('${app.id}-') &&
            FileSystemEntity.isFileSync(file.path) &&
            file.path != downloadedFile.path) {
          file.delete(recursive: true);
        }
      }
      if (isAPK) {
        downloadSucceeded = true;
        return DownloadedApk(app.id, downloadedFile);
      } else {
        downloadSucceeded = true;
        return DownloadedDir(
          app.id,
          downloadedFile,
          extractedDir!,
          isXAPK ? DownloadedDirType.xApk : DownloadedDirType.zip,
        );
      }
    } finally {
      if (identical(_downloadCancelTokens[app.id], cancelToken)) {
        _downloadCancelTokens.remove(app.id);
      }
      _progressNotifyTimer?.cancel();
      notificationsProvider?.cancel(notifId);
      if (apps[app.id] != null) {
        apps[app.id]!.downloadTotalBytes = null;
        if (!downloadSucceeded || !retainInstallPhaseProgressForHandoff) {
          apps[app.id]!.downloadProgress = null;
        }
        notifyListeners();
      }
      if (!downloadSucceeded || !retainInstallPhaseProgressForHandoff) {
        unawaited(NativeFeatures.stopDownloadForegroundService());
      }
    }
  }

  bool areDownloadsRunning() => apps.values
      .where((element) => element.downloadProgress != null)
      .isNotEmpty;

  void setAppPageError(String appId, Object error, {String? title}) {
    appPageErrors[appId] = (title: title, message: error.toString());
    notifyListeners();
  }

  void clearAppPageError(String appId) {
    if (appPageErrors.remove(appId) != null) {
      notifyListeners();
    }
  }

  Future<bool> canInstallSilently(App app) async {
    if (!settingsProvider.enableBackgroundUpdates) {
      return false;
    }
    if (app.additionalSettings['exemptFromBackgroundUpdates'] == true) {
      logs.add('Exempted from BG updates: ${app.id}');
      return false;
    }
    if (app.apkUrls.length > 1) {
      logs.add('Multiple APK URLs: ${app.id}');
      return false; // Manual API selection means silent install is not possible
    }

    var osInfo = await DeviceInfoPlugin().androidInfo;
    String? installerPackageName;
    try {
      installerPackageName = osInfo.version.sdkInt >= 30
          ? (await pm.getInstallSourceInfo(
              packageName: app.id,
            ))?.installingPackageName
          : (await pm.getInstallerPackageName(packageName: app.id));
    } catch (e) {
      logs.add(
        'Failed to get installed package details: ${app.id} (${e.toString()})',
      );
      return false; // App probably not installed
    }

    int? targetSDK = (await getInstalledInfo(
      app.id,
    ))?.applicationInfo?.targetSdkVersion;
    int requiredSDK = osInfo.version.sdkInt - 3;
    // The APK should target a new enough API
    // https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)
    if (!(targetSDK != null && targetSDK >= requiredSDK)) {
      logs.add(
        'App currently targets API $targetSDK which is too low for background updates (requires API $requiredSDK): ${app.id}',
      );
      return false;
    }

    if (settingsProvider.useShizuku) {
      return true;
    }

    if (app.id == obtainiumId) {
      return false;
    }
    if (installerPackageName != obtainiumId) {
      // If we did not install the app, silent install is not possible
      return false;
    }
    if (osInfo.version.sdkInt < 31) {
      // The OS must also be new enough
      logs.add('Android SDK too old: ${osInfo.version.sdkInt}');
      return false;
    }
    return true;
  }

  Future<void> waitForUserToReturnToForeground(BuildContext context) async {
    if (isForeground) {
      return;
    }
    NotificationsProvider notificationsProvider = context
        .read<NotificationsProvider>();
    // Give the app a moment to return to foreground in case of fast transitions
    await Future.delayed(const Duration(milliseconds: 1000));
    if (!isForeground) {
      await notificationsProvider.notify(
        completeInstallationNotification,
        cancelExisting: true,
      );
      while (await FGBGEvents.instance.stream.first != FGBGType.foreground) {}
      await notificationsProvider.cancel(completeInstallationNotification.id);
    }
  }

  Future<bool> canDowngradeApps() async =>
      settingsProvider.enableLetMeDowngrade &&
      (await getInstalledInfo('com.berdik.letmedowngrade')) != null;

  Future<void> unzipFile(String filePath, String destinationPath) async {
    await ZipFile.extractToDirectory(
      zipFile: File(filePath),
      destinationDir: Directory(destinationPath),
    );
  }

  Future<void> extractTarballFile(
    String filePath,
    String destinationPath,
  ) async {
    final bytes = await File(filePath).readAsBytes();
    List<int> decompressed;
    // Detect compression by magic bytes (the file extension may be wrong after download).
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      // gzip
      decompressed = const archive.GZipDecoder().decodeBytes(bytes);
    } else if (bytes.length >= 3 &&
        bytes[0] == 0x42 &&
        bytes[1] == 0x5a &&
        bytes[2] == 0x68) {
      // bzip2 ('BZh')
      decompressed = archive.BZip2Decoder().decodeBytes(bytes);
    } else if (bytes.length >= 6 &&
        bytes[0] == 0xfd &&
        bytes[1] == 0x37 &&
        bytes[2] == 0x7a &&
        bytes[3] == 0x58 &&
        bytes[4] == 0x5a &&
        bytes[5] == 0x00) {
      // xz
      decompressed = archive.XZDecoder().decodeBytes(bytes);
    } else {
      // Assume uncompressed tar
      decompressed = bytes;
    }
    final tarArchive = archive.TarDecoder().decodeBytes(decompressed);
    final destDir = Directory(destinationPath);
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }
    for (final file in tarArchive.files) {
      if (file.isFile) {
        final outFile = File('${destDir.path}/${file.name}');
        outFile.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
      }
    }
  }

  Uri? _documentUriFromSafPluginResult(dynamic pluginResult) {
    if (pluginResult == null) return null;
    if (pluginResult is Map) {
      return Uri.parse(
        Map<String, dynamic>.from(pluginResult)['uri'] as String,
      );
    }
    return (pluginResult as dynamic).uri as Uri?;
  }

  /// Writes [source] into the SAF tree as [displayName] without loading the
  /// whole file into memory. Replaces an existing document with the same name.
  Future<bool> _chunkedCopyApkToSafTree(
    File source,
    Uri treeUri,
    String displayName, {
    String? mimeType,
  }) async {
    final String resolvedMime =
        mimeType ??
        (displayName.toLowerCase().endsWith('.apk')
            ? 'application/vnd.android.package-archive'
            : (displayName.toLowerCase().endsWith('.zip')
                  ? 'application/zip'
                  : (displayName.toLowerCase().endsWith('.json')
                        ? 'application/json'
                        : '*/*')));
    final dynamic existing = await saf.findFile(treeUri, displayName);
    if (existing != null) {
      final Uri? existingUri = existing is Map
          ? Uri.parse(Map<String, dynamic>.from(existing)['uri'] as String)
          : (existing as dynamic).uri as Uri?;
      if (existingUri != null) {
        await saf.delete(existingUri);
      }
    }
    Uri? documentUri;
    var isFirstChunk = true;
    await for (final List<int> chunk in source.openRead()) {
      final Uint8List bytes = Uint8List.fromList(chunk);
      if (isFirstChunk) {
        final dynamic created = await saf.createFile(
          treeUri,
          mimeType: resolvedMime,
          displayName: displayName,
          bytes: bytes,
        );
        isFirstChunk = false;
        documentUri = _documentUriFromSafPluginResult(created);
        if (documentUri == null) {
          return false;
        }
      } else {
        await saf.writeToFile(
          documentUri!,
          bytes: bytes,
          mode: FileMode.append,
        );
      }
    }
    if (isFirstChunk) {
      final dynamic created = await saf.createFile(
        treeUri,
        mimeType: resolvedMime,
        displayName: displayName,
        bytes: Uint8List(0),
      );
      return _documentUriFromSafPluginResult(created) != null;
    }
    return true;
  }

  Future<bool> installApkDir(
    DownloadedDir dir,
    BuildContext? firstTimeWithContext, {
    bool needsBGWorkaround = false,
    bool shizukuPretendToBeGooglePlay = false,

    /// See [installApk]'s param of the same name.
    BuildContext? malwareScanContext,
  }) async {
    // We don't know which APKs in an XAPK or ZIP are supported by the user's device
    // So we try installing all of them and assume success if at least one installed
    // If 0 APKs installed, throw the first install error encountered
    // Obviously this approach is naive and is undesirable in many cases, needs to be improved
    var somethingInstalled = false;
    try {
      final AppInMemory? appInMemory = apps[dir.appId];
      if (appInMemory != null) {
        final App app = appInMemory.app;
        final AppSource source = SourceProvider().getSource(
          app.url,
          overrideSource: app.overrideSource,
        );
        if (reproducibleBuildEnforcementBlocksInstall(app, source)) {
          try {
            if (dir.file.existsSync()) {
              dir.file.deleteSync();
            }
            if (dir.extracted.existsSync()) {
              dir.extracted.deleteSync(recursive: true);
            }
          } catch (_) {}
          throw ObtainiumError(reproducibleBuildEnforcedBlockedMessage());
        }
        final bool githubAttestationEngineRunning =
            source is GitHub &&
            source.shouldVerifyAttestations(
              app.additionalSettings,
              settingsProvider,
            );
        final bool enforceAttest =
            source is GitHub &&
            source.shouldEnforceAttestations(
              app.additionalSettings,
              settingsProvider,
            );
        final bool verifyAttest = githubAttestationEngineRunning;
        if (source is GitHub && verifyAttest) {
          final String? attestationStatus = await verifyGitHubAttestation(
            app,
            dir.file,
          );
          app.latestAttestationStatus = attestationStatus;
          apps[dir.appId] = AppInMemory(
            app,
            appInMemory.downloadProgress,
            appInMemory.installedInfo,
            appInMemory.icon,
          );
          if (enforceAttest &&
              attestationStatus != githubAttestationStatusVerified) {
            try {
              if (dir.file.existsSync()) {
                dir.file.deleteSync();
              }
              if (dir.extracted.existsSync()) {
                dir.extracted.deleteSync(recursive: true);
              }
            } catch (_) {}
            throw ObtainiumError(
              tr(
                attestationStatus == githubAttestationStatusUnsupported
                    ? 'githubAttestationEnforcedButUnsupported'
                    : 'githubAttestationEnforcedButFailed',
              ),
            );
          }
        }
        apps[dir.appId]?.downloadProgress = -2;
        notifyListeners();
        final String? malwareScanStatus = await scanApkWithVirusTotal(
          app,
          dir.file,
        );
        if (malwareScanStatus != null) {
          app.latestMalwareScanStatus = malwareScanStatus;
          final double progress = malwareScanStatus != malwareScanStatusClean ? -3 : -1;
          apps[dir.appId] = AppInMemory(
            app,
            progress,
            appInMemory.installedInfo,
            appInMemory.icon,
          );
          notifyListeners();
          final bool proceedAfterScan = await _handleMalwareScanResult(
            app: app,
            status: malwareScanStatus,
            // ignore: use_build_context_synchronously
            malwareScanContext: malwareScanContext,
            cleanupOnSkip: () {
              try {
                if (dir.file.existsSync()) {
                  dir.file.deleteSync();
                }
                if (dir.extracted.existsSync()) {
                  dir.extracted.deleteSync(recursive: true);
                }
              } catch (_) {}
            },
          );
          if (!proceedAfterScan) {
            return false;
          }
          apps[dir.appId]?.downloadProgress = -1;
          notifyListeners();
        } else {
          apps[dir.appId]?.downloadProgress = -1;
          notifyListeners();
        }
      }
      MultiAppMultiError errors = MultiAppMultiError();
      List<File> apkFiles = [];
      for (var file
          in dir.extracted
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        if (isApk(file.path)) {
          apkFiles.add(file);
        } else if (isObb(file.path)) {
          await moveObbFile(file, dir.appId);
        }
      }

      File? temp;
      apkFiles.removeWhere((element) {
        bool res = element.uri.pathSegments.last.startsWith(dir.appId);
        if (res) {
          temp = element;
        }
        return res;
      });
      if (temp != null) {
        apkFiles = [temp!, ...apkFiles];
      }

      try {
        if (firstTimeWithContext != null && !firstTimeWithContext.mounted) {
          firstTimeWithContext = null;
        }
        var wasInstalled = await installApk(
          DownloadedApk(dir.appId, apkFiles[0]),
          firstTimeWithContext, // ignore: use_build_context_synchronously
          needsBGWorkaround: needsBGWorkaround,
          shizukuPretendToBeGooglePlay: shizukuPretendToBeGooglePlay,
          additionalAPKs: apkFiles
              .sublist(1)
              .map((a) => DownloadedApk(dir.appId, a))
              .toList(),
          skipApkSaveFolderPersistForPrimaryApk: true,
          thirdPartyHandoffContainerPath:
              settingsProvider.installerMode == 'legacy' &&
                  dir.file.existsSync()
              ? dir.file.path
              : null,
          // ignore: use_build_context_synchronously
          malwareScanContext: malwareScanContext,
          skipMalwareScan: true,
        );
        somethingInstalled = somethingInstalled || wasInstalled;
      } catch (e) {
        logs.add('Could not install APKs from ${dir.type}: ${e.toString()}');
        errors.add(dir.appId, e, appName: apps[dir.appId]?.name);
      }
      if (errors.idsByErrorString.isNotEmpty) {
        throw errors;
      }
    } finally {
      unawaited(_finalizeDownloadedDirDisposition(dir, somethingInstalled));
    }
    return somethingInstalled;
  }

  /// Bundle SAF copy + temp dir cleanup for XAPK/ZIP installs (off critical path).
  Future<void> _finalizeDownloadedDirDisposition(
    DownloadedDir dir,
    bool somethingInstalled,
  ) async {
    try {
      final App? appForSave = apps[dir.appId]?.app;
      final bool saveApkCopies = settingsProvider.saveDownloadedApkCopies;
      final Uri? resolvedApkSaveUri = await settingsProvider.getApkSaveDir(
        warnIfInaccessible: saveApkCopies,
      );
      var bundleCopiedOk = false;
      if (Platform.isAndroid &&
          saveApkCopies &&
          appForSave != null &&
          resolvedApkSaveUri != null &&
          dir.file.existsSync()) {
        try {
          bundleCopiedOk = await _chunkedCopyApkToSafTree(
            dir.file,
            resolvedApkSaveUri,
            storeFacingDownloadDisplayNameForApp(appForSave),
          );
        } catch (exception, stackTrace) {
          logs.add(
            'APK save folder copy failed: ${exception.toString()}\n$stackTrace',
          );
          Fluttertoast.showToast(msg: tr('apkSaveFolderCopyFailed'));
        }
      }
      final bool skipLatest =
          appForSave != null && isSkipActiveForCurrentLatest(appForSave);
      final bool hasSaveFolder = saveApkCopies && resolvedApkSaveUri != null;
      final bool shouldDeleteBundle;
      if (hasSaveFolder && appForSave != null && dir.file.existsSync()) {
        shouldDeleteBundle =
            bundleCopiedOk && (somethingInstalled || skipLatest);
      } else if (!saveApkCopies) {
        if (somethingInstalled) {
          shouldDeleteBundle = true;
        } else {
          shouldDeleteBundle = skipLatest;
        }
      } else if (resolvedApkSaveUri == null) {
        if (somethingInstalled) {
          shouldDeleteBundle = false;
        } else {
          shouldDeleteBundle = skipLatest;
        }
      } else {
        shouldDeleteBundle =
            somethingInstalled || (!somethingInstalled && skipLatest);
      }
      if (shouldDeleteBundle && dir.file.existsSync()) {
        try {
          dir.file.deleteSync();
        } catch (_) {}
      }
      dir.extracted.delete(recursive: true);
    } catch (exception, stackTrace) {
      logs.add(
        'Post-install bundle disposition failed: ${exception.toString()}\n$stackTrace',
      );
    }
  }

  Future<bool> installApk(
    DownloadedApk file,
    BuildContext? firstTimeWithContext, {
    bool needsBGWorkaround = false,
    bool shizukuPretendToBeGooglePlay = false,
    List<DownloadedApk> additionalAPKs = const [],

    /// When true, the outer bundle ([installApkDir]) persists the container; do
    /// not copy this extracted APK under the same release asset name.
    bool skipApkSaveFolderPersistForPrimaryApk = false,

    /// Third-party installer: hand off this file (XAPK/ZIP download) instead of
    /// extracted split APK paths so installers like InstallerX see the same bundle
    /// as when opening the file from a file manager.
    String? thirdPartyHandoffContainerPath,

    /// The context of the install call itself - unlike [firstTimeWithContext]
    /// (only set for brand-new installs), this is non-null for *any*
    /// interactive install/update. Used to decide whether a VirusTotal scan
    /// result can be shown as a dialog (someone's watching) or must instead
    /// skip the app and notify (background/silent - see [installFn]).
    BuildContext? malwareScanContext,

    /// Set by [installApkDir] when it calls this method for a split APK -
    /// the container was already scanned once, so scanning each split part
    /// again would waste VirusTotal's rate limit for no benefit.
    bool skipMalwareScan = false,
  }) async {
    final bool saveApkCopiesRequested =
        settingsProvider.saveDownloadedApkCopies &&
        !skipApkSaveFolderPersistForPrimaryApk;
    final Uri? apkSaveTreeUri = saveApkCopiesRequested
        ? await settingsProvider.getApkSaveDir(warnIfInaccessible: true)
        : null;
    var installReportedOk = false;
    try {
      final AppInMemory? appInMemory = apps[file.appId];
      if (appInMemory != null) {
        final App app = appInMemory.app;
        final AppSource source = SourceProvider().getSource(
          app.url,
          overrideSource: app.overrideSource,
        );
        if (reproducibleBuildEnforcementBlocksInstall(app, source)) {
          try {
            if (file.file.existsSync()) {
              file.file.deleteSync();
            }
            for (var additionalApk in additionalAPKs) {
              if (additionalApk.file.existsSync()) {
                additionalApk.file.deleteSync();
              }
            }
          } catch (_) {}
          throw ObtainiumError(reproducibleBuildEnforcedBlockedMessage());
        }
        final bool githubAttestationEngineRunning =
            source is GitHub &&
            source.shouldVerifyAttestations(
              app.additionalSettings,
              settingsProvider,
            );
        final bool enforceAttest =
            source is GitHub &&
            source.shouldEnforceAttestations(
              app.additionalSettings,
              settingsProvider,
            );
        final bool verifyAttest = githubAttestationEngineRunning;
        if (source is GitHub && verifyAttest) {
          final String? attestationStatus = await verifyGitHubAttestation(
            app,
            file.file,
          );
          app.latestAttestationStatus = attestationStatus;
          apps[file.appId] = AppInMemory(
            app,
            appInMemory.downloadProgress,
            appInMemory.installedInfo,
            appInMemory.icon,
          );
          if (enforceAttest &&
              attestationStatus != githubAttestationStatusVerified) {
            try {
              if (file.file.existsSync()) {
                file.file.deleteSync();
              }
              for (var a in additionalAPKs) {
                if (a.file.existsSync()) {
                  a.file.deleteSync();
                }
              }
            } catch (_) {}
            throw ObtainiumError(
              tr(
                attestationStatus == githubAttestationStatusUnsupported
                    ? 'githubAttestationEnforcedButUnsupported'
                    : 'githubAttestationEnforcedButFailed',
              ),
            );
          }
        }
        if (!skipMalwareScan) {
          apps[file.appId]?.downloadProgress = -2;
          notifyListeners();
        }
        final String? malwareScanStatus = skipMalwareScan
            ? null
            : await scanApkWithVirusTotal(app, file.file);
        if (malwareScanStatus != null) {
          app.latestMalwareScanStatus = malwareScanStatus;
          final double progress = malwareScanStatus != malwareScanStatusClean ? -3 : -1;
          apps[file.appId] = AppInMemory(
            app,
            progress,
            appInMemory.installedInfo,
            appInMemory.icon,
          );
          notifyListeners();
          final bool proceedAfterScan = await _handleMalwareScanResult(
            app: app,
            status: malwareScanStatus,
            // ignore: use_build_context_synchronously
            malwareScanContext: malwareScanContext,
            cleanupOnSkip: () {
              try {
                if (file.file.existsSync()) {
                  file.file.deleteSync();
                }
                for (var a in additionalAPKs) {
                  if (a.file.existsSync()) {
                    a.file.deleteSync();
                  }
                }
              } catch (_) {}
            },
          );
          if (!proceedAfterScan) {
            return false;
          }
          apps[file.appId]?.downloadProgress = -1;
          notifyListeners();
        } else {
          if (!skipMalwareScan) {
            apps[file.appId]?.downloadProgress = -1;
            notifyListeners();
          }
        }
      }
      if (firstTimeWithContext != null &&
          settingsProvider.beforeNewInstallsShareToAppVerifier) {
        XFile f = XFile(
          file.file.path,
          mimeType: 'application/vnd.android.package-archive',
        );
        Fluttertoast.showToast(
          msg: tr('appVerifierInstructionToast'),
          toastLength: Toast.LENGTH_LONG,
        );
        try {
          await SharePlus.instance.share(ShareParams(files: [f]));
          if (firstTimeWithContext.mounted) {
            await waitForUserToReturnToForeground(firstTimeWithContext);
          }
        } catch (e) {
          logs.add('Share to App Verifier failed: $e');
        }
      }
      var newInfo = await pm.getPackageArchiveInfo(
        archiveFilePath: file.file.path,
      );
      if (newInfo == null) {
        try {
          deleteFile(file.file);
          for (var a in additionalAPKs) {
            deleteFile(a.file);
          }
        } catch (e) {
          //
        } finally {
          throw ObtainiumError(tr('badDownload'));
        }
      }
      PackageInfo? appInfo = await getInstalledInfo(apps[file.appId]!.app.id);
      logs.add(
        'Installing "${newInfo.packageName}" version "${newInfo.versionName}" versionCode "${newInfo.versionCode}"${appInfo != null ? ' (from existing version "${appInfo.versionName}" versionCode "${appInfo.versionCode}")' : ''}',
      );
      if (appInfo != null &&
          newInfo.versionCode! < appInfo.versionCode! &&
          settingsProvider.installerMode == 'stock' &&
          !(await canDowngradeApps()) &&
          settingsProvider.showAppDowngradeError) {
        throw DowngradeError(appInfo.versionCode!, newInfo.versionCode!);
      }
      if (needsBGWorkaround) {
        installReportedOk = true;
        // The below 'await' will never return if we are in a background process
        // To work around this, we should assume the install will be successful
        // So we update the app's installed version first as we will never get to the later code
        // We can't conditionally get rid of the 'await' as this causes install fails (BG process times out) - see #896
        // TODO: When fixed, update this function and the calls to it accordingly
        apps[file.appId]!.app.installedVersion =
            apps[file.appId]!.app.latestVersion;
        await saveApps([
          apps[file.appId]!.app,
        ], attemptToCorrectInstallStatus: false);
      }
      if (settingsProvider.installerMode == 'legacy') {
        final targetPkg = settingsProvider.legacyInstallerPackage;
        final targetAct = settingsProvider.legacyInstallerActivity;
        if (targetPkg == null || targetAct == null) {
          throw ObtainiumError(tr('thirdPartyInstallerNotSelected'));
        }
        final String thirdPartyPathsArg;
        if (thirdPartyHandoffContainerPath != null &&
            File(thirdPartyHandoffContainerPath).existsSync()) {
          thirdPartyPathsArg = thirdPartyHandoffContainerPath;
        } else {
          thirdPartyPathsArg = [
            file.file.path,
            ...additionalAPKs.map((a) => a.file.path),
          ].join(',');
        }
        bool thirdPartyInstallSucceeded = await installer
            .installApkViaThirdParty(
              thirdPartyPathsArg,
              targetPackage: targetPkg,
              targetActivity: targetAct,
              expectedPackageName: apps[file.appId]!.app.id,
            );
        if (thirdPartyInstallSucceeded) {
          installReportedOk = true;
          apps[file.appId]!.app.installedVersion =
              apps[file.appId]!.app.latestVersion;
        }
        await saveApps([apps[file.appId]!.app]);
        return thirdPartyInstallSucceeded;
      }
      int? code;
      if (!settingsProvider.useShizuku) {
        var allAPKs = [file.file.path];
        allAPKs.addAll(additionalAPKs.map((a) => a.file.path));
        code = await AndroidPackageInstaller.installApk(
          apkFilePath: allAPKs.join(','),
        );
      } else {
        code = await ShizukuApkInstaller().installAPK(
          file.file.uri.toString(),
          shizukuPretendToBeGooglePlay ? "com.android.vending" : "",
        );
      }
      bool installed = false;
      if (code != null && code != 0 && code != 3) {
        throw InstallError(code);
      } else if (code == 0) {
        installReportedOk = true;
        installed = true;
        apps[file.appId]!.app.installedVersion =
            apps[file.appId]!.app.latestVersion;
      }
      await saveApps([apps[file.appId]!.app]);
      return installed;
    } finally {
      if (Platform.isAndroid) {
        unawaited(
          _disposeInstalledApkFilesAfterSession(
            appId: file.appId,
            primaryFile: file.file,
            additionalAPKs: additionalAPKs,
            installReportedOk: installReportedOk,
            saveApkCopiesRequested: saveApkCopiesRequested,
            apkSaveTreeUri: apkSaveTreeUri,
          ),
        );
      }
    }
  }

  /// SAF copy + temp APK cleanup after install. Runs off the critical path so
  /// [downloadProgress] can clear as soon as the installer returns.
  Future<void> _disposeInstalledApkFilesAfterSession({
    required String appId,
    required File primaryFile,
    required List<DownloadedApk> additionalAPKs,
    required bool installReportedOk,
    required bool saveApkCopiesRequested,
    required Uri? apkSaveTreeUri,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final App? appRef = apps[appId]?.app;
      final bool skipLatest =
          appRef != null && isSkipActiveForCurrentLatest(appRef);
      final bool hasSaveFolder = apkSaveTreeUri != null;

      var copiedOk = false;
      if (hasSaveFolder && appRef != null && primaryFile.existsSync()) {
        try {
          copiedOk = await _chunkedCopyApkToSafTree(
            primaryFile,
            apkSaveTreeUri,
            storeFacingDownloadDisplayNameForApp(appRef),
          );
        } catch (exception, stackTrace) {
          logs.add(
            'APK save folder copy failed: ${exception.toString()}\n$stackTrace',
          );
          Fluttertoast.showToast(msg: tr('apkSaveFolderCopyFailed'));
        }
      }

      final bool deletePrimary;
      if (hasSaveFolder) {
        deletePrimary = copiedOk && (installReportedOk || skipLatest);
      } else if (!saveApkCopiesRequested) {
        deletePrimary = installReportedOk || (!installReportedOk && skipLatest);
      } else {
        deletePrimary = !installReportedOk && skipLatest;
      }

      if (deletePrimary && primaryFile.existsSync()) {
        try {
          primaryFile.deleteSync();
        } catch (_) {}
      }
      if (deletePrimary) {
        for (final suppliedApk in additionalAPKs) {
          try {
            if (suppliedApk.file.existsSync()) {
              suppliedApk.file.deleteSync();
            }
          } catch (_) {}
        }
      }
    } catch (exception, stackTrace) {
      logs.add(
        'Post-install APK disposition failed: ${exception.toString()}\n$stackTrace',
      );
    }
  }

  Future<String> getStorageRootPath() async {
    final Directory appStorageDir = await getAppStorageDir();
    if (appStorageDir.path.startsWith('/storage/emulated/')) {
      return '/${appStorageDir.uri.pathSegments.sublist(0, 3).join('/')}';
    }
    return '/storage/emulated/0';
  }

  Future<void> moveObbFile(File file, String appId) async {
    if (!isObb(file.path)) return;

    // TODO: Does not support Android 11+
    if ((await DeviceInfoPlugin().androidInfo).version.sdkInt <= 29) {
      await Permission.storage.request();
    }

    String obbDirPath = "${await getStorageRootPath()}/Android/obb/$appId";
    Directory(obbDirPath).createSync(recursive: true);

    String obbFileName = file.path.split("/").last;
    await file.copy("$obbDirPath/$obbFileName");
  }

  void uninstallApp(String appId) async {
    var intent = AndroidIntent(
      action: 'android.intent.action.DELETE',
      data: 'package:$appId',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );
    await intent.launch();
  }

  Future<MapEntry<String, String>?> confirmAppFileUrl(
    App app,
    BuildContext? context,
    bool pickAnyAsset, {
    bool evenIfSingleChoice = false,
    ThemeData? dialogTheme,
  }) async {
    var urlsToSelectFrom = app.apkUrls;
    if (pickAnyAsset) {
      urlsToSelectFrom = [...urlsToSelectFrom, ...app.otherAssetUrls];
    }
    // If the App has more than one APK, the user should pick one (if context provided)
    MapEntry<String, String>? appFileUrl =
        urlsToSelectFrom[app.preferredApkIndex >= 0
            ? app.preferredApkIndex
            : 0];
    // get device supported architecture
    List<String> archs = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    if (context != null && !context.mounted) {
      return appFileUrl;
    }

    if ((urlsToSelectFrom.length > 1 || evenIfSingleChoice) &&
        context != null) {
      appFileUrl = await showDialog(
        // ignore: use_build_context_synchronously
        context: context,
        builder: (BuildContext ctx) {
          final Widget dialog = AppFilePicker(
            app: app,
            initVal: appFileUrl,
            archs: archs,
            pickAnyAsset: pickAnyAsset,
          );
          return dialogTheme == null
              ? dialog
              : Theme(data: dialogTheme, child: dialog);
        },
      );
    }
    getHost(String url) {
      if (url == 'placeholder') {
        return null;
      }
      var temp = Uri.parse(url).host.split('.');
      return temp.sublist(temp.length - 2).join('.');
    }

    // If the picked APK comes from an origin different from the source, get user confirmation (if context provided)
    if (appFileUrl != null &&
        ![
          getHost(app.url),
          'placeholder',
        ].contains(getHost(appFileUrl.value)) &&
        context != null) {
      if (!context.mounted) {
        return null;
      }
      if (!(settingsProvider.hideAPKOriginWarning) &&
          await showDialog(
                // ignore: use_build_context_synchronously
                context: context,
                builder: (BuildContext ctx) {
                  final Widget dialog = APKOriginWarningDialog(
                    sourceUrl: app.url,
                    apkUrl: appFileUrl!.value,
                  );
                  return dialogTheme == null
                      ? dialog
                      : Theme(data: dialogTheme, child: dialog);
                },
              ) !=
              true) {
        appFileUrl = null;
      }
    }
    return appFileUrl;
  }

  // Given a list of AppIds, uses stored info about the apps to download APKs and install them
  // If the APKs can be installed silently, they are
  // If no BuildContext is provided, apps that require user interaction are ignored
  // If user input is needed and the App is in the background, a notification is sent to get the user's attention
  // Returns an array of Ids for Apps that were successfully downloaded, regardless of installation result
  Future<List<String>> downloadAndInstallLatestApps(
    List<String> appIds,
    BuildContext? context, {
    NotificationsProvider? notificationsProvider,
    bool forceParallelDownloads = false,
    bool useExisting = true,
    ThemeData? dialogTheme,
  }) async {
    notificationsProvider =
        notificationsProvider ?? context?.read<NotificationsProvider>();
    List<String> appsToInstall = [];
    List<String> trackOnlyAppsToUpdate = [];
    // For all specified Apps, filter out those for which:
    // 1. A URL cannot be picked
    // 2. That cannot be installed silently (IF no buildContext was given for interactive install)
    for (var id in appIds) {
      if (apps[id] == null) {
        throw ObtainiumError(tr('appNotFound'));
      }
      final App appToInstall = apps[id]!.app;
      MapEntry<String, String>? apkUrl;
      var trackOnly = appToInstall.additionalSettings['trackOnly'] == true;
      var refreshBeforeDownload =
          appToInstall.additionalSettings['refreshBeforeDownload'] == true ||
          appToInstall.apkUrls.isNotEmpty &&
              appToInstall.apkUrls.first.value == 'placeholder';
      if (refreshBeforeDownload) {
        await checkUpdate(appToInstall.id);
      }
      final App refreshedApp = apps[id]!.app;
      final AppSource source = SourceProvider().getSource(
        refreshedApp.url,
        overrideSource: refreshedApp.overrideSource,
      );
      if (buildVerificationEnforcementBlocksInstall(
        refreshedApp,
        source,
        settingsProvider,
      )) {
        throw ObtainiumError(
          buildVerificationEnforcedBlockedMessage(
            refreshedApp,
            source,
            settingsProvider,
          ),
        );
      }
      if (!trackOnly) {
        if (context != null && !context.mounted) return [];
        // ignore: use_build_context_synchronously
        apkUrl = await confirmAppFileUrl(
          apps[id]!.app,
          context,
          false,
          dialogTheme: dialogTheme,
        );
      }
      if (apkUrl != null) {
        int urlInd = apps[id]!.app.apkUrls
            .map((e) => e.value)
            .toList()
            .indexOf(apkUrl.value);
        if (urlInd >= 0 && urlInd != apps[id]!.app.preferredApkIndex) {
          apps[id]!.app.preferredApkIndex = urlInd;
          await saveApps([apps[id]!.app], updateInstalledInfo: false);
        }
        if (context != null || await canInstallSilently(apps[id]!.app)) {
          appsToInstall.add(id);
        }
      }
      if (trackOnly) {
        trackOnlyAppsToUpdate.add(id);
      }
    }
    // Mark all specified track-only apps as latest
    saveApps(
      trackOnlyAppsToUpdate.map((e) {
        var a = apps[e]!.app;
        a.installedVersion = a.latestVersion;
        a.additionalSettings['trackOnlyUndeterminedInstalledVersion'] = false;
        a.additionalSettings['trackOnlyTemporaryPackageId'] = false;
        return a;
      }).toList(),
      attemptToCorrectInstallStatus: false,
      updateInstalledInfo: false,
    );

    // Prepare to download+install Apps
    MultiAppMultiError errors = MultiAppMultiError();
    List<String> installedIds = [];
    // Apps skipped because of a flagged/failed VirusTotal scan during this
    // batch - reported as ONE consolidated notification at the end instead
    // of one per app (see the throw site below) and kept out of [errors] so
    // they don't also trigger the generic install-error notification.
    List<({String appName, String status, String? detail})> malwareScanSkips =
        [];

    // Move Obtainium to the end of the line (let all other apps update first)
    appsToInstall = moveStrToEnd(
      appsToInstall,
      obtainiumId,
      strB: obtainiumTempId,
    );

    Future<void> installFn(
      String id,
      bool willBeSilent,
      DownloadedApk? downloadedFile,
      DownloadedDir? downloadedDir,
    ) async {
      apps[id]?.downloadProgress = -1;
      notifyListeners();
      try {
        bool sayInstalled = true;
        var contextIfNewInstall = apps[id]?.installedInfo == null
            ? context
            : null;
        bool needBGWorkaround =
            willBeSilent && context == null && !settingsProvider.useShizuku;
        bool shizukuPretendToBeGooglePlay =
            settingsProvider.shizukuPretendToBeGooglePlay ||
            apps[id]!.app.additionalSettings['shizukuPretendToBeGooglePlay'] ==
                true;

        if (!willBeSilent && context != null && !settingsProvider.useShizuku) {
          // ignore: use_build_context_synchronously
          await waitForUserToReturnToForeground(context);
        }

        if (downloadedFile != null) {
          if (needBGWorkaround) {
            installApk(
              downloadedFile,
              // ignore: use_build_context_synchronously
              contextIfNewInstall,
              needsBGWorkaround: true,
              shizukuPretendToBeGooglePlay: shizukuPretendToBeGooglePlay,
              // ignore: use_build_context_synchronously
              malwareScanContext: context,
            );
          } else {
            sayInstalled = await installApk(
              downloadedFile,
              // ignore: use_build_context_synchronously
              contextIfNewInstall,
              shizukuPretendToBeGooglePlay: shizukuPretendToBeGooglePlay,
              // ignore: use_build_context_synchronously
              malwareScanContext: context,
            );
          }
        } else {
          if (needBGWorkaround) {
            installApkDir(
              downloadedDir!,
              // ignore: use_build_context_synchronously
              contextIfNewInstall,
              needsBGWorkaround: true,
              // ignore: use_build_context_synchronously
              malwareScanContext: context,
            );
          } else {
            sayInstalled = await installApkDir(
              downloadedDir!,
              // ignore: use_build_context_synchronously
              contextIfNewInstall,
              shizukuPretendToBeGooglePlay: shizukuPretendToBeGooglePlay,
              // ignore: use_build_context_synchronously
              malwareScanContext: context,
            );
          }
        }
        if (willBeSilent && context == null) {
          if (!settingsProvider.useShizuku) {
            notificationsProvider?.notify(
              SilentUpdateAttemptNotification([apps[id]!.app], id: id.hashCode),
            );
          } else {
            notificationsProvider?.notify(
              SilentUpdateNotification(
                [apps[id]!.app],
                sayInstalled,
                id: id.hashCode,
              ),
            );
          }
        }
        if (sayInstalled) {
          installedIds.add(id);
          // Dismiss the update notification since the app was successfully installed
          notificationsProvider?.cancel(UpdateNotification([]).id);
        }
      } finally {
        apps[id]?.downloadProgress = null;
        notifyListeners();
        unawaited(NativeFeatures.stopDownloadForegroundService());
      }
    }

    Future<Map<Object?, Object?>> downloadFn(String id) async {
      bool willBeSilent = false;
      DownloadedApk? downloadedFile;
      DownloadedDir? downloadedDir;
      bool installPhaseServiceRetained = false;
      try {
        var downloadedArtifact =
            // ignore: use_build_context_synchronously
            await downloadApp(
              apps[id]!.app,
              context,
              notificationsProvider: notificationsProvider,
              useExisting: useExisting,
              retainInstallPhaseProgressForHandoff: true,
            );
        installPhaseServiceRetained = true;
        if (downloadedArtifact is DownloadedApk) {
          downloadedFile = downloadedArtifact;
        } else {
          downloadedDir = downloadedArtifact as DownloadedDir;
        }
        id = downloadedFile?.appId ?? downloadedDir!.appId;
        willBeSilent = await canInstallSilently(apps[id]!.app);
        if (settingsProvider.installerMode == 'legacy') {
          // Third-party installer path bypasses the standard permission check.
        } else if (!settingsProvider.useShizuku) {
          if (!(await settingsProvider.getInstallPermission(enforce: false))) {
            throw ObtainiumError(tr('cancelled'));
          }
        } else {
          switch ((await ShizukuApkInstaller().checkPermission())!) {
            case 'services_not_found':
              throw ObtainiumError(tr('shizukuBinderNotFound'));
            case 'old_shizuku':
              throw ObtainiumError(tr('shizukuOld'));
            case 'old_android_with_adb':
              throw ObtainiumError(tr('shizukuOldAndroidWithADB'));
            case 'denied':
              throw ObtainiumError(tr('cancelled'));
          }
        }
      } catch (exception) {
        apps[id]?.downloadProgress = null;
        apps[id]?.downloadTotalBytes = null;
        if (installPhaseServiceRetained) {
          unawaited(NativeFeatures.stopDownloadForegroundService());
        }
        if (exception is DownloadCancelledError) {
          notifyListeners();
          return {
            'id': id,
            'cancelled': true,
            'willBeSilent': willBeSilent,
            'downloadedFile': downloadedFile,
            'downloadedDir': downloadedDir,
          };
        }
        errors.add(id, exception, appName: apps[id]?.name);
        notifyListeners();
      }
      return {
        'id': id,
        'cancelled': false,
        'willBeSilent': willBeSilent,
        'downloadedFile': downloadedFile,
        'downloadedDir': downloadedDir,
      };
    }

    bool needsLegacyInterInstallDelay = false;
    Future<void> installDownloadResult(Map<Object?, Object?> result) async {
      if (result['cancelled'] == true) {
        return;
      }
      if (result['downloadedFile'] == null && result['downloadedDir'] == null) {
        return;
      }
      if (!errors.appIdNames.containsKey(result['id'])) {
        try {
          if (settingsProvider.installerMode == 'legacy' &&
              needsLegacyInterInstallDelay) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          await installFn(
            result['id'] as String,
            result['willBeSilent'] as bool,
            result['downloadedFile'] as DownloadedApk?,
            result['downloadedDir'] as DownloadedDir?,
          );
        } catch (exception) {
          var id = result['id'] as String;
          if (exception is MalwareScanBlockedError) {
            malwareScanSkips.add((
              appName: apps[id]?.name ?? id,
              status: exception.status,
              detail: exception.detail,
            ));
          } else {
            errors.add(id, exception, appName: apps[id]?.name);
          }
        }
        if (settingsProvider.installerMode == 'legacy') {
          needsLegacyInterInstallDelay = true;
        }
      }
    }

    if (forceParallelDownloads || settingsProvider.parallelDownloads) {
      Future<void> installChain = Future.value();
      final downloadResultsByAppId = <String, Future<Map<Object?, Object?>>>{
        for (final appIdToProcess in appsToInstall)
          appIdToProcess: downloadFn(appIdToProcess),
      };
      final selfUpdateAppIds = appsToInstall
          .where((appIdToProcess) => isObtainiumAppId(appIdToProcess))
          .toList();

      // Downloads stay parallel, but installing this app before the rest can
      // stop the process and leave the remaining queue unfinished.
      Future<void> installWhenDownloaded(String appIdToProcess) async {
        final downloadResult = await downloadResultsByAppId[appIdToProcess]!;
        final completer = Completer<void>();
        installChain = installChain
            .then((_) async {
              try {
                await installDownloadResult(downloadResult);
              } finally {
                if (!completer.isCompleted) {
                  completer.complete();
                }
              }
            })
            .catchError((exception) {
              if (!completer.isCompleted) {
                completer.complete();
              }
            });
        await completer.future;
      }

      await Future.wait(
        appsToInstall
            .where((appIdToProcess) => !isObtainiumAppId(appIdToProcess))
            .map(installWhenDownloaded),
      );
      for (final appIdToProcess in selfUpdateAppIds) {
        await installDownloadResult(
          await downloadResultsByAppId[appIdToProcess]!,
        );
      }
    } else {
      for (final appIdToProcess in appsToInstall) {
        await installDownloadResult(await downloadFn(appIdToProcess));
      }
    }

    if (malwareScanSkips.isNotEmpty) {
      notificationsProvider?.notify(
        MalwareScanSkippedNotification(malwareScanSkips),
      );
    }

    if (errors.idsByErrorString.isNotEmpty) {
      throw errors;
    }

    return installedIds;
  }

  Future<List<String>> downloadAppAssets(
    List<String> appIds,
    BuildContext context, {
    bool forceParallelDownloads = false,
    ThemeData? dialogTheme,
  }) async {
    NotificationsProvider notificationsProvider = context
        .read<NotificationsProvider>();
    List<MapEntry<MapEntry<String, String>, App>> filesToDownload = [];
    for (var id in appIds) {
      if (apps[id] == null) {
        throw ObtainiumError(tr('appNotFound'));
      }
      MapEntry<String, String>? fileUrl;
      var refreshBeforeDownload =
          apps[id]!.app.additionalSettings['refreshBeforeDownload'] == true ||
          apps[id]!.app.apkUrls.isNotEmpty &&
              apps[id]!.app.apkUrls.first.value == 'placeholder';
      if (refreshBeforeDownload) {
        await checkUpdate(apps[id]!.app.id);
      }
      if (apps[id]!.app.apkUrls.isNotEmpty ||
          apps[id]!.app.otherAssetUrls.isNotEmpty) {
        if (!context.mounted) return [];
        MapEntry<String, String>? tempFileUrl = await confirmAppFileUrl(
          apps[id]!.app,
          context,
          true,
          evenIfSingleChoice: true,
          dialogTheme: dialogTheme,
        );
        if (tempFileUrl != null) {
          var s = SourceProvider().getSource(
            apps[id]!.app.url,
            overrideSource: apps[id]!.app.overrideSource,
          );
          var additionalSettingsPlusSourceConfig = {
            ...apps[id]!.app.additionalSettings,
            ...(await s.getSourceConfigValues(
              apps[id]!.app.additionalSettings,
              settingsProvider,
            )),
          };
          fileUrl = MapEntry(
            tempFileUrl.key,
            await s.assetUrlPrefetchModifier(
              await s.generalReqPrefetchModifier(
                tempFileUrl.value,
                additionalSettingsPlusSourceConfig,
              ),
              apps[id]!.app.url,
              additionalSettingsPlusSourceConfig,
            ),
          );
        }
      }
      if (fileUrl != null) {
        filesToDownload.add(MapEntry(fileUrl, apps[id]!.app));
      }
    }

    // Prepare to download+install Apps
    MultiAppMultiError errors = MultiAppMultiError();
    List<String> downloadedIds = [];

    Future<void> downloadFn(MapEntry<String, String> fileUrl, App app) async {
      try {
        final Uri? apkSaveTreeUri = await settingsProvider.getApkSaveDir(
          warnIfInaccessible: true,
        );

        final String downloadPath;
        final String fileName;
        if (apkSaveTreeUri != null) {
          downloadPath = apkDir.path;
          fileName = 'temp_manual_${app.id}_${fileUrl.hashCode}';
        } else {
          downloadPath = '${await getStorageRootPath()}/Download';
          fileName = sanitizeApkSaveDisplayName(fileUrl.key);
        }

        final File downloadedFile = await downloadFile(
          fileUrl.value,
          fileName,
          true,
          (double? progress) {
            notificationsProvider.notify(
              DownloadNotification(fileUrl.key, progress?.ceil() ?? 0),
            );
          },
          downloadPath,
          headers: await SourceProvider()
              .getSource(app.url, overrideSource: app.overrideSource)
              .getRequestHeaders(
                app.additionalSettings,
                fileUrl.value,
                forAPKDownload: isApk(fileUrl.key),
              ),
          useExisting: false,
          allowInsecure: app.additionalSettings['allowInsecure'] == true,
          logs: logs,
        );

        if (apkSaveTreeUri != null) {
          try {
            final String targetName = sanitizeApkSaveDisplayName(fileUrl.key);
            final bool copied = await _chunkedCopyApkToSafTree(
              downloadedFile,
              apkSaveTreeUri,
              targetName,
            );
            if (!copied) {
              throw ObtainiumError(tr('apkSaveFolderCopyFailed'));
            }
          } finally {
            if (downloadedFile.existsSync()) {
              try {
                downloadedFile.deleteSync();
              } catch (_) {}
            }
          }
        }

        notificationsProvider.notify(
          DownloadedNotification(fileUrl.key, fileUrl.value),
        );
      } catch (e) {
        errors.add(fileUrl.key, e);
      } finally {
        notificationsProvider.cancel(DownloadNotification(fileUrl.key, 0).id);
      }
    }

    if (forceParallelDownloads || !settingsProvider.parallelDownloads) {
      for (var urlWithApp in filesToDownload) {
        await downloadFn(urlWithApp.key, urlWithApp.value);
      }
    } else {
      await Future.wait(
        filesToDownload.map(
          (urlWithApp) => downloadFn(urlWithApp.key, urlWithApp.value),
        ),
      );
    }
    if (errors.idsByErrorString.isNotEmpty) {
      throw errors;
    }
    return downloadedIds;
  }

  Future<Directory> getAppsDir() async {
    Directory appsDir = Directory(
      '${(await getAppStorageDir()).path}/app_data',
    );
    if (!appsDir.existsSync()) {
      appsDir.createSync(recursive: true);
    }
    return appsDir;
  }

  bool isVersionDetectionPossible(AppInMemory? app) {
    if (app?.app == null) {
      return false;
    }
    // Read-only (type checks only) — use the template to avoid a per-call
    // source construction.
    var source = SourceProvider().getSourceTemplate(
      app!.app.url,
      overrideSource: app.app.overrideSource,
    );
    var naiveStandardVersionDetection =
        app.app.additionalSettings['naiveStandardVersionDetection'] == true ||
        source.naiveStandardVersionDetection;
    String? realInstalledVersion =
        app.app.additionalSettings['useVersionCodeAsOSVersion'] == true
        ? app.installedInfo?.versionCode.toString()
        : app.installedInfo?.versionName;
    bool isHTMLWithNoVersionDetection =
        (source is HTML &&
        (app.app.additionalSettings['versionExtractionRegEx'] as String?)
                ?.isNotEmpty !=
            true);
    bool isDirectAPKLink = source is DirectAPKLink;
    final bool hasCommitSha =
        realInstalledVersion != null &&
        (_commitHashLikeTokensFromVersion(realInstalledVersion).isNotEmpty ||
            _commitHashLikeTokensFromVersion(app.app.latestVersion).isNotEmpty);
    final bool releaseCommitShaAsVersion =
        app.app.additionalSettings['releaseCommitShaAsVersion'] == true;
    return app.app.additionalSettings['trackOnly'] != true &&
        app.app.additionalSettings['releaseDateAsVersion'] != true &&
        !isHTMLWithNoVersionDetection &&
        !isDirectAPKLink &&
        realInstalledVersion != null &&
        (reconcileVersionDifferences(
                  realInstalledVersion,
                  app.app.latestVersion,
                ) !=
                null ||
            naiveStandardVersionDetection ||
            hasCommitSha ||
            releaseCommitShaAsVersion);
  }

  // Given an App and it's on-device info...
  // Reconcile unexpected differences between its reported installed version, real installed version, and reported latest version
  App? getCorrectedInstallStatusAppIfPossible(
    App app,
    PackageInfo? installedInfo,
  ) {
    var modded = false;
    var trackOnly = app.additionalSettings['trackOnly'] == true;
    if (trackOnly &&
        !isTempId(app) &&
        app.additionalSettings['trackOnlyTemporaryPackageId'] == true) {
      app.additionalSettings['trackOnlyTemporaryPackageId'] = false;
      modded = true;
    }
    if (installedInfo?.lastUpdateTime != null) {
      if (app.additionalSettings['lastInstalledTime'] !=
          installedInfo!.lastUpdateTime) {
        app.additionalSettings['lastInstalledTime'] =
            installedInfo.lastUpdateTime;
        modded = true;
      }
    } else {
      if (app.additionalSettings.containsKey('lastInstalledTime')) {
        app.additionalSettings.remove('lastInstalledTime');
        modded = true;
      }
    }
    var versionDetectionIsStandard =
        app.additionalSettings['versionDetection'] == 'auto' ||
        app.additionalSettings['versionDetection'] == 'standard' ||
        app.additionalSettings['versionDetection'] == 'versionCode' ||
        app.additionalSettings['versionDetection'] == true ||
        app.additionalSettings['versionDetection'] == null;
    var naiveStandardVersionDetection =
        app.additionalSettings['naiveStandardVersionDetection'] == true ||
        SourceProvider().naiveStandardVersionDetectionForUrl(
          app.url,
          overrideSource: app.overrideSource,
        );
    String? realInstalledVersion =
        app.additionalSettings['useVersionCodeAsOSVersion'] == true
        ? installedInfo?.versionCode.toString()
        : installedInfo?.versionName;
    // FIRST, COMPARE THE APP'S REPORTED AND REAL INSTALLED VERSIONS, WHERE ONE IS NULL
    if (installedInfo == null && app.installedVersion != null && !trackOnly) {
      // App says it's installed but isn't really (and isn't track only) - set to not installed
      app.installedVersion = null;
      modded = true;
    } else if (realInstalledVersion != null && app.installedVersion == null) {
      // App says it's not installed but really is - set to installed and use real package versionName (or versionCode if chosen)
      app.installedVersion = versionDetectionIsStandard
          ? realInstalledVersion
          : app.latestVersion;
      if (trackOnly) {
        app.additionalSettings['trackOnlyUndeterminedInstalledVersion'] = false;
      }
      modded = true;
    }
    if (realInstalledVersion != null &&
        app.installedVersion != null &&
        realInstalledVersion != app.installedVersion &&
        !versionDetectionIsStandard) {
      // Version detection can be disabled because the APK manifest version is
      // not the source/release version. Still, an external install should be
      // reflected when the manifest version can be reconciled with the source
      // latest or the previous stored installed version; only unreconcilable
      // pairs keep the source pseudo-version.
      final correctedInstalledVersion =
          reconciledInstalledVersionForDisabledVersionDetection(
            realInstalledVersion,
            app.installedVersion!,
            app.latestVersion,
          );
      if (correctedInstalledVersion != null) {
        app.installedVersion = correctedInstalledVersion;
        modded = true;
      }
    }

    // Auto-heal format mismatch between stored installedVersion and the active useVersionCodeAsOSVersion setting
    if (realInstalledVersion != null &&
        app.installedVersion != null &&
        versionDetectionIsStandard) {
      bool formatMismatch = false;
      final isStoredPureInteger = RegExp(
        r'^\d+$',
      ).hasMatch(app.installedVersion!);
      final isRealPureInteger = RegExp(r'^\d+$').hasMatch(realInstalledVersion);
      if (app.additionalSettings['useVersionCodeAsOSVersion'] == true) {
        if (!isStoredPureInteger) {
          formatMismatch = true;
        }
      } else {
        if (isStoredPureInteger &&
            (!isRealPureInteger ||
                realInstalledVersion != app.installedVersion)) {
          formatMismatch = true;
        }
      }
      if (formatMismatch) {
        app.installedVersion = realInstalledVersion;
        modded = true;
      }
    }

    // SECOND, RECONCILE DIFFERENCES BETWEEN THE APP'S REPORTED AND REAL INSTALLED VERSIONS, WHERE NEITHER IS NULL
    if (realInstalledVersion != null &&
        realInstalledVersion != app.installedVersion &&
        versionDetectionIsStandard) {
      // App's reported version and real version don't match (and it uses standard version detection)
      var correctedInstalledVersion = reconcileVersionDifferences(
        realInstalledVersion,
        app.installedVersion!,
      );
      if (correctedInstalledVersion?.key == false) {
        app.installedVersion = correctedInstalledVersion!.value;
        modded = true;
      } else if (naiveStandardVersionDetection) {
        app.installedVersion = realInstalledVersion;
        modded = true;
      }
    }
    // THIRD, RECONCILE THE APP'S REPORTED INSTALLED AND LATEST VERSIONS
    if (app.installedVersion != null &&
        app.installedVersion != app.latestVersion &&
        versionDetectionIsStandard) {
      // App's reported installed and latest versions don't match (and it uses standard version detection)
      // If they share a standard format, make sure the App's reported installed version uses that format
      var correctedInstalledVersion = reconcileVersionDifferences(
        app.installedVersion!,
        app.latestVersion,
      );
      if (correctedInstalledVersion?.key == true) {
        app.installedVersion = correctedInstalledVersion!.value;
        modded = true;
      }
    }
    // FOURTH, DISABLE VERSION DETECTION IF ENABLED AND THE REPORTED/REAL INSTALLED VERSIONS ARE NOT STANDARDIZED
    // Skip for track-only: do not set installedVersion = latestVersion, so "update available" can still show
    // Do not disable when the real device version and latest are effectively equal (e.g. same commit hash).
    final bool realInstalledVersionMatchesLatest =
        realInstalledVersion != null &&
        versionsEffectivelyEqual(realInstalledVersion, app.latestVersion);
    final bool canAutoDisable =
        app.additionalSettings['useVersionCodeAsOSVersion'] != true &&
        (app.additionalSettings['versionDetection'] == 'auto' ||
            app.additionalSettings['versionDetection'] == true ||
            app.additionalSettings['versionDetection'] == null);
    if (canAutoDisable &&
        !trackOnly &&
        installedInfo != null &&
        versionDetectionIsStandard &&
        !realInstalledVersionMatchesLatest &&
        !isVersionDetectionPossible(
          AppInMemory(app, null, installedInfo, null),
        )) {
      app.additionalSettings['versionDetection'] = 'pseudo';
      app.installedVersion = app.latestVersion;
      logs.add('Could not reconcile version formats for: ${app.id}');
      modded = true;
    }

    if (clearRedundantSkippedLatestForApp(app)) {
      modded = true;
    }

    return modded ? app : null;
  }

  // When [silent] is true (foreground refreshes) we skip the loading-indicator
  // notify at the start and suppress the end notify when the app list is
  // unchanged — avoids two full rebuilds of every mounted page on every
  // lock/unlock or app-switch when nothing actually changed.
  Future<void> loadApps({
    String? singleId,
    bool silent = false,
    bool lightInstalledInfoFetch = false,
  }) async {
    await _loadingCompleter?.future;
    _loadingCompleter = Completer<void>();
    if (!silent) {
      loadingApps = true;
      notifyListeners();
    }
    await _purgeStalePendingRemovalFilesWithoutLiveDeferral();
    var sp = SourceProvider();
    List<List<String>> errors = [];
    // Always use the light (no signing-cert) flags. The load/reconcile path
    // only needs versionName / versionCode / lastUpdateTime via
    // getCorrectedInstallStatusAppIfPossible; enumerating signing certificates
    // for every device package is ~10× more expensive and nothing in this path
    // consumes them (cert hashes, if ever needed, are fetched on demand). The
    // [lightInstalledInfoFetch] param is retained for call-site compatibility
    // but no longer changes the flags. This keeps the cold start from stalling
    // on the single most expensive PackageManager call.
    var installedAppsData = await getAllInstalledInfo(light: true);
    // Index the device's installed packages once. The previous per-app
    // `firstWhere` was an O(tracked × installed) scan on the UI isolate.
    final Map<String, PackageInfo> installedInfoByPackage = {
      for (final info in installedAppsData)
        if (info.packageName != null) info.packageName!: info,
    };
    List<String> removedAppIds = [];
    bool anyAppModded = false;
    final DateTime? reuseWatermark = singleId == null
        ? _lastFullDiskLoadAt
        : null;
    final DateTime diskLoadStartedAt = DateTime.now();
    final List<FileSystemEntity> appDirItems = await (await getAppsDir())
        .list()
        .toList(); // Parse Apps from JSON
    // Parse in bounded chunks, yielding to the event loop between each so the UI
    // isolate can paint a frame and process touches during a large cold load.
    // (Incremental reuse already keeps resumes cheap; this targets first launch.)
    const int loadChunkSize = 16;
    for (
      int chunkStart = 0;
      chunkStart < appDirItems.length;
      chunkStart += loadChunkSize
    ) {
      final int chunkEnd = (chunkStart + loadChunkSize) < appDirItems.length
          ? chunkStart + loadChunkSize
          : appDirItems.length;
      await Future.wait(
        appDirItems.sublist(chunkStart, chunkEnd).map((item) async {
          if (!item.path.toLowerCase().endsWith('.json')) return;
          final String fileName = item.path.split('/').last;
          if (singleId != null &&
              fileName.toLowerCase() != '${singleId.toLowerCase()}.json') {
            return;
          }
          // App JSON files are named `${app.id}.json`, so the id can be
          // recovered from the filename without reading the file.
          final String idFromFile = fileName.substring(
            0,
            fileName.length - '.json'.length,
          );
          App? app;
          bool reused = false;
          // Incremental parse: reuse the in-memory app when its JSON file
          // has not changed since the last full load. Skips both the file
          // read and the synchronous decode. stat() runs on the dart:io
          // thread pool, off the UI isolate; the cold start (no watermark)
          // skips stat entirely and parses everything.
          final AppInMemory? existing = apps[idFromFile];
          if (existing != null && reuseWatermark != null) {
            try {
              final FileStat stat = await item.stat();
              if (stat.modified.isBefore(reuseWatermark)) {
                app = existing.app;
                reused = true;
              }
            } catch (_) {
              // stat failed — fall through to a normal parse.
            }
          }
          if (!reused) {
            try {
              app = App.fromJson(
                jsonDecode(await File(item.path).readAsString()),
              );
            } catch (err) {
              if (err is FormatException) {
                logs.add(
                  'Corrupt JSON when loading App (will be ignored): $err',
                );
                await item.rename('${item.path}.corrupt');
              } else {
                rethrow;
              }
            }
          }
          if (app != null) {
            if (!reused) {
              // Save the app to the in-memory list without grabbing any OS info first
              apps.update(
                app.id,
                (value) => AppInMemory(
                  app!,
                  value.downloadProgress,
                  value.installedInfo,
                  value.icon,
                ),
                ifAbsent: () => AppInMemory(app!, null, null, null),
              );
            }
            try {
              // Validate the app's source resolves (no invalid apps loaded).
              // Read-only — use the template to avoid constructing a source per
              // app on load.
              sp.getSourceTemplate(app.url, overrideSource: app.overrideSource);
              // Reconcile install status against the device package list.
              // This runs even for reused apps: the JSON may be unchanged
              // while the package was installed/uninstalled/updated
              // externally since the last load.
              final PackageInfo? installedInfo = installedInfoByPackage[app.id];
              var moddedApp = getCorrectedInstallStatusAppIfPossible(
                app,
                installedInfo,
              );
              if (moddedApp != null) {
                app = moddedApp;
                anyAppModded = true;
                // Note the app ID if it was uninstalled externally
                if (moddedApp.installedVersion == null) {
                  removedAppIds.add(moddedApp.id);
                }
              }
              // Update the app in memory with install info and corrections
              apps.update(
                app.id,
                (value) => AppInMemory(
                  app!,
                  value.downloadProgress,
                  installedInfo,
                  value.icon,
                ),
                ifAbsent: () => AppInMemory(app!, null, installedInfo, null),
              );
            } catch (e) {
              errors.add([app!.id, app.finalName, e.toString()]);
            }
          }
        }),
      );
      if (singleId == null && chunkEnd < appDirItems.length) {
        // Let the UI isolate breathe between chunks of a large cold load.
        await Future.delayed(Duration.zero);
      }
    }
    // Stamp the watermark only after a full load completed its parse pass, so
    // the next full load can reuse everything that hasn't changed since.
    if (singleId == null) {
      _lastFullDiskLoadAt = diskLoadStartedAt;
    }
    if (errors.isNotEmpty) {
      removeApps(errors.map((e) => e[0]).toList());
      NotificationsProvider().notify(
        AppsRemovedNotification(errors.map((e) => [e[1], e[2]]).toList()),
      );
    }
    // Delete externally uninstalled Apps if needed
    if (removedAppIds.isNotEmpty) {
      if (removedAppIds.isNotEmpty) {
        if (settingsProvider.removeOnExternalUninstall) {
          await removeApps(removedAppIds);
        }
      }
    }
    loadingApps = false;
    _loadingCompleter?.complete();
    _loadingCompleter = null;
    // In silent mode only notify if something actually changed — prevents
    // a redundant full rebuild on foreground events when the app list is
    // identical to what was already displayed.
    final bool dataChanged =
        anyAppModded || errors.isNotEmpty || removedAppIds.isNotEmpty;
    if (!silent || dataChanged) {
      _pendingUpdateCountDirty = true;
      notifyListeners();
    }
  }

  bool _bytesLookLikeRasterImage(Uint8List bytes) {
    if (bytes.length < 12) return false;
    // PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    // WebP (RIFF....WEBP)
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  bool _bytesLookLikePng(Uint8List bytes) {
    if (bytes.length < 8) return false;
    return bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A;
  }

  Future<void> _migrateUserIconsFromLegacyCacheDir() async {
    try {
      if (!await iconsCacheDir.exists()) return;
      for (final FileSystemEntity entity
          in await iconsCacheDir.list().toList()) {
        if (entity is! File) continue;
        final String fileName = entity.uri.pathSegments.last;
        if (!fileName.endsWith('.user.png')) continue;
        final File destination = File('${userAppIconsDir.path}/$fileName');
        if (await destination.exists()) {
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }
        try {
          await entity.copy(destination.path);
          await entity.delete();
        } catch (e) {
          logs.add('User icon migrate $fileName: $e');
        }
      }
    } catch (e) {
      logs.add('User icon migrate: $e');
    }
  }

  File _userAppIconPngFile(String appId) {
    return File('${userAppIconsDir.path}/$appId.user.png');
  }

  // Icons from getAppIcon() are often 192–432 px. We only display them at
  // ~40 dp, so 128 px is more than enough at any device pixel ratio. Resize
  // before writing to the disk cache so both the on-disk and in-memory
  // representations stay small. Uses ui.instantiateImageCodec which decodes
  // on a background thread — no main-isolate blocking.
  static const int _iconMaxCachePx = 128;

  Future<Uint8List> _resizeIconForCache(Uint8List bytes) async {
    try {
      final codec = await instantiateImageCodec(
        bytes,
        targetWidth: _iconMaxCachePx,
        targetHeight: _iconMaxCachePx,
      );
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ImageByteFormat.png,
      );
      frame.image.dispose();
      codec.dispose();
      if (byteData != null) return byteData.buffer.asUint8List();
    } catch (e) {
      logs.add('Icon resize failed, keeping original: $e');
    }
    return bytes;
  }

  Future<Uint8List?> _fetchIconFromUrl(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) return null;
      final res = await get(uri);
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      if (!_bytesLookLikeRasterImage(bytes)) return null;
      return bytes;
    } catch (e) {
      logs.add('Icon fetch failed for $url: $e');
      return null;
    }
  }

  /// Fetches the installed app's launcher icon via the platform channel,
  /// tolerating a missing package. When [PackageManager.getAppIcon] is called
  /// for an app whose package is no longer resolvable (e.g. uninstalled for the
  /// current user, or a track-only app that was never installed), the JNI hop
  /// throws `NameNotFoundException`. Previously this surfaced as an uncaught
  /// Dart error on every row warm. Here we swallow it, drop the stale
  /// [AppInMemory.installedInfo] so the dead lookup isn't retried, and let the
  /// caller fall back to the app's [App.iconUrl].
  Future<Uint8List?> _getInstalledAppIconSafely(String appId) async {
    final applicationInfo = apps[appId]?.installedInfo?.applicationInfo;
    if (applicationInfo == null) return null;
    try {
      return await applicationInfo.getAppIcon();
    } catch (e) {
      logs.add('App icon unavailable for $appId (clearing stale info): $e');
      final AppInMemory? existing = apps[appId];
      if (existing != null && existing.installedInfo != null) {
        apps.update(
          appId,
          (value) =>
              AppInMemory(value.app, value.downloadProgress, null, value.icon),
        );
      }
      return null;
    }
  }

  Future<void> updateAppIcon(String? appId, {bool ignoreCache = false}) async {
    if (appId == null || apps[appId] == null) return;

    final File userIconFile = _userAppIconPngFile(appId);
    if (userIconFile.existsSync()) {
      try {
        final Uint8List iconBytes = await userIconFile.readAsBytes();
        if (_bytesLookLikePng(iconBytes)) {
          final Uint8List? currentIcon = apps[appId]!.icon;
          if (currentIcon != null &&
              currentIcon.length == iconBytes.length &&
              listEquals(currentIcon, iconBytes)) {
            return;
          }
          apps.update(
            appId,
            (value) => AppInMemory(
              value.app,
              value.downloadProgress,
              value.installedInfo,
              iconBytes,
            ),
          );
          notifyListeners();
          return;
        }
      } catch (e) {
        logs.add('User icon load failed for $appId: $e');
      }
    }

    if (apps[appId]!.icon != null && !ignoreCache) return;

    var cachedIcon = File('${iconsCacheDir.path}/$appId.png');
    if (ignoreCache && cachedIcon.existsSync()) {
      await cachedIcon.delete();
    }
    var alreadyCached = cachedIcon.existsSync() && !ignoreCache;
    Uint8List? icon;
    if (alreadyCached) {
      icon = await cachedIcon.readAsBytes();
    } else {
      icon = await _getInstalledAppIconSafely(appId);
    }
    if (icon == null && !alreadyCached) {
      final url = apps[appId]!.app.iconUrl;
      if (url != null && url.isNotEmpty) {
        icon = await _fetchIconFromUrl(url);
      }
    }
    if (icon != null && !alreadyCached) {
      icon = await _resizeIconForCache(icon);
      await cachedIcon.writeAsBytes(icon);
    }
    if (ignoreCache) {
      apps.update(
        apps[appId]!.app.id,
        (value) => AppInMemory(
          value.app,
          value.downloadProgress,
          value.installedInfo,
          icon,
        ),
        ifAbsent: () => AppInMemory(
          apps[appId]!.app,
          null,
          apps[appId]?.installedInfo,
          icon,
        ),
      );
      notifyListeners();
      return;
    }
    if (icon != null) {
      apps.update(
        apps[appId]!.app.id,
        (value) => AppInMemory(
          apps[appId]!.app,
          value.downloadProgress,
          value.installedInfo,
          icon,
        ),
        ifAbsent: () => AppInMemory(
          apps[appId]!.app,
          null,
          apps[appId]?.installedInfo,
          icon,
        ),
      );
      notifyListeners();
    }
  }

  bool hasUserAppIconOverride(String appId) =>
      _userAppIconPngFile(appId).existsSync();

  bool validateUserAppIconPngBytes(Uint8List bytes) => _bytesLookLikePng(bytes);

  /// Icon bytes as shown when the per-app user PNG override is ignored (cache,
  /// installed app, or [App.iconUrl]). Does not read [userAppIconsDir] or mutate state.
  Future<Uint8List?> loadIconPreviewExcludingUserOverride(String appId) async {
    if (apps[appId] == null) return null;
    final File cachedIcon = File('${iconsCacheDir.path}/$appId.png');
    if (cachedIcon.existsSync()) {
      try {
        return await cachedIcon.readAsBytes();
      } catch (e) {
        logs.add('loadIconPreviewExcludingUserOverride cache: $e');
      }
    }
    Uint8List? icon = await _getInstalledAppIconSafely(appId);
    if (icon == null) {
      final String? url = apps[appId]!.app.iconUrl;
      if (url != null && url.isNotEmpty) {
        icon = await _fetchIconFromUrl(url);
      }
    }
    return icon;
  }

  /// Writes validated PNG bytes to [userAppIconsDir] and updates in-memory icon.
  /// Returns null on success, or a translated error string.
  Future<String?> applyUserAppIconPngBytes(
    String appId,
    Uint8List bytes,
  ) async {
    if (apps[appId] == null) {
      return tr('unexpectedError');
    }
    if (!_bytesLookLikePng(bytes)) {
      return tr('changeAppIconInvalidPng');
    }
    try {
      final File dest = _userAppIconPngFile(appId);
      await dest.writeAsBytes(bytes);
      apps.update(
        appId,
        (value) => AppInMemory(
          value.app,
          value.downloadProgress,
          value.installedInfo,
          bytes,
        ),
      );
      notifyListeners();
      return null;
    } catch (e) {
      logs.add('applyUserAppIconPngBytes: $e');
      return tr('unexpectedError');
    }
  }

  /// Copies a user-selected PNG into app storage ([userAppIconsDir]) and updates memory.
  /// Returns null on success, or a translated error string.
  Future<String?> setUserAppIconFromPngPath(
    String appId,
    String filePath,
  ) async {
    try {
      final File sourceFile = File(filePath);
      if (!sourceFile.existsSync()) {
        return tr('unexpectedError');
      }
      final Uint8List bytes = await sourceFile.readAsBytes();
      return applyUserAppIconPngBytes(appId, bytes);
    } catch (e) {
      logs.add('setUserAppIconFromPngPath: $e');
      return tr('unexpectedError');
    }
  }

  Future<void> resetAppIconToDefault(String appId) async {
    if (apps[appId] == null) return;
    final File userFile = _userAppIconPngFile(appId);
    if (userFile.existsSync()) {
      deleteFile(userFile);
    }
    await updateAppIcon(appId, ignoreCache: true);
  }

  Future<void> saveApps(
    List<App> apps, {
    bool attemptToCorrectInstallStatus = true,
    bool onlyIfExists = true,
    bool notifyListenersAfterSave = true,
    bool autoExportAfterSave = true,
    bool updateInstalledInfo = true,
    // When provided, install info is read from this device-package snapshot
    // instead of a per-app getInstalledInfo() call. getInstalledInfo()
    // enumerates ALL installed packages on every call, so for a bulk save (e.g.
    // an update-check scan of hundreds of apps) the caller should enumerate
    // once and pass the map here to avoid O(apps × devicePackages) work. The
    // map still carries the current device versions, so external-update
    // detection is preserved.
    Map<String, PackageInfo>? prefetchedInstalledInfo,
  }) async {
    attemptToCorrectInstallStatus = attemptToCorrectInstallStatus;
    if (!updateInstalledInfo) {
      bool didAnyInMemoryUpdate = false;
      for (final appToSave in apps) {
        final AppInMemory? cachedInMemory = this.apps[appToSave.id];
        if (cachedInMemory != null || !onlyIfExists) {
          var appCopy = appToSave.deepCopy();
          clearStaleSkippedLatestVersionInPlace(appCopy);
          final installedInfo = cachedInMemory?.installedInfo;
          final iconBytes = cachedInMemory?.icon;
          final String? cachedName = cachedInMemory?.app.name.trim();
          if (cachedName?.isNotEmpty == true &&
              cachedName != cachedInMemory?.app.id &&
              (appCopy.name.trim().isEmpty ||
                  appCopy.name.trim() == appCopy.id ||
                  appCopy.name.trim() == cachedName)) {
            appCopy.name = cachedInMemory!.app.name;
          }
          this.apps[appCopy.id] = AppInMemory(
            appCopy,
            cachedInMemory?.downloadProgress,
            installedInfo,
            iconBytes,
          );
          didAnyInMemoryUpdate = true;
        }
      }
      if (didAnyInMemoryUpdate && notifyListenersAfterSave) {
        _pendingUpdateCountDirty = true;
        notifyListeners();
      }
    }
    // For a multi-app save with no caller-supplied snapshot, enumerate device
    // packages ONCE here. Otherwise each app's getInstalledInfo() re-enumerates
    // every installed package — O(apps × devicePackages) of platform-thread
    // work that blocks touch dispatch. Mirrors the prefetch in checkUpdates;
    // the map carries current device versions, so external-update detection is
    // preserved. Skipped for single-app saves (one enumeration either way).
    Map<String, PackageInfo>? effectivePrefetch = prefetchedInstalledInfo;
    if (effectivePrefetch == null && updateInstalledInfo && apps.length > 1) {
      try {
        final List<PackageInfo> all = await getAllInstalledInfo(light: true);
        effectivePrefetch = {
          for (final info in all)
            if (info.packageName != null) info.packageName!: info,
        };
      } catch (e) {
        logs.add('Failed to prefetch installed info for bulk save: $e');
      }
    }
    await Future.wait(
      apps.map((appToSave) async {
        var app = appToSave.deepCopy();
        clearStaleSkippedLatestVersionInPlace(app);
        PackageInfo? info;
        Uint8List? icon;
        final AppInMemory? cachedInMemory = this.apps[app.id];
        if (!updateInstalledInfo && cachedInMemory != null) {
          info = cachedInMemory.installedInfo;
          icon = cachedInMemory.icon;
          final String cachedName = cachedInMemory.app.name.trim();
          if (cachedName.isNotEmpty &&
              cachedName != cachedInMemory.app.id &&
              (app.name.trim().isEmpty ||
                  app.name.trim() == app.id ||
                  app.name.trim() == cachedName)) {
            app.name = cachedInMemory.app.name;
          }
        } else {
          info = effectivePrefetch != null
              ? effectivePrefetch[app.id]
              : await getInstalledInfo(app.id);
          // Reuse the cached icon whenever the installed package
          // hasn't changed since the last save. [getAppIcon] returns large PNG
          // bytes via a JNI hop. The current versionName (from the prefetched
          // snapshot or a fresh lookup) is what lets us detect external
          // uninstalls / updates.
          final bool installedUnchanged =
              cachedInMemory != null &&
              cachedInMemory.icon != null &&
              cachedInMemory.installedInfo?.packageName == info?.packageName &&
              cachedInMemory.installedInfo?.versionName == info?.versionName &&
              cachedInMemory.installedInfo?.versionCode == info?.versionCode;
          if (installedUnchanged) {
            icon = cachedInMemory.icon;
          } else {
            try {
              // getAppIcon() is a JNI hop that throws NameNotFoundException if
              // the package vanished between getInstalledInfo() and here.
              icon = await info?.applicationInfo?.getAppIcon();
              if (icon != null) {
                icon = await _resizeIconForCache(icon);
                await File(
                  '${iconsCacheDir.path}/${app.id}.png',
                ).writeAsBytes(icon);
              }
            } catch (e) {
              logs.add('App icon unavailable while saving ${app.id}: $e');
              icon = null;
            }
            String? localizedLabel;
            if (Platform.isAndroid && info != null) {
              final labelsByPackageName =
                  await BulkImportService.getApplicationLabels([app.id]);
              localizedLabel = labelsByPackageName[app.id]?.trim();
              if (localizedLabel?.isNotEmpty != true) {
                info = effectivePrefetch != null
                    ? effectivePrefetch[app.id]
                    : await getInstalledInfo(app.id);
              }
            }
            final String? appLabel = localizedLabel?.isNotEmpty == true
                ? localizedLabel
                : info?.applicationInfo?.nonLocalizedLabel?.toString().trim();
            if (appLabel?.isNotEmpty == true) {
              app.name = appLabel!;
            }
          }
        }
        if (attemptToCorrectInstallStatus) {
          app = getCorrectedInstallStatusAppIfPossible(app, info) ?? app;
        }
        if (!onlyIfExists || this.apps.containsKey(app.id)) {
          String filePath = '${(await getAppsDir()).path}/${app.id}.json';
          await File(
            '$filePath.tmp',
          ).writeAsString(jsonEncode(app.toJson())); // #2089
          await File('$filePath.tmp').rename(filePath);
        }
        try {
          this.apps.update(
            app.id,
            (value) => AppInMemory(app, value.downloadProgress, info, icon),
            ifAbsent: onlyIfExists
                ? null
                : () => AppInMemory(app, null, info, icon),
          );
        } catch (e) {
          if (e is! ArgumentError || e.name != 'key') {
            rethrow;
          }
        }
      }),
    );
    if (notifyListenersAfterSave) {
      _pendingUpdateCountDirty = true;
      notifyListeners();
    }
    if (autoExportAfterSave) {
      export(isAuto: true);
    }
  }

  String _fileBasename(String rawPath) {
    final int unix = rawPath.lastIndexOf('/');
    final int win = rawPath.lastIndexOf('\\');
    final int index = unix > win ? unix : win;
    return index < 0 ? rawPath : rawPath.substring(index + 1);
  }

  /// Deletes APK cache, icon files, and optionally the main app JSON under [getAppsDir].
  Future<void> deleteObtainiumAppDiskData(
    List<String> appIds, {
    bool deleteMainJson = true,
  }) async {
    final List<FileSystemEntity> apkFiles = apkDir.listSync();
    final Directory appsDirectory = await getAppsDir();
    await Future.wait(
      appIds.map((String appId) async {
        if (deleteMainJson) {
          final File mainJson = File('${appsDirectory.path}/$appId.json');
          if (mainJson.existsSync()) {
            deleteFile(mainJson);
          }
        }
        for (final FileSystemEntity element in apkFiles) {
          if (_fileBasename(element.path).startsWith('$appId-')) {
            element.deleteSync(recursive: true);
          }
        }
        final File standardIconCache = File('${iconsCacheDir.path}/$appId.png');
        if (standardIconCache.existsSync()) {
          deleteFile(standardIconCache);
        }
        final File userIconStored = _userAppIconPngFile(appId);
        if (userIconStored.existsSync()) {
          deleteFile(userIconStored);
        }
        final File legacyUserIconInCache = File(
          '${iconsCacheDir.path}/$appId.user.png',
        );
        if (legacyUserIconInCache.existsSync()) {
          deleteFile(legacyUserIconInCache);
        }
      }),
    );
  }

  Future<void> removeApps(List<String> appIds) async {
    await deleteObtainiumAppDiskData(appIds, deleteMainJson: true);
    for (final String appId in appIds) {
      apps.remove(appId);
    }
    if (appIds.isNotEmpty) {
      _pendingUpdateCountDirty = true;
      notifyListeners();
      export(isAuto: true);
    }
  }

  Future<void> _moveAppJsonToPendingRemoval(String appId) async {
    final Directory appsDirectory = await getAppsDir();
    final Directory pendingDir = Directory(
      '${appsDirectory.path}/pending_removal',
    );
    if (!pendingDir.existsSync()) {
      pendingDir.createSync(recursive: true);
    }
    final File sourceJson = File('${appsDirectory.path}/$appId.json');
    if (!sourceJson.existsSync()) {
      return;
    }
    final File destinationJson = File('${pendingDir.path}/$appId.json');
    if (destinationJson.existsSync()) {
      deleteFile(destinationJson);
    }
    sourceJson.renameSync(destinationJson.path);
  }

  Future<void> _restoreAppJsonFromPendingRemoval(String appId) async {
    final Directory appsDirectory = await getAppsDir();
    final File pendingJson = File(
      '${appsDirectory.path}/pending_removal/$appId.json',
    );
    final File mainJson = File('${appsDirectory.path}/$appId.json');
    if (!pendingJson.existsSync()) {
      return;
    }
    if (mainJson.existsSync()) {
      deleteFile(pendingJson);
      return;
    }
    pendingJson.renameSync(mainJson.path);
  }

  /// Drops pending-removal JSON that no longer has an in-memory deferral (e.g. after process restart).
  Future<void> _purgeStalePendingRemovalFilesWithoutLiveDeferral() async {
    final Directory appsDirectory = await getAppsDir();
    final Directory pendingDir = Directory(
      '${appsDirectory.path}/pending_removal',
    );
    if (!pendingDir.existsSync()) {
      return;
    }
    for (final FileSystemEntity entity in pendingDir.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.json')) continue;
      final String fileName = _fileBasename(entity.path);
      final String appId = fileName.substring(0, fileName.length - 5);
      if (_deferredObtainiumSnapshots.containsKey(appId)) {
        continue;
      }
      deleteFile(entity);
      await deleteObtainiumAppDiskData([appId], deleteMainJson: false);
    }
  }

  Future<void> scheduleDeferredObtainiumRemovals(
    List<AppInMemory> rowSnapshots,
  ) async {
    for (final AppInMemory row in rowSnapshots) {
      final String appId = row.app.id;
      _deferredObtainiumSnapshots[appId] = row.deepCopy();
      await _moveAppJsonToPendingRemoval(appId);
      apps.remove(appId);
      _deferredObtainiumTimers[appId]?.cancel();
      _deferredObtainiumTimers[appId] = Timer(const Duration(seconds: 5), () {
        _finalizeDeferredObtainiumRemoval(appId);
      });
    }
    _pendingUpdateCountDirty = true;
    notifyListeners();
    export(isAuto: true);
  }

  Future<void> undoDeferredObtainiumRemovals(Set<String> appIds) async {
    for (final String appId in appIds) {
      _deferredObtainiumTimers[appId]?.cancel();
      _deferredObtainiumTimers.remove(appId);
      final AppInMemory? snapshot = _deferredObtainiumSnapshots.remove(appId);
      if (snapshot == null) continue;
      await _restoreAppJsonFromPendingRemoval(appId);
      final File mainJson = File('${(await getAppsDir()).path}/$appId.json');
      if (!mainJson.existsSync()) {
        await saveApps(
          [snapshot.app],
          onlyIfExists: false,
          updateInstalledInfo: false,
        );
      }
      apps[appId] = snapshot.deepCopy();
    }
    _pendingUpdateCountDirty = true;
    notifyListeners();
    export(isAuto: true);
  }

  Future<void> _finalizeDeferredObtainiumRemoval(String appId) async {
    _deferredObtainiumTimers.remove(appId)?.cancel();
    _deferredObtainiumSnapshots.remove(appId);
    final Directory appsDirectory = await getAppsDir();
    final File mainJson = File('${appsDirectory.path}/$appId.json');
    if (mainJson.existsSync()) {
      final File stalePending = File(
        '${appsDirectory.path}/pending_removal/$appId.json',
      );
      if (stalePending.existsSync()) {
        deleteFile(stalePending);
      }
      return;
    }
    final File pendingJson = File(
      '${appsDirectory.path}/pending_removal/$appId.json',
    );
    if (pendingJson.existsSync()) {
      deleteFile(pendingJson);
    }
    await deleteObtainiumAppDiskData([appId], deleteMainJson: false);
    export(isAuto: true);
    _pendingUpdateCountDirty = true;
    notifyListeners();
  }

  Future<void> changeTrackOnlyAppPackageId(
    String previousPackageId,
    String newPackageId,
  ) async {
    final trimmed = newPackageId.trim();
    if (!_androidApplicationIdPattern.hasMatch(trimmed)) {
      throw ObtainiumError(tr('invalidAndroidPackageId'));
    }
    if (trimmed == previousPackageId) {
      return;
    }
    if (!apps.containsKey(previousPackageId)) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    final existingApp = apps[previousPackageId]!.app;
    if (existingApp.additionalSettings['trackOnly'] != true) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    if (apps.containsKey(trimmed)) {
      throw ObtainiumError(tr('appAlreadyAdded'));
    }
    final updatedApp = existingApp.deepCopy();
    updatedApp.id = trimmed;
    if (!isTempId(updatedApp)) {
      updatedApp.additionalSettings['trackOnlyTemporaryPackageId'] = false;
    } else {
      updatedApp.additionalSettings['trackOnlyTemporaryPackageId'] = true;
    }
    await removeApps([previousPackageId]);
    await saveApps([updatedApp], onlyIfExists: false);
  }

  Future<RemoveAppsWithModalResult> removeAppsWithModal(
    BuildContext context,
    List<App> appsToAffect,
  ) async {
    final bool showUninstallOption = appsToAffect
        .where(
          (a) =>
              a.installedVersion != null &&
              a.additionalSettings['trackOnly'] != true,
        )
        .isNotEmpty;
    final Map<String, dynamic>? values = await showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return GeneratedFormModal(
          primaryActionColour: Theme.of(context).colorScheme.error,
          title: plural('removeAppQuestion', appsToAffect.length),
          items: !showUninstallOption
              ? []
              : [
                  [
                    GeneratedFormSwitch(
                      'rmAppEntry',
                      label: tr('removeFromObtainX'),
                      defaultValue: true,
                    ),
                  ],
                  [
                    GeneratedFormSwitch(
                      'uninstallApp',
                      label: tr('uninstallFromDevice'),
                    ),
                  ],
                ],
          initValid: true,
        );
      },
    );
    if (values == null) {
      return RemoveAppsWithModalResult.cancelled;
    }
    final bool uninstall =
        values['uninstallApp'] == true && showUninstallOption;
    final bool removeFromObtainx =
        !showUninstallOption || values['rmAppEntry'] == true;
    if (!removeFromObtainx && !uninstall) {
      return RemoveAppsWithModalResult.cancelled;
    }
    final List<AppInMemory> rowSnapshots = appsToAffect
        .map((App a) => apps[a.id]!.deepCopy())
        .toList();
    if (uninstall) {
      for (final App appEntry in appsToAffect) {
        if (appEntry.installedVersion != null) {
          uninstallApp(appEntry.id);
        }
      }
    }
    if (removeFromObtainx) {
      if (uninstall) {
        await removeApps(appsToAffect.map((e) => e.id).toList());
        return const RemoveAppsWithModalResult._(
          confirmed: true,
          removedFromObtainiumImmediately: true,
          obtainiumEntryRemovedOrScheduled: true,
        );
      } else {
        await scheduleDeferredObtainiumRemovals(rowSnapshots);
        return RemoveAppsWithModalResult._(
          confirmed: true,
          deferredUndoAppIds: appsToAffect.map((App e) => e.id).toSet(),
          obtainiumEntryRemovedOrScheduled: true,
        );
      }
    }
    if (uninstall) {
      await saveApps(appsToAffect, attemptToCorrectInstallStatus: false);
      return const RemoveAppsWithModalResult._(confirmed: true);
    }
    return RemoveAppsWithModalResult.cancelled;
  }

  Future<void> openAppSettings(String appId) async {
    if (settingsProvider.openAppInfoInAppManager) {
      try {
        final AndroidIntent intent = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: 'app-manager://details?id=$appId',
        );
        await intent.launch();
        return;
      } catch (_) {
        // Fall back to standard settings if App Manager is not installed or launch fails
      }
    }
    final AndroidIntent intent = AndroidIntent(
      action: 'action_application_details_settings',
      data: 'package:$appId',
    );
    await intent.launch();
  }

  void addMissingCategories(SettingsProvider settingsProvider) {
    var cats = settingsProvider.categories;
    apps.forEach((key, value) {
      for (var c in value.app.categories) {
        if (!cats.containsKey(c)) {
          cats[c] = generateRandomLightColor().toARGB32();
        }
      }
    });
    settingsProvider.setCategories(cats, appsProvider: this);
  }

  Future<App?> checkUpdate(
    String appId, {
    bool notifyListenersAfterSave = true,
    bool autoExportAfterSave = true,
    Map<String, PackageInfo>? prefetchedInstalledInfo,
  }) async {
    App? currentApp = apps[appId]!.app;
    // Pause update checks until the user resolves a pending repo rename.
    if (currentApp.hasPendingRepoRename) {
      return null;
    }
    SourceProvider sourceProvider = SourceProvider();
    App newApp = await sourceProvider.getApp(
      sourceProvider.getSource(
        currentApp.url,
        overrideSource: currentApp.overrideSource,
      ),
      currentApp.url,
      Map<String, dynamic>.from(currentApp.additionalSettings),
      currentApp: currentApp,
    );
    final App? latestAppBeforeSave = apps[appId]?.app;
    if (latestAppBeforeSave == null) {
      return null;
    }
    if (latestAppBeforeSave.url != currentApp.url ||
        latestAppBeforeSave.overrideSource != currentApp.overrideSource) {
      return null;
    }
    final App appToSave = latestAppBeforeSave.deepCopy()
      ..author = newApp.author
      ..name = newApp.name
      ..latestVersion = newApp.latestVersion
      ..apkUrls = newApp.apkUrls
      ..preferredApkIndex =
          latestAppBeforeSave.preferredApkIndex < newApp.apkUrls.length
          ? latestAppBeforeSave.preferredApkIndex
          : newApp.preferredApkIndex
      ..lastUpdateCheck = newApp.lastUpdateCheck
      ..releaseDate = newApp.releaseDate
      ..changeLog = newApp.changeLog
      ..otherAssetUrls = newApp.otherAssetUrls
      ..iconUrl = newApp.iconUrl
      ..rawLatestVersionFromSource = newApp.rawLatestVersionFromSource
      ..rawApkNamesFromSource = newApp.rawApkNamesFromSource
      ..rawReleaseTitlesFromSource = newApp.rawReleaseTitlesFromSource
      ..apkSizeBytes = newApp.apkSizeBytes
      ..pendingRepoRenameUrl = newApp.pendingRepoRenameUrl
      ..latestIsReproducible = newApp.latestIsReproducible
      ..latestReproducibleStatus = newApp.latestReproducibleStatus
      ..latestAttestationStatus = newApp.latestAttestationStatus;
    await saveApps(
      [appToSave],
      notifyListenersAfterSave: notifyListenersAfterSave,
      autoExportAfterSave: autoExportAfterSave,
      prefetchedInstalledInfo: prefetchedInstalledInfo,
    );
    if (apkMirrorSizeDebug && currentApp.url.contains('apkmirror.com')) {
      final App? savedApp = apps[appId]?.app;
      try {
        await LogsProvider(runDefaultClear: false).add(
          'OBTAINX-APK-SIZE-DEBUG AppsProvider: checkUpdate id=$appId oldLatest=${currentApp.latestVersion} newLatest=${newApp.latestVersion} returnedSize=${newApp.apkSizeBytes?.toString() ?? "<null>"} savedSize=${savedApp?.apkSizeBytes?.toString() ?? "<null>"} savedInstalled=${savedApp?.installedVersion ?? "<null>"} savedTrackOnly=${savedApp?.additionalSettings['trackOnly'] == true}',
          level: LogLevels.debug,
        );
      } catch (_) {
        // Debug logging must never affect update checks.
      }
    }
    return appToSave.latestVersion != currentApp.latestVersion
        ? appToSave
        : null;
  }

  List<String> getAppsSortedByUpdateCheckTime({
    DateTime? ignoreAppsCheckedAfter,
    bool onlyCheckInstalledOrTrackOnlyApps = false,
  }) {
    List<String> appIds = apps.values
        .where(
          (app) =>
              app.app.lastUpdateCheck == null ||
              ignoreAppsCheckedAfter == null ||
              app.app.lastUpdateCheck!.isBefore(ignoreAppsCheckedAfter),
        )
        .where((app) {
          if (!onlyCheckInstalledOrTrackOnlyApps) {
            return true;
          } else {
            return app.app.installedVersion != null ||
                app.app.additionalSettings['trackOnly'] == true;
          }
        })
        .where((app) => app.app.additionalSettings['onDemandOnly'] != true)
        .map((e) => e.app.id)
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

  Future<List<App>> checkUpdates({
    DateTime? ignoreAppsCheckedAfter,
    bool throwErrorsForRetry = false,
    List<String>? specificIds,
    SettingsProvider? sp,
  }) async {
    SettingsProvider settingsProvider = sp ?? this.settingsProvider;
    List<App> updates = [];
    MultiAppMultiError errors = MultiAppMultiError();
    if (!gettingUpdates) {
      gettingUpdates = true;
      try {
        late List<String> appIds;
        if (specificIds != null) {
          appIds = specificIds.where((id) => apps.containsKey(id)).toList();
          if (settingsProvider.onlyCheckInstalledOrTrackOnlyApps) {
            appIds = appIds.where((id) {
              final AppInMemory appInMemory = apps[id]!;
              return appInMemory.app.installedVersion != null ||
                  appInMemory.app.additionalSettings['trackOnly'] == true;
            }).toList();
          }
          if (ignoreAppsCheckedAfter != null) {
            final DateTime cutoff = ignoreAppsCheckedAfter;
            appIds = appIds.where((id) {
              final last = apps[id]!.app.lastUpdateCheck;
              return last == null || last.isBefore(cutoff);
            }).toList();
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
            ignoreAppsCheckedAfter: ignoreAppsCheckedAfter,
            onlyCheckInstalledOrTrackOnlyApps:
                settingsProvider.onlyCheckInstalledOrTrackOnlyApps,
          );
        }
        var nextAppIndex = 0;
        var appSaveCompleted = false;
        var lastProgressNotificationAt = DateTime.fromMicrosecondsSinceEpoch(0);
        const progressNotificationInterval = Duration(milliseconds: 250);
        final maxParallelUpdateChecks =
            await _maxParallelUpdateChecksForDevice();
        final workerCount = appIds.length < maxParallelUpdateChecks
            ? appIds.length
            : maxParallelUpdateChecks;
        // Enumerate installed packages ONCE for the whole scan. Each per-app
        // saveApps would otherwise call getInstalledInfo(), which re-enumerates
        // every device package — O(apps × devicePackages). The snapshot still
        // holds current device versions, so external updates are still detected.
        final List<PackageInfo> allInstalledForScan = await getAllInstalledInfo(
          light: true,
        );
        final Map<String, PackageInfo> prefetchedInstalledInfo = {
          for (final info in allInstalledForScan)
            if (info.packageName != null) info.packageName!: info,
        };

        Future<void> runUpdateCheckWorker() async {
          while (true) {
            final currentAppIndex = nextAppIndex;
            if (currentAppIndex >= appIds.length) {
              return;
            }
            nextAppIndex += 1;
            final appId = appIds[currentAppIndex];
            App? newApp;
            try {
              newApp = await checkUpdate(
                appId,
                notifyListenersAfterSave: false,
                autoExportAfterSave: false,
                prefetchedInstalledInfo: prefetchedInstalledInfo,
              );
              appSaveCompleted = true;
              final now = DateTime.now();
              if (now.difference(lastProgressNotificationAt) >=
                  progressNotificationInterval) {
                lastProgressNotificationAt = now;
                notifyListeners();
              }
            } catch (error) {
              if ((error is RateLimitError || error is SocketException) &&
                  throwErrorsForRetry) {
                rethrow;
              }
              if (error is RepositoryRenamedError) {
                await updatePendingRepoRename(appId, error.newUrl);
              } else {
                errors.add(appId, error, appName: apps[appId]?.name);
              }
            }
            if (newApp != null) {
              updates.add(newApp);
            }
          }
        }

        await Future.wait(
          List.generate(workerCount, (unusedIndex) => runUpdateCheckWorker()),
          eagerError: true,
        );
        if (appSaveCompleted) {
          notifyListeners();
          export(isAuto: true);
        }
      } finally {
        gettingUpdates = false;
      }
    }
    if (errors.idsByErrorString.isNotEmpty) {
      var res = <String, dynamic>{};
      res['errors'] = errors;
      res['updates'] = updates;
      throw res;
    }
    return updates;
  }

  /// Returns app ids with an installable or attention-needed update.
  /// When [includeVersionOrderUncertain] is false (default), only
  /// [appHasActionableUpdate] counts for installed apps so "update all" and
  /// background install do not treat ambiguous ordering as a known behind-latest case.
  /// When true, [versionOrderUncertainUpdate] apps are included too (e.g. tab badge).
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
      if (excludeOnDemandOnly &&
          app.additionalSettings['onDemandOnly'] == true) {
        continue;
      }
      final installed = app.installedVersion;
      final latest = app.latestVersion;

      if (installed == null) {
        if (!(nonInstalledOnly || !installedOnly)) continue;
        if (installed != latest) {
          updateAppIds.add(app.id);
        }
      } else {
        if (!(installedOnly || !nonInstalledOnly)) continue;
        if (appHasActionableUpdate(app) ||
            (includeVersionOrderUncertain &&
                versionOrderUncertainUpdate(app))) {
          updateAppIds.add(app.id);
        }
      }
    }
    return updateAppIds;
  }

  Map<String, dynamic> generateExportJSON({
    List<String>? appIds,
    int? overrideExportSettings,
    SettingsProvider? sp,
  }) {
    final SettingsProvider exportSettingsProvider = sp ?? settingsProvider;
    Map<String, dynamic> finalExport = {};
    finalExport['apps'] = apps.values
        .where((e) {
          if (appIds == null) {
            return true;
          } else {
            return appIds.contains(e.app.id);
          }
        })
        .map((e) {
          final appJson = e.app.toJson();
          final Map<String, dynamic> additionalSettings =
              Map<String, dynamic>.from(
                jsonDecode(appJson['additionalSettings'] as String),
              );
          final List<dynamic>? folderIds =
              additionalSettings['folderIds'] as List?;
          if (folderIds != null && folderIds.isNotEmpty) {
            final Map<String, String> folderNames = {};
            final existingFolders = exportSettingsProvider.appFolders;
            for (final folderId in folderIds) {
              for (final f in existingFolders) {
                if (f.id == folderId) {
                  folderNames[folderId] = f.name;
                  break;
                }
              }
            }
            additionalSettings['folderNames'] = folderNames;
            appJson['additionalSettings'] = jsonEncode(additionalSettings);
          }
          return appJson;
        })
        .toList();
    int shouldExportSettings = exportSettingsProvider.exportSettings;
    if (overrideExportSettings != null) {
      shouldExportSettings = overrideExportSettings;
    }
    if (shouldExportSettings > 0) {
      var settingsValueKeys = exportSettingsProvider.prefs?.getKeys();
      if (shouldExportSettings < 2) {
        settingsValueKeys?.removeWhere((k) => k.endsWith('-creds'));
      }
      finalExport['settings'] = Map<String, Object?>.fromEntries(
        (settingsValueKeys
                ?.map(
                  (key) =>
                      MapEntry(key, exportSettingsProvider.prefs?.get(key)),
                )
                .toList()) ??
            [],
      );
    }
    return finalExport;
  }

  Future<String?> export({
    bool pickOnly = false,
    isAuto = false,
    SettingsProvider? sp,
  }) async {
    // Auto exports get debounced - bursts of saveApps calls coalesce into a
    // single trailing-edge fire 2s after the last call. Manual exports
    // (pickOnly or user-triggered Save) bypass the debounce and run inline
    // because the user is awaiting the returned path.
    if (isAuto && !pickOnly) {
      _autoExportTimer?.cancel();
      _autoExportTimer = Timer(_autoExportDebounce, () {
        _autoExportTimer = null;
        // Fire-and-forget: existing isAuto callers don't await the result.
        unawaited(_runExport(pickOnly: false, isAuto: true, sp: sp));
      });
      return null;
    }
    return _runExport(pickOnly: pickOnly, isAuto: isAuto, sp: sp);
  }

  /// Performs the actual export work: SAF directory checks, optional cleanup
  /// of prior auto-export files, JSON encoding (off-isolate), and the SAF
  /// createFile write. Called inline for manual exports and via the debounce
  /// timer for auto exports.
  Future<String?> _runExport({
    required bool pickOnly,
    required bool isAuto,
    SettingsProvider? sp,
  }) async {
    try {
      SettingsProvider settingsProvider = sp ?? this.settingsProvider;
      var exportDir = await settingsProvider.getExportDir(
        warnIfInaccessible: true,
      );
      if (isAuto) {
        if (settingsProvider.autoExportOnChanges != true) {
          return null;
        }
        if (exportDir == null) {
          return null;
        }
        List<dynamic> files = [];
        try {
          files = await saf
              .listFiles(exportDir, columns: [saf.DocumentFileColumn.id])
              .where((f) => f.uri.pathSegments.last.endsWith('-auto.json'))
              .toList();
        } catch (e) {
          await LogsProvider(runDefaultClear: false).add(
            'Failed to list files in auto-export directory: $e',
            level: LogLevels.error,
          );
        }
        if (files.isNotEmpty) {
          for (var f in files) {
            try {
              await saf.delete(f.uri);
            } catch (e) {
              await LogsProvider(runDefaultClear: false).add(
                'Failed to delete old auto-export file: $e',
                level: LogLevels.error,
              );
            }
          }
        }
      }
      if (exportDir == null || pickOnly) {
        await settingsProvider.pickExportDir();
        exportDir = await settingsProvider.getExportDir(
          warnIfInaccessible: true,
        );
      }
      if (exportDir == null) {
        return null;
      }
      String? returnPath;
      if (!pickOnly) {
        Map<String, dynamic> finalExport = generateExportJSON(
          sp: settingsProvider,
        );
        // Heavy work - JsonEncoder.withIndent over the whole apps+settings
        // payload plus utf8 encoding - is run on a background isolate so the
        // UI thread stays responsive even when the export is large.
        final Uint8List bytes = await Isolate.run<Uint8List>(() {
          const JsonEncoder encoder = JsonEncoder.withIndent('    ');
          return Uint8List.fromList(utf8.encode(encoder.convert(finalExport)));
        }, debugName: 'export-json-encode');
        var result = await saf.createFile(
          exportDir,
          displayName:
              '${tr('obtainiumExportHyphenatedLowercase')}-${DateTime.now().toIso8601String().replaceAll(':', '-')}${isAuto ? '-auto' : ''}.json',
          mimeType: 'application/json',
          bytes: bytes,
        );
        if (result == null) {
          throw ObtainiumError(tr('unexpectedError'));
        }
        returnPath = exportDir.pathSegments
            .join('/')
            .replaceFirst('tree/primary:', '/');
      }
      return returnPath;
    } catch (e, stack) {
      debugPrint('Export failed: $e\n$stack');
      try {
        await LogsProvider(
          runDefaultClear: false,
        ).add('Export failed: $e', level: LogLevels.error);
      } catch (_) {}
      return null;
    }
  }

  Future<MapEntry<List<App>, bool>> import(String appsJSON) async {
    var decodedJSON = jsonDecode(appsJSON);
    var newFormat = decodedJSON is! List;
    List<App> importedApps =
        ((newFormat ? decodedJSON['apps'] : decodedJSON) as List<dynamic>)
            .map((e) => App.fromJson(e))
            .toList();

    final List<AppFolder> existingFolders = List<AppFolder>.from(
      settingsProvider.appFolders,
    );
    final Map<String, String> backupIdToTargetId = {};
    final List<AppFolder> foldersToCreate = [];

    // Parse backup folders from settings if they exist
    final Map<String, String> backupFolderIdToName = {};
    if (newFormat &&
        decodedJSON['settings'] != null &&
        decodedJSON['settings']['appFolders'] != null) {
      try {
        final list =
            jsonDecode(decodedJSON['settings']['appFolders'] as String)
                as List<dynamic>;
        for (var e in list) {
          final folder = AppFolder.fromJson(e as Map<String, dynamic>);
          backupFolderIdToName[folder.id] = folder.name;
        }
      } catch (_) {}
    }

    // Gather folder names from imported apps' folderNames map
    for (final app in importedApps) {
      final Map<dynamic, dynamic>? appFolderNames =
          app.additionalSettings['folderNames'] as Map?;
      if (appFolderNames != null) {
        appFolderNames.forEach((key, val) {
          if (key is String && val is String) {
            backupFolderIdToName.putIfAbsent(key, () => val);
          }
        });
      }
    }

    // Match or create folders
    backupFolderIdToName.forEach((backupId, name) {
      AppFolder? match;
      for (final f in existingFolders) {
        if (f.name.trim().toLowerCase() == name.trim().toLowerCase()) {
          match = f;
          break;
        }
      }

      if (match != null) {
        backupIdToTargetId[backupId] = match.id;
      } else {
        final newFolder = AppFolder(id: backupId, name: name);
        foldersToCreate.add(newFolder);
        backupIdToTargetId[backupId] = backupId;
      }
    });

    if (foldersToCreate.isNotEmpty) {
      existingFolders.addAll(foldersToCreate);
      settingsProvider.appFolders = existingFolders;
    }

    // Rewrite app folderIds and folderNames maps
    for (final app in importedApps) {
      final folderIds = folderIdsForApp(app);
      final Map<String, dynamic> updatedFolderNames = {};

      if (folderIds.isNotEmpty) {
        final List<String> updatedFolderIds = [];
        for (final id in folderIds) {
          final String? targetId = backupIdToTargetId[id];
          if (targetId != null) {
            updatedFolderIds.add(targetId);
            final String? folderName = backupFolderIdToName[id];
            if (folderName != null) {
              updatedFolderNames[targetId] = folderName;
            }
          } else {
            AppFolder? match;
            for (final f in existingFolders) {
              if (f.id == id) {
                match = f;
                break;
              }
            }
            if (match != null) {
              updatedFolderIds.add(id);
              updatedFolderNames[id] = match.name;
            }
          }
        }
        app.additionalSettings['folderIds'] = updatedFolderIds;
      }

      final excludedFolderIds = excludedFolderIdsForApp(app);
      if (excludedFolderIds.isNotEmpty) {
        final List<String> updatedExcludedIds = [];
        for (final id in excludedFolderIds) {
          final String? targetId = backupIdToTargetId[id];
          if (targetId != null) {
            updatedExcludedIds.add(targetId);
          } else {
            if (existingFolders.any((f) => f.id == id)) {
              updatedExcludedIds.add(id);
            }
          }
        }
        app.additionalSettings['excludedFolderIds'] = updatedExcludedIds;
      }

      app.additionalSettings['folderNames'] = updatedFolderNames;
    }

    await _loadingCompleter?.future;
    await Future.wait(
      importedApps.map((a) async {
        var installedInfo = await getInstalledInfo(a.id, printErr: false);
        a.installedVersion =
            a.additionalSettings['useVersionCodeAsOSVersion'] == true
            ? installedInfo?.versionCode.toString()
            : installedInfo?.versionName;
      }),
    );
    await saveApps(importedApps, onlyIfExists: false);
    notifyListeners();

    if (newFormat && decodedJSON['settings'] != null) {
      var settingsMap = decodedJSON['settings'] as Map<String, Object?>;
      settingsMap.forEach((key, value) {
        if (key == 'appFolders') {
          // Skip folder settings as we already merged/saved them
          return;
        }
        if (value is int) {
          settingsProvider.prefs?.setInt(key, value);
        } else if (value is double) {
          settingsProvider.prefs?.setDouble(key, value);
        } else if (value is bool) {
          settingsProvider.prefs?.setBool(key, value);
        } else if (value is List) {
          settingsProvider.prefs?.setStringList(
            key,
            value.map((e) => e as String).toList(),
          );
        } else {
          settingsProvider.prefs?.setString(key, value as String);
        }
      });
      await settingsProvider.initializeSettings();
    }
    return MapEntry<List<App>, bool>(
      importedApps,
      newFormat && decodedJSON['settings'] != null,
    );
  }

  @override
  void dispose() {
    for (final cancelToken in _downloadCancelTokens.values) {
      cancelToken.cancel();
    }
    _downloadCancelTokens.clear();
    _progressNotifyTimer?.cancel();
    for (final Timer timer in _deferredObtainiumTimers.values) {
      timer.cancel();
    }
    _deferredObtainiumTimers.clear();
    // Pending JSON under pending_removal/ is left on disk; the next [loadApps]
    // run commits removal via [_purgeStalePendingRemovalFilesWithoutLiveDeferral]
    // when no in-memory deferral tracks that id.
    if (_receivesThirdPartyInstallEvents) {
      installer.registerThirdPartyInstallPackageChangedCallback(null);
      _receivesThirdPartyInstallEvents = false;
    }
    foregroundSubscription?.cancel();
    super.dispose();
  }

  /// After a new app is in [apps] (e.g. [saveApps] with [onlyIfExists]: false),
  /// adds it to every folder whose rule matches and saves again if anything changed.
  /// Prefer the live [App] from [apps] so post-save corrections apply to rule matching.
  Future<void> assignMatchingFoldersToAppIfNeeded(App app) async {
    final sourceProvider = SourceProvider();
    final resolvedSource = sourceProvider
        .getSource(app.url, overrideSource: app.overrideSource)
        .runtimeType
        .toString();
    bool changed = false;
    for (final folder in settingsProvider.appFolders) {
      if (folder.rule == null) continue;
      if (excludedFolderIdsForApp(app).contains(folder.id)) continue;
      if (folder.rule!.matches(app, resolvedSource: resolvedSource)) {
        addAppToFolder(app, folder.id, folder.name);
        changed = true;
      }
    }
    if (changed) {
      await saveApps([app], updateInstalledInfo: false);
    }
  }

  Future<List<List<String>>> addAppsByURL(
    List<String> urls, {
    AppSource? sourceOverride,
  }) async {
    List<dynamic> results = await SourceProvider().getAppsByURLNaive(
      urls,
      alreadyAddedUrls: apps.values.map((e) => e.app.url).toList(),
      sourceOverride: sourceOverride,
    );
    List<App> pps = results[0];
    Map<String, dynamic> errorsMap = results[1];
    for (var app in pps) {
      if (apps.containsKey(app.id)) {
        errorsMap.addAll({app.id: tr('appAlreadyAdded')});
      } else {
        await saveApps([app], onlyIfExists: false);
        final liveApp = apps[app.id]?.app;
        if (liveApp != null) {
          await assignMatchingFoldersToAppIfNeeded(liveApp);
        }
      }
    }
    List<List<String>> errors = errorsMap.keys
        .map((e) => [e, errorsMap[e].toString()])
        .toList();
    return errors;
  }
}

class AppFilePicker extends StatefulWidget {
  const AppFilePicker({
    super.key,
    required this.app,
    this.initVal,
    this.archs,
    this.pickAnyAsset = false,
  });

  final App app;
  final MapEntry<String, String>? initVal;
  final List<String>? archs;
  final bool pickAnyAsset;

  @override
  State<AppFilePicker> createState() => _AppFilePickerState();
}

class _AppFilePickerState extends State<AppFilePicker> {
  MapEntry<String, String>? fileUrl;

  @override
  Widget build(BuildContext context) {
    fileUrl ??= widget.initVal;
    var urlsToSelectFrom = widget.app.apkUrls;
    if (widget.pickAnyAsset) {
      urlsToSelectFrom = [...urlsToSelectFrom, ...widget.app.otherAssetUrls];
    }
    return AlertDialog(
      scrollable: true,
      title: Text(
        widget.pickAnyAsset
            ? tr('selectX', args: [lowerCaseIfEnglish(tr('releaseAsset'))])
            : tr('pickAnAPK'),
      ),
      contentPadding: appDialogContentPadding,
      content: Column(
        children: [
          urlsToSelectFrom.length > 1
              ? Text(
                  tr('appHasMoreThanOnePackage', args: [widget.app.finalName]),
                )
              : const SizedBox.shrink(),
          const SizedBox(height: 16),
          RadioGroup<String>(
            groupValue: fileUrl!.value,
            onChanged: (String? val) {
              if (val == null) return;
              setState(() {
                fileUrl = urlsToSelectFrom.where((e) => e.value == val).first;
              });
            },
            child: Column(
              children: urlsToSelectFrom
                  .map(
                    (u) => RadioListTile<String>(
                      title: Text(u.key),
                      value: u.value,
                    ),
                  )
                  .toList(),
            ),
          ),
          if (widget.archs != null) const SizedBox(height: 16),
          if (widget.archs != null)
            Text(
              widget.archs!.length == 1
                  ? tr('deviceSupportsXArch', args: [widget.archs![0]])
                  : tr('deviceSupportsFollowingArchs') +
                        list2FriendlyString(
                          widget.archs!.map((e) => '\'$e\'').toList(),
                        ),
              style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(null);
          },
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: () {
            hapticSelection();
            Navigator.of(context).pop(fileUrl);
          },
          child: Text(tr('continue')),
        ),
      ],
    );
  }
}

class APKOriginWarningDialog extends StatefulWidget {
  const APKOriginWarningDialog({
    super.key,
    required this.sourceUrl,
    required this.apkUrl,
  });

  final String sourceUrl;
  final String apkUrl;

  @override
  State<APKOriginWarningDialog> createState() => _APKOriginWarningDialogState();
}

class _APKOriginWarningDialogState extends State<APKOriginWarningDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(tr('warning')),
      contentPadding: appDialogContentPadding,
      content: Text(
        tr(
          'sourceIsXButPackageFromYPrompt',
          args: [
            Uri.parse(widget.sourceUrl).host,
            Uri.parse(widget.apkUrl).host,
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(null);
          },
          child: Text(tr('cancel')),
        ),
        TextButton(
          onPressed: () {
            hapticSelection();
            Navigator.of(context).pop(true);
          },
          child: Text(tr('continue')),
        ),
      ],
    );
  }
}

/// Shown for an interactive install when a VirusTotal scan comes back
/// [malwareScanStatusFlagged] or [malwareScanStatusError] - the human decides
/// whether to proceed. Returns true for "Install anyway", null for "Cancel
/// install" (mirrors [APKOriginWarningDialog]'s pop convention).
class MalwareScanWarningDialog extends StatelessWidget {
  const MalwareScanWarningDialog({
    super.key,
    required this.appName,
    required this.status,
    required this.detail,
    required this.reportUrl,
  });

  final String appName;
  final String status;
  final String? detail;
  final String? reportUrl;

  @override
  Widget build(BuildContext context) {
    final bool flagged = status == malwareScanStatusFlagged;
    return AlertDialog(
      scrollable: true,
      title: Text(
        tr(flagged ? 'malwareScanFlaggedTitle' : 'malwareScanErrorTitle'),
      ),
      contentPadding: appDialogContentPadding,
      content: Text(
        detail ??
            tr(flagged ? 'malwareScanFlaggedTitle' : 'malwareScanErrorTitle'),
      ),
      actions: [
        if (reportUrl != null)
          TextButton(
            onPressed: () {
              launchUrlString(reportUrl!, mode: LaunchMode.externalApplication);
            },
            child: Text(tr('virusTotalViewReport')),
          ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(null);
          },
          child: Text(tr('cancelInstall')),
        ),
        TextButton(
          onPressed: () {
            hapticSelection();
            Navigator.of(context).pop(true);
          },
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(tr('installAnyway')),
        ),
      ],
    );
  }
}

/// Background updater function
///
/// @param `List<MapEntry<String, int>>?` toCheck: The appIds to check for updates (with the number of previous attempts made per appid) (defaults to all apps)
///
/// @param `List<String>?` toInstall: The appIds to attempt to update (if empty - which is the default - all pending updates are taken)
///
/// When toCheck is empty, the function is in "install mode" (else it is in "update mode").
/// In update mode, all apps in toCheck are checked for updates (in parallel).
/// If an update is available and it cannot be installed silently, the user is notified of the available update.
/// If there are any errors, we recursively call the same function with retry count for the relevant apps decremented (if zero, the user is notified).
///
/// Once all update checks are complete, the task is run again in install mode.
/// In this mode, all pending silent updates are downloaded (in parallel) and installed in the background.
/// If there is an error, the user is notified.
///
Future<void> bgUpdateCheck(String taskId, Map<String, dynamic>? params) async {
  debugPrint('BG task started $taskId: ${params.toString()}');
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await loadTranslations();

  LogsProvider logs = LogsProvider();
  NotificationsProvider notificationsProvider = NotificationsProvider();
  SettingsProvider settingsProvider = SettingsProvider();
  await settingsProvider.initializeSettings();
  AppsProvider appsProvider = AppsProvider(
    isBg: true,
    sharedSettings: settingsProvider,
  );
  await appsProvider.loadApps();

  int maxAttempts = 4;
  int maxRetryWaitSeconds = 5;

  var netResult = await (Connectivity().checkConnectivity());
  if (netResult.contains(ConnectivityResult.none) ||
      netResult.isEmpty ||
      (netResult.contains(ConnectivityResult.vpn) && netResult.length == 1)) {
    logs.add('BG update task: No network.');
    return;
  }

  params ??= {};

  if (taskId == 'obtainium_interactive_retry') {
    params['toCheck'] = [];
  }

  bool firstEverUpdateTask =
      DateTime.fromMillisecondsSinceEpoch(
        0,
      ).compareTo(appsProvider.settingsProvider.lastCompletedBGCheckTime) ==
      0;

  List<MapEntry<String, int>> toCheck = <MapEntry<String, int>>[
    ...(params['toCheck']
            ?.map(
              (entry) => MapEntry<String, int>(
                entry['key'] as String,
                entry['value'] as int,
              ),
            )
            .toList() ??
        appsProvider
            .getAppsSortedByUpdateCheckTime(
              ignoreAppsCheckedAfter: params['toCheck'] == null
                  ? firstEverUpdateTask
                        ? null
                        : appsProvider.settingsProvider.lastCompletedBGCheckTime
                  : null,
              onlyCheckInstalledOrTrackOnlyApps: appsProvider
                  .settingsProvider
                  .onlyCheckInstalledOrTrackOnlyApps,
            )
            .map((e) => MapEntry(e, 0))),
  ];
  List<MapEntry<String, int>> toInstall = <MapEntry<String, int>>[
    ...(params['toInstall']
            ?.map(
              (entry) => MapEntry<String, int>(
                entry['key'] as String,
                entry['value'] as int,
              ),
            )
            .toList() ??
        (<List<MapEntry<String, int>>>[])),
  ];

  var networkRestricted =
      appsProvider.settingsProvider.bgUpdatesOnWiFiOnly &&
      !netResult.contains(ConnectivityResult.wifi) &&
      !netResult.contains(ConnectivityResult.ethernet);

  var chargingRestricted =
      appsProvider.settingsProvider.bgUpdatesWhileChargingOnly &&
      (await Battery().batteryState) != BatteryState.charging;

  if (networkRestricted) {
    logs.add('BG update task: Network restriction in effect.');
  }

  if (chargingRestricted) {
    logs.add('BG update task: Charging restriction in effect.');
  }

  if (toCheck.isNotEmpty) {
    // Task is either in update mode or install mode
    // If in update mode, we check for updates.
    // We divide the results into 4 groups:
    // - toNotify - Apps with updates that the user will be notified about (can't be silently installed)
    // - toThrow - Apps with update check errors that the user will be notified about (no retry)
    // After grouping the updates, we take care of toNotify and toThrow first
    // Then we run the function again in install mode (toCheck is empty)

    var enoughTimePassed =
        appsProvider.settingsProvider.updateInterval != 0 &&
        appsProvider.settingsProvider.lastCompletedBGCheckTime
            .add(
              Duration(minutes: appsProvider.settingsProvider.updateInterval),
            )
            .isBefore(DateTime.now());
    if (!enoughTimePassed) {
      debugPrint(
        'BG update task: Too early for another check (last check was ${appsProvider.settingsProvider.lastCompletedBGCheckTime.toIso8601String()}, interval is ${appsProvider.settingsProvider.updateInterval}).',
      );
      return;
    }

    logs.add('BG update task: Started (${toCheck.length}).');

    // Init. vars.
    List<App> updates = []; // All updates found (silent and non-silent)
    List<App> toNotify =
        []; // All non-silent updates that the user will be notified about
    List<MapEntry<String, int>> toRetry =
        []; // All apps that got errors while checking
    var retryAfterXSeconds = 0;
    MultiAppMultiError?
    errors; // All errors including those that will lead to a retry
    MultiAppMultiError toThrow =
        MultiAppMultiError(); // All errors that will not lead to a retry, just a notification
    CheckingUpdatesNotification notif = CheckingUpdatesNotification(
      plural('apps', toCheck.length),
    ); // The notif. to show while checking

    try {
      // Check for updates
      notificationsProvider.notify(notif, cancelExisting: true);
      updates = await appsProvider.checkUpdates(
        specificIds: toCheck.map((e) => e.key).toList(),
        sp: appsProvider.settingsProvider,
      );
    } catch (e) {
      if (e is Map) {
        updates = e['updates'];
        errors = e['errors'];
        errors!.rawErrors.forEach((key, err) {
          logs.add(
            'BG update task: Got error on checking for $key \'${err.toString()}\'.',
          );

          var toCheckApp = toCheck.where((element) => element.key == key).first;
          if (toCheckApp.value < maxAttempts) {
            toRetry.add(MapEntry(toCheckApp.key, toCheckApp.value + 1));
            // Next task interval is based on the error with the longest retry time
            int minRetryIntervalForThisApp = err is RateLimitError
                ? (err.remainingMinutes * 60)
                : e is ClientException
                ? (15 * 60)
                : (toCheckApp.value + 1);
            if (minRetryIntervalForThisApp > maxRetryWaitSeconds) {
              minRetryIntervalForThisApp = maxRetryWaitSeconds;
            }
            if (minRetryIntervalForThisApp > retryAfterXSeconds) {
              retryAfterXSeconds = minRetryIntervalForThisApp;
            }
          } else {
            if (err is! RateLimitError) {
              toThrow.add(key, err, appName: errors?.appIdNames[key]);
            }
          }
        });
      } else {
        // We don't expect to ever get here in any situation so no need to catch (but log it in case)
        logs.add('Fatal error in BG update task: ${e.toString()}');
        rethrow;
      }
    } finally {
      notificationsProvider.cancel(notif.id);
    }

    // Filter out updates that will be installed silently (the rest go into toNotify).
    // Only notify for definite behind-latest updates, not version-order-unclear rows
    // (those are surfaced on the app page and apps list without a push ping).
    for (var i = 0; i < updates.length; i++) {
      final App checkedApp = updates[i];
      if (!appHasActionableUpdate(checkedApp)) {
        continue;
      }
      var canInstallSilently = await appsProvider.canInstallSilently(
        checkedApp,
      );
      if (networkRestricted || chargingRestricted || !canInstallSilently) {
        if (checkedApp.additionalSettings['skipUpdateNotifications'] != true) {
          logs.add(
            'BG update task notifying for ${checkedApp.id} (networkRestricted $networkRestricted, chargingRestricted: $chargingRestricted, canInstallSilently: $canInstallSilently).',
          );
          toNotify.add(checkedApp);
        }
      }
    }

    // Send the update notification(s) — keep track-only apps (watched but not
    // installed by ObtainX) in their own notification so users can tell them apart
    // from updates ObtainX can install.
    if (toNotify.isNotEmpty) {
      final installableUpdates = toNotify
          .where((a) => a.additionalSettings['trackOnly'] != true)
          .toList();
      final trackOnlyUpdates = toNotify
          .where((a) => a.additionalSettings['trackOnly'] == true)
          .toList();
      if (installableUpdates.isNotEmpty) {
        notificationsProvider.notify(UpdateNotification(installableUpdates));
      }
      if (trackOnlyUpdates.isNotEmpty) {
        notificationsProvider.notify(
          TrackOnlyUpdateNotification(trackOnlyUpdates),
        );
      }
    }

    // Send the error notifications (grouped by error string)
    if (toThrow.rawErrors.isNotEmpty) {
      for (var element in toThrow.idsByErrorString.entries) {
        notificationsProvider.notify(
          ErrorCheckingUpdatesNotification(
            errors!.errorsAppsString(element.key, element.value),
            id: Random().nextInt(10000),
          ),
        );
      }
    }
    // if there are update checks to retry, schedule a retry task
    logs.add('BG update task: Done checking for updates.');
    if (toRetry.isNotEmpty) {
      logs.add(
        'BG update task $taskId: Will retry in $retryAfterXSeconds seconds (${toRetry.length} to retry, ${toInstall.length} to install).',
      );
      return await bgUpdateCheck(taskId, {
        'toCheck': toRetry
            .map((entry) => {'key': entry.key, 'value': entry.value})
            .toList(),
        'toInstall': toInstall
            .map((entry) => {'key': entry.key, 'value': entry.value})
            .toList(),
      });
    } else {
      // If there are no more update checks, call the function in install mode
      logs.add(
        'BG update task: Done checking for updates (${toRetry.length} to retry, ${toInstall.length} to install).',
      );
      return await bgUpdateCheck(taskId, {
        'toCheck': [],
        'toInstall': toInstall
            .map((entry) => {'key': entry.key, 'value': entry.value})
            .toList(),
      });
    }
  } else {
    // In install mode...
    if (await NativeFeatures.isDeviceInteractive()) {
      logs.add(
        'BG install task: Device is active (screen on). Postponing background installations.',
      );
      try {
        await BackgroundFetch.scheduleTask(
          TaskConfig(
            taskId: 'obtainium_interactive_retry',
            delay: 15 * 60 * 1000, // 15 minutes
            periodic: false,
            forceAlarmManager: true,
            stopOnTerminate: false,
            enableHeadless: true,
          ),
        );
        logs.add(
          'BG install task: Scheduled obtainium_interactive_retry task.',
        );
      } catch (err) {
        logs.add('BG install task: Failed to schedule retry task: $err');
      }
      return;
    }

    // If you haven't explicitly been given updates to install, grab all available silent updates
    logs.add('BG install task: Started (${toInstall.length}).');
    if (toInstall.isEmpty && !networkRestricted && !chargingRestricted) {
      var temp = appsProvider.findExistingUpdates(
        installedOnly: true,
        excludeOnDemandOnly: true,
      );
      for (var i = 0; i < temp.length; i++) {
        if (await appsProvider.canInstallSilently(
          appsProvider.apps[temp[i]]!.app,
        )) {
          toInstall.add(MapEntry(temp[i], 0));
        }
      }
    }
    if (toInstall.isNotEmpty) {
      var tempObtArr = toInstall.where(
        (element) => isObtainiumAppId(element.key),
      );
      if (tempObtArr.isNotEmpty) {
        // Move obtainium to the end of the list as it must always install last
        var obt = tempObtArr.first;
        toInstall = moveStrToEndMapEntryWithCount(toInstall, obt);
      }
      // Loop through all updates and install each
      try {
        await appsProvider.downloadAndInstallLatestApps(
          toInstall.map((e) => e.key).toList(),
          null,
          notificationsProvider: notificationsProvider,
          forceParallelDownloads: true,
        );
      } catch (e) {
        if (e is MultiAppMultiError) {
          e.idsByErrorString.forEach((key, value) {
            notificationsProvider.notify(
              ErrorInstallingUpdatesNotification(
                e.errorsAppsString(key, value),
              ),
            );
          });
        } else {
          // We don't expect to ever get here in any situation so no need to catch (but log it in case)
          logs.add('Fatal error in BG install task: ${e.toString()}');
          rethrow;
        }
      }
      logs.add('BG install task: Done installing updates.');
    }
  }
  appsProvider.settingsProvider.lastCompletedBGCheckTime = DateTime.now();
}
