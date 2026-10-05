// Core app data models shared by providers, sources, and UI.

import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/models/typed_settings.dart';
import 'package:obtainium/providers/app_json_migration.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/services/apk_filter_service.dart';
import 'package:obtainium/version/version_detection_mode.dart';

// ------------------------------------------------------------------------
// AppNames
// ------------------------------------------------------------------------

class AppNames {
  final String author;
  final String name;

  const AppNames(this.author, this.name);

  AppNames copyWith({String? author, String? name}) {
    return AppNames(author ?? this.author, name ?? this.name);
  }
}

// ------------------------------------------------------------------------
// APKDetails
// ------------------------------------------------------------------------

class APKDetails {
  String version;

  /// Source version code associated with the preferred APK, when available.
  final int? versionCode;

  /// Version codes by asset name, retained through filtering and variant choice.
  final Map<String, int> versionCodesByAsset;
  List<MapEntry<String, String>> apkUrls;

  /// Not final: [AppNames] is immutable, so sources that refine a name after
  /// fetching assign `details.names = details.names.copyWith(...)`.
  AppNames names;
  final DateTime? releaseDate;
  String? changeLog;
  final List<MapEntry<String, String>> allAssetUrls;

  /// Optional absolute URL to a raster app icon from the source (for non-installed apps).
  String? iconUrl;

  /// Release names/titles seen before title filtering (RegEx assist).
  List<String> rawReleaseTitleCandidates;
  final String? releaseTitle;

  /// Size of the preferred APK in bytes, if known at update-check time (e.g. GitHub releases).
  int? apkSizeBytes;
  bool? isReproducible;
  String? reproducibleStatus;
  String? attestationStatus;

  APKDetails(
    this.version,
    this.apkUrls,
    this.names, {
    this.versionCode,
    this.versionCodesByAsset = const {},
    this.releaseDate,
    this.changeLog,
    this.allAssetUrls = const [],
    this.iconUrl,
    this.rawReleaseTitleCandidates = const [],
    this.releaseTitle,
    this.apkSizeBytes,
    this.isReproducible,
    this.reproducibleStatus,
    this.attestationStatus,
  });

  /// Copies every field, so a source that rewrites one of them (e.g. GitLab's
  /// artifact URLs) never drops the ObtainX-only metadata. Nullable fields use
  /// a sentinel, so passing `null` clears them.
  APKDetails copyWith({
    String? version,
    List<MapEntry<String, String>>? apkUrls,
    AppNames? names,
    Object? versionCode = _sentinel,
    Map<String, int>? versionCodesByAsset,
    Object? releaseDate = _sentinel,
    Object? changeLog = _sentinel,
    List<MapEntry<String, String>>? allAssetUrls,
    Object? iconUrl = _sentinel,
    List<String>? rawReleaseTitleCandidates,
    Object? releaseTitle = _sentinel,
    Object? apkSizeBytes = _sentinel,
    Object? isReproducible = _sentinel,
    Object? reproducibleStatus = _sentinel,
    Object? attestationStatus = _sentinel,
  }) {
    return APKDetails(
      version ?? this.version,
      apkUrls ?? this.apkUrls,
      names ?? this.names,
      versionCode: versionCode == _sentinel
          ? this.versionCode
          : versionCode as int?,
      versionCodesByAsset: versionCodesByAsset ?? this.versionCodesByAsset,
      releaseDate: releaseDate == _sentinel
          ? this.releaseDate
          : releaseDate as DateTime?,
      changeLog: changeLog == _sentinel ? this.changeLog : changeLog as String?,
      allAssetUrls: allAssetUrls ?? this.allAssetUrls,
      iconUrl: iconUrl == _sentinel ? this.iconUrl : iconUrl as String?,
      rawReleaseTitleCandidates:
          rawReleaseTitleCandidates ?? this.rawReleaseTitleCandidates,
      releaseTitle: releaseTitle == _sentinel
          ? this.releaseTitle
          : releaseTitle as String?,
      apkSizeBytes: apkSizeBytes == _sentinel
          ? this.apkSizeBytes
          : apkSizeBytes as int?,
      isReproducible: isReproducible == _sentinel
          ? this.isReproducible
          : isReproducible as bool?,
      reproducibleStatus: reproducibleStatus == _sentinel
          ? this.reproducibleStatus
          : reproducibleStatus as String?,
      attestationStatus: attestationStatus == _sentinel
          ? this.attestationStatus
          : attestationStatus as String?,
    );
  }
}

/// Converts a list of [MapEntry] pairs into a 2D list of strings for JSON encoding.
List<List<String>> stringMapListTo2DList(
  List<MapEntry<String, String>> mapList,
) => mapList.map((e) => [e.key, e.value]).toList();

/// Converts a 2D list (decoded from JSON) back into a list of [MapEntry] pairs.
List<MapEntry<String, String>> assumed2DlistToStringMapList(
  List<dynamic> arr,
) => arr.map((e) => MapEntry(e[0] as String, e[1] as String)).toList();

// ------------------------------------------------------------------------
// App
// ------------------------------------------------------------------------

class App {
  final String id;

  /// Stable identity for this one listing, letting a single package be tracked
  /// from more than one store at once.
  ///
  /// Null for a package's only listing, whose key is just [id] - so records
  /// written before multi-store tracking keep their file names. A second
  /// listing of the same package gets a value like `com.example.app@FDroid`,
  /// assigned once when it is added.
  ///
  /// Deliberately **not** derived from the tracked source: swapping a listing
  /// from GitHub to F-Droid rewrites [url] and [overrideSource], and a
  /// source-derived key would silently re-point the listing at a different
  /// record (losing the original and breaking the swap back).
  final String? listingId;
  final String url;
  final String author;
  final String name;
  final String? installedVersion;
  final String latestVersion;
  final List<MapEntry<String, String>> apkUrls;
  final List<MapEntry<String, String>> otherAssetUrls;
  final int preferredApkIndex;
  final Map<String, dynamic> additionalSettings;
  final DateTime? lastUpdateCheck;
  final bool pinned;
  final List<String> categories;
  final DateTime? releaseDate;
  final String? changeLog;
  final String? overrideSource;
  final bool allowIdChange;
  final String? pendingRepoRenameUrl;

  /// Absolute URL to a raster app icon from the source (for non-installed apps).
  final String? iconUrl;

  /// Size of the preferred APK in bytes, if known at update-check time.
  final int? apkSizeBytes;

  /// Version string from the source before extraction / release-date/title
  /// replacement. Used for helpers and RegEx assist; omitted from JSON when null.
  final String? rawLatestVersionFromSource;

  /// APK row keys (e.g. filenames) before [filterApks], newline-separated. RegEx assist.
  final String? rawApkNamesFromSource;

  /// Release title candidates before title filter, newline-separated. RegEx assist.
  final String? rawReleaseTitlesFromSource;

  final bool? latestIsReproducible;
  final String? latestReproducibleStatus;

  /// Version code whose exact APK verification produced the stored status.
  final int? latestReproducibleVersionCode;
  final String? latestAttestationStatus;
  final String? latestMalwareScanStatus;
  final String? latestMalwareScanDetail;
  final String? latestMalwareScanReportUrl;

  const App({
    required this.id,
    this.listingId,
    required this.url,
    required this.author,
    required this.name,
    this.installedVersion,
    required this.latestVersion,
    this.apkUrls = const [],
    this.otherAssetUrls = const [],
    required this.preferredApkIndex,
    required this.additionalSettings,
    this.lastUpdateCheck,
    this.pinned = false,
    this.categories = const [],
    this.releaseDate,
    this.changeLog,
    this.overrideSource,
    this.allowIdChange = false,
    this.pendingRepoRenameUrl,
    this.iconUrl,
    this.apkSizeBytes,
    this.rawLatestVersionFromSource,
    this.rawApkNamesFromSource,
    this.rawReleaseTitlesFromSource,
    this.latestIsReproducible,
    this.latestReproducibleStatus,
    this.latestReproducibleVersionCode,
    this.latestAttestationStatus,
    this.latestMalwareScanStatus,
    this.latestMalwareScanDetail,
    this.latestMalwareScanReportUrl,
  });

  @override
  String toString() {
    return 'ID: $id URL: $url INSTALLED: $installedVersion LATEST: $latestVersion APK: $apkUrls PREFERREDAPK: $preferredApkIndex ADDITIONALSETTINGS: ${additionalSettings.toString()} LASTCHECK: ${lastUpdateCheck.toString()} PINNED $pinned';
  }

  /// Key identifying this listing in [AppsProvider.apps] and on disk.
  String get listingKey => listingId ?? id;

  bool get hasPendingRepoRename =>
      pendingRepoRenameUrl != null && pendingRepoRenameUrl!.isNotEmpty;

  String? get overrideName {
    final override = settings.getStringOrNull('appName')?.trim();
    if (override == null || override.isEmpty) {
      return null;
    }
    final String sourceName = name.trim();
    // Ignore an override that merely restates the package id (either the exact
    // app id, or anything shaped like a package id) when the source already
    // provides a readable name.
    if (override == id && sourceName.isNotEmpty && sourceName != id) {
      return null;
    }
    if (looksLikeAndroidPackageId(override) &&
        sourceName.isNotEmpty &&
        sourceName != override) {
      return null;
    }
    return override;
  }

  String get finalName {
    return overrideName ?? name;
  }

  String? get overrideAuthor {
    final a = settings.getStringOrNull('appAuthor');
    return a != null && a.trim().isNotEmpty ? a : null;
  }

  String get finalAuthor {
    return overrideAuthor ?? author;
  }

  /// Type-safe accessor for [additionalSettings].
  TypedSettings get settings => TypedSettings(additionalSettings);

  /// This app's parsed version-detection mode.
  VersionDetectionMode get versionDetectionMode =>
      VersionDetectionMode.fromStored(additionalSettings['versionDetection']);

  /// Whether the stored versions are meant to be comparable with the device's —
  /// i.e. every mode except [VersionDetectionMode.pseudo].
  bool get usesStandardVersionDetection =>
      versionDetectionMode != VersionDetectionMode.pseudo;

  /// Whether the device's `versionCode` (not `versionName`) is this app's real
  /// installed version.
  ///
  /// `useVersionCodeAsOSVersion` is a derived boolean kept in sync with the
  /// [VersionDetectionMode.versionCode] dropdown option, so either one being set
  /// means the same thing. Reading only the boolean (as install-status
  /// reconciliation used to) compares `versionName` against a stored version
  /// code whenever the two fall out of sync.
  bool get usesVersionCodeAsOsVersion =>
      versionDetectionMode == VersionDetectionMode.versionCode ||
      settings.getBool('useVersionCodeAsOSVersion');

  App copyWith({
    String? id,
    Object? listingId = _sentinel,
    String? url,
    String? author,
    String? name,
    Object? installedVersion = _sentinel,
    String? latestVersion,
    List<MapEntry<String, String>>? apkUrls,
    List<MapEntry<String, String>>? otherAssetUrls,
    int? preferredApkIndex,
    Map<String, dynamic>? additionalSettings,
    Object? lastUpdateCheck = _sentinel,
    bool? pinned,
    List<String>? categories,
    Object? releaseDate = _sentinel,
    Object? changeLog = _sentinel,
    Object? overrideSource = _sentinel,
    bool? allowIdChange,
    Object? pendingRepoRenameUrl = _sentinel,
    Object? iconUrl = _sentinel,
    Object? apkSizeBytes = _sentinel,
    Object? rawLatestVersionFromSource = _sentinel,
    Object? rawApkNamesFromSource = _sentinel,
    Object? rawReleaseTitlesFromSource = _sentinel,
    Object? latestIsReproducible = _sentinel,
    Object? latestReproducibleStatus = _sentinel,
    Object? latestReproducibleVersionCode = _sentinel,
    Object? latestAttestationStatus = _sentinel,
    Object? latestMalwareScanStatus = _sentinel,
    Object? latestMalwareScanDetail = _sentinel,
    Object? latestMalwareScanReportUrl = _sentinel,
  }) {
    return App(
      id: id ?? this.id,
      listingId: listingId == _sentinel
          ? this.listingId
          : listingId?.toString(),
      url: url ?? this.url,
      author: author ?? this.author,
      name: name ?? this.name,
      installedVersion: installedVersion == _sentinel
          ? this.installedVersion
          : installedVersion?.toString(),
      latestVersion: latestVersion ?? this.latestVersion,
      apkUrls: apkUrls ?? List<MapEntry<String, String>>.from(this.apkUrls),
      otherAssetUrls:
          otherAssetUrls ??
          List<MapEntry<String, String>>.from(this.otherAssetUrls),
      preferredApkIndex: preferredApkIndex ?? this.preferredApkIndex,
      additionalSettings:
          additionalSettings ??
          Map<String, dynamic>.from(this.additionalSettings),
      lastUpdateCheck: lastUpdateCheck == _sentinel
          ? this.lastUpdateCheck
          : lastUpdateCheck as DateTime?,
      pinned: pinned ?? this.pinned,
      categories: categories ?? List<String>.from(this.categories),
      releaseDate: releaseDate == _sentinel
          ? this.releaseDate
          : releaseDate as DateTime?,
      changeLog: changeLog == _sentinel
          ? this.changeLog
          : changeLog?.toString(),
      overrideSource: overrideSource == _sentinel
          ? this.overrideSource
          : overrideSource?.toString(),
      allowIdChange: allowIdChange ?? this.allowIdChange,
      pendingRepoRenameUrl: pendingRepoRenameUrl == _sentinel
          ? this.pendingRepoRenameUrl
          : pendingRepoRenameUrl?.toString(),
      iconUrl: iconUrl == _sentinel ? this.iconUrl : iconUrl?.toString(),
      apkSizeBytes: apkSizeBytes == _sentinel
          ? this.apkSizeBytes
          : apkSizeBytes as int?,
      rawLatestVersionFromSource: rawLatestVersionFromSource == _sentinel
          ? this.rawLatestVersionFromSource
          : rawLatestVersionFromSource?.toString(),
      rawApkNamesFromSource: rawApkNamesFromSource == _sentinel
          ? this.rawApkNamesFromSource
          : rawApkNamesFromSource?.toString(),
      rawReleaseTitlesFromSource: rawReleaseTitlesFromSource == _sentinel
          ? this.rawReleaseTitlesFromSource
          : rawReleaseTitlesFromSource?.toString(),
      latestIsReproducible: latestIsReproducible == _sentinel
          ? this.latestIsReproducible
          : latestIsReproducible as bool?,
      latestReproducibleStatus: latestReproducibleStatus == _sentinel
          ? this.latestReproducibleStatus
          : latestReproducibleStatus?.toString(),
      latestReproducibleVersionCode: latestReproducibleVersionCode == _sentinel
          ? this.latestReproducibleVersionCode
          : latestReproducibleVersionCode as int?,
      latestAttestationStatus: latestAttestationStatus == _sentinel
          ? this.latestAttestationStatus
          : latestAttestationStatus?.toString(),
      latestMalwareScanStatus: latestMalwareScanStatus == _sentinel
          ? this.latestMalwareScanStatus
          : latestMalwareScanStatus?.toString(),
      latestMalwareScanDetail: latestMalwareScanDetail == _sentinel
          ? this.latestMalwareScanDetail
          : latestMalwareScanDetail?.toString(),
      latestMalwareScanReportUrl: latestMalwareScanReportUrl == _sentinel
          ? this.latestMalwareScanReportUrl
          : latestMalwareScanReportUrl?.toString(),
    );
  }

  /// Returns a deep copy of this app. Since [App] is immutable and [copyWith]
  /// already clones its mutable collections, a zero-argument [copyWith] is a
  /// faithful deep copy.
  App deepCopy() => copyWith();

  factory App.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> originalJson = Map.from(json);
    try {
      json = appJSONCompatibilityModifiers(Map.from(json));
    } catch (e) {
      // Fall back to the unmigrated JSON so the app still loads rather than
      // being lost (e.g. when its saved URL no longer matches any source).
      json = originalJson;
      unawaited(
        LogsProvider().add(
          'Error running JSON compat modifiers (using original JSON): ${e.toString()}',
          level: LogLevel.warning,
        ),
      );
    }
    try {
      return App(
        id: json['id']?.toString() ?? '',
        listingId: listingIdFromJsonValue(
          json['listingId'],
          packageId: json['id']?.toString() ?? '',
        ),
        url: json['url']?.toString() ?? '',
        author: json['author']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        installedVersion: json['installedVersion']?.toString(),
        latestVersion: json['latestVersion']?.toString() ?? tr('unknown'),
        apkUrls: assumed2DlistToStringMapList(
          jsonDecode((json['apkUrls'] ?? '[["placeholder", "placeholder"]]')),
        ),
        preferredApkIndex: (json['preferredApkIndex'] ?? -1) as int,
        additionalSettings:
            jsonDecode(json['additionalSettings']) as Map<String, dynamic>,
        lastUpdateCheck: dateTimeFromJsonValue(json['lastUpdateCheck']),
        pinned: json['pinned'] ?? false,
        categories: json['categories'] != null
            ? (json['categories'] as List<dynamic>)
                  .map((e) => e.toString())
                  .toList()
            : json['category'] != null
            ? [json['category'].toString()]
            : [],
        releaseDate: dateTimeFromJsonValue(json['releaseDate']),
        changeLog: json['changeLog']?.toString(),
        overrideSource: json['overrideSource']?.toString(),
        allowIdChange: json['allowIdChange'] ?? false,
        otherAssetUrls: assumed2DlistToStringMapList(
          jsonDecode((json['otherAssetUrls'] ?? '[]')),
        ),
        pendingRepoRenameUrl: json['pendingRepoRenameUrl']?.toString(),
        iconUrl: json['iconUrl']?.toString(),
        apkSizeBytes: json['apkSizeBytes'] as int?,
        rawLatestVersionFromSource: json['rawLatestVersionFromSource']
            ?.toString(),
        rawApkNamesFromSource: json['rawApkNamesFromSource']?.toString(),
        rawReleaseTitlesFromSource: json['rawReleaseTitlesFromSource']
            ?.toString(),
        latestIsReproducible: json['latestIsReproducible'] as bool?,
        latestReproducibleStatus: reproducibleBuildStatusFromJsonValue(
          json['latestReproducibleStatus'] ?? json['latestIsReproducible'],
        ),
        latestReproducibleVersionCode:
            json['latestReproducibleVersionCode'] is num
            ? (json['latestReproducibleVersionCode'] as num).toInt()
            : int.tryParse(
                json['latestReproducibleVersionCode']?.toString() ?? '',
              ),
        latestAttestationStatus: githubAttestationStatusFromJsonValue(
          json['latestAttestationStatus'] ?? json['latestIsAttested'],
        ),
        latestMalwareScanStatus: malwareScanStatusFromJsonValue(
          json['latestMalwareScanStatus'],
        ),
        latestMalwareScanDetail: json['latestMalwareScanDetail']?.toString(),
        latestMalwareScanReportUrl: json['latestMalwareScanReportUrl']
            ?.toString(),
      );
    } on TypeError catch (e) {
      unawaited(
        LogsProvider().add(
          'Type mismatch in App.fromJson: ${e.toString()}',
          level: LogLevel.error,
        ),
      );
      rethrow;
    }
  }

  Map<String, dynamic> toJson({bool encodeNested = true}) => {
    'id': id,
    // Omitted for a package's only listing, so single-store records stay
    // byte-for-byte compatible with what earlier versions (and Obtainium)
    // wrote and expect.
    if (listingId != null) 'listingId': listingId,
    'url': url,
    'author': author,
    'name': name,
    'installedVersion': installedVersion,
    'latestVersion': latestVersion,
    'apkUrls': encodeNested
        ? jsonEncode(stringMapListTo2DList(apkUrls))
        : stringMapListTo2DList(apkUrls),
    'otherAssetUrls': encodeNested
        ? jsonEncode(stringMapListTo2DList(otherAssetUrls))
        : stringMapListTo2DList(otherAssetUrls),
    'preferredApkIndex': preferredApkIndex,
    'additionalSettings': encodeNested
        ? jsonEncode(additionalSettings)
        : additionalSettings,
    'lastUpdateCheck': lastUpdateCheck?.microsecondsSinceEpoch,
    'pinned': pinned,
    'categories': categories,
    'releaseDate': releaseDate?.microsecondsSinceEpoch,
    'changeLog': changeLog,
    'overrideSource': overrideSource,
    'allowIdChange': allowIdChange,
    'pendingRepoRenameUrl': pendingRepoRenameUrl,
    if (iconUrl != null) 'iconUrl': iconUrl,
    if (apkSizeBytes != null) 'apkSizeBytes': apkSizeBytes,
    if (rawLatestVersionFromSource != null)
      'rawLatestVersionFromSource': rawLatestVersionFromSource,
    if (rawApkNamesFromSource != null)
      'rawApkNamesFromSource': rawApkNamesFromSource,
    if (rawReleaseTitlesFromSource != null)
      'rawReleaseTitlesFromSource': rawReleaseTitlesFromSource,
    if (latestIsReproducible != null)
      'latestIsReproducible': latestIsReproducible,
    if (latestReproducibleStatus != null)
      'latestReproducibleStatus': latestReproducibleStatus,
    if (latestReproducibleVersionCode != null)
      'latestReproducibleVersionCode': latestReproducibleVersionCode,
    if (latestAttestationStatus != null)
      'latestAttestationStatus': latestAttestationStatus,
    if (latestMalwareScanStatus != null)
      'latestMalwareScanStatus': latestMalwareScanStatus,
    if (latestMalwareScanDetail != null)
      'latestMalwareScanDetail': latestMalwareScanDetail,
    if (latestMalwareScanReportUrl != null)
      'latestMalwareScanReportUrl': latestMalwareScanReportUrl,
  };
}

/// Sentinel value used by [App.copyWith] to distinguish "not provided" from
/// an explicitly supplied `null` for nullable fields. Since [Object] uses
/// identity-based equality, a `const` sentinel guarantees it never collides
/// with any real value the caller could pass.
const _sentinel = Object();

/// Returns true if the app's ID is a temporary placeholder rather than a real
/// package name. Matches [generateTempID]'s sha256-hex prefix and legacy numeric
/// IDs; real package names contain a dot and never match.
bool isTempId(App app) {
  return RegExp(r'^[0-9]+$').hasMatch(app.id) ||
      RegExp(r'^[0-9a-f]{12}$').hasMatch(app.id);
}

/// Returns true when the app uses pseudo-versioning (track-only or disabled version detection).
bool isVersionPseudo(App app) =>
    app.settings.getBool('trackOnly') ||
    (app.installedVersion != null && !app.usesStandardVersionDetection);

// ------------------------------------------------------------------------
// ObtainX-only: store verification statuses, listing identity and tolerant
// JSON parsing used by [App].
// ------------------------------------------------------------------------

// GitHub build attestation status values (stored in App.latestAttestationStatus).
const String githubAttestationStatusVerified = 'verified';
const String githubAttestationStatusUnsupported = 'unsupported';
const String githubAttestationStatusError = 'error';

const Set<String> validGitHubAttestationStatuses = {
  githubAttestationStatusVerified,
  githubAttestationStatusUnsupported,
  githubAttestationStatusError,
};

// Reproducible-build status values (stored in App.latestReproducibleStatus).
const String reproducibleBuildStatusVerified = 'verified';
const String reproducibleBuildStatusNotReproducible = 'not_reproducible';
const String reproducibleBuildStatusNoData = 'no_data';
const String reproducibleBuildStatusError = 'error';

const Set<String> validReproducibleBuildStatuses = {
  reproducibleBuildStatusVerified,
  reproducibleBuildStatusNotReproducible,
  reproducibleBuildStatusNoData,
  reproducibleBuildStatusError,
};

// Malware-scan (VirusTotal) status values (stored in App.latestMalwareScanStatus).
const String malwareScanStatusClean = 'clean';
const String malwareScanStatusFlagged = 'flagged';
const String malwareScanStatusError = 'error';

const Set<String> validMalwareScanStatuses = {
  malwareScanStatusClean,
  malwareScanStatusFlagged,
  malwareScanStatusError,
};

/// Coerces a stored JSON value into a valid malware-scan status, or null.
String? malwareScanStatusFromJsonValue(Object? value) {
  if (value is String && validMalwareScanStatuses.contains(value)) {
    return value;
  }
  return null;
}

/// Coerces a stored JSON value (string, or legacy bool) into a valid
/// attestation status, or null.
String? githubAttestationStatusFromJsonValue(Object? value) {
  if (value is String && validGitHubAttestationStatuses.contains(value)) {
    return value;
  }
  if (value is bool) {
    return value
        ? githubAttestationStatusVerified
        : githubAttestationStatusUnsupported;
  }
  return null;
}

/// Coerces a stored JSON value (string, or legacy bool) into a valid
/// reproducible-build status, or null.
String? reproducibleBuildStatusFromJsonValue(Object? value) {
  if (value is String && validReproducibleBuildStatuses.contains(value)) {
    return value;
  }
  if (value is bool) {
    return value
        ? reproducibleBuildStatusVerified
        : reproducibleBuildStatusNotReproducible;
  }
  return null;
}

/// Maps a tri-state reproducible bool (true/false/null) to a status string.
String reproducibleBuildStatusFromBool(bool? value) {
  if (value == true) {
    return reproducibleBuildStatusVerified;
  }
  if (value == false) {
    return reproducibleBuildStatusNotReproducible;
  }
  return reproducibleBuildStatusNoData;
}

/// Maps a reproducible-build status string back to a tri-state bool.
bool? reproducibleBuildBoolFromStatus(String? status) {
  if (status == reproducibleBuildStatusVerified) {
    return true;
  }
  if (status == reproducibleBuildStatusNotReproducible) {
    return false;
  }
  return null;
}

String reproducibleBuildStatusForEnforcement(App app) {
  return app.latestReproducibleStatus ??
      reproducibleBuildStatusFromBool(app.latestIsReproducible);
}

/// Whether [value] looks like an Android application id (e.g. `org.example.app`)
/// rather than a human-readable app name. Used to decide when a source's
/// readable name should replace a stale package-id-looking stored name.
bool looksLikeAndroidPackageId(String value) {
  return RegExp(
    r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$',
  ).hasMatch(value.trim());
}

/// Tolerant parser for stored date fields (lastUpdateCheck / releaseDate).
/// Accepts an int (microsecondsSinceEpoch), an ISO-8601 string, or a numeric
/// string. Returns null for null/unparseable. A raw
/// `DateTime.fromMicrosecondsSinceEpoch(json[...])` throws a TypeError on a
/// String value, which aborts the whole import — this restores fork main's
/// tolerance for string-encoded dates in legacy/third-party backups.
DateTime? dateTimeFromJsonValue(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return DateTime.fromMicrosecondsSinceEpoch(value);
  }
  if (value is String) {
    final DateTime? isoDateTime = DateTime.tryParse(value);
    if (isoDateTime != null) {
      return isoDateTime;
    }
    final int? microsecondsSinceEpoch = int.tryParse(value);
    if (microsecondsSinceEpoch != null) {
      return DateTime.fromMicrosecondsSinceEpoch(microsecondsSinceEpoch);
    }
  }
  return null;
}

/// Separates Android package ID from store identity in a listing ID (and
/// therefore in on-disk record names). Package IDs cannot contain `@`.
const String appListingKeySeparator = '@';

/// Candidate listing ID for a package tracked from a second store.
String appListingKey(String packageId, String sourceIdentifier) =>
    '$packageId$appListingKeySeparator$sourceIdentifier';

/// Normalizes a stored `listingId`, collapsing a value that merely restates
/// [packageId] (and anything blank) back to null.
String? listingIdFromJsonValue(Object? value, {required String packageId}) {
  final String? listingId = value?.toString().trim();
  if (listingId == null || listingId.isEmpty || listingId == packageId) {
    return null;
  }
  return listingId;
}
