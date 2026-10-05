// ========================================================================
// SourceProvider — resolves URLs to AppSource instances and builds Apps.
//
// App sources, models, and services live in their own libraries. This file
// re-exports them so existing `import source_provider.dart` call sites keep
// resolving the same names.
// ========================================================================

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/app_sources/apk4free.dart';
import 'package:obtainium/app_sources/apkcombo.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/apkpure.dart';
import 'package:obtainium/app_sources/app_source.dart';
import 'package:obtainium/app_sources/aptoide.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/coolapk.dart';
import 'package:obtainium/app_sources/direct_apk_link.dart';
import 'package:obtainium/app_sources/farsroid.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/githubstars.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/app_sources/huaweiappgallery.dart';
import 'package:obtainium/app_sources/itchio.dart';
import 'package:obtainium/app_sources/izzyondroid.dart';
import 'package:obtainium/app_sources/jenkins.dart';
import 'package:obtainium/app_sources/liteapks.dart';
import 'package:obtainium/app_sources/neutroncode.dart';
import 'package:obtainium/app_sources/rockmods.dart';
import 'package:obtainium/app_sources/rustore.dart';
import 'package:obtainium/app_sources/samsunggalaxystore.dart';
import 'package:obtainium/app_sources/sourceforge.dart';
import 'package:obtainium/app_sources/sourcehut.dart';
import 'package:obtainium/app_sources/telegramapp.dart';
import 'package:obtainium/app_sources/tencent.dart';
import 'package:obtainium/app_sources/uptodown.dart';
import 'package:obtainium/app_sources/vivoappstore.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/apk_filter_service.dart';
import 'package:obtainium/utils/min_update_age.dart';
import 'package:obtainium/utils/string_utils.dart';
import 'package:obtainium/utils/url_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:obtainium/version/version_detection_mode.dart';
import 'package:obtainium/version/version_strings.dart';

export 'package:obtainium/app_sources/app_source.dart';
export 'package:obtainium/models/app.dart';
export 'package:obtainium/models/typed_settings.dart';
export 'package:obtainium/services/apk_filter_service.dart';
export 'package:obtainium/services/http_service.dart';
export 'package:obtainium/utils/string_utils.dart' show getSourceRegex;
export 'package:obtainium/utils/url_utils.dart' show preStandardizeUrl;

// Version semantics live in lib/version/ and are re-exported here so the ~40
// files that already import source_provider.dart (for [App]) keep seeing the
// whole version API from one place.
export 'package:obtainium/version/version_detection_mode.dart';
export 'package:obtainium/version/version_strings.dart';

const int kDefaultFetchConcurrency = 4;

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

/// Store identity for [app] (the AppSource runtime type, e.g. `GitHub`).
///
/// This is derived from the app's *current* URL, so it changes whenever the
/// tracked source is swapped. It names the store for display and for the label
/// a second listing is minted under - never which record on disk a listing
/// belongs to (see [App.listingId]), and never whether two listings duplicate
/// each other (see [storeIdentityForApp]).
String sourceIdentifierForApp(App app) {
  try {
    return SourceProvider()
        .getSourceTemplate(app.url, overrideSource: app.overrideSource)
        .sourceIdentifier;
  } catch (_) {
    return app.overrideSource ?? 'Unknown';
  }
}

/// Which store a listing tracks [app] from, for deciding whether two listings
/// of one package are duplicates.
///
/// The source type alone is too coarse: `FDroidRepo` covers every third-party
/// repo and `HTML` every website, so two listings pointing at unrelated hosts
/// would otherwise count as the same store and one of them would be refused.
/// The host is therefore part of the identity, at host granularity - two repos
/// on one host are one store.
///
/// Comparison-only, and deliberately never used as (or embedded in) a record
/// name: it is derived from the mutable [App.url], so a source swap changes it,
/// while a listing's record must keep its identity across that swap.
String storeIdentityForApp(App app) {
  final String sourceIdentifier = sourceIdentifierForApp(app);
  String host = Uri.tryParse(app.url)?.host.toLowerCase() ?? '';
  // Source matching treats a leading 'www.' as equivalent, and stored URLs keep
  // whatever the user pasted, so the two spellings must be one store.
  if (host.startsWith('www.')) {
    host = host.substring('www.'.length);
  }
  return host.isEmpty ? sourceIdentifier : '$sourceIdentifier:$host';
}

/// The settings a newly added app on [source] starts with: the source's
/// defaults, with "Include prereleases" turned on when [includePrereleases]
/// (the "Include pre-releases by default" setting) and the source offers it.
///
/// Every way of adding an app other than the Add app form starts here, so the
/// setting reaches them all. The form pre-ticks the switch it shows instead.
Map<String, dynamic> newAppDefaultSettings(
  AppSource source, {
  required bool includePrereleases,
}) {
  final Map<String, dynamic> defaults = getDefaultValuesFromFormItems(
    source.combinedAppSpecificSettingFormItems,
  );
  if (includePrereleases && defaults.containsKey('includePrereleases')) {
    defaults['includePrereleases'] = true;
  }
  return defaults;
}

class SourceProvider {
  static final SourceProvider _instance = SourceProvider._();
  factory SourceProvider() => _instance;
  SourceProvider._();

  static final Map<String, RegExp> _sourceRegexCache = {};
  static final Map<String, int> _sourceMatchIndexCache = {};

  // Single source of truth for source construction. Matching uses cached,
  // never-mutated templates and [getSource] constructs only the matched source.
  //
  // ORDER IS DELIBERATE — host-based sources are listed alphabetically by their
  // display name (the [name] field, comparing case-insensitively and ignoring
  // punctuation, so "Farsroid" precedes "F-Droid official"). This order is what
  // the source-picker lists render (filter-by-source sheet, "Supported sources"
  // dialog, override-source dropdown), so it must stay alphabetical — do NOT
  // revert to upstream's arbitrary definition order. The two hostless catch-alls
  // stay pinned at the end: source matching walks this list in order and these
  // match by URL *shape* rather than host, so they must be tried only after
  // every host-based source — DirectAPKLink (only .apk URLs) before HTML (the
  // universal fallback), so HTML is ALWAYS last.
  static final List<AppSource Function()> _sourceFactories = [
    () => Apk4Free(),
    () => APKCombo(),
    () => APKMirror(),
    () => APKPure(),
    () => Aptoide(),
    () => Codeberg(),
    () => CoolApk(),
    () => Farsroid(),
    () => FDroid(), // "F-Droid official"
    () => FDroidRepo(), // "F-Droid third-party repo"
    () => Forgejo(), // Forgejo instances other than Codeberg.org
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
    () => SamsungGalaxyStore(), // "Samsung Galaxy Store"
    () => SourceForge(),
    () => SourceHut(),
    () => TelegramApp(), // "Telegram <app>"
    () => Tencent(), // "Tencent App Store"
    () => Uptodown(),
    () => VivoAppStore(), // "vivo App Store (CN)"
    () => DirectAPKLink(), // "Direct APK link"
    () => HTML(), // Must be the last entry - HTML is the catch-all fallback.
  ];

  static List<AppSource>? _sourceTemplatesCache;
  static List<AppSource> get _sourceTemplates => _sourceTemplatesCache ??=
      _sourceFactories.map((factory) => factory()).toList();

  /// Fresh source instances for callers that may mutate the returned objects.
  List<AppSource> get sources =>
      _sourceFactories.map((factory) => factory()).toList();

  /// Add mass URL source classes here so they are available via the service.
  List<MassAppUrlSource> massUrlSources = [GitHubStars()];

  /// Read-only view of the cached source set for callers that only read source
  /// properties (name, hosts, form items) and never mutate them — e.g. the
  /// settings source-specific section and the filter-by-source sheet. Callers
  /// MUST NOT mutate the returned instances; use [sources] for a fresh copy.
  List<AppSource> get sourceTemplates => _sourceTemplates;

  /// Read-only source resolution mirroring [getSource]; use on hot paths that
  /// only need the source's type or its (type-level) flags/form items — e.g.
  /// JSON compatibility migration and version-detection checks. Callers MUST
  /// NOT mutate the returned instance.
  AppSource getSourceTemplate(String url, {String? overrideSource}) {
    if (overrideSource != null) {
      // Override resolution rewrites the source host for this app. Construct
      // only that matched adapter so the shared template remains immutable.
      return getSource(url, overrideSource: overrideSource);
    }
    return _sourceTemplates[_matchSourceIndexForStandardizedUrl(
      preStandardizeUrl(url),
    )];
  }

  // `naiveStandardVersionDetection` depends only on the resolved source (a
  // function of host + overrideSource), so cache it per host to avoid a
  // getSource() per app on the install-status reconcile hot path.
  static final Map<String, bool> _naiveStandardVersionDetectionCache = {};
  bool naiveStandardVersionDetectionForUrl(
    String url, {
    String? overrideSource,
  }) {
    final String host = Uri.tryParse(url)?.host ?? url;
    final String key = '${overrideSource ?? ''} $host';
    return _naiveStandardVersionDetectionCache[key] ??= getSourceTemplate(
      url,
      overrideSource: overrideSource,
    ).naiveStandardVersionDetection;
  }

  AppSource getSource(String url, {String? overrideSource}) {
    url = preStandardizeUrl(url);
    final int sourceIndex = _matchSourceIndexForStandardizedUrl(
      url,
      overrideSource: overrideSource,
    );
    final AppSource res = _sourceFactories[sourceIndex]();
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

  int _matchSourceIndexForStandardizedUrl(
    String url, {
    String? overrideSource,
  }) {
    final String matchCacheKey = '${overrideSource ?? ''}\n$url';
    final int? cachedSourceIndex = _sourceMatchIndexCache[matchCacheKey];
    if (cachedSourceIndex != null) {
      return cachedSourceIndex;
    }
    final List<AppSource> templates = _sourceTemplates;
    if (overrideSource != null) {
      final int sourceIndex = templates.indexWhere(
        (source) => source.sourceIdentifier == overrideSource,
      );
      if (sourceIndex < 0) {
        throw UnsupportedURLError()..url = url;
      }
      _sourceMatchIndexCache[matchCacheKey] = sourceIndex;
      return sourceIndex;
    }
    for (int sourceIndex = 0; sourceIndex < templates.length; sourceIndex++) {
      final AppSource source = templates[sourceIndex];
      if (source.hosts.isEmpty) continue;
      try {
        final String cacheKey =
            '${source.allowSubDomains}:${source.hosts.join(',')}';
        final RegExp regex = _sourceRegexCache[cacheKey] ??= RegExp(
          '^${source.allowSubDomains ? '([^\\.]+\\.)*' : '(www\\.)?'}(${getSourceRegex(source.hosts)})\$',
        );
        if (regex.hasMatch(Uri.parse(url).host)) {
          _sourceMatchIndexCache[matchCacheKey] = sourceIndex;
          return sourceIndex;
        }
      } catch (_) {
        // Ignore and try the next source.
      }
    }
    for (int sourceIndex = 0; sourceIndex < templates.length; sourceIndex++) {
      final AppSource source = templates[sourceIndex];
      if (source.hosts.isNotEmpty || source.neverAutoSelect) continue;
      try {
        source.sourceSpecificStandardizeURL(url, forSelection: true);
        _sourceMatchIndexCache[matchCacheKey] = sourceIndex;
        return sourceIndex;
      } catch (_) {
        // Ignore and try the next source.
      }
    }
    throw UnsupportedURLError()..url = url;
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
  ) => sha256
      .convert(utf8.encode(standardUrl + additionalSettings.toString()))
      .toString()
      .substring(0, 12);

  Future<String> _resolveAppId(
    AppSource source,
    App? currentApp,
    Map<String, dynamic> additionalSettings,
    bool trackOnly,
    String standardUrl,
    bool inferAppIdIfOptional,
  ) async {
    if (currentApp?.id != null) return currentApp!.id;
    final String? explicitId = explicitAppIdFromSettings(additionalSettings);
    if (explicitId != null) return explicitId;
    if ((!trackOnly || source.inferAppIdEvenWhenTrackOnly) &&
        (!source.appIdInferIsOptional ||
            (source.appIdInferIsOptional && inferAppIdIfOptional))) {
      final inferred = await source.tryInferringAppId(
        standardUrl,
        additionalSettings: additionalSettings,
      );
      if (inferred != null) return inferred;
    }
    return generateTempID(standardUrl, additionalSettings);
  }

  Future<App> getApp(
    AppSource source,
    String url,
    Map<String, dynamic> additionalSettings, {
    App? currentApp,
    bool trackOnlyOverride = false,
    bool sourceIsOverriden = false,
    bool inferAppIdIfOptional = false,
  }) async {
    additionalSettings = Map<String, dynamic>.from(additionalSettings);
    if (trackOnlyOverride || source.enforceTrackOnly) {
      additionalSettings['trackOnly'] = true;
    }
    final trackOnly = additionalSettings['trackOnly'] == true;
    // Populate the derived per-source version-string booleans (releaseTitle/
    // assetName/releaseDate/commitSha) from the unified versionStringSource
    // dropdown BEFORE the source reads them — otherwise a freshly-added app's
    // selection is silently ignored on its first check (it only self-heals
    // after save + reload). Parity with fork main.
    syncVersionStringSourceSettings(additionalSettings);
    final String standardUrl;
    try {
      standardUrl = source.standardizeUrl(url);
    } on ObtainiumError catch (e) {
      throw e..withUrlContext(url);
    }
    // Hand the source the previously-known app so it can skip redundant
    // secondary verification round-trips when the upstream release is unchanged.
    source.previouslyCheckedApp = currentApp;
    final APKDetails apk;
    try {
      apk = await source.getLatestAPKDetails(standardUrl, additionalSettings);
    } on ObtainiumError catch (e) {
      throw e..withUrlContext(standardUrl);
    }

    // Capture raw snapshots before version extraction / release-date/title
    // replacement and APK filtering mutate them (used by the RegEx assist).
    final String rawLatestVersionFromSource = apk.version;
    additionalSettings.remove('rawSelectedReleaseTitle');
    if (apk.releaseTitle != null) {
      additionalSettings['rawSelectedReleaseTitle'] = apk.releaseTitle;
    }
    final codesByAsset = <String, int>{
      if (apk.versionCode != null && apk.apkUrls.isNotEmpty)
        apk.apkUrls.last.key: apk.versionCode!,
      ...apk.versionCodesByAsset,
    };
    final String? rawApkNamesFromSource = encodeRawAssistLines(
      apk.apkUrls.map((MapEntry<String, String> entry) => entry.key),
    );
    final String? rawReleaseTitlesFromSource = encodeRawAssistLines(
      apk.rawReleaseTitleCandidates,
    );

    // Only stored values are read, so skip SettingsProvider's one-time init.
    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();

    // Adding an app honours the minimum update age too (upstream #3004,
    // #3303). Sources that can look back already return an older eligible
    // release, so this only blocks a source whose latest release is too young
    // and has no older alternative. An update check (currentApp != null)
    // suppresses the young release in AppsProvider instead, so it never fails.
    if (currentApp == null && !trackOnly) {
      final int minAgeDays = await effectiveMinUpdateAgeDays(
        additionalSettings,
        settingsProvider: settings,
      );
      if (isReleaseTooYoung(apk.releaseDate, minAgeDays)) {
        throw MinUpdateAgeError(apk.releaseDate!, minAgeDays)
          ..url = standardUrl;
      }
    }

    if (!source.suppressStandardVersionExtraction) {
      final String? extractedVersion = extractVersion(
        additionalSettings['versionExtractionRegEx'] as String?,
        additionalSettings['matchGroupToUse'] as String?,
        apk.version,
      );
      if (extractedVersion != null) {
        apk.version = extractedVersion;
      }
    }

    if (additionalSettings['releaseDateAsVersion'] == true &&
        apk.releaseDate != null) {
      // ISO-8601 (parity with fork main): a readable, stable string. Upstream's
      // microsecondsSinceEpoch renders as an opaque integer and, on upgrade,
      // recomputes to a different value → a one-time spurious "update".
      apk.version = apk.releaseDate!.toUtc().toIso8601String();
    }
    // In version-code mode the app's installed version is the device's
    // versionCode, so the stored latest version has to be a version code too.
    // Comparing a code against a dotted version string cannot be ordered (a
    // versionCode of 123 reads as "newer" than 1.2.4), so prefer the source's own
    // version code whenever it publishes one. Only the default version string is
    // overridden — an explicit versionStringSource choice still wins.
    if (appApkFilterRegExIsSet(additionalSettings)) {
      apk.apkUrls = filterApks(
        apk.apkUrls,
        additionalSettings['apkFilterRegEx'],
        additionalSettings['invertAPKFilter'],
      );
    } else {
      // The global APK filter (upstream #2979) stands in for an unset app
      // filter. The app's invert switch belongs to its own filter, so it
      // doesn't apply here.
      final String? globalApkFilterRegEx = usableApkFilterRegEx(
        settings.globalApkFilterRegEx,
      );
      if (globalApkFilterRegEx != null) {
        apk.apkUrls = filterApks(apk.apkUrls, globalApkFilterRegEx, false);
      }
    }
    if (apk.apkUrls.isEmpty && !trackOnly) {
      throw NoAPKError()..url = standardUrl;
    }
    if (additionalSettings['autoApkFilterByArch'] == true) {
      apk.apkUrls = await filterApksByArch(apk.apkUrls);
      if (apk.apkUrls.isEmpty && !trackOnly) {
        throw NoAPKError()..url = standardUrl;
      }
    }
    final int preferredApkIndex;
    if (apk.apkUrls.isEmpty) {
      preferredApkIndex = 0;
    } else if (currentApp == null) {
      preferredApkIndex = apk.apkUrls.length - 1;
    } else {
      preferredApkIndex = currentApp.preferredApkIndex.clamp(
        0,
        apk.apkUrls.length - 1,
      );
    }
    final String sourceName = apk.names.name.trim();
    final selectedCode = apk.apkUrls.isEmpty
        ? null
        : codesByAsset[apk.apkUrls[preferredApkIndex].key];
    final usesCodeLabel =
        versionCodeAsOsVersionFor(additionalSettings) &&
        selectedCode != null &&
        getVersionStringSource(additionalSettings) ==
            versionStringSourceDefault;
    if (usesCodeLabel) {
      apk.version = selectedCode.toString();
    }
    additionalSettings.remove('sourceVersionCodes');
    if (codesByAsset.isNotEmpty) {
      additionalSettings['sourceVersionCodes'] = {
        'sourceUrl': standardUrl,
        'overrideSource': sourceIsOverriden
            ? source.sourceIdentifier
            : currentApp?.overrideSource,
        'version': apk.version,
        'usesCodeLabel': usesCodeLabel,
        'assetUrls': {for (final asset in apk.apkUrls) asset.key: asset.value},
        'codes': {
          for (final asset in apk.apkUrls)
            if (codesByAsset.containsKey(asset.key))
              asset.key: codesByAsset[asset.key],
        },
      };
    }
    // Replace the stored name with the source's readable name when the stored
    // name is missing, is exactly the app id, or merely looks like a package id
    // (e.g. 'org.example.app') while the source offers a real display name.
    var name = currentApp != null ? currentApp.name.trim() : '';
    if (name.isEmpty ||
        name == currentApp?.id ||
        (looksLikeAndroidPackageId(name) &&
            sourceName.isNotEmpty &&
            sourceName != name)) {
      name = sourceName.isNotEmpty ? sourceName : name;
    }
    // Reuse the previous check's verification/size/icon when the resolved
    // version is unchanged, so a skipped secondary round-trip doesn't clear them.
    final bool sameVersionAsPrevious =
        currentApp != null && currentApp.latestVersion == apk.version;
    final String? resolvedReproducibleStatus =
        apk.reproducibleStatus ??
        (apk.isReproducible != null
            ? reproducibleBuildStatusFromBool(apk.isReproducible)
            : sameVersionAsPrevious
            ? currentApp.latestReproducibleStatus
            : null);
    final App finalApp = App(
      id: await _resolveAppId(
        source,
        currentApp,
        additionalSettings,
        trackOnly,
        standardUrl,
        inferAppIdIfOptional,
      ),
      url: standardUrl,
      author: apk.names.author,
      name: name,
      installedVersion: currentApp?.installedVersion,
      latestVersion: apk.version,
      apkUrls: apk.apkUrls,
      preferredApkIndex: preferredApkIndex,
      additionalSettings: additionalSettings,
      lastUpdateCheck: DateTime.now(),
      pinned: currentApp?.pinned ?? false,
      categories: currentApp?.categories ?? const [],
      releaseDate: apk.releaseDate,
      changeLog: apk.changeLog,
      overrideSource: sourceIsOverriden
          ? source.sourceIdentifier
          : currentApp?.overrideSource,
      allowIdChange:
          currentApp?.allowIdChange ??
          trackOnly || (source.appIdInferIsOptional && inferAppIdIfOptional),
      otherAssetUrls: apk.allAssetUrls
          .where((a) => apk.apkUrls.indexWhere((p) => a.key == p.key) < 0)
          .toList(),
      iconUrl: apk.iconUrl ?? currentApp?.iconUrl,
      apkSizeBytes:
          apk.apkSizeBytes ??
          (sameVersionAsPrevious ? currentApp.apkSizeBytes : null),
      rawLatestVersionFromSource: rawLatestVersionFromSource,
      rawApkNamesFromSource: rawApkNamesFromSource,
      rawReleaseTitlesFromSource: rawReleaseTitlesFromSource,
      latestIsReproducible: reproducibleBuildBoolFromStatus(
        resolvedReproducibleStatus,
      ),
      latestReproducibleStatus: resolvedReproducibleStatus,
      latestReproducibleVersionCode: apk.versionCode,
      latestAttestationStatus:
          apk.attestationStatus ??
          (sameVersionAsPrevious ? currentApp.latestAttestationStatus : null),
    );
    return source.resolveVersionComparison(source.postProcessApp(finalApp));
  }

  /// Fetches the app at [url] with its source's default settings.
  ///
  /// [inferAppIds] looks up the package ID where the URL doesn't carry one
  /// (GitHub, GitLab, Codeberg, SourceHut read the repo's build files), as
  /// the Add app page does. Off, such apps get a temporary ID instead, which
  /// is cheaper for a long list: each lookup costs API requests.
  ///
  /// [includePrereleases] turns on the source's "Include prereleases" option,
  /// as Add app does when that's the default in settings. [settings] go on top
  /// of the defaults, as the values filled in on Add app would.
  Future<App> getAppByURLNaive(
    String url, {
    AppSource? sourceOverride,
    bool inferAppIds = false,
    bool includePrereleases = false,
    Map<String, dynamic> settings = const {},
  }) {
    final source = sourceOverride ?? getSource(url);
    final Map<String, dynamic> defaults = newAppDefaultSettings(
      source,
      includePrereleases: includePrereleases,
    );
    return getApp(
      source,
      url,
      sourceIsOverriden: sourceOverride != null,
      inferAppIdIfOptional: inferAppIds,
      {...defaults, ...settings},
    );
  }

  // Returns errors in [results, errors] instead of throwing them
  Future<List<dynamic>> getAppsByURLNaive(
    List<String> urls, {
    Set<String> alreadyAddedUrls = const {},
    AppSource? sourceOverride,
    bool includePrereleases = false,
  }) async {
    final List<App> apps = [];
    final Map<String, dynamic> errors = {};
    const concurrency = kDefaultFetchConcurrency;
    for (var i = 0; i < urls.length; i += concurrency) {
      final end = i + concurrency > urls.length ? urls.length : i + concurrency;
      final batch = urls.sublist(i, end);
      final results = await Future.wait(
        batch.map((url) async {
          try {
            if (alreadyAddedUrls.contains(url)) {
              // Unlike upstream (#3038), no "(url)" suffix: these errors are
              // keyed by URL and ImportErrorDialog already shows it above the
              // message.
              throw ObtainiumError(tr('appAlreadyAdded'));
            }
            return await getAppByURLNaive(
              url,
              sourceOverride: sourceOverride,
              includePrereleases: includePrereleases,
            );
          } catch (e) {
            return e;
          }
        }),
      );
      for (var j = 0; j < batch.length; j++) {
        final result = results[j];
        if (result is App) {
          apps.add(result);
        } else {
          errors[batch[j]] = result;
        }
      }
    }
    return [apps, errors];
  }
}
