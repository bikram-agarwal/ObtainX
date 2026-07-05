// Defines App sources and provides functions used to interact with them
// AppSource is an abstract class with a concrete implementation for each source

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:http/http.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/apkpure.dart';
import 'package:obtainium/app_sources/aptoide.dart';
import 'package:obtainium/app_sources/apk4free.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/coolapk.dart';
import 'package:obtainium/app_sources/direct_apk_link.dart';
import 'package:obtainium/app_sources/farsroid.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/app_sources/huaweiappgallery.dart';
import 'package:obtainium/app_sources/itchio.dart';
import 'package:obtainium/app_sources/izzyondroid.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/app_sources/jenkins.dart';
import 'package:obtainium/app_sources/liteapks.dart';
import 'package:obtainium/app_sources/neutroncode.dart';
import 'package:obtainium/app_sources/rockmods.dart';
import 'package:obtainium/app_sources/rustore.dart';
import 'package:obtainium/app_sources/sourceforge.dart';
import 'package:obtainium/app_sources/sourcehut.dart';
import 'package:obtainium/app_sources/telegramapp.dart';
import 'package:obtainium/app_sources/tencent.dart';
import 'package:obtainium/app_sources/uptodown.dart';
import 'package:obtainium/app_sources/vivoappstore.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/mass_app_sources/githubstars.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';

class AppNames {
  late String author;
  late String name;

  AppNames(this.author, this.name);
}

const String githubAttestationStatusVerified = 'verified';
const String githubAttestationStatusUnsupported = 'unsupported';
const String githubAttestationStatusError = 'error';

const Set<String> validGitHubAttestationStatuses = {
  githubAttestationStatusVerified,
  githubAttestationStatusUnsupported,
  githubAttestationStatusError,
};

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

String reproducibleBuildStatusFromBool(bool? value) {
  if (value == true) {
    return reproducibleBuildStatusVerified;
  }
  if (value == false) {
    return reproducibleBuildStatusNotReproducible;
  }
  return reproducibleBuildStatusNoData;
}

bool? reproducibleBuildBoolFromStatus(String? status) {
  if (status == reproducibleBuildStatusVerified) {
    return true;
  }
  if (status == reproducibleBuildStatusNotReproducible) {
    return false;
  }
  return null;
}

bool looksLikeAndroidPackageId(String value) {
  return RegExp(
    r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$',
  ).hasMatch(value.trim());
}

class APKDetails {
  late String version;
  late List<MapEntry<String, String>> apkUrls;
  late AppNames names;
  late DateTime? releaseDate;
  late String? changeLog;
  late List<MapEntry<String, String>> allAssetUrls;

  /// Optional absolute URL to a raster app icon from the source (for non-installed apps).
  String? iconUrl;

  /// Release names/titles seen before [filterReleaseTitlesByRegEx] (RegEx assist).
  List<String> rawReleaseTitleCandidates;

  /// Size of the preferred APK in bytes, if known at update-check time (e.g. GitHub releases).
  int? apkSizeBytes;
  bool? isReproducible;
  String? reproducibleStatus;
  String? attestationStatus;

  APKDetails(
    this.version,
    this.apkUrls,
    this.names, {
    this.releaseDate,
    this.changeLog,
    this.allAssetUrls = const [],
    this.iconUrl,
    this.rawReleaseTitleCandidates = const [],
    this.apkSizeBytes,
    this.isReproducible,
    this.reproducibleStatus,
    this.attestationStatus,
  });
}

const String versionStringSourceDefault = 'default';
const String versionStringSourceReleaseTitle = 'releaseTitle';
const String versionStringSourceAssetName = 'assetName';
const String versionStringSourceReleaseDate = 'releaseDate';
const String versionStringSourceReleaseCommitSha = 'releaseCommitSha';

const Set<String> validVersionStringSources = {
  versionStringSourceDefault,
  versionStringSourceReleaseTitle,
  versionStringSourceAssetName,
  versionStringSourceReleaseDate,
  versionStringSourceReleaseCommitSha,
};

String getVersionStringSource(
  Map<String, dynamic> additionalSettings, {
  bool preferConfiguredSource = true,
}) {
  final dynamic configuredSource = additionalSettings['versionStringSource'];
  if (configuredSource is String &&
      preferConfiguredSource &&
      validVersionStringSources.contains(configuredSource)) {
    return configuredSource;
  }
  if (additionalSettings['releaseDateAsVersion'] == true) {
    return versionStringSourceReleaseDate;
  }
  if (additionalSettings['releaseTitleAsVersion'] == true) {
    return versionStringSourceReleaseTitle;
  }
  if (additionalSettings['extractVersionFromAssetName'] == true) {
    return versionStringSourceAssetName;
  }
  if (additionalSettings['releaseCommitShaAsVersion'] == true) {
    return versionStringSourceReleaseCommitSha;
  }
  if (configuredSource is String &&
      validVersionStringSources.contains(configuredSource)) {
    return configuredSource;
  }
  return versionStringSourceDefault;
}

void syncVersionStringSourceSettings(
  Map<String, dynamic> additionalSettings, {
  bool preferConfiguredSource = true,
}) {
  final String versionStringSource = getVersionStringSource(
    additionalSettings,
    preferConfiguredSource: preferConfiguredSource,
  );
  additionalSettings['versionStringSource'] = versionStringSource;
  additionalSettings['releaseDateAsVersion'] =
      versionStringSource == versionStringSourceReleaseDate;
  additionalSettings['releaseTitleAsVersion'] =
      versionStringSource == versionStringSourceReleaseTitle;
  additionalSettings['extractVersionFromAssetName'] =
      versionStringSource == versionStringSourceAssetName;
  additionalSettings['releaseCommitShaAsVersion'] =
      versionStringSource == versionStringSourceReleaseCommitSha;
}

List<List<String>> stringMapListTo2DList(
  List<MapEntry<String, String>> mapList,
) => mapList.map((e) => [e.key, e.value]).toList();

List<MapEntry<String, String>> assumed2DlistToStringMapList(
  List<dynamic> arr,
) => arr.map((e) => MapEntry(e[0] as String, e[1] as String)).toList();

// App JSON schema has changed multiple times over the many versions of Obtainium
// This function takes an App JSON and modifies it if needed to conform to the latest (current) version
// Per-source-type caches for appJSONCompatibilityModifiers. The flattened
// app-specific form items and their default values are deterministic per source
// type, but were previously rebuilt — clones + many tr() lookups — for every app
// on load. (clone() already copies defaultValue by reference, so the original
// code already shared default-value objects across apps; caching adds no new
// mutation risk, and the working copy below is copied before being mutated.)
final Map<String, List<GeneratedFormItem>> _flattenedFormItemsBySourceType = {};
final Map<String, Map<String, dynamic>> _defaultSettingsBySourceType = {};

Map<String, dynamic> appJSONCompatibilityModifiers(Map<String, dynamic> json) {
  // Read-only: only the source's type and (type-level) form items are needed
  // here, so use the shared template and avoid constructing a source per app.
  var source = SourceProvider().getSourceTemplate(
    json['url'],
    overrideSource: json['overrideSource'],
  );
  final String sourceTypeKey = source.runtimeType.toString();
  var formItems = _flattenedFormItemsBySourceType[sourceTypeKey] ??= source
      .combinedAppSpecificSettingFormItems
      .reduce((value, element) => [...value, ...element]);
  Map<String, dynamic> additionalSettings = Map<String, dynamic>.from(
    _defaultSettingsBySourceType[sourceTypeKey] ??=
        getDefaultValuesFromFormItems([formItems]),
  );
  Map<String, dynamic> originalAdditionalSettings = {};
  if (json['additionalSettings'] != null) {
    originalAdditionalSettings = Map<String, dynamic>.from(
      jsonDecode(json['additionalSettings']),
    );
    additionalSettings.addEntries(originalAdditionalSettings.entries);
  }
  // If needed, migrate old-style additionalData to newer-style additionalSettings (V1)
  if (json['additionalData'] != null) {
    List<String> temp = List<String>.from(jsonDecode(json['additionalData']));
    temp.asMap().forEach((i, value) {
      if (i < formItems.length) {
        if (formItems[i] is GeneratedFormSwitch) {
          additionalSettings[formItems[i].key] = value == 'true';
        } else {
          additionalSettings[formItems[i].key] = value;
        }
      }
    });
    additionalSettings['trackOnly'] =
        json['trackOnly'] == 'true' || json['trackOnly'] == true;
    additionalSettings['noVersionDetection'] =
        json['noVersionDetection'] == 'true' || json['trackOnly'] == true;
  }
  // Convert bool style version detection options to dropdown style
  if (additionalSettings['noVersionDetection'] == true) {
    additionalSettings['versionDetection'] = 'noVersionDetection';
    if (additionalSettings['releaseDateAsVersion'] == true) {
      additionalSettings['versionDetection'] = 'releaseDateAsVersion';
      additionalSettings.remove('releaseDateAsVersion');
    }
    if (additionalSettings['noVersionDetection'] != null) {
      additionalSettings.remove('noVersionDetection');
    }
    if (additionalSettings['releaseDateAsVersion'] != null) {
      additionalSettings.remove('releaseDateAsVersion');
    }
  }
  // Convert old dropdown/boolean style version detection options to new three-state string values
  if (additionalSettings['versionDetection'] == 'standardVersionDetection') {
    additionalSettings['versionDetection'] = 'auto';
  } else if (additionalSettings['versionDetection'] == 'noVersionDetection') {
    additionalSettings['versionDetection'] = 'pseudo';
  } else if (additionalSettings['versionDetection'] == 'releaseDateAsVersion') {
    additionalSettings['versionDetection'] = 'pseudo';
    additionalSettings['releaseDateAsVersion'] = true;
  } else if (additionalSettings['versionDetection'] == true) {
    additionalSettings['versionDetection'] = 'auto';
  } else if (additionalSettings['versionDetection'] == false) {
    additionalSettings['versionDetection'] = 'pseudo';
  }
  syncVersionStringSourceSettings(
    additionalSettings,
    preferConfiguredSource: originalAdditionalSettings.containsKey(
      'versionStringSource',
    ),
  );
  if (additionalSettings['versionDetection'] == 'versionCode' ||
      additionalSettings['useVersionCodeAsOSVersion'] == true) {
    additionalSettings['versionDetection'] = 'versionCode';
    additionalSettings['useVersionCodeAsOSVersion'] = true;
  } else {
    additionalSettings['useVersionCodeAsOSVersion'] = false;
  }
  // Convert bool style pseudo version method to dropdown style
  if (originalAdditionalSettings['supportFixedAPKURL'] == true) {
    additionalSettings['defaultPseudoVersioningMethod'] = 'partialAPKHash';
  } else if (originalAdditionalSettings['supportFixedAPKURL'] == false) {
    additionalSettings['defaultPseudoVersioningMethod'] = 'APKLinkHash';
  }
  // Ensure additionalSettings are correctly typed
  for (var item in formItems) {
    if (additionalSettings[item.key] != null) {
      additionalSettings[item.key] = item.ensureType(
        additionalSettings[item.key],
      );
    }
  }
  int preferredApkIndex = json['preferredApkIndex'] == null
      ? 0
      : json['preferredApkIndex'] as int;
  if (preferredApkIndex < 0) {
    preferredApkIndex = 0;
  }
  json['preferredApkIndex'] = preferredApkIndex;
  // apkUrls can either be old list or new named list apkUrls
  List<MapEntry<String, String>> apkUrls = [];
  if (json['apkUrls'] != null) {
    var apkUrlJson = jsonDecode(json['apkUrls']);
    try {
      apkUrls = getApkUrlsFromUrls(List<String>.from(apkUrlJson));
    } catch (e) {
      apkUrls = assumed2DlistToStringMapList(List<dynamic>.from(apkUrlJson));
      apkUrls = List<dynamic>.from(
        apkUrlJson,
      ).map((e) => MapEntry(e[0] as String, e[1] as String)).toList();
    }
    json['apkUrls'] = jsonEncode(stringMapListTo2DList(apkUrls));
  }
  // Arch based APK filter option should be disabled if it previously did not exist
  if (additionalSettings['autoApkFilterByArch'] == null) {
    additionalSettings['autoApkFilterByArch'] = false;
  }
  // GitHub "don't sort" option to new dropdown format
  if (additionalSettings['dontSortReleasesList'] == true) {
    additionalSettings['sortMethodChoice'] = 'none';
  }
  if (source is HTML) {
    // HTML key rename
    if (originalAdditionalSettings['sortByFileNamesNotLinks'] != null) {
      additionalSettings['sortByLastLinkSegment'] =
          originalAdditionalSettings['sortByFileNamesNotLinks'];
    }
    // HTML single 'intermediate link' should be converted to multi-support version
    if (originalAdditionalSettings['intermediateLinkRegex'] != null &&
        additionalSettings['intermediateLinkRegex']?.isNotEmpty != true) {
      additionalSettings['intermediateLink'] = [
        {
          'customLinkFilterRegex':
              originalAdditionalSettings['intermediateLinkRegex'],
          'filterByLinkText':
              originalAdditionalSettings['intermediateLinkByText'],
        },
      ];
    }
    if ((additionalSettings['intermediateLink']?.length ?? 0) > 0) {
      additionalSettings['intermediateLink'] =
          additionalSettings['intermediateLink'].where((e) {
            return e['customLinkFilterRegex']?.isNotEmpty == true;
          }).toList();
    }
    // Steam source apps should be converted to HTML (#1244)
    var legacySteamSourceApps = ['steam', 'steam-chat-app'];
    if (legacySteamSourceApps.contains(additionalSettings['app'] ?? '')) {
      json['url'] = '${json['url']}/mobile';
      var replacementAdditionalSettings = getDefaultValuesFromFormItems(
        HTML().combinedAppSpecificSettingFormItems,
      );
      for (var s in replacementAdditionalSettings.keys) {
        if (additionalSettings.containsKey(s)) {
          replacementAdditionalSettings[s] = additionalSettings[s];
        }
      }
      replacementAdditionalSettings['customLinkFilterRegex'] =
          '/${additionalSettings['app']}-(([0-9]+\\.?){1,})\\.apk';
      replacementAdditionalSettings['versionExtractionRegEx'] =
          replacementAdditionalSettings['customLinkFilterRegex'];
      replacementAdditionalSettings['matchGroupToUse'] = '\$1';
      additionalSettings = replacementAdditionalSettings;
    }
    // Signal apps from before it was removed should be converted to HTML (#1928)
    if (json['url'] == 'https://signal.org' &&
        json['id'] == 'org.thoughtcrime.securesms' &&
        json['author'] == 'Signal' &&
        json['name'] == 'Signal' &&
        json['overrideSource'] == null &&
        additionalSettings['trackOnly'] == false &&
        additionalSettings['versionExtractionRegEx'] == '' &&
        json['lastUpdateCheck'] != null) {
      json['url'] = 'https://updates.signal.org/android/latest.json';
      var replacementAdditionalSettings = getDefaultValuesFromFormItems(
        HTML().combinedAppSpecificSettingFormItems,
      );
      replacementAdditionalSettings['versionExtractionRegEx'] =
          '\\d+.\\d+.\\d+';
      additionalSettings = replacementAdditionalSettings;
    }
    // WhatsApp from before it was removed should be converted to HTML (#1943)
    if (json['url'] == 'https://whatsapp.com' &&
        json['id'] == 'com.whatsapp' &&
        json['author'] == 'Meta' &&
        json['name'] == 'WhatsApp' &&
        json['overrideSource'] == null &&
        additionalSettings['trackOnly'] == false &&
        additionalSettings['versionExtractionRegEx'] == '' &&
        json['lastUpdateCheck'] != null) {
      json['url'] = 'https://whatsapp.com/android';
      var replacementAdditionalSettings = getDefaultValuesFromFormItems(
        HTML().combinedAppSpecificSettingFormItems,
      );
      replacementAdditionalSettings['refreshBeforeDownload'] = true;
      additionalSettings = replacementAdditionalSettings;
    }
    // VLC from before it was removed should be converted to HTML (#1943)
    if (json['url'] == 'https://videolan.org' &&
        json['id'] == 'org.videolan.vlc' &&
        json['author'] == 'VideoLAN' &&
        json['name'] == 'VLC' &&
        json['overrideSource'] == null &&
        additionalSettings['trackOnly'] == false &&
        additionalSettings['versionExtractionRegEx'] == '' &&
        json['lastUpdateCheck'] != null) {
      json['url'] = 'https://www.videolan.org/vlc/download-android.html';
      var replacementAdditionalSettings = getDefaultValuesFromFormItems(
        HTML().combinedAppSpecificSettingFormItems,
      );
      replacementAdditionalSettings['refreshBeforeDownload'] = true;
      replacementAdditionalSettings['intermediateLink'] =
          <Map<String, dynamic>>[
            {
              'customLinkFilterRegex': 'APK',
              'filterByLinkText': true,
              'skipSort': false,
              'reverseSort': false,
              'sortByLastLinkSegment': false,
            },
            {
              'customLinkFilterRegex': 'arm64-v8a\\.apk\$',
              'filterByLinkText': false,
              'skipSort': false,
              'reverseSort': false,
              'sortByLastLinkSegment': false,
            },
          ];
      replacementAdditionalSettings['versionExtractionRegEx'] =
          '/vlc-android/([^/]+)/';
      replacementAdditionalSettings['matchGroupToUse'] = "1";
      additionalSettings = replacementAdditionalSettings;
    }
  }
  json['additionalSettings'] = jsonEncode(additionalSettings);
  // F-Droid no longer needs cloudflare exception since override can be used - migrate apps appropriately
  // This allows us to reverse the changes made for issue #418 (support cloudflare.f-droid)
  // While not causing problems for existing apps from that source that were added in a previous version
  var overrideSourceWasUndefined = !json.keys.contains('overrideSource');
  if ((json['url'] as String).startsWith('https://cloudflare.f-droid.org')) {
    json['overrideSource'] = FDroid().runtimeType.toString();
  } else if (overrideSourceWasUndefined) {
    // Similar to above, but for third-party F-Droid repos
    RegExpMatch? match = RegExp(
      '^https?://.+/fdroid/([^/]+(/|\\?)|[^/]+\$)',
    ).firstMatch(json['url'] as String);
    if (match != null) {
      json['overrideSource'] = FDroidRepo().runtimeType.toString();
    }
  }
  return json;
}

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

class App {
  late String id;
  late String url;
  late String author;
  late String name;
  String? installedVersion;
  late String latestVersion;

  /// Version string from the source before [extractVersion] / release-date replacement.
  /// Not shown on the app page; used for helpers and diagnostics. Omitted from JSON when null.
  String? rawLatestVersionFromSource;

  /// APK row keys (e.g. filenames) before [filterApks], newline-separated. RegEx assist.
  String? rawApkNamesFromSource;

  /// Release title candidates before title filter, newline-separated. RegEx assist.
  String? rawReleaseTitlesFromSource;
  List<MapEntry<String, String>> apkUrls = []; // Key is name, value is URL
  List<MapEntry<String, String>> otherAssetUrls = [];
  late int preferredApkIndex;
  late Map<String, dynamic> additionalSettings;
  late DateTime? lastUpdateCheck;
  bool pinned = false;
  List<String> categories;
  late DateTime? releaseDate;
  late String? changeLog;
  late String? overrideSource;
  bool allowIdChange = false;
  String? iconUrl;

  /// Size of the preferred APK in bytes, if known at update-check time.
  int? apkSizeBytes;
  String? pendingRepoRenameUrl;
  bool? latestIsReproducible;
  String? latestReproducibleStatus;
  String? latestAttestationStatus;
  App(
    this.id,
    this.url,
    this.author,
    this.name,
    this.installedVersion,
    this.latestVersion,
    this.apkUrls,
    this.preferredApkIndex,
    this.additionalSettings,
    this.lastUpdateCheck,
    this.pinned, {
    this.categories = const [],
    this.releaseDate,
    this.changeLog,
    this.overrideSource,
    this.allowIdChange = false,
    this.otherAssetUrls = const [],
    this.iconUrl,
    this.rawLatestVersionFromSource,
    this.rawApkNamesFromSource,
    this.rawReleaseTitlesFromSource,
    this.apkSizeBytes,
    this.pendingRepoRenameUrl,
    this.latestIsReproducible,
    this.latestReproducibleStatus,
    this.latestAttestationStatus,
  });

  @override
  String toString() {
    return 'ID: $id URL: $url INSTALLED: $installedVersion LATEST: $latestVersion APK: $apkUrls PREFERREDAPK: $preferredApkIndex ADDITIONALSETTINGS: ${additionalSettings.toString()} LASTCHECK: ${lastUpdateCheck.toString()} PINNED $pinned';
  }

  bool get hasPendingRepoRename =>
      pendingRepoRenameUrl != null && pendingRepoRenameUrl!.isNotEmpty;

  String? get overrideName {
    final String? override = additionalSettings['appName']?.toString().trim();
    if (override?.isNotEmpty != true) {
      return null;
    }
    final String sourceName = name.trim();
    if (override == id && sourceName.isNotEmpty && sourceName != id) {
      return null;
    }
    if (looksLikeAndroidPackageId(override!) &&
        sourceName.isNotEmpty &&
        sourceName != override) {
      return null;
    }
    return override;
  }

  String get finalName {
    return overrideName ?? name;
  }

  String? get overrideAuthor =>
      additionalSettings['appAuthor']?.toString().trim().isNotEmpty == true
      ? additionalSettings['appAuthor']
      : null;

  String get finalAuthor {
    return overrideAuthor ?? author;
  }

  App deepCopy() => App(
    id,
    url,
    author,
    name,
    installedVersion,
    latestVersion,
    apkUrls,
    preferredApkIndex,
    Map.from(additionalSettings),
    lastUpdateCheck,
    pinned,
    categories: categories,
    changeLog: changeLog,
    releaseDate: releaseDate,
    overrideSource: overrideSource,
    allowIdChange: allowIdChange,
    otherAssetUrls: otherAssetUrls,
    iconUrl: iconUrl,
    rawLatestVersionFromSource: rawLatestVersionFromSource,
    rawApkNamesFromSource: rawApkNamesFromSource,
    rawReleaseTitlesFromSource: rawReleaseTitlesFromSource,
    apkSizeBytes: apkSizeBytes,
    pendingRepoRenameUrl: pendingRepoRenameUrl,
    latestIsReproducible: latestIsReproducible,
    latestReproducibleStatus: latestReproducibleStatus,
    latestAttestationStatus: latestAttestationStatus,
  );

  factory App.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> originalJSON = Map.from(json);
    try {
      json = appJSONCompatibilityModifiers(json);
    } catch (e) {
      json = originalJSON;
      LogsProvider().add(
        'Error running JSON compat modifiers: ${e.toString()}: ${originalJSON.toString()}',
      );
    }
    return App(
      json['id'] as String,
      json['url'] as String,
      json['author'] as String,
      json['name'] as String,
      json['installedVersion'] == null
          ? null
          : json['installedVersion'] as String,
      (json['latestVersion'] ?? tr('unknown')) as String,
      assumed2DlistToStringMapList(
        jsonDecode((json['apkUrls'] ?? '[["placeholder", "placeholder"]]')),
      ),
      (json['preferredApkIndex'] ?? -1) as int,
      jsonDecode(json['additionalSettings']) as Map<String, dynamic>,
      dateTimeFromJsonValue(json['lastUpdateCheck']),
      json['pinned'] ?? false,
      categories: json['categories'] != null
          ? (json['categories'] as List<dynamic>)
                .map((e) => e.toString())
                .toList()
          : json['category'] != null
          ? [json['category'] as String]
          : [],
      releaseDate: dateTimeFromJsonValue(json['releaseDate']),
      changeLog: json['changeLog'] == null ? null : json['changeLog'] as String,
      overrideSource: json['overrideSource'],
      allowIdChange: json['allowIdChange'] ?? false,
      otherAssetUrls: assumed2DlistToStringMapList(
        jsonDecode((json['otherAssetUrls'] ?? '[]')),
      ),
      iconUrl: json['iconUrl'] as String?,
      rawLatestVersionFromSource: json['rawLatestVersionFromSource'] as String?,
      rawApkNamesFromSource: json['rawApkNamesFromSource'] as String?,
      rawReleaseTitlesFromSource: json['rawReleaseTitlesFromSource'] as String?,
      apkSizeBytes: json['apkSizeBytes'] as int?,
      pendingRepoRenameUrl: json['pendingRepoRenameUrl'] as String?,
      latestIsReproducible: json['latestIsReproducible'] as bool?,
      latestReproducibleStatus: reproducibleBuildStatusFromJsonValue(
        json['latestReproducibleStatus'] ?? json['latestIsReproducible'],
      ),
      latestAttestationStatus: githubAttestationStatusFromJsonValue(
        json['latestAttestationStatus'] ?? json['latestIsAttested'],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'author': author,
    'name': name,
    'installedVersion': installedVersion,
    'latestVersion': latestVersion,
    'apkUrls': jsonEncode(stringMapListTo2DList(apkUrls)),
    'otherAssetUrls': jsonEncode(stringMapListTo2DList(otherAssetUrls)),
    'preferredApkIndex': preferredApkIndex,
    'additionalSettings': jsonEncode(additionalSettings),
    'lastUpdateCheck': lastUpdateCheck?.microsecondsSinceEpoch,
    'pinned': pinned,
    'categories': categories,
    'releaseDate': releaseDate?.microsecondsSinceEpoch,
    'changeLog': changeLog,
    'overrideSource': overrideSource,
    'allowIdChange': allowIdChange,
    if (iconUrl != null) 'iconUrl': iconUrl,
    if (rawLatestVersionFromSource != null)
      'rawLatestVersionFromSource': rawLatestVersionFromSource,
    if (rawApkNamesFromSource != null)
      'rawApkNamesFromSource': rawApkNamesFromSource,
    if (rawReleaseTitlesFromSource != null)
      'rawReleaseTitlesFromSource': rawReleaseTitlesFromSource,
    if (apkSizeBytes != null) 'apkSizeBytes': apkSizeBytes,
    'pendingRepoRenameUrl': pendingRepoRenameUrl,
    if (latestIsReproducible != null)
      'latestIsReproducible': latestIsReproducible,
    if (latestReproducibleStatus != null)
      'latestReproducibleStatus': latestReproducibleStatus,
    if (latestAttestationStatus != null)
      'latestAttestationStatus': latestAttestationStatus,
  };
}

// Ensure the input is starts with HTTPS and has no WWW
String preStandardizeUrl(String url) {
  var firstDotIndex = url.indexOf('.');
  if (!(firstDotIndex >= 0 && firstDotIndex != url.length - 1)) {
    throw UnsupportedURLError();
  }
  if (url.toLowerCase().indexOf('http://') != 0 &&
      url.toLowerCase().indexOf('https://') != 0) {
    url = 'https://$url';
  }
  var uri = Uri.tryParse(url);
  var trailingSlash =
      ((uri?.path.endsWith('/') ?? false) ||
          ((uri?.path.isEmpty ?? false) && url.endsWith('/'))) &&
      (uri?.queryParameters.isEmpty ?? false);

  url =
      url
          .split('/')
          .where((e) => e.isNotEmpty)
          .join('/')
          .replaceFirst(':/', '://') +
      (trailingSlash ? '/' : '');
  return url;
}

String noAPKFound = tr('noAPKFound');

List<String> getLinksFromParsedHTML(
  html_dom.Document dom,
  RegExp hrefPattern,
  String prependToLinks,
) => dom
    .querySelectorAll('a')
    .where((element) {
      if (element.attributes['href'] == null) return false;
      return hrefPattern.hasMatch(element.attributes['href']!);
    })
    .map((e) => '$prependToLinks${e.attributes['href']!}')
    .toList();

Map<String, dynamic> getDefaultValuesFromFormItems(
  List<List<GeneratedFormItem>> items,
) {
  return Map.fromEntries(
    items
        .expand((row) => row)
        .where((el) => el is! GeneratedFormSectionHeader)
        .map((el) => MapEntry(el.key, el.defaultValue ?? '')),
  );
}

const int _maxRawAssistStoredLines = 40;
const int _maxRawAssistStoredChars = 8000;

/// Newline-separated snapshot for RegEx assist dialogs (null if empty).
String? encodeRawAssistLines(Iterable<String> lines) {
  final List<String> out = <String>[];
  int chars = 0;
  for (final String line in lines) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    if (out.length >= _maxRawAssistStoredLines) {
      break;
    }
    if (chars + trimmed.length + 1 > _maxRawAssistStoredChars) {
      break;
    }
    if (!out.contains(trimmed)) {
      out.add(trimmed);
      chars += trimmed.length + 1;
    }
  }
  if (out.isEmpty) {
    return null;
  }
  return out.join('\n');
}

List<MapEntry<String, String>> getApkUrlsFromUrls(List<String> urls) =>
    urls.map((e) {
      var segments = e.split('/').where((el) => el.trim().isNotEmpty);
      var apkSegs = segments.where((s) => s.toLowerCase().endsWith('.apk'));
      return MapEntry(apkSegs.isNotEmpty ? apkSegs.last : segments.last, e);
    }).toList();

Future<List<MapEntry<String, String>>> filterApksByArch(
  List<MapEntry<String, String>> apkUrls,
) async {
  if (apkUrls.length > 1) {
    var abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    for (var abi in abis) {
      var urls2 = apkUrls
          .where(
            (element) =>
                RegExp('.*$abi.*', caseSensitive: false).hasMatch(element.key),
          )
          .toList();
      if (urls2.isNotEmpty && urls2.length < apkUrls.length) {
        apkUrls = urls2;
        break;
      }
    }
  }
  return apkUrls;
}

String getSourceRegex(List<String> hosts) {
  return '(${hosts.join('|').replaceAll('.', '\\.')})';
}

HttpClient createHttpClient(bool insecure) {
  final client = HttpClient();
  if (insecure) {
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
  }
  return client;
}

Future<MapEntry<Uri, MapEntry<HttpClient, HttpClientResponse>>>
sourceRequestStreamResponse(
  String method,
  String url,
  Map<String, String>? requestHeaders,
  Map<String, dynamic> additionalSettings, {
  bool followRedirects = true,
  Object? postBody,
}) async {
  var currentUrl = Uri.parse(url);
  var redirectCount = 0;
  const maxRedirects = 10;
  List<Cookie> cookies = [];
  while (redirectCount < maxRedirects) {
    var httpClient = createHttpClient(
      additionalSettings['allowInsecure'] == true,
    );
    var request = await httpClient.openUrl(method, currentUrl);
    if (requestHeaders != null) {
      requestHeaders.forEach((key, value) {
        request.headers.set(key, value);
      });
    }
    request.cookies.addAll(cookies);
    request.followRedirects = false;
    if (postBody != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(postBody));
    }
    final response = await request.close();

    if (followRedirects &&
        (response.statusCode >= 300 && response.statusCode <= 399)) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location != null) {
        currentUrl = Uri.parse(ensureAbsoluteUrl(location, currentUrl));
        redirectCount++;
        cookies = response.cookies;
        httpClient.close();
        continue;
      }
    }

    return MapEntry(currentUrl, MapEntry(httpClient, response));
  }
  throw ObtainiumError('Too many redirects ($maxRedirects)');
}

Future<Response> httpClientResponseStreamToFinalResponse(
  HttpClient httpClient,
  String method,
  String url,
  HttpClientResponse response,
) async {
  final bytes = (await response.fold<BytesBuilder>(
    BytesBuilder(),
    (b, d) => b..add(d),
  )).toBytes();

  final headers = <String, String>{};
  response.headers.forEach((name, values) {
    headers[name] = values.join(', ');
  });

  httpClient.close();

  return http.Response.bytes(
    bytes,
    response.statusCode,
    headers: headers,
    request: http.Request(method, Uri.parse(url)),
  );
}

abstract class AppSource {
  List<String> hosts = [];
  bool hostChanged = false;
  bool hostIdenticalDespiteAnyChange = false;
  late String name;
  bool enforceTrackOnly = false;
  bool changeLogIfAnyIsMarkDown = true;
  bool appIdInferIsOptional = false;
  bool allowSubDomains = false;
  bool naiveStandardVersionDetection = false;
  bool allowOverride = true;
  bool neverAutoSelect = false;
  bool showReleaseDateAsVersionToggle = false;
  bool showReleaseTitleAsVersionToggle = false;
  bool showExtractVersionFromAssetNameToggle = false;
  bool showReleaseCommitShaAsVersionToggle = false;
  bool versionDetectionDisallowed = false;
  List<String> excludeCommonSettingKeys = [];
  bool urlsAlwaysHaveExtension = false;
  bool allowIncludeZips = false;
  bool allowIncludeTarballs = false;

  /// Transient per-check context: the app as it was known before this update
  /// check, set by [SourceProvider.getApp] right before [getLatestAPKDetails].
  /// Lets a source skip an expensive *secondary* verification network round-trip
  /// (GitHub attestation API, F-Droid fdroiddata metadata YAML) when the raw
  /// upstream version is unchanged since the last check, reusing the cached
  /// result instead. Not persisted; safe to read because [SourceProvider.getSource]
  /// hands each check its own source instance.
  App? previouslyCheckedApp;

  AppSource() {
    name = runtimeType.toString();
  }

  String standardizeUrl(String url) {
    url = preStandardizeUrl(url);
    if (!hostChanged) {
      url = sourceSpecificStandardizeURL(url);
    }
    return url;
  }

  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    return null;
  }

  App endOfGetAppChanges(App app) {
    return app;
  }

  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    var sp = SettingsProvider();
    await sp.initializeSettings();
    getSourceConfigValues(additionalSettings, sp);
    var additionalSettingsPlusSourceConfig = {
      ...additionalSettings,
      ...(await getSourceConfigValues(additionalSettings, sp)),
    };
    url = await generalReqPrefetchModifier(
      url,
      additionalSettingsPlusSourceConfig,
    );
    var method = postBody == null ? 'GET' : 'POST';
    var requestHeaders = await getRequestHeaders(
      additionalSettingsPlusSourceConfig,
      url,
    );
    requestHeaders ??= <String, String>{};
    if (!requestHeaders.containsKey(HttpHeaders.userAgentHeader)) {
      requestHeaders = Map<String, String>.from(requestHeaders)
        ..[HttpHeaders.userAgentHeader] = 'Obtainium';
    }
    var streamedResponseUrlWithResponseAndClient =
        await sourceRequestStreamResponse(
          method,
          url,
          requestHeaders,
          additionalSettingsPlusSourceConfig,
          followRedirects: followRedirects,
          postBody: postBody,
        );
    return await httpClientResponseStreamToFinalResponse(
      streamedResponseUrlWithResponseAndClient.value.key,
      method,
      streamedResponseUrlWithResponseAndClient.key.toString(),
      streamedResponseUrlWithResponseAndClient.value.value,
    );
  }

  void runOnAddAppInputChange(String inputUrl) {
    //
  }

  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    throw NotImplementedError();
  }

  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) {
    throw NotImplementedError();
  }

  // Different Sources may need different kinds of additional data for Apps
  List<List<GeneratedFormItem>> additionalSourceAppSpecificSettingFormItems =
      [];

  // Some additional data may be needed for Apps regardless of Source
  List<List<GeneratedFormItem>>
  additionalAppSpecificSourceAgnosticSettingFormItemsNeverUseDirectly = [
    [
      GeneratedFormSectionHeader(
        '__formSectionTracking',
        label: tr('additionalOptionsSectionTracking'),
      ),
    ],
    [
      GeneratedFormSwitch(
        'trackOnly',
        label: tr('trackOnly'),
        labelTooltip: tr('trackOnlyAppDescription'),
      ),
    ],
    [
      GeneratedFormSwitch(
        'onDemandOnly',
        label: tr('onDemandOnly'),
        defaultValue: false,
        labelTooltip: tr('onDemandOnlyDescription'),
      ),
    ],
    [
      GeneratedFormSwitch(
        'exemptFromBackgroundUpdates',
        label: tr('exemptFromBackgroundUpdates'),
      ),
    ],
    [
      GeneratedFormSwitch(
        'skipUpdateNotifications',
        label: tr('skipUpdateNotifications'),
      ),
    ],
    [
      GeneratedFormSectionHeader(
        '__formSectionVersion',
        label: tr('additionalOptionsSectionVersion'),
      ),
    ],
    [
      GeneratedFormTextField(
        'versionExtractionRegEx',
        label: tr('trimVersionString'),
        required: false,
        additionalValidators: [(value) => regExValidator(value)],
      ),
    ],
    [
      GeneratedFormTextField(
        'matchGroupToUse',
        label: tr('matchGroupToUseForX', args: [tr('trimVersionString')]),
        required: false,
        hint: '\$0',
      ),
    ],
    [
      GeneratedFormDropdown(
        'versionDetection',
        [
          MapEntry('auto', tr('versionDetectionModeAuto')),
          MapEntry('standard', tr('versionDetectionModeStandard')),
          MapEntry('pseudo', tr('versionDetectionModePseudo')),
          MapEntry('versionCode', tr('versionDetectionModeVersionCode')),
        ],
        label: tr('versionDetection'),
        defaultValue: 'auto',
      ),
    ],
    [
      GeneratedFormSectionHeader(
        '__formSectionApk',
        label: tr('additionalOptionsSectionApk'),
      ),
    ],
    [
      GeneratedFormTextField(
        'apkFilterRegEx',
        label: tr('filterAPKsByRegEx'),
        required: false,
        additionalValidators: [
          (value) {
            return regExValidator(value);
          },
        ],
      ),
    ],
    [
      GeneratedFormSwitch(
        'invertAPKFilter',
        label: tr('invertRegEx'),
        defaultValue: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'autoApkFilterByArch',
        label: tr('autoApkFilterByArch'),
        defaultValue: true,
      ),
    ],
    [
      GeneratedFormSectionHeader(
        '__formSectionAdvanced',
        label: tr('additionalOptionsSectionAdvanced'),
      ),
    ],
    [
      GeneratedFormSwitch(
        'shizukuPretendToBeGooglePlay',
        label: tr('shizukuPretendToBeGooglePlay'),
        defaultValue: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'allowInsecure',
        label: tr('allowInsecure'),
        defaultValue: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'refreshBeforeDownload',
        label: tr('refreshBeforeDownload'),
      ),
    ],
  ];

  List<MapEntry<String, String>> get versionStringSourceOptions {
    final List<MapEntry<String, String>> options = [
      MapEntry(versionStringSourceDefault, tr('versionStringSourceDefault')),
    ];
    if (showReleaseTitleAsVersionToggle) {
      options.add(
        MapEntry(
          versionStringSourceReleaseTitle,
          tr('versionStringSourceReleaseTitle'),
        ),
      );
    }
    if (showExtractVersionFromAssetNameToggle) {
      options.add(
        MapEntry(
          versionStringSourceAssetName,
          tr('versionStringSourceAssetName'),
        ),
      );
    }
    if (showReleaseDateAsVersionToggle) {
      options.add(
        MapEntry(
          versionStringSourceReleaseDate,
          tr('versionStringSourceReleaseDate'),
        ),
      );
    }
    if (showReleaseCommitShaAsVersionToggle) {
      options.add(
        MapEntry(
          versionStringSourceReleaseCommitSha,
          tr('versionStringSourceReleaseCommitSha'),
        ),
      );
    }
    return options;
  }

  // Previous 2 variables combined into one at runtime for convenient usage + additional processing
  List<List<GeneratedFormItem>> get combinedAppSpecificSettingFormItems {
    var agnosticItems = cloneFormItems(
      additionalAppSpecificSourceAgnosticSettingFormItemsNeverUseDirectly,
    );

    final int versionSectionHeaderIndex = agnosticItems.indexWhere(
      (List<GeneratedFormItem> row) =>
          row.length == 1 && row.first.key == '__formSectionVersion',
    );
    final List<MapEntry<String, String>> versionSourceOptions =
        versionStringSourceOptions;
    if (versionSourceOptions.length > 1 &&
        !agnosticItems.any(
          (List<GeneratedFormItem> row) => row.any(
            (GeneratedFormItem item) => item.key == 'versionStringSource',
          ),
        )) {
      agnosticItems.insert(
        versionSectionHeaderIndex >= 0 ? versionSectionHeaderIndex + 1 : 0,
        [
          GeneratedFormDropdown(
            'versionStringSource',
            versionSourceOptions,
            label: tr('versionStringSource'),
            defaultValue: versionStringSourceDefault,
          ),
        ],
      );
    }

    agnosticItems = agnosticItems
        .map(
          (e) => e
              .where((ee) => !excludeCommonSettingKeys.contains(ee.key))
              .toList(),
        )
        .where((e) => e.isNotEmpty)
        .toList();

    var moreConditionalItems = <List<GeneratedFormItem>>[];
    if (allowIncludeZips) {
      moreConditionalItems.addAll([
        [
          GeneratedFormSwitch(
            'includeZips',
            label: tr('includeZips'),
            defaultValue: false,
          ),
        ],
        [
          GeneratedFormTextField(
            'zippedApkFilterRegEx',
            label: tr('zippedApkFilterRegEx'),
            required: false,
            additionalValidators: [
              (value) {
                return regExValidator(value);
              },
            ],
          ),
        ],
      ]);
    }

    if (allowIncludeTarballs) {
      moreConditionalItems.addAll([
        [
          GeneratedFormSwitch(
            'includeTarballs',
            label: tr('includeTarballs'),
            defaultValue: false,
          ),
        ],
        [
          GeneratedFormTextField(
            'tarballedApkFilterRegEx',
            label: tr('tarballedApkFilterRegEx'),
            required: false,
            additionalValidators: [
              (value) {
                return regExValidator(value);
              },
            ],
          ),
        ],
      ]);
    }

    if (versionDetectionDisallowed) {
      for (final GeneratedFormItem item in agnosticItems.expand((row) => row)) {
        if (item.key == 'versionDetection' ||
            item.key == 'useVersionCodeAsOSVersion') {
          if (item is GeneratedFormSwitch) {
            item.disabled = true;
            item.defaultValue = false;
          }
        }
      }
    }

    return [
      ...additionalSourceAppSpecificSettingFormItems,
      ...agnosticItems,
      ...moreConditionalItems,
    ];
  }

  // Some Sources may have additional settings at the Source level (not specific to Apps) - these use SettingsProvider
  // If the source has been overridden, we expect the user to define one-time values as additional settings - don't use the stored values
  List<GeneratedFormItem> sourceConfigSettingFormItems = [];
  Future<Map<String, String>> getSourceConfigValues(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) async {
    Map<String, String> results = {};
    for (var e in sourceConfigSettingFormItems) {
      var val = hostChanged && !hostIdenticalDespiteAnyChange
          ? additionalSettings[e.key]
          : additionalSettings[e.key] ??
                (e.runtimeType == GeneratedFormSwitch
                    ? settingsProvider.getSettingBool(e.key).toString()
                    : settingsProvider.getSettingString(e.key));
      if (val != null) {
        results[e.key] = val.toString();
      }
    }
    return results;
  }

  String? changeLogPageFromStandardUrl(String standardUrl) {
    return null;
  }

  Future<String?> getSourceNote() async {
    return null;
  }

  Future<String> assetUrlPrefetchModifier(
    String assetUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return assetUrl;
  }

  Future<String> generalReqPrefetchModifier(
    String reqUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return reqUrl;
  }

  bool canSearch = false;
  bool includeAdditionalOptsInMainSearch = false;
  List<GeneratedFormItem> searchQuerySettingFormItems = [];
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) {
    throw NotImplementedError();
  }

  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    return null;
  }
}

ObtainiumError getObtainiumHttpError(Response res) {
  return ObtainiumError(
    (res.reasonPhrase != null &&
            res.reasonPhrase != null &&
            res.reasonPhrase!.isNotEmpty)
        ? res.reasonPhrase!
        : tr('errorWithHttpStatusCode', args: [res.statusCode.toString()]),
  );
}

abstract class MassAppUrlSource {
  late String name;
  late List<String> requiredArgs;
  Future<Map<String, List<String>>> getUrlsWithDescriptions(List<String> args);
}

String? regExValidator(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  try {
    RegExp(value);
  } catch (e) {
    return tr('invalidRegEx');
  }
  return null;
}

String? intValidator(String? value, {bool positive = false}) {
  if (value == null) {
    return tr('invalidInput');
  }
  var num = int.tryParse(value);
  if (num == null) {
    return tr('invalidInput');
  }
  if (positive && num <= 0) {
    return tr('invalidInput');
  }
  return null;
}

bool isTempId(App app) {
  // return app.id == generateTempID(app.url, app.additionalSettings);
  return RegExp('^[0-9]+\$').hasMatch(app.id);
}

String? replaceMatchGroupsInString(RegExpMatch match, String matchGroupString) {
  if (RegExp('^\\d+\$').hasMatch(matchGroupString)) {
    matchGroupString = '\$$matchGroupString';
  }
  // Regular expression to match numbers in the input string
  final numberRegex = RegExp(r'\$\d+');
  // Extract all numbers from the input string
  final numbers = numberRegex.allMatches(matchGroupString);
  if (numbers.isEmpty) {
    // If no numbers found, return the original string
    return null;
  }
  // Replace numbers with corresponding match groups
  var outputString = matchGroupString;
  for (final numberMatch in numbers) {
    final number = numberMatch.group(0)!;
    final int matchGroupIndex = int.parse(number.substring(1));
    if (matchGroupIndex > match.groupCount) {
      return null;
    }
    final matchGroup = match.group(matchGroupIndex) ?? '';
    // Check if the number is preceded by a single backslash
    final isEscaped = outputString.contains('\\$number');
    // Replace the number with the corresponding match group
    if (!isEscaped) {
      outputString = outputString.replaceAll(number, matchGroup);
    } else {
      outputString = outputString.replaceAll('\\$number', number);
    }
  }
  return outputString;
}

String? extractVersion(
  String? versionExtractionRegEx,
  String? matchGroupString,
  String stringToCheck,
) {
  if (versionExtractionRegEx?.isNotEmpty == true) {
    String? version = stringToCheck;
    var match = RegExp(versionExtractionRegEx!).allMatches(version);
    if (match.isEmpty) {
      throw NoVersionError();
    }
    matchGroupString = matchGroupString?.trim() ?? '';
    if (matchGroupString.isEmpty) {
      matchGroupString = "0";
    }
    version = replaceMatchGroupsInString(match.last, matchGroupString);
    if (version?.isNotEmpty != true) {
      throw NoVersionError();
    }
    return version!;
  } else {
    return null;
  }
}

List<MapEntry<String, String>> filterApks(
  List<MapEntry<String, String>> apkUrls,
  String? apkFilterRegEx,
  bool? invert,
) {
  if (apkFilterRegEx?.isNotEmpty == true) {
    var reg = RegExp(apkFilterRegEx!);
    apkUrls = apkUrls.where((element) {
      var hasMatch = reg.hasMatch(element.key);
      return invert == true ? !hasMatch : hasMatch;
    }).toList();
  }
  return apkUrls;
}

bool isEnglish() => tr('and') == 'and'; // Quick hack, find a better way
String lowerCaseIfEnglish(String str) => isEnglish() ? str.toLowerCase() : str;

bool isVersionPseudo(App app) =>
    app.additionalSettings['trackOnly'] == true ||
    (app.installedVersion != null &&
        (app.additionalSettings['versionDetection'] == 'pseudo' ||
            app.additionalSettings['versionDetection'] == false));

String toTitleCase(String text) {
  if (text.isEmpty) return text;
  return text
      .split(RegExp(r'[\s\-_]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

class SourceProvider {
  static final Map<String, RegExp> _sourceRegexCache = {};

  // Add more source classes here so they are available via the service.
  // Single source of truth: factories. Constructing an AppSource is expensive
  // (each constructor builds its localized form-item tree via many tr() calls),
  // and the previous `sources` getter rebuilt all ~25 of them on every access —
  // and getSource() accessed it 1-2× per call, ~3× per app on load (≈30k
  // constructions for a 400-app library). We now match against cached, never-
  // mutated template instances and only construct ONE fresh source — the matched
  // one — so each caller still gets its own isolated, mutable instance.
  // Order: host-based sources are listed alphabetically by their display name
  // (`AppSource.name`) — this same list is what the add-app supported-sources
  // tooltip and the filter-apps sheet render, in order, so the user-visible list
  // reads alphabetically. Note the sort key is the *display* name, which a few
  // sources override (e.g. Codeberg → "Forgejo (Codeberg)" sorts under F), not the class name.
  // The two hostless, pattern-matched fallbacks are pinned to the end instead:
  // matching walks this list in order, and these match by URL *shape* rather than
  // host, so they must be tried only after every host-based source. DirectAPKLink
  // (accepts only .apk URLs) must precede HTML (the universal catch-all) — so HTML
  // stays ALWAYS last. If you add another hostless catch-all source, order it so
  // more-specific matchers come first.
  static final List<AppSource Function()> _sourceFactories =
      <AppSource Function()>[
        () => Apk4Free(),
        () => APKMirror(),
        () => APKPure(),
        () => Aptoide(),
        () => CoolApk(),
        () => Farsroid(),
        () => FDroid(),
        () => FDroidRepo(),
        () => Codeberg(), // "Forgejo (Codeberg)"
        () => GitHub(),
        () => GitLab(),
        () => HuaweiAppGallery(), // "Huawei AppGallery"
        () => ItchIO(), // "itch.io"
        () => IzzyOnDroid(),
        () => Jenkins(),
        () => LiteAPKs(),
        () => NeutronCode(),
        () => RockMods(),
        () => RuStore(),
        () => SourceHut(),
        () => TelegramApp(), // "Telegram <app>"
        () => Tencent(),
        () => Uptodown(),
        () => VivoAppStore(),
        () => DirectAPKLink(),
        () => HTML(),
      ];

  // Lazily-built, never-mutated, never-returned template instances used only for
  // source matching (reading hosts / allowSubDomains). Built once for the app.
  static List<AppSource>? _sourceTemplatesCache;
  static List<AppSource> get _sourceTemplates => _sourceTemplatesCache ??=
      _sourceFactories.map((factory) => factory()).toList();

  // Public API unchanged: still returns fresh instances (callers may mutate).
  List<AppSource> get sources =>
      _sourceFactories.map((factory) => factory()).toList();

  // Read-only view for callers that only read source properties (name, hosts,
  // sourceConfigSettingFormItems) and never mutate the instances — e.g. the
  // settings source-specific section and the filter-by-source sheet. Returns
  // the shared cached templates so these callers don't reconstruct all ~25
  // sources (each running many tr() calls) on every build. Callers MUST NOT
  // mutate the returned instances; use `sources` if you need a fresh copy.
  List<AppSource> get sourceTemplates => _sourceTemplates;

  // Add more mass url source classes here so they are available via the service.
  // Lazily built and cached: constructing a MassAppUrlSource runs tr() calls,
  // and SourceProvider() is instantiated per app-list row / per build, so an
  // eager field initializer rebuilt GitHubStars on every one. Read-only at all
  // call sites (only ever `.map`-ed over), so a shared cached list is safe.
  static List<MassAppUrlSource>? _massUrlSourcesCache;
  List<MassAppUrlSource> get massUrlSources =>
      _massUrlSourcesCache ??= [GitHubStars()];

  // `naiveStandardVersionDetection` depends only on the resolved source (which is
  // a function of host + overrideSource), so cache it per host to avoid a
  // getSource() per app in the install-status reconcile hot path.
  static final Map<String, bool> _naiveStandardVersionDetectionCache = {};
  bool naiveStandardVersionDetectionForUrl(
    String url, {
    String? overrideSource,
  }) {
    final String host = Uri.tryParse(url)?.host ?? url;
    final String key = '${overrideSource ?? ''} $host';
    return _naiveStandardVersionDetectionCache[key] ??= getSourceTemplate(
      url,
      overrideSource: overrideSource,
    ).naiveStandardVersionDetection;
  }

  AppSource getSource(String url, {String? overrideSource}) {
    url = preStandardizeUrl(url);
    final int idx = _matchSourceIndexForStandardizedUrl(
      url,
      overrideSource: overrideSource,
    );
    final AppSource res = _sourceFactories[idx]();
    if (overrideSource != null) {
      final originalHosts = res.hosts;
      final newHost = Uri.parse(url).host;
      res.hosts = [newHost];
      res.hostChanged = true;
      if (originalHosts.contains(newHost)) {
        res.hostIdenticalDespiteAnyChange = true;
      }
    }
    return res;
  }

  /// Read-only source resolution: returns the shared, never-mutated template for
  /// the matched source instead of constructing a fresh instance. Use this on hot
  /// paths that only need the source's type or its (type-level) form items /
  /// flags — e.g. JSON compatibility migration and version-detection checks — so
  /// loading a large library doesn't construct a source per app. Callers MUST NOT
  /// mutate the returned instance.
  AppSource getSourceTemplate(String url, {String? overrideSource}) {
    return _sourceTemplates[_matchSourceIndexForStandardizedUrl(
      preStandardizeUrl(url),
      overrideSource: overrideSource,
    )];
  }

  // Matches a (pre-standardized) URL to a source index without constructing any
  // source. Matching only reads template hosts/flags and calls
  // sourceSpecificStandardizeURL, which is a side-effect-free URL transform for
  // the empty-host sources it is used on, so it is safe against shared templates.
  int _matchSourceIndexForStandardizedUrl(
    String url, {
    String? overrideSource,
  }) {
    final List<AppSource> templates = _sourceTemplates;
    if (overrideSource != null) {
      final int idx = templates.indexWhere(
        (e) => e.runtimeType.toString() == overrideSource,
      );
      if (idx < 0) {
        throw UnsupportedURLError();
      }
      return idx;
    }
    for (int i = 0; i < templates.length; i++) {
      final s = templates[i];
      if (s.hosts.isEmpty) {
        continue;
      }
      try {
        final cacheKey = '${s.allowSubDomains}:${s.hosts.join(',')}';
        final regex = SourceProvider._sourceRegexCache[cacheKey] ??= RegExp(
          '^${s.allowSubDomains ? '([^\\.]+\\.)*' : '(www\\.)?'}(${getSourceRegex(s.hosts)})\$',
        );
        if (regex.hasMatch(Uri.parse(url).host)) {
          return i;
        }
      } catch (e) {
        // Ignore
      }
    }
    for (int i = 0; i < templates.length; i++) {
      final s = templates[i];
      if (s.hosts.isNotEmpty || s.neverAutoSelect) {
        continue;
      }
      try {
        s.sourceSpecificStandardizeURL(url, forSelection: true);
        return i;
      } catch (e) {
        //
      }
    }
    throw UnsupportedURLError();
  }

  bool ifRequiredAppSpecificSettingsExist(AppSource source) {
    for (var row in source.combinedAppSpecificSettingFormItems) {
      for (var element in row) {
        if (element is GeneratedFormTextField && element.required) {
          return true;
        }
      }
    }
    return false;
  }

  String generateTempID(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) => (standardUrl + additionalSettings.toString()).hashCode.toString();

  Future<App> getApp(
    AppSource source,
    String url,
    Map<String, dynamic> additionalSettings, {
    App? currentApp,
    bool trackOnlyOverride = false,
    bool sourceIsOverriden = false,
    bool inferAppIdIfOptional = false,
  }) async {
    if (trackOnlyOverride || source.enforceTrackOnly) {
      additionalSettings['trackOnly'] = true;
    }
    syncVersionStringSourceSettings(additionalSettings);
    String standardUrl = source.standardizeUrl(url);
    // Hand the source the previously-known app so it can skip redundant
    // verification round-trips when the upstream release hasn't changed.
    source.previouslyCheckedApp = currentApp;
    APKDetails apk = await source.getLatestAPKDetails(
      standardUrl,
      additionalSettings,
    );
    final String? rawApkNamesFromSource = encodeRawAssistLines(
      apk.apkUrls.map((MapEntry<String, String> entry) => entry.key),
    );
    final String? rawReleaseTitlesFromSource = encodeRawAssistLines(
      apk.rawReleaseTitleCandidates,
    );
    var trackOnly = additionalSettings['trackOnly'] == true;
    final String rawLatestVersionFromSource = apk.version;

    if (additionalSettings['releaseDateAsVersion'] == true &&
        apk.releaseDate != null) {
      apk.version = apk.releaseDate!.toUtc().toIso8601String();
    }

    if (source.runtimeType !=
            HTML().runtimeType && // Some sources do it separately
        source.runtimeType != SourceForge().runtimeType) {
      String? extractedVersion = extractVersion(
        additionalSettings['versionExtractionRegEx'] as String?,
        additionalSettings['matchGroupToUse'] as String?,
        apk.version,
      );
      if (extractedVersion != null) {
        apk.version = extractedVersion;
      }
    }
    apk.apkUrls = filterApks(
      apk.apkUrls,
      additionalSettings['apkFilterRegEx'],
      additionalSettings['invertAPKFilter'],
    );
    if (apk.apkUrls.isEmpty && !trackOnly) {
      throw NoAPKError();
    }
    if (additionalSettings['autoApkFilterByArch'] == true) {
      apk.apkUrls = await filterApksByArch(apk.apkUrls);
    }
    String sourceName = apk.names.name.trim();
    if (sourceName.isNotEmpty) {
      sourceName = toTitleCase(sourceName);
    }
    var name = currentApp != null ? currentApp.name.trim() : '';
    if (name.isEmpty ||
        name == currentApp?.id ||
        (looksLikeAndroidPackageId(name) &&
            sourceName.isNotEmpty &&
            sourceName != name)) {
      name = sourceName.isNotEmpty ? sourceName : name;
    }
    final String? resolvedReproducibleStatus =
        apk.reproducibleStatus ??
        (apk.isReproducible != null
            ? reproducibleBuildStatusFromBool(apk.isReproducible)
            : currentApp != null && currentApp.latestVersion == apk.version
            ? currentApp.latestReproducibleStatus
            : null);
    App finalApp = App(
      currentApp?.id ??
          ((additionalSettings['appId'] != null)
              ? additionalSettings['appId']
              : null) ??
          ((!source.appIdInferIsOptional ||
                  (source.appIdInferIsOptional && inferAppIdIfOptional))
              ? await source.tryInferringAppId(
                  standardUrl,
                  additionalSettings: additionalSettings,
                )
              : null) ??
          generateTempID(standardUrl, additionalSettings),
      standardUrl,
      apk.names.author,
      name,
      currentApp?.installedVersion,
      apk.version,
      apk.apkUrls,
      apk.apkUrls.length - 1 >= 0 ? apk.apkUrls.length - 1 : 0,
      additionalSettings,
      DateTime.now(),
      currentApp?.pinned ?? false,
      categories: currentApp?.categories ?? const [],
      releaseDate: apk.releaseDate,
      changeLog: apk.changeLog,
      overrideSource: sourceIsOverriden
          ? source.runtimeType.toString()
          : currentApp?.overrideSource,
      allowIdChange:
          currentApp?.allowIdChange ??
          trackOnly ||
              (source.appIdInferIsOptional &&
                  inferAppIdIfOptional), // Optional ID inferring may be incorrect - allow correction on first install
      otherAssetUrls: apk.allAssetUrls
          .where((a) => apk.apkUrls.indexWhere((p) => a.key == p.key) < 0)
          .toList(),
      iconUrl: apk.iconUrl ?? currentApp?.iconUrl,
      rawLatestVersionFromSource: rawLatestVersionFromSource,
      rawApkNamesFromSource: rawApkNamesFromSource,
      rawReleaseTitlesFromSource: rawReleaseTitlesFromSource,
      // Cache key for the size is effectively (appId, latestVersion):
      // we keep the previously-resolved size when version is unchanged,
      // and clear it whenever the source reports a new version. This
      // applies uniformly to every source - including APKMirror, whose
      // size is now resolved lazily on the AppPage. The previous
      // `source is APKMirror ? null : ...` distrust treatment is gone:
      // it was compensating for an unreliable in-update-check resolver
      // that no longer exists.
      apkSizeBytes:
          apk.apkSizeBytes ??
          (currentApp != null && currentApp.latestVersion == apk.version
              ? currentApp.apkSizeBytes
              : null),
      latestIsReproducible: reproducibleBuildBoolFromStatus(
        resolvedReproducibleStatus,
      ),
      latestReproducibleStatus: resolvedReproducibleStatus,
      latestAttestationStatus:
          apk.attestationStatus ??
          (currentApp != null && currentApp.latestVersion == apk.version
              ? currentApp.latestAttestationStatus
              : null),
    );
    return source.endOfGetAppChanges(finalApp);
  }

  // Returns errors in [results, errors] instead of throwing them
  Future<List<dynamic>> getAppsByURLNaive(
    List<String> urls, {
    List<String> alreadyAddedUrls = const [],
    AppSource? sourceOverride,
  }) async {
    List<App> apps = [];
    Map<String, dynamic> errors = {};
    for (var url in urls) {
      try {
        if (alreadyAddedUrls.contains(url)) {
          throw ObtainiumError(tr('appAlreadyAdded'));
        }
        var source = sourceOverride ?? getSource(url);
        apps.add(
          await getApp(
            source,
            url,
            sourceIsOverriden: sourceOverride != null,
            getDefaultValuesFromFormItems(
              source.combinedAppSpecificSettingFormItems,
            ),
          ),
        );
      } catch (e) {
        errors.addAll(<String, dynamic>{url: e});
      }
    }
    return [apps, errors];
  }
}
