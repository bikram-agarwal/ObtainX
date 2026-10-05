// AppSource — abstract base class for all app sources.

import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/izzyondroid.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/http/source_request_session.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/models/typed_settings.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/apk_filter_service.dart';
import 'package:obtainium/services/http_service.dart';
import 'package:obtainium/utils/signing_cert_utils.dart';
import 'package:obtainium/utils/string_utils.dart';
import 'package:obtainium/utils/url_utils.dart';
import 'package:obtainium/version/version_detection_mode.dart';
import 'package:obtainium/version/version_strings.dart';

// ========================================================================
// AppSource — abstract base class for all app sources.
// ========================================================================

/// Options (in days) for the minimum-age-for-updates setting. Zero disables
/// the delay; the empty string means "use the global default" for per-app
/// overrides.
const List<int> minimumUpdateAgeOptions = [0, 1, 2, 3, 5, 7, 14, 30];

abstract class AppSource {
  List<String> hosts = [];

  /// Download hosts (e.g. a store's CDN) whose APKs don't trigger the
  /// "downloaded from a different origin" warning.
  List<String> trustedApkHosts = [];
  bool hostChanged = false;
  bool hostIdenticalDespiteAnyChange = false;
  late String name;
  bool enforceTrackOnly = false;
  bool changeLogIfAnyIsMarkDown = true;
  bool changeLogPageIsStandardUrl = false;
  bool appIdInferIsOptional = false;
  bool inferAppIdFromUrlPath = false;

  /// Look the package ID up for track-only apps too (upstream's flag). A
  /// track-only app is still matched to the installed package by its ID.
  bool inferAppIdEvenWhenTrackOnly = false;
  bool allowSubDomains = false;
  bool naiveStandardVersionDetection = false;
  bool allowOverride = true;
  bool neverAutoSelect = false;
  bool showReleaseDateAsVersionToggle = false;
  bool showReleaseTitleAsVersionToggle = false;
  bool showExtractVersionFromAssetNameToggle = false;
  bool showReleaseCommitShaAsVersionToggle = false;
  bool versionDetectionDisallowed = false;
  bool suppressStandardVersionExtraction = false;
  List<String> excludeCommonSettingKeys = [];
  bool urlsAlwaysHaveExtension = false;

  /// Lets requests for this source follow an HTTPS→HTTP redirect, which is
  /// otherwise refused (for stores whose CDN only serves cleartext).
  bool allowInsecureRedirects = false;
  bool allowIncludeZips = false;
  bool allowIncludeTarballs = false;
  bool regionalStore = false;
  String get sourceIdentifier => runtimeType.toString();

  /// Transient per-check context: the app as it was known before this update
  /// check, set by [SourceProvider.getApp] right before [getLatestAPKDetails].
  /// Lets a source skip an expensive *secondary* verification network round-trip
  /// (e.g. F-Droid reproducible-build metadata) when the raw upstream version is
  /// unchanged since the last check, reusing the cached result instead. Not
  /// persisted; safe to read because each check gets its own source instance.
  App? previouslyCheckedApp;

  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    return null;
  }

  AppSource() {
    name = runtimeType.toString();
  }

  String standardizeUrl(String url) {
    url = preStandardizeUrl(url);
    if (!hostChanged || hostIdenticalDespiteAnyChange) {
      url = sourceSpecificStandardizeURL(url);
    }
    return url;
  }

  App postProcessApp(App app) {
    return app;
  }

  Future<App> resolveVersionComparison(App app) async {
    return app;
  }

  Future<Map<String, dynamic>> buildMergedSettings(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) async {
    return {
      ...additionalSettings,
      ...(await getSourceConfigValues(additionalSettings, settingsProvider)),
    };
  }

  Future<http.Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    final sp = SettingsProvider();
    await sp.initializeSettings();
    final additionalSettingsPlusSourceConfig = await buildMergedSettings(
      additionalSettings,
      sp,
    );
    url = await generalReqPrefetchModifier(
      url,
      additionalSettingsPlusSourceConfig,
    );
    final method = postBody == null ? 'GET' : 'POST';
    final requestHeaders = await getRequestHeaders(
      additionalSettingsPlusSourceConfig,
      url,
    );
    final session = SourceRequestSession.current;
    final allowInsecure =
        additionalSettingsPlusSourceConfig['allowInsecure'] == true;
    final certificatePinning = sp.enableCertificatePinning;
    Future<http.Response> loadResponse() async {
      final service = HttpService();
      final sharedClient = session?.clientFor(allowInsecure);
      final streamed = await service.sourceRequestStreamResponse(
        method,
        url,
        requestHeaders,
        additionalSettingsPlusSourceConfig,
        followRedirects: followRedirects,
        postBody: postBody,
        sharedClient: sharedClient,
        allowInsecureRedirects: allowInsecureRedirects,
        certificatePinning: certificatePinning,
      );
      return service.httpClientResponseStreamToFinalResponse(
        streamed.value.key,
        method,
        streamed.key.toString(),
        streamed.value.value,
        // A hop that needed its own trust store (RuStore, pinned hosts) ran on
        // a dedicated client, which must be closed even inside a session.
        closeClient: !identical(streamed.value.key, sharedClient),
      );
    }

    final String requestPath = Uri.parse(url).path;
    if (session != null &&
        method == 'GET' &&
        (requestPath.endsWith('/index.xml') ||
            requestPath.endsWith('/index-v2.json'))) {
      // Key after URL/header customization so credentials, TLS policy and
      // redirects cannot accidentally share a response across configurations.
      final headerNames = requestHeaders?.keys.toList() ?? <String>[];
      headerNames.sort();
      final key = jsonEncode([
        url,
        allowInsecure,
        certificatePinning,
        followRedirects,
        for (final name in headerNames) [name, requestHeaders![name]],
      ]);
      return session.repositoryResponse(key, loadResponse);
    }
    return loadResponse();
  }

  void runOnAddAppInputChange(String inputUrl) {}

  /// Delegates to [ApkFilterService.apkContainerExtensions].
  static List<String> get apkContainerExtensions =>
      ApkFilterService.apkContainerExtensions;

  /// Delegates to [ApkFilterService.archiveExtensions].
  static List<String> get archiveExtensions =>
      ApkFilterService.archiveExtensions;

  /// Delegates to [ApkFilterService.tarballExtensions].
  static List<String> get tarballExtensions =>
      ApkFilterService.tarballExtensions;

  /// Delegates to [ApkFilterService.isApkOrContainerFile].
  static bool isApkOrContainerFile(
    String name, {
    bool includeArchives = false,
    bool includeTarballs = false,
  }) => ApkFilterService.isApkOrContainerFile(
    name,
    includeArchives: includeArchives,
    includeTarballs: includeTarballs,
  );

  /// A convenience for the common standardize-by-regex pattern: build a regex
  /// from the source's [hosts] plus the given subdomain prefix and path, match
  /// against [url], and return the match or throw [InvalidURLError].  Many
  /// sources (16+) repeat this block verbatim; subclasses can call this
  /// helper instead.
  String standardizeUrlWithRegex(
    String url, {
    required String subdomainPrefix,
    required String pathPattern,
  }) {
    final re = RegExp(
      '^https?://$subdomainPrefix${getSourceRegex(hosts)}$pathPattern',
      caseSensitive: false,
    );
    final match = re.firstMatch(url);
    if (match == null) throw InvalidURLError(name)..url = url;
    return match.group(0)!;
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

  /// Per-source additional form items (e.g. GitHub's sort method, HTML's version regex).
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [];

  static List<GeneratedFormItem> get fallbackToOlderReleasesFormItem => [
    GeneratedFormSwitch(
      'fallbackToOlderReleases',
      label: tr('fallbackToOlderReleases'),
      value: true,
    ),
  ];

  /// Some additional data may be needed for Apps regardless of Source.
  ///
  /// ORDER + SECTION HEADERS ARE DELIBERATE. The [GeneratedFormSectionHeader]
  /// rows split the Additional-Options page into separate section cards (the
  /// renderer groups every header + its following rows into one card when
  /// `wrapFormSectionsInCards` is set). Do NOT flatten this back into one list
  /// or drop the headers — that collapses the page into a single giant card
  /// (matches the fork's `main`). Name / author / notes are intentionally NOT
  /// here: they are edited via the app detail page's "Edit app info" dialog, not
  /// this form.
  List<List<GeneratedFormItem>> get _commonAppSettingFormItems => [
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
        value: false,
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
      // Per-app override of the global minimum update age; '' = use global.
      GeneratedFormSlider(
        'minimumUpdateAgeDays',
        [
          MapEntry('', tr('useGlobalDefault')),
          for (final days in minimumUpdateAgeOptions)
            MapEntry(days.toString(), days == 0 ? tr('none') : '$days'),
        ],
        label: tr('minimumUpdateAgeDays'),
        value: '',
        required: false,
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
      // Version detection is a THREE-STATE dropdown, not a bool switch. Every
      // reader (isVersionPseudo, app.dart's isVersionDetectionStandard,
      // apps_provider_updates/lifecycle, additional_options_page) keys off the
      // string values 'auto'/'standard'/'pseudo'/'versionCode'. A bool switch
      // here silently corrupts the value (GeneratedFormSwitch.ensureType coerces
      // it to a bool on every deserialize) and breaks install/update detection —
      // do NOT revert to a switch. 'versionCode' subsumes the old separate
      // useVersionCodeAsOSVersion switch (kept in sync as a derived bool).
      GeneratedFormDropdown(
        'versionDetection',
        [
          MapEntry('auto', tr('versionDetectionModeAuto')),
          MapEntry('standard', tr('versionDetectionModeStandard')),
          MapEntry('pseudo', tr('versionDetectionModePseudo')),
          MapEntry('versionCode', tr('versionDetectionModeVersionCode')),
        ],
        label: tr('versionDetection'),
        value: 'auto',
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
        label: '${tr('invertRegEx')} (${tr('filterAPKsByRegEx')})',
        value: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'autoApkFilterByArch',
        label: tr('autoApkFilterByArch'),
        value: true,
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
        value: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'allowInsecure',
        label: tr('allowInsecure'),
        value: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'refreshBeforeDownload',
        label: tr('refreshBeforeDownload'),
      ),
    ],
    [
      // Same label as the global setting in Settings > Integrations,
      // deliberately: this is that switch scoped to one app, not a separate
      // opt-out with inverted meaning.
      GeneratedFormSwitch(
        enableVirusTotalScanKey,
        label: tr('enableVirusTotalScanning'),
        value: true,
        labelTooltip: tr('perAppVirusTotalScanTooltip'),
      ),
    ],
    [
      // Opt-in hard block (upstream #2922): an APK signed by any other
      // certificate is never installed, including on first install.
      GeneratedFormTextField(
        'allowedSigningCertHashes',
        label: tr('allowedSigningCertHashes'),
        hint: 'AA:BB:CC:…',
        required: false,
        max: 4,
        helpUrl: 'https://developer.android.com/tools/apksigner',
        additionalValidators: [
          (value) =>
              isValidCertHashList(value) ? null : tr('invalidSigningCertHash'),
        ],
      ),
    ],
  ];

  /// The choices for the unified "Use as version string" (`versionStringSource`)
  /// dropdown. 'Default' is always offered; each alternate pseudo-version source
  /// is added only when the source opted in via its show*Toggle flag. A single
  /// dropdown here replaces the old scattered per-source boolean switches
  /// (releaseTitleAsVersion / releaseDateAsVersion / …) — parity with fork main.
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

  /// Combines per-source form items with the common app-setting form items,
  /// interspersing conditional items (zip/tarball options, version toggles) and
  /// filtering out excluded keys. Cloned so that callers cannot mutate the
  /// shared source-owned form items. Rebuilt on every access so that labels
  /// pick up the current locale via tr().
  List<List<GeneratedFormItem>> get combinedAppSpecificSettingFormItems {
    var agnosticItems = cloneFormItems(_commonAppSettingFormItems);

    // Insert the unified versionStringSource dropdown at the top of the Version
    // section (right after its header) when the source offers any alternate
    // version-string source. Mirrors fork main; do NOT revert to per-flag
    // switches (the backend's single source of truth is the versionStringSource
    // string, kept in sync with the legacy booleans by syncVersionStringSourceSettings).
    final List<MapEntry<String, String>> versionSourceOptions =
        versionStringSourceOptions;
    if (versionSourceOptions.length > 1 &&
        !agnosticItems.any(
          (row) => row.any((item) => item.key == 'versionStringSource'),
        )) {
      final int versionSectionHeaderIndex = agnosticItems.indexWhere(
        (row) => row.length == 1 && row.first.key == '__formSectionVersion',
      );
      agnosticItems.insert(
        versionSectionHeaderIndex >= 0 ? versionSectionHeaderIndex + 1 : 0,
        [
          GeneratedFormDropdown(
            'versionStringSource',
            versionSourceOptions,
            label: tr('versionStringSource'),
            value: versionStringSourceDefault,
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

    final moreConditionalItems = <List<GeneratedFormItem>>[];
    if (allowIncludeZips) {
      moreConditionalItems.addAll([
        [
          GeneratedFormSwitch(
            'includeZips',
            label: tr('includeZips'),
            value: false,
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
            value: false,
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
      for (final item in agnosticItems.expand((row) => row)) {
        if (item.key != 'versionDetection' &&
            item.key != 'useVersionCodeAsOSVersion') {
          continue;
        }
        if (item is GeneratedFormSwitch) {
          item.disabled = true;
          item.value = false;
        } else if (item is GeneratedFormDropdown) {
          // versionDetection is a dropdown now. Pinning it to the only mode this
          // source supports is what actually enforces the flag: the previous
          // switch-only guard silently did nothing, leaving every mode selectable
          // on sources that cannot compare versions at all (and 'versionCode' /
          // explicit 'standard' are excluded from install-status auto-disable, so
          // nothing corrected the choice afterwards).
          item.disabledOptKeys = VersionDetectionMode.values
              .where((mode) => mode != VersionDetectionMode.pseudo)
              .map((mode) => mode.key)
              .toList();
          item.value = VersionDetectionMode.pseudo.key;
        }
      }
    }

    final combined = [
      // Clone so callers (e.g. the add-app form pre-filling default values)
      // can't mutate the source-owned items. Sources are now cached/shared, so
      // an in-place edit here would otherwise leak across apps.
      ...cloneFormItems(additionalSourceAppSpecificSettingFormItems),
      ...agnosticItems,
      ...moreConditionalItems,
    ];

    final List<List<GeneratedFormItem>> pruned = [];
    List<GeneratedFormItem>? pendingHeaderRow;

    for (final row in combined) {
      final bool isHeader =
          row.length == 1 && row.first is GeneratedFormSectionHeader;
      if (isHeader) {
        pendingHeaderRow = row;
      } else {
        if (pendingHeaderRow != null) {
          pruned.add(pendingHeaderRow);
          pendingHeaderRow = null;
        }
        pruned.add(row);
      }
    }

    return pruned;
  }

  bool get hasAppSpecificSettings =>
      combinedAppSpecificSettingFormItems.isNotEmpty;

  /// Flattened, read-only view of [combinedAppSpecificSettingFormItems],
  /// used by callers that only need to enumerate keys without cloning.
  List<GeneratedFormItem> get flatCombinedFormItemsReadOnly =>
      combinedAppSpecificSettingFormItems.expand((row) => row).toList();

  /// Source-level additional settings (not specific to Apps) backed by [SettingsProvider].
  /// If the source has been overridden, per-app additional settings take precedence.
  List<GeneratedFormItem> get sourceConfigSettingFormItems => [];
  Future<Map<String, String>> getSourceConfigValues(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) async {
    final Map<String, String> results = {};
    for (var e in sourceConfigSettingFormItems) {
      final dynamic perAppValue = additionalSettings[e.key];
      // A blank per-app value (e.g. an empty token field) means "not set", so
      // it must not shadow the global value.
      final bool perAppValueUnset =
          perAppValue == null ||
          (perAppValue is String && perAppValue.trim().isEmpty);
      var val = hostChanged && !hostIdenticalDespiteAnyChange
          ? perAppValue
          : !perAppValueUnset
          ? perAppValue
          : (e is GeneratedFormSwitch
                ? settingsProvider.getSettingBool(e.key).toString()
                : settingsProvider.getSettingString(e.key));
      if (val != null) {
        if (e is GeneratedFormSwitch) {
          val = val.toString();
        }
        results[e.key] = val;
      }
    }
    return results;
  }

  String? changeLogPageFromStandardUrl(String standardUrl) {
    return changeLogPageIsStandardUrl ? standardUrl : null;
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
  List<GeneratedFormItem> get searchQuerySettingFormItems => [];
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) {
    throw NotImplementedError();
  }

  static String stripLastPathSegment(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(
          pathSegments: uri.pathSegments.sublist(
            0,
            uri.pathSegments.length - 1,
          ),
        )
        .toString();
  }

  static Future<String?> tryInferAppIdFromLastPathSegment(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    return Uri.parse(
      standardUrl,
    ).pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  }

  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    if (inferAppIdFromUrlPath) {
      return tryInferAppIdFromLastPathSegment(standardUrl);
    }
    return null;
  }
}

// ========================================================================
// MassAppUrlSource — abstract base for mass URL import sources.
// ========================================================================

abstract class MassAppUrlSource {
  String get name;
  List<String> get requiredArgs;
  Future<Map<String, List<String>>> getUrlsWithDescriptions(List<String> args);
}

// ------------------------------------------------------------------------
// ObtainX-only: per-app VirusTotal key, version-string sources and explicit
// app IDs, all read by [AppSource] and its subclasses.
// ------------------------------------------------------------------------

/// Per-app companion to the global `enableVirusTotalScanning` setting: turning
/// this off excludes one app from the pre-install VirusTotal scan. Same polarity
/// and label as the global switch on purpose - on means "scan", so the two read
/// identically wherever they appear.
///
/// Defaults to **true**, which every read MUST repeat as
/// `getBool(enableVirusTotalScanKey, defaultValue: true)`. Apps saved before this
/// key existed have no entry for it, and [TypedSettings.getBool]'s own default is
/// false, so a bare `getBool(enableVirusTotalScanKey)` reads as "don't scan" and
/// silently disables scanning for every pre-existing app. There is exactly one
/// read site - AppsProvider.willScanApkWithVirusTotal - so keep it that way.
const String enableVirusTotalScanKey = 'enableVirusTotalScan';

// Version-string-source values (stored in additionalSettings['versionStringSource']).
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

/// Resolves the effective version-string source from [additionalSettings],
/// preferring an explicitly configured value and otherwise falling back to the
/// legacy per-method boolean flags.
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

/// Normalises [additionalSettings] so that the string version-source key and
/// the legacy per-method boolean flags agree with each other.
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

/// The user-supplied "App ID - Custom" value, or null when none was given.
///
/// Empty means "not supplied", not "the id is the empty string".
/// [GeneratedFormTextField] defaults to `''`, and the Add-app page assigns the
/// whole form value map to `additionalSettings` on every change, so an untouched
/// box reaches callers as `''` as soon as the user touches any other option.
/// Treating that as explicit made the app id blank.
/// [IzzyOnDroid.tryInferringAppId] guards its own read the same way.
String? explicitAppIdFromSettings(Map<String, dynamic> additionalSettings) {
  final String? raw = additionalSettings['appId'] as String?;
  final String? trimmed = raw?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
