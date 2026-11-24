import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show mapEquals;

import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/huaweiappgallery.dart';
import 'package:obtainium/core/logging/app_logger.dart';
import 'package:obtainium/custom_errors.dart';

import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/providers/virustotal_provider.dart';
import 'package:obtainium/services/json_file_work.dart';
import 'package:obtainium/utils/app_id_utils.dart';
import 'package:obtainium/utils/color_utils.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

/// Secret settings excluded from the "settings without secrets" backup mode.
/// Source credentials conventionally end in `-creds`. Validation fingerprints
/// are hashes of those tokens, so a "no secrets" backup must omit them too -
/// otherwise the hash travels with the file and the token is still recoverable
/// by anyone who later obtains it, and import would restore a shield with no
/// matching PAT. VirusTotal predates the `-creds` convention, so its key and
/// fingerprint are listed explicitly.
bool isSecretSettingKey(String key) {
  return key.endsWith('-creds') ||
      key == HuaweiAppGallery.sessionPrefsKey ||
      key == GitHub.validatedPATFingerprintKey ||
      key == GitLab.validatedPATFingerprintKey ||
      key == Codeberg.validatedTokenFingerprintKey ||
      key == virusTotalApiKeyKey ||
      key == virusTotalValidatedApiKeyFingerprintKey;
}

bool hasSecretsInSettingsMap(Map<String, dynamic>? settingsMap) {
  if (settingsMap == null || settingsMap.isEmpty) return false;
  return settingsMap.entries.any(
    (e) =>
        isSecretSettingKey(e.key) &&
        e.value != null &&
        e.value.toString().isNotEmpty,
  );
}

class BackupContent {
  final List<App> apps;
  final Map<String, dynamic>? settingsMap;

  /// The category colors the backup carries, from either place it can hold
  /// them ([categoryColorsFromBackup]).
  final Map<String, int>? categoryColors;
  final ExportSchema? schema;

  const BackupContent({
    required this.apps,
    this.settingsMap,
    this.categoryColors,
    this.schema,
  });
}

/// Formats an ARGB32 color integer as `#RRGGBB` for backup export.
String categoryColorHexFromInt(int argb) {
  final int rgb = argb & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

final RegExp _categoryColorHex = RegExp(r'^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

/// Parses a `#RRGGBB` / `#AARRGGBB` (with or without `#`) hex string into an
/// ARGB32 integer, returning null for invalid inputs.
int? parseCategoryColorHex(String rawHex) {
  final RegExpMatch? match = _categoryColorHex.firstMatch(rawHex.trim());
  if (match == null) return null;
  final String digits = match.group(1)!;
  final int parsed = int.parse(digits, radix: 16);
  return digits.length == 6 ? (0xFF000000 | parsed) : parsed;
}

/// The `categoryColors` an export writes, or null for none.
///
/// Exported settings already hold every color, in the `categories` setting, so
/// the colors are written here only when settings aren't exported, and only
/// for the categories the exported apps use.
Map<String, String>? categoryColorsForExport({
  required bool settingsExported,
  required Map<String, int> colors,
  required Iterable<Map<String, dynamic>> appJsons,
}) {
  if (settingsExported) return null;
  final Map<String, String> exported = <String, String>{};
  for (final Map<String, dynamic> appJson in appJsons) {
    final List<dynamic>? categories = appJson['categories'] as List?;
    if (categories == null) continue;
    for (final String name in categories.whereType<String>()) {
      final int? color = colors[name];
      if (color != null) exported[name] = categoryColorHexFromInt(color);
    }
  }
  return exported.isEmpty ? null : exported;
}

/// The category colors a backup carries, or null for none: its
/// `categoryColors` ([hexColors]) when it has them, else the `categories`
/// setting in its [settingsMap]. That setting is a JSON string, as the pref
/// stores it, in ObtainX and Obtainium backups alike.
///
/// The colors are read even when the settings aren't imported, so apps
/// imported without them keep their categories' colors.
Map<String, int>? categoryColorsFromBackup({
  Map<String, String>? hexColors,
  Map<String, dynamic>? settingsMap,
}) {
  final Map<String, int> colors = <String, int>{};
  if (hexColors != null && hexColors.isNotEmpty) {
    hexColors.forEach((String name, String hex) {
      final int? color = parseCategoryColorHex(hex);
      if (color != null) colors[name] = color;
    });
  } else {
    dynamic stored = settingsMap?['categories'];
    if (stored is String) {
      try {
        stored = jsonDecode(stored);
      } on FormatException {
        stored = null;
      }
    }
    if (stored is Map) {
      stored.forEach((dynamic name, dynamic color) {
        if (name is String && color is int) colors[name] = color;
      });
    }
  }
  return colors.isEmpty ? null : colors;
}

/// The category map an import leaves: [current] (empty after a restore, which
/// resets the settings first) with the backup's [backupColors] merged in.
///
/// With [settingsImported], every backup color is taken and wins over the
/// current one, as every other imported setting does. Without, only the
/// categories the [importedApps] use are added, and current colors stay.
/// Categories only [current] has are always kept: apps may still carry them.
///
/// A category that any app in [library] carries and that has no color still
/// gets [newColor]. The map is written once, and a category missing from it
/// would be stripped from every app ([SettingsProvider.setCategories]).
Map<String, int> categoriesAfterImport({
  required Map<String, int> current,
  required Map<String, int>? backupColors,
  required bool settingsImported,
  required Iterable<App> importedApps,
  required Iterable<App> library,
  required int Function() newColor,
}) {
  final Map<String, int> merged = Map<String, int>.from(current);
  if (backupColors != null) {
    final Set<String> importedCategories = importedApps
        .expand((App app) => app.categories)
        .toSet();
    backupColors.forEach((String name, int color) {
      if (settingsImported) {
        merged[name] = color;
      } else if (importedCategories.contains(name)) {
        merged.putIfAbsent(name, () => color);
      }
    });
  }
  for (final App app in library) {
    for (final String name in app.categories) {
      merged.putIfAbsent(name, newColor);
    }
  }
  return merged;
}

/// One app for Import from URL list to add: a typed URL, or an app that an
/// `obtainium://` link or app JSON described ([seed]). All of them are
/// fetched and saved the same way (see [fetchUrlImportEntry]).
class UrlImportEntry {
  const UrlImportEntry(this.url, {this.seed});

  final String url;
  final App? seed;
}

/// What an Import from URL list does with each entry, before anything is
/// fetched.
class UrlImportPlan {
  /// Entries to fetch, once each, in the order given.
  final List<UrlImportEntry> toFetch;

  /// Listings already tracked from one of the entries.
  final List<AppInMemory> alreadyTracked;

  const UrlImportPlan({required this.toFetch, required this.alreadyTracked});
}

/// Sorts [entries] into ones [listings] already tracks, which can be shown
/// right away, and ones whose app has to be fetched first.
///
/// An add never overwrites: saving over a tracked app would wipe its latest
/// version, pin, categories, folders and the user's settings edits. The same
/// package from a different store becomes a further listing, as in every add
/// flow; replacing a listing's store is the swap-source flow's job.
///
/// A typed URL matches on the URL the listing is stored under (the source's
/// standard form), which is all that can be known before fetching. An entry
/// that names its package matches on that package from the same store
/// ([sameStoreListingIn]), the way a link always has: one URL can build two
/// packages (a GitHub repo's `.gh` and `.offline` APKs). Anything else tracked
/// is only found once fetched.
UrlImportPlan planUrlImport(
  AppListings listings,
  List<UrlImportEntry> entries,
  SourceProvider sourceProvider,
) {
  final Map<String, AppInMemory> byUrl = {
    for (final AppInMemory listing in listings.values) listing.app.url: listing,
  };
  final List<UrlImportEntry> toFetch = [];
  final List<AppInMemory> alreadyTracked = [];
  final Set<String> seen = {};
  for (final UrlImportEntry entry in entries) {
    final String url = entry.url;
    String standardUrl = url;
    try {
      standardUrl = sourceProvider.getSource(url).standardizeUrl(url);
    } catch (_) {
      // Fetching it reports what is wrong with it.
    }
    final App? seed = entry.seed;
    final bool namesPackage = seed != null && !isTempId(seed);
    if (!seen.add(namesPackage ? '$standardUrl ${seed.id}' : standardUrl)) {
      continue;
    }
    final AppInMemory? tracked = namesPackage
        ? sameStoreListingIn(listings, seed)
        : byUrl[standardUrl] ?? byUrl[url];
    if (tracked == null) {
      toFetch.add(entry);
    } else if (!alreadyTracked.contains(tracked)) {
      alreadyTracked.add(tracked);
    }
  }
  return UrlImportPlan(toFetch: toFetch, alreadyTracked: alreadyTracked);
}

/// The settings a link's or JSON's [seed] app is fetched with: its own, as
/// Add app's fields would be filled in, with its package ID as the custom App
/// ID. A temporary ID is left out, so the real one is looked up as for a URL.
///
/// Folder memberships are left out: they name folders on the phone the app
/// came from. Smart folders still apply once it's saved.
Map<String, dynamic> urlImportSettingsFor(App seed) {
  final App copy = seed.deepCopy();
  clearAllFoldersFromApp(copy);
  return {...copy.additionalSettings, if (!isTempId(seed)) 'appId': seed.id};
}

/// Fetches [entry]'s app the way Import from URL list fetches a typed URL
/// ([SourceProvider.getAppByURLNaive], looking up the package ID). A link's or
/// JSON's app also brings what Add app would ask for: its settings (see
/// [urlImportSettingsFor]), a source it forces, and its categories.
Future<App> fetchUrlImportEntry(
  SourceProvider sourceProvider,
  UrlImportEntry entry, {
  required bool includePrereleases,
}) async {
  final App? seed = entry.seed;
  final String? forcedSource = seed?.overrideSource;
  final App app = await sourceProvider.getAppByURLNaive(
    entry.url,
    sourceOverride: forcedSource == null
        ? null
        : sourceProvider.getSource(entry.url, overrideSource: forcedSource),
    inferAppIds: true,
    includePrereleases: includePrereleases,
    settings: seed == null ? const {} : urlImportSettingsFor(seed),
  );
  return seed == null ? app : app.copyWith(categories: seed.categories);
}

/// A link's payload laid out for reading: indented, with each app's
/// `additionalSettings` expanded. The format carries that as a JSON string
/// inside the JSON, which reads as a wall of escapes. Display only; a payload
/// that doesn't decode comes back as it was.
String readableLinkPayload(String payload) {
  Object? expand(Object? value) {
    if (value is List) return value.map(expand).toList();
    if (value is Map) {
      return value.map((Object? key, Object? field) {
        if (key == 'additionalSettings' && field is String) {
          try {
            return MapEntry(key, jsonDecode(field));
          } catch (_) {
            // Shown as the string it is.
          }
        }
        return MapEntry(key, expand(field));
      });
    }
    return value;
  }

  try {
    return const JsonEncoder.withIndent('  ')
        .convert(expand(jsonDecode(payload)));
  } catch (_) {
    return payload;
  }
}

/// The installed version an imported [app] starts with (upstream #3531): the
/// one on this device, else the exported one for a track-only or
/// pseudo-versioned app, whose version is the user's mark rather than the
/// device's. Any other app that isn't installed here has none.
///
/// v1.7.5 sync D-02: asks [App.usesStandardVersionDetection], as
/// `versionDetection` is a string enum here. Upstream's
/// `getBool('versionDetection')` reads 'auto' and 'standard' as false and would
/// keep every app's exported version. Saving still runs the install-status
/// reconciliation, which clears the version again for an app it can verify
/// isn't installed: only track-only apps it can't verify (a temporary ID, or a
/// version the user marked) keep theirs.
String? resolveImportedInstalledVersion(
  App app,
  String? deviceInstalledVersion,
) {
  if (deviceInstalledVersion != null) return deviceInstalledVersion;
  if (app.settings.getBool('trackOnly') || !app.usesStandardVersionDetection) {
    return app.installedVersion;
  }
  return null;
}

/// [app] from a backup, ready to save: its installed version from
/// [resolveImportedInstalledVersion], and never "the package ID may change"
/// (upstream #3527). A file could otherwise carry that flag past the check that
/// stops an update from installing a different package.
App prepareImportedApp(App app, String? deviceInstalledVersion) => app.copyWith(
  installedVersion: resolveImportedInstalledVersion(
    app,
    deviceInstalledVersion,
  ),
  allowIdChange: false,
);

/// Whether [file], listed in the export folder, is an earlier auto-export that
/// a new one replaces: a timestamped `-auto.json`, or the fixed [customName]
/// file. Matched by display name, as a listed file's URI ends in its document
/// ID (`primary:Backups/name.json`), not its name.
bool isReplacedAutoExport(saf.DocumentFile file, String? customName) {
  final String name = file.name ?? file.uri.pathSegments.last.split('/').last;
  return name.endsWith('-auto.json') ||
      (customName != null && name == '$customName.json');
}

/// Import/export of app configurations for [AppsProvider].
extension AppsProviderImportExport on AppsProvider {
  /// Builds an exportable JSON map containing app data and optionally settings.
  Map<String, dynamic> generateExportJSON({
    List<String>? appIds,
    int? overrideExportSettings,
    SettingsProvider? sp,
  }) {
    // Build from the caller-provided provider (the UI's instance) rather than
    // the extension getter, so the export reflects the intended settings
    // (parity with fork main).
    final SettingsProvider settingsProvider = sp ?? this.settingsProvider;
    final selectedIds = appIds?.toSet();
    final folderNamesById = {
      for (final folder in settingsProvider.appFolders) folder.id: folder.name,
    };
    int shouldExportSettings = settingsProvider.exportSettings;
    if (overrideExportSettings != null) {
      shouldExportSettings = overrideExportSettings;
    }
    final appList = apps.values
        .where(
          (e) =>
              selectedIds == null ||
              selectedIds.contains(e.listingKey) ||
              selectedIds.contains(e.app.id),
        )
        .map((e) {
          // Inject a folderId→name map so folder membership can be restored
          // (by name) on a device with different folder IDs. Mirrors fork main.
          final appJson = e.app.toJson();
          final Map<String, dynamic> additionalSettings =
              Map<String, dynamic>.from(e.app.additionalSettings);
          final List<dynamic>? folderIds =
              additionalSettings['folderIds'] as List?;
          if (folderIds != null && folderIds.isNotEmpty) {
            final Map<String, String> folderNames = {};
            for (final folderId in folderIds) {
              final folderName = folderNamesById[folderId];
              if (folderName != null) {
                folderNames[folderId as String] = folderName;
              }
            }
            additionalSettings['folderNames'] = folderNames;
          }
          // Per-app credentials (an overridden source's token, e.g.
          // github-creds) live in additionalSettings, not prefs, so an export
          // without secrets strips them here too (upstream b0356157).
          if (shouldExportSettings < 2) {
            additionalSettings.removeWhere(
              (String key, dynamic _) => isSecretSettingKey(key),
            );
          }
          appJson['additionalSettings'] = jsonEncode(additionalSettings);
          return appJson;
        })
        .toList();
    Map<String, dynamic>? settingsMap;
    Map<String, dynamic>? settingsObtainXMap;
    if (shouldExportSettings > 0) {
      final settingsValueKeys = settingsProvider.prefs?.getKeys().toSet();
      if (shouldExportSettings < 2) {
        settingsValueKeys?.removeWhere(isSecretSettingKey);
      }
      final Map<String, dynamic> fullSettings =
          Map<String, dynamic>.fromEntries(
            (settingsValueKeys
                    ?.map(
                      (key) => MapEntry(key, settingsProvider.prefs?.get(key)),
                    )
                    .toList()) ??
                [],
          );
      final SplitExportSettings splitSettings = splitSettingsForExport(
        fullSettings,
      );
      settingsMap = splitSettings.settings;
      settingsObtainXMap = splitSettings.settingsObtainX;
    }
    final schema = ExportSchema(
      schemaVersion: currentExportSchemaVersion,
      exportedAt: DateTime.now().toIso8601String(),
      appVersion: kPackageVersion,
      apps: appList,
      settings: settingsMap,
      settingsObtainX: settingsObtainXMap,
      categoryColors: categoryColorsForExport(
        settingsExported: shouldExportSettings > 0,
        colors: settingsProvider.categories,
        appJsons: appList,
      ),
    );
    return schema.toJson();
  }

  /// Exports all app data (and optionally settings) as a JSON file to the configured export directory.
  Future<String?> export({
    bool pickOnly = false,
    isAuto = false,
    SettingsProvider? sp,
  }) async {
    final SettingsProvider settingsProvider = sp ?? this.settingsProvider;
    if (isAuto && !settingsProvider.autoExportOnChanges) {
      return null;
    }
    final String? customName = settingsProvider.autoExportFileName;
    var exportDir = await settingsProvider.getExportDir(
      warnIfInaccessible: true,
    );
    if (isAuto) {
      if (exportDir == null) {
        if (settingsProvider.prefs?.getString('exportDir') != null) {
          unawaited(
            logs.add(
              'Auto-export skipped: export directory permission unavailable',
            ),
          );
        }
        return null;
      }
      final files = await saf
          .listFiles(
            exportDir,
            columns: [
              saf.DocumentFileColumn.id,
              saf.DocumentFileColumn.displayName,
            ],
          )
          .where((f) => isReplacedAutoExport(f, customName))
          .toList();
      for (final f in files) {
        // Awaited so the old file is gone before its replacement (same custom
        // name) is created (upstream b0356157).
        await NativeFeatures.deleteDocument(f.uri);
      }
    }
    if (exportDir == null || pickOnly) {
      await settingsProvider.pickExportDir();
      exportDir = await settingsProvider.getExportDir(warnIfInaccessible: true);
    }
    if (exportDir == null) {
      return null;
    }
    String? returnPath;
    if (!pickOnly) {
      final Map<String, dynamic> finalExport = generateExportJSON(
        sp: settingsProvider,
      );
      final bytes = await encodeJsonBytesOffIsolate(
        finalExport,
        indent: '    ',
      );
      // An auto-export with a custom name keeps one fixed file, replaced each
      // time, instead of a new timestamped file per change.
      final String displayName = isAuto && customName != null
          ? '$customName.json'
          : '${tr('obtainiumExportHyphenatedLowercase')}-${DateTime.now().toIso8601String().replaceAll(':', '-')}${isAuto ? '-auto' : ''}.json';
      final result = await saf.createFile(
        exportDir,
        displayName: displayName,
        mimeType: 'application/json',
        bytes: bytes,
      );
      if (result == null) {
        throw ObtainiumError(tr('unexpectedError'));
      }
      // Any volume, so an SD card path reads right too (upstream 1d699fd9).
      returnPath = exportDir.pathSegments
          .join('/')
          .replaceFirst(RegExp(r'^tree/[^:]+:'), '/');
    }
    return returnPath;
  }

  /// Parses a backup JSON string into a [BackupContent] object.
  ///
  /// [idsAreHints]: the apps' IDs are only hints, as in `obtainium://` links
  /// and pasted app JSON (Import from URL list), where a missing `id` means
  /// "infer it from the source". An app with no ID and no listing ID is then
  /// accepted; any ID that is given must still be safe.
  BackupContent parseBackupContent(
    String appsJSON, {
    bool idsAreHints = false,
  }) {
    dynamic decodedJSON;
    try {
      decodedJSON = jsonDecode(appsJSON);
    } catch (e) {
      throw ObtainiumError('${tr('failedToImport')}: ${e.toString()}');
    }
    final hasSchemaVersion =
        decodedJSON is Map && decodedJSON.containsKey('schemaVersion');
    List<App> importedApps;
    ExportSchema? schema;
    try {
      if (hasSchemaVersion) {
        schema = ExportSchema.fromJson(decodedJSON as Map<String, dynamic>);
        importedApps = schema.apps.map((e) => App.fromJson(e)).toList();
      } else {
        final newFormat = decodedJSON is! List;
        importedApps =
            ((newFormat ? decodedJSON['apps'] : decodedJSON) as List<dynamic>)
                .map((e) => App.fromJson(e))
                .toList();
      }
    } catch (e) {
      throw ObtainiumError('${tr('failedToImport')}: ${e.toString()}');
    }
    // Upstream #3527 (v1.7.5 sync D-01): an ID that names a path outside the
    // apps folder rejects the whole backup. Checked here, at parse time, so it
    // runs before a restore resets settings and wipes the library, and so it
    // covers every reader: file import and restore, the backup picker, and
    // `obtainium://` links and pasted JSON (Import from URL list).
    for (final App app in importedApps) {
      // A link's app with no ID at all: Import from URL list infers it, and
      // the write guard checks whatever ID it ends up with (Phase C).
      if (idsAreHints && app.id.isEmpty && app.listingId == null) continue;
      if (!hasSafeStorageIds(app)) {
        AppLogger.warn(
          'Rejected import with unsafe app ID: ${app.id} (${app.listingKey})',
        );
        throw ObtainiumError(tr('invalidInput'));
      }
    }
    // Resolve settings: shared block plus optional ObtainX overlay.
    final Map<String, dynamic>? sharedSettings = hasSchemaVersion
        ? schema!.settings
        : (decodedJSON is Map
              ? decodedJSON['settings'] as Map<String, dynamic>?
              : null);
    final Map<String, dynamic>? settingsObtainXOverlay = hasSchemaVersion
        ? schema!.settingsObtainX
        : (decodedJSON is Map
              ? decodedJSON['settingsObtainX'] as Map<String, dynamic>?
              : null);
    final Map<String, dynamic>? settingsMap = mergeImportedSettingsMaps(
      sharedSettings,
      settingsObtainXOverlay,
    );
    return BackupContent(
      apps: appsWithImportedShizukuBackend(importedApps, settingsMap),
      settingsMap: settingsMap,
      categoryColors: categoryColorsFromBackup(
        hexColors: schema?.categoryColors,
        settingsMap: settingsMap,
      ),
      schema: schema,
    );
  }

  /// Imports apps (and optionally settings) from a JSON string, returning the parsed apps and a settings-present flag.
  ///
  /// [replaceExisting] is "restore" rather than "import": ObtainX's tracked
  /// apps AND its settings are both reset to out-of-the-box defaults first, so
  /// the result is OOTB-ObtainX-plus-whatever-the-backup-contains rather than
  /// the backup merged on top of whatever was there before. It never touches
  /// installed apps or their on-device data — only ObtainX's own state.
  ///
  /// File import and restore overwrite on purpose. Apps that are only added,
  /// never overwriting (links, Import from URL list), go through
  /// [AppsProvider.addFetchedApps] instead.
  Future<MapEntry<List<App>, bool>> import(
    String appsJSON, {
    Set<String>? selectedAppIds,
    bool importSettings = true,
    bool replaceExisting = false,
  }) async {
    final backupContent = parseBackupContent(appsJSON);
    List<App> importedApps = backupContent.apps;
    final settingsMap = backupContent.settingsMap;

    if (selectedAppIds != null) {
      importedApps = importedApps
          .where((a) => selectedAppIds.contains(a.id))
          .toList();
    }

    // Reset settings to OOTB before folder reconciliation reads
    // settingsProvider.appFolders, so a restore starts from a clean slate
    // instead of merging backup folders into whatever folders already existed.
    if (replaceExisting) {
      await settingsProvider.resetToDefaults();
    }

    // Merge backed-up folders into existing ones (by name) and remap each app's
    // folder references to the resolved IDs before saving.
    importedApps = _reconcileImportedFolders(
      importedApps,
      importSettings ? settingsMap : null,
    );

    await waitForAppsToLoad();
    if (replaceExisting) {
      final existingAppIds = apps.keys.toList();
      if (existingAppIds.isNotEmpty) {
        await removeApps(existingAppIds);
      }
    }
    for (var i = 0; i < importedApps.length; i++) {
      final a = importedApps[i];
      final installedInfo = await getInstalledInfo(a.id);
      importedApps[i] = prepareImportedApp(
        a,
        a.usesVersionCodeAsOsVersion
            ? installedInfo?.versionCode.toString()
            : installedInfo?.versionName,
      );
    }
    await saveApps(importedApps, onlyIfExists: false);
    bool hasSettings = false;
    if (importSettings && settingsMap != null) {
      hasSettings = true;
      // 'appFolders' is skipped: already merged/persisted by
      // _reconcileImportedFolders. 'categories' is skipped: it is merged with
      // the current categories below. Upstream settings ObtainX dropped aren't
      // written at all. Reload settings so the merged folder list (and
      // everything else) is reflected in memory immediately.
      _applyImportedSettings(
        settingsMap,
        skipKeys: const {
          'appFolders',
          'categories',
          ...droppedUpstreamSettingKeys,
        },
      );
      await settingsProvider.initializeSettings();
    }
    final Map<String, int> currentCategories = settingsProvider.categories;
    final Map<String, int> importedCategories = categoriesAfterImport(
      current: currentCategories,
      backupColors: backupContent.categoryColors,
      settingsImported: hasSettings,
      importedApps: importedApps,
      library: apps.values.map((AppInMemory listing) => listing.app),
      newColor: () => generateRandomLightColor().toARGB32(),
    );
    if (!mapEquals(importedCategories, currentCategories)) {
      settingsProvider.setCategories(importedCategories, appsProvider: this);
    }
    return MapEntry<List<App>, bool>(importedApps, hasSettings);
  }

  /// Merges backed-up folders into the existing folder list (matching by name,
  /// creating only the missing ones), then returns [importedApps] with each
  /// app's folderIds / excludedFolderIds / folderNames remapped from backup IDs
  /// to the resolved target IDs. Mirrors fork main, adapted for the immutable
  /// [App] (copyWith instead of in-place mutation).
  List<App> _reconcileImportedFolders(
    List<App> importedApps,
    Map<String, dynamic>? settingsMap,
  ) {
    final List<AppFolder> existingFolders = List<AppFolder>.from(
      settingsProvider.appFolders,
    );
    final Map<String, String> backupIdToTargetId = {};
    final List<AppFolder> foldersToCreate = [];
    final Map<String, AppFolder> backupFolders = {};
    final Map<String, String> backupFolderIdToName = {};

    // Folders from the backup's own folder list.
    final dynamic backupFoldersRaw = settingsMap?['appFolders'];
    if (backupFoldersRaw is String) {
      try {
        final list = jsonDecode(backupFoldersRaw) as List<dynamic>;
        for (final e in list) {
          final folder = AppFolder.fromJson(e as Map<String, dynamic>);
          backupFolders[folder.id] = folder;
          backupFolderIdToName[folder.id] = folder.name;
        }
      } catch (_) {}
    }
    // Names carried on the apps themselves.
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

    // Match each backup folder to an existing one by name, else schedule it.
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
        final AppFolder targetFolder =
            backupFolders[backupId] ?? AppFolder(id: backupId, name: name);
        foldersToCreate.add(targetFolder);
        backupIdToTargetId[backupId] = backupId;
      }
    });
    if (foldersToCreate.isNotEmpty) {
      existingFolders.addAll(foldersToCreate);
      settingsProvider.appFolders = existingFolders;
    }

    // Resolve a backup folder ID to its target ID, or null if it maps to no
    // known folder (drop the reference in that case).
    String? resolveId(String id) {
      final targetId = backupIdToTargetId[id];
      if (targetId != null) return targetId;
      if (existingFolders.any((f) => f.id == id)) return id;
      return null;
    }

    // Remap each app's folder references onto a fresh additionalSettings map.
    return importedApps.map((app) {
      final folderIds = folderIdsForApp(app);
      // Read the legacy exclusion list raw (not the merged view) so remapping
      // doesn't duplicate override-derived excludes into it — overrides are
      // remapped separately below.
      final rawExcluded = app.additionalSettings['excludedFolderIds'];
      final excludedIds = rawExcluded is List
          ? List<String>.from(rawExcluded)
          : const <String>[];
      final overridesRaw = app.additionalSettings['folderOverrides'];
      final hasOverrides = overridesRaw is Map && overridesRaw.isNotEmpty;
      if (folderIds.isEmpty && excludedIds.isEmpty && !hasOverrides) {
        return app;
      }
      final Map<String, dynamic> updated = Map<String, dynamic>.from(
        app.additionalSettings,
      );
      final Map<String, dynamic> updatedFolderNames = {};
      if (folderIds.isNotEmpty) {
        final List<String> updatedFolderIds = [];
        for (final id in folderIds) {
          final String? targetId = resolveId(id);
          if (targetId == null) continue;
          updatedFolderIds.add(targetId);
          final String folderName =
              backupFolderIdToName[id] ??
              existingFolders.firstWhere((f) => f.id == targetId).name;
          updatedFolderNames[targetId] = folderName;
        }
        updated['folderIds'] = updatedFolderIds;
      }
      if (excludedIds.isNotEmpty) {
        final List<String> updatedExcludedIds = [];
        for (final id in excludedIds) {
          final String? targetId = resolveId(id);
          if (targetId != null) updatedExcludedIds.add(targetId);
        }
        updated['excludedFolderIds'] = updatedExcludedIds;
      }
      // Remap the membership overrides (Always include / Always exclude) so
      // they survive folder-ID remapping instead of being silently lost.
      if (hasOverrides) {
        final Map<String, dynamic> updatedOverrides = {};
        overridesRaw.forEach((key, value) {
          final String? targetId = resolveId(key.toString());
          if (targetId != null) updatedOverrides[targetId] = value;
        });
        updated['folderOverrides'] = updatedOverrides;
      }
      updated['folderNames'] = updatedFolderNames;
      return app.copyWith(additionalSettings: updated);
    }).toList();
  }

  void _applyImportedSettings(
    Map<String, dynamic> settingsMap, {
    Set<String> skipKeys = const {},
  }) {
    settingsMap.forEach((key, value) {
      if (skipKeys.contains(key)) return;
      if (value is int) {
        settingsProvider.prefs?.setInt(key, value);
      } else if (value is double) {
        settingsProvider.prefs?.setDouble(key, value);
      } else if (value is bool) {
        settingsProvider.prefs?.setBool(key, value);
      } else if (value is List) {
        settingsProvider.prefs?.setStringList(
          key,
          value.whereType<String>().toList(),
        );
      } else if (value is String) {
        settingsProvider.setSettingString(key, value);
      }
    });
  }
}

const int obtainiumSortColumnCount = 4;
const String obtainXFolderViewSettingPrefix = 'folderView_';
// obtainXSettingsSectionPrefix lives in settings_provider.dart.

/// Pref keys with no counterpart in upstream Obtainium. They're kept out of
/// [SplitExportSettings.settings] (so an Obtainium import isn't polluted by keys
/// it can never use) and carried in [SplitExportSettings.settingsObtainX]
/// instead. Every other pref goes in [settings], matching Obtainium's own backup
/// format so Obtainium restores it directly.
///
/// Notably absent: grouping (`groupBy`) and the installer (`installMethod`).
/// ObtainX now persists both under upstream's own keys/values, so they are plain
/// shared settings — no translation, no overlay.
const Set<String> obtainXOnlySettingKeys = {
  'appFolders',
  'appAccentColorSource',
  'activeCustomSeedHex',
  'savedCustomSeedHexList',
  'appThemePaletteStyle',
  'progressiveBlurEnabled',
  'progressiveBlurDefaultMigrated',
  'reduceVisualEffects',
  'useGradientBackground',
  'shadingIntensity',
  'appUiScale',
  'cardCornerScale',
  'matchAppPageToIconColors',
  'showAppTypeBadge',
  'showTrackedStoreBadge',
  'showCategoriesBadge',
  'showAuthorBadge',
  'showVersionBadge',
  'saveDownloadedApkCopies',
  'apkSaveDir',
  'iconsDir',
  'rightSwipeAction',
  'leftSwipeAction',
  'rightSwipeActionName',
  'leftSwipeActionName',
  'swipeActionEnumVersion',
  'enableVirusTotalScanning',
  'githubValidatedPATFingerprint',
  'codeberg-validated-token-fingerprint',
  'openAppInfoInAppManager',
  'folderCriteriaMigrationVersion',
  'collapsedGroups',
  'showFolderedAppsOnMainPage',
  'groupNonInstalledSeparately',
  'groupTrackOnlySeparately',
  'groupUpdatesSeparately',
  'enableLetMeDowngrade',
  'lastCompletedBGCheckTime',
  'bgNextCheckDue',
  'showDebugOpts',
  'useFGService',
  'hideBatteryOptimizationWarning',
};

bool isObtainXOnlySettingKey(String key) {
  return obtainXOnlySettingKeys.contains(key) ||
      key.startsWith(obtainXFolderViewSettingPrefix) ||
      key.startsWith(obtainXSettingsSectionPrefix);
}

class SplitExportSettings {
  const SplitExportSettings({required this.settings, this.settingsObtainX});

  final Map<String, dynamic> settings;
  final Map<String, dynamic>? settingsObtainX;
}

/// Builds the Obtainium-facing [settings] block: every pref except ObtainX-only
/// keys, with the one value ObtainX can encode out of Obtainium's range
/// (`sortColumn`) sanitized. Shared keys (`groupBy`, `installMethod`, …) are
/// already Obtainium-compatible thanks to the settings convergence, so they pass
/// through verbatim.
Map<String, dynamic> buildObtainiumSettingsMap(
  Map<String, dynamic> fullSettings,
) {
  final Map<String, dynamic> settings = <String, dynamic>{};

  fullSettings.forEach((String key, dynamic value) {
    if (!isObtainXOnlySettingKey(key)) {
      settings[key] = value;
    }
  });

  sanitizeExportedSettingsForObtainium(settings);
  return settings;
}

/// Builds the ObtainX-only overlay: keys Obtainium can't use, plus the original
/// value of any setting [buildObtainiumSettingsMap] had to sanitize (so an
/// ObtainX self-import restores it exactly).
Map<String, dynamic> buildObtainXSettingsMap(
  Map<String, dynamic> fullSettings,
  Map<String, dynamic> obtainiumSettings,
) {
  final Map<String, dynamic> settingsObtainX = <String, dynamic>{};

  fullSettings.forEach((String key, dynamic value) {
    if (isObtainXOnlySettingKey(key)) {
      settingsObtainX[key] = value;
    }
  });

  // `sortColumn` is the only shared key ObtainX can set out of Obtainium's range
  // (its lastUpdateCheck = index 4). The shared block sanitized it; keep the real
  // value here so ObtainX's own import overrides the sanitized one.
  final dynamic fullSortColumn = fullSettings['sortColumn'];
  if (fullSortColumn != null &&
      fullSortColumn != obtainiumSettings['sortColumn']) {
    settingsObtainX['sortColumn'] = fullSortColumn;
  }
  final dynamic fullInstallMethod = fullSettings['installMethod'];
  if (fullInstallMethod != null &&
      fullInstallMethod != obtainiumSettings['installMethod']) {
    settingsObtainX['installMethod'] = fullInstallMethod;
  }

  return settingsObtainX;
}

/// Splits live prefs into a shared Obtainium-safe block and an ObtainX overlay.
SplitExportSettings splitSettingsForExport(Map<String, dynamic> fullSettings) {
  final Map<String, dynamic> settings = buildObtainiumSettingsMap(fullSettings);
  final Map<String, dynamic> settingsObtainX = buildObtainXSettingsMap(
    fullSettings,
    settings,
  );

  return SplitExportSettings(
    settings: settings,
    settingsObtainX: settingsObtainX.isEmpty ? null : settingsObtainX,
  );
}

/// Merges the shared settings block with the ObtainX overlay on import. The
/// overlay wins on conflicts (e.g. the real `sortColumn` over the sanitized
/// one), then [normalizeImportedSettings] maps upstream-only values.
Map<String, dynamic>? mergeImportedSettingsMaps(
  Map<String, dynamic>? sharedSettings,
  Map<String, dynamic>? settingsObtainX,
) {
  if (sharedSettings == null) {
    return null;
  }
  return normalizeImportedSettings(<String, dynamic>{
    ...sharedSettings,
    ...?settingsObtainX,
  });
}

/// Obtainium's Shizuku backend setting (`shizukuInstallerMode`, #2844) also
/// applies to apps whose per-app install method is Shizuku, so in Obtainium
/// those install through Dhizuku when the backend is Dhizuku. ObtainX has
/// Dhizuku as a mode of its own, so such apps get `installerMode: dhizuku`;
/// otherwise they'd use real Shizuku and fail on a Dhizuku-only device.
List<App> appsWithImportedShizukuBackend(
  List<App> apps,
  Map<String, dynamic>? settings,
) {
  if (settings?['shizukuInstallerMode'] != InstallerMode.dhizuku.name) {
    return apps;
  }
  return apps.map((App app) {
    if (app.additionalSettings['installerMode'] != InstallerMode.shizuku.name) {
      return app;
    }
    return app.copyWith(
      additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
        ..['installerMode'] = InstallerMode.dhizuku.name,
    );
  }).toList();
}

/// Obtainium reads `sortColumn` as an unchecked index into its 4-value
/// [SortColumnSettings]. ObtainX adds a 5th value
/// ([SortColumnSettings.lastUpdateCheck], index 4), which would crash
/// Obtainium's home screen on import — so clamp any out-of-range index to a safe
/// default in the shared block. (`groupBy` needs no such handling: Obtainium
/// tolerates unknown group values, falling back to none.)
void sanitizeExportedSettingsForObtainium(Map<String, dynamic> settings) {
  final dynamic sortColumn = settings['sortColumn'];
  if (sortColumn is int &&
      (sortColumn < 0 || sortColumn >= obtainiumSortColumnCount)) {
    settings['sortColumn'] = SortColumnSettings.releaseDate.index;
  }
  // Obtainium has no Dhizuku installer mode: since v1.7 it is a backend of its
  // Shizuku mode (#2844). Writing both keys makes Obtainium really install
  // through Dhizuku; ObtainX's own overlay keeps `installMethod: dhizuku`.
  if (settings['installMethod'] == InstallerMode.dhizuku.name) {
    settings['installMethod'] = InstallerMode.shizuku.name;
    settings['shizukuInstallerMode'] = InstallerMode.dhizuku.name;
  }
}

/// Maps an imported backup's settings onto ObtainX's, before
/// `droppedUpstreamSettingKeys` are skipped:
/// - Obtainium's Shizuku sub-backend (`shizukuInstallerMode`, #2844) picks
///   ObtainX's installer mode: `shizuku` + `dhizuku` → `dhizuku`; `auto` and
///   `shizuku` stay `shizuku`. The key itself is then dropped.
/// - `exportDir` is kept only as a `content://` folder: Obtainium's TV
///   Downloads sentinel `tv-downloads:` (or anything else) has no folder
///   behind it here, so every auto-export would fail with a toast (SET-H8).
Map<String, dynamic> normalizeImportedSettings(Map<String, dynamic> settings) {
  if (settings['installMethod'] == InstallerMode.shizuku.name &&
      settings['shizukuInstallerMode'] == InstallerMode.dhizuku.name) {
    settings['installMethod'] = InstallerMode.dhizuku.name;
  }
  // An older backup (ObtainX before the v1.7.4 sync, Obtainium before 1.7)
  // has only the Wi-Fi-only / charging-only switches. Write the guard key it
  // stands for too: a device that already stores the guard key reads that
  // first, so an Import would otherwise keep the device's choice (D5).
  for (final MapEntry<String, String> guard in bgGuardLegacyKeys.entries) {
    final dynamic legacy = settings[guard.value];
    if (legacy is bool && !settings.containsKey(guard.key)) {
      settings[guard.key] = bgGuardModeFromLegacy(legacy).name;
    }
  }
  final dynamic exportDir = settings['exportDir'];
  if (exportDir != null &&
      !(exportDir is String && exportDir.startsWith('content://'))) {
    settings.remove('exportDir');
  }
  return settings;
}

const int currentExportSchemaVersion = 2;
const String kPackageVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.0.0',
);

class ExportSchema {
  final int schemaVersion;
  final String exportedAt;
  final String appVersion;
  final List<Map<String, dynamic>> apps;
  final Map<String, dynamic>? settings;
  final Map<String, dynamic>? settingsObtainX;
  final Map<String, String>? categoryColors;

  ExportSchema({
    required this.schemaVersion,
    required this.exportedAt,
    required this.appVersion,
    required this.apps,
    this.settings,
    this.settingsObtainX,
    this.categoryColors,
  });

  factory ExportSchema.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'] as int? ?? 1;
    if (schemaVersion > currentExportSchemaVersion) {
      throw FormatException(
        tr(
          'backupCreatedByNewerVersion',
          args: [
            schemaVersion.toString(),
            currentExportSchemaVersion.toString(),
          ],
        ),
      );
    }
    return ExportSchema(
      schemaVersion: schemaVersion,
      exportedAt: json['exportedAt'] as String? ?? '',
      appVersion: json['appVersion'] as String? ?? '',
      apps:
          (json['apps'] as List<dynamic>?)
              ?.map((e) => e as Map<String, dynamic>)
              .toList() ??
          [],
      settings: json['settings'] as Map<String, dynamic>?,
      settingsObtainX: json['settingsObtainX'] as Map<String, dynamic>?,
      categoryColors: (json['categoryColors'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> json = <String, dynamic>{
      'schemaVersion': currentExportSchemaVersion,
      'exportedAt': exportedAt,
      'appVersion': appVersion,
      'apps': apps,
      'settings': settings,
    };
    if (settingsObtainX != null && settingsObtainX!.isNotEmpty) {
      json['settingsObtainX'] = settingsObtainX;
    }
    if (categoryColors != null && categoryColors!.isNotEmpty) {
      json['categoryColors'] = categoryColors;
    }
    return json;
  }
}
