// ========================================================================
// App JSON migration — legacy schema transformations applied on load.
// ========================================================================

import 'dart:convert';

import 'package:obtainium/app_sources/app_source.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/app_sources/huaweiappgallery.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/source_provider.dart' show SourceProvider;
import 'package:obtainium/services/apk_filter_service.dart';
import 'package:obtainium/version/version_detection_mode.dart';

Map<String, dynamic> _migrateAppToHTML(
  Map<String, dynamic> json,
  Map<String, dynamic> additionalSettings, {
  required String newUrl,
  Map<String, dynamic>? overrides,
}) {
  json['url'] = newUrl;
  final replacement = getDefaultValuesFromFormItems(
    HTML().combinedAppSpecificSettingFormItems,
  );
  for (var s in replacement.keys) {
    if (additionalSettings.containsKey(s)) {
      replacement[s] = additionalSettings[s];
    }
  }
  if (overrides != null) replacement.addAll(overrides);
  return replacement;
}

/// Migrates old-style `additionalData` array (list of strings) to the
/// newer `additionalSettings` map, keyed by form-item key.
void _migrateAdditionalDataToSettings(
  Map<String, dynamic> json,
  Map<String, dynamic> additionalSettings,
  List<GeneratedFormItem> formItems,
) {
  if (json['additionalData'] == null) return;
  final decoded = jsonDecode(json['additionalData']);
  if (decoded is! List) return;
  final List<String> temp = List<String>.from(decoded);
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
      json['noVersionDetection'] == 'true' ||
      json['noVersionDetection'] == true ||
      // Ancient additionalData-format apps: track-only implies no version
      // detection (parity with fork main).
      json['trackOnly'] == true;
}

/// Converts legacy booleans `noVersionDetection` / `releaseDateAsVersion`
/// to the current `versionDetection` string dropdown and back.
void _migrateVersionDetectionFormat(Map<String, dynamic> additionalSettings) {
  // Legacy bool-style flags → intermediate dropdown keys.
  if (additionalSettings['noVersionDetection'] == true) {
    additionalSettings['versionDetection'] = 'noVersionDetection';
    if (additionalSettings['releaseDateAsVersion'] == true) {
      additionalSettings['versionDetection'] = 'releaseDateAsVersion';
    }
    additionalSettings.remove('noVersionDetection');
    additionalSettings.remove('releaseDateAsVersion');
  }
  // 'releaseDateAsVersion' additionally carries a version-string choice, which
  // [VersionDetectionMode.fromStored] (a pure mode parse) can't express — apply
  // that side effect before normalising.
  if (additionalSettings['versionDetection'] == 'releaseDateAsVersion') {
    additionalSettings['releaseDateAsVersion'] = true;
  }
  // Every other legacy encoding (bools, the pre-dropdown strings) is handled by
  // [VersionDetectionMode.fromStored]; this rewrites the stored value to the
  // canonical mode key and re-derives useVersionCodeAsOSVersion. It MUST land on
  // a string, never a bool — a bool makes every installed app read as
  // pseudo-versioned (see isVersionPseudo) and breaks update detection.
  normalizeVersionDetectionSettings(
    additionalSettings,
    promoteLegacyBoolean: true,
  );
}

/// Converts legacy `supportFixedAPKURL` bool to `defaultPseudoVersioningMethod`.
void _migratePseudoVersioningMethod(
  Map<String, dynamic> originalAdditionalSettings,
  Map<String, dynamic> additionalSettings,
) {
  if (originalAdditionalSettings['supportFixedAPKURL'] == true) {
    additionalSettings['defaultPseudoVersioningMethod'] = 'partialAPKHash';
  } else if (originalAdditionalSettings['supportFixedAPKURL'] == false) {
    additionalSettings['defaultPseudoVersioningMethod'] = 'APKLinkHash';
  }
}

/// Ensures every known form item's value is coerced to its declared type.
void _coerceAdditionalSettingTypes(
  Map<String, dynamic> additionalSettings,
  List<GeneratedFormItem> formItems,
) {
  for (var item in formItems) {
    if (additionalSettings[item.key] != null) {
      additionalSettings[item.key] = item.ensureType(
        additionalSettings[item.key],
      );
    }
  }
}

/// Resolves legacy saved forms where switches that now turn each other off
/// were both enabled. Form order determines priority.
void _normalizeMutuallyExclusiveSwitches(
  Map<String, dynamic> additionalSettings,
  List<GeneratedFormItem> formItems,
) {
  for (final GeneratedFormItem item in formItems) {
    if (item is! GeneratedFormSwitch || additionalSettings[item.key] != true) {
      continue;
    }
    for (final String targetKey in item.turnsOffKeys) {
      additionalSettings[targetKey] = false;
    }
  }
}

/// Normalises `apkUrls` to the current 2D-list JSON format.
void _migrateApkUrlsFormat(Map<String, dynamic> json) {
  if (json['apkUrls'] == null) return;
  final apkUrlJson = jsonDecode(json['apkUrls']);
  List<MapEntry<String, String>> apkUrls;
  try {
    apkUrls = getApkUrlsFromUrls(List<String>.from(apkUrlJson));
  } catch (e) {
    apkUrls = assumed2DlistToStringMapList(List<dynamic>.from(apkUrlJson));
  }
  json['apkUrls'] = jsonEncode(stringMapListTo2DList(apkUrls));
}

/// Applies HTML-source-specific one-time migrations: key renames,
/// intermediate-link format upgrade, and legacy-source → HTML conversions
/// (Steam, Signal, WhatsApp, VLC).
Map<String, dynamic> _migrateHtmlSpecificMigrations(
  Map<String, dynamic> json,
  Map<String, dynamic> originalAdditionalSettings,
  Map<String, dynamic> additionalSettings,
) {
  if (originalAdditionalSettings['sortByFileNamesNotLinks'] != null) {
    additionalSettings['sortByLastLinkSegment'] =
        originalAdditionalSettings['sortByFileNamesNotLinks'];
  }
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

  final legacySteamSourceApps = ['steam', 'steam-chat-app'];
  if (legacySteamSourceApps.contains(additionalSettings['app'] ?? '')) {
    additionalSettings = _migrateAppToHTML(
      json,
      additionalSettings,
      newUrl: '${json['url']}/mobile',
      overrides: {
        'customLinkFilterRegex':
            '/${additionalSettings['app']}-(([0-9]+\\.?){1,})\\.apk',
        'versionExtractionRegEx':
            '/${additionalSettings['app']}-(([0-9]+\\.?){1,})\\.apk',
        'matchGroupToUse': '\$1',
      },
    );
  }
  if (json['url'] == 'https://signal.org' &&
      json['id'] == 'org.thoughtcrime.securesms' &&
      json['author'] == 'Signal' &&
      json['name'] == 'Signal' &&
      json['overrideSource'] == null &&
      additionalSettings['trackOnly'] == false &&
      additionalSettings['versionExtractionRegEx'] == '' &&
      json['lastUpdateCheck'] != null) {
    additionalSettings = _migrateAppToHTML(
      json,
      additionalSettings,
      newUrl: 'https://updates.signal.org/android/latest.json',
      overrides: {'versionExtractionRegEx': r'\d+.\d+.\d+'},
    );
  }
  if (json['url'] == 'https://whatsapp.com' &&
      json['id'] == 'com.whatsapp' &&
      json['author'] == 'Meta' &&
      json['name'] == 'WhatsApp' &&
      json['overrideSource'] == null &&
      additionalSettings['trackOnly'] == false &&
      additionalSettings['versionExtractionRegEx'] == '' &&
      json['lastUpdateCheck'] != null) {
    additionalSettings = _migrateAppToHTML(
      json,
      additionalSettings,
      newUrl: 'https://whatsapp.com/android',
      overrides: {'refreshBeforeDownload': true},
    );
  }
  if (json['url'] == 'https://videolan.org' &&
      json['id'] == 'org.videolan.vlc' &&
      json['author'] == 'VideoLAN' &&
      json['name'] == 'VLC' &&
      json['overrideSource'] == null &&
      additionalSettings['trackOnly'] == false &&
      additionalSettings['versionExtractionRegEx'] == '' &&
      json['lastUpdateCheck'] != null) {
    additionalSettings = _migrateAppToHTML(
      json,
      additionalSettings,
      newUrl: 'https://www.videolan.org/vlc/download-android.html',
      overrides: {
        'refreshBeforeDownload': true,
        'intermediateLink': <Map<String, dynamic>>[
          {
            'customLinkFilterRegex': 'APK',
            'filterByLinkText': true,
            'skipSort': false,
            'reverseSort': false,
            'sortByLastLinkSegment': false,
          },
          {
            'customLinkFilterRegex': r'arm64-v8a\.apk$',
            'filterByLinkText': false,
            'skipSort': false,
            'reverseSort': false,
            'sortByLastLinkSegment': false,
          },
        ],
        'versionExtractionRegEx': '/vlc-android/([^/]+)/',
        'matchGroupToUse': '1',
      },
    );
  }
  return additionalSettings;
}

/// One-time migration for Huawei AppGallery apps saved while the source
/// forced pseudo-versioning by release date (upstream be702b3c), before it
/// moved to the AppGallery API, which reports real version names.
///
/// Adapted to ObtainX: `versionDetection` is a string mode (never a bool) and
/// release-date versions are ISO-8601 here, epoch digits in Obtainium backups.
/// It triggers only on that release-date state, which the API source no longer
/// offers, so it stays idempotent. An app that is merely `pseudo` keeps its
/// mode: that is a legitimate choice this cannot tell apart from the old pin.
void _migrateHuaweiAppGallery(
  Map<String, dynamic> json,
  Map<String, dynamic> additionalSettings,
) {
  bool isPseudoVersion(dynamic v) =>
      v is String &&
      (RegExp(r'^\d{10,}$').hasMatch(v) ||
          RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}').hasMatch(v));
  final hasLegacyState =
      additionalSettings['releaseDateAsVersion'] == true ||
      additionalSettings['versionStringSource'] ==
          versionStringSourceReleaseDate ||
      isPseudoVersion(json['installedVersion']) ||
      isPseudoVersion(json['latestVersion']);
  if (!hasLegacyState) return;
  additionalSettings['versionDetection'] = VersionDetectionMode.auto.key;
  additionalSettings['versionStringSource'] = versionStringSourceDefault;
  syncVersionStringSourceSettings(additionalSettings);
  normalizeVersionDetectionSettings(additionalSettings);
  if (isPseudoVersion(json['installedVersion'])) {
    json['installedVersion'] = null;
  }
}

/// Migrates F-Droid cloudflare URLs to override-source and auto-detects
/// third-party F-Droid repo URLs.
void _migrateFdroidOverrides(Map<String, dynamic> json) {
  final overrideSourceWasUndefined = !json.keys.contains('overrideSource');
  if ((json['url'] as String).startsWith('https://cloudflare.f-droid.org')) {
    json['overrideSource'] = FDroid().sourceIdentifier;
  } else if (overrideSourceWasUndefined) {
    final RegExpMatch? match = RegExp(
      '^https?://.+/fdroid/([^/]+(/|\\?)|[^/]+\$)',
    ).firstMatch(json['url'] as String);
    if (match != null) {
      json['overrideSource'] = FDroidRepo().sourceIdentifier;
    }
  }
}

/// Applies any legacy JSON transformations so the stored [json] matches the
/// current schema. All transformations are idempotent, so they run on every
/// load.
Map<String, dynamic> appJSONCompatibilityModifiers(Map<String, dynamic> json) {
  final source = SourceProvider().getSource(
    json['url'],
    overrideSource: json['overrideSource'],
  );
  final formItems = source.flatCombinedFormItemsReadOnly;
  Map<String, dynamic> additionalSettings = getDefaultValuesFromFormItems([
    formItems,
  ]);
  Map<String, dynamic> originalAdditionalSettings = {};
  if (json['additionalSettings'] != null) {
    originalAdditionalSettings = Map<String, dynamic>.from(
      jsonDecode(json['additionalSettings']),
    );
    additionalSettings.addEntries(originalAdditionalSettings.entries);
  }

  _migrateAdditionalDataToSettings(json, additionalSettings, formItems);
  _migrateVersionDetectionFormat(additionalSettings);
  // Populate the versionStringSource string from any legacy per-method boolean
  // flags so the unified dropdown pre-fills correctly (parity with fork main,
  // which syncs here during deserialization). Prefer an already-configured
  // string value when the app has one.
  syncVersionStringSourceSettings(
    additionalSettings,
    preferConfiguredSource: originalAdditionalSettings.containsKey(
      'versionStringSource',
    ),
  );
  _migratePseudoVersioningMethod(
    originalAdditionalSettings,
    additionalSettings,
  );
  _coerceAdditionalSettingTypes(additionalSettings, formItems);
  _normalizeMutuallyExclusiveSwitches(additionalSettings, formItems);

  int preferredApkIndex = json['preferredApkIndex'] == null
      ? 0
      : json['preferredApkIndex'] as int;
  if (preferredApkIndex < 0) {
    preferredApkIndex = 0;
  }
  json['preferredApkIndex'] = preferredApkIndex;
  _migrateApkUrlsFormat(json);

  if (additionalSettings['autoApkFilterByArch'] == null) {
    additionalSettings['autoApkFilterByArch'] = false;
  }
  if (additionalSettings['dontSortReleasesList'] == true) {
    additionalSettings['sortMethodChoice'] = 'none';
  }

  if (source is HTML) {
    additionalSettings = _migrateHtmlSpecificMigrations(
      json,
      originalAdditionalSettings,
      additionalSettings,
    );
  }

  if (source is HuaweiAppGallery) {
    _migrateHuaweiAppGallery(json, additionalSettings);
  }

  json['additionalSettings'] = jsonEncode(additionalSettings);
  _migrateFdroidOverrides(json);
  return json;
}

/// Upstream's name for loading a stored app. [App.fromJson] already applies
/// [appJSONCompatibilityModifiers] (and falls back to the unmigrated JSON), so
/// this is a plain alias that must not migrate a second time.
App appFromStoredJson(Map<String, dynamic> json) => App.fromJson(json);
