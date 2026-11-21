import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/gradle_app_id.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/utils/min_update_age.dart';
import 'package:obtainium/utils/update_health.dart';
import 'package:obtainium/version/app_version.dart';
import 'package:obtainium/widgets/app_toast.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic>? _jsonObjectFromResponseBody(String responseBody) {
  try {
    final dynamic decodedBody = jsonDecode(responseBody);
    if (decodedBody is Map<String, dynamic>) {
      return decodedBody;
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// The newest upload date among [release]'s APK assets, or among all its
/// assets when the APK filter left none (upstream #3339), so a track-only
/// release that carries only a source archive still gets a date.
DateTime? newestAssetDateFromRelease(dynamic release) {
  if (release is! Map) return null;
  final allAssets = release['assets'] as List<dynamic>?;
  final filteredAssets = release['filteredAssets'] as List<dynamic>?;
  final assets = filteredAssets?.isNotEmpty == true
      ? filteredAssets
      : allAssets;
  final dates = assets
      ?.map((asset) {
        // GitHub assets carry both timestamps; Forgejo/Gitea assets (Codeberg,
        // which reuses this code) expose only `created_at` — verified against
        // codeberg.org/api/v1 on 2026-08-18. Without the fallback this
        // returned null for every Forgejo asset, so "Use latest asset upload
        // as release date" silently did nothing there and left the release
        // date unset.
        final updated = asset?['updated_at'] ?? asset?['created_at'];
        return updated is String ? DateTime.tryParse(updated) : null;
      })
      .whereType<DateTime>()
      .toList();
  if (dates == null || dates.isEmpty) return null;
  dates.sort((a, b) => b.compareTo(a));
  return dates.first;
}

/// Whether [release] is passed over as a prerelease or a draft (#3447).
/// Drafts are visible only with a token that has write access to the repo.
bool isReleaseExcluded(
  dynamic release, {
  required bool includePrereleases,
  required bool includeDrafts,
}) =>
    (!includePrereleases && release['prerelease'] == true) ||
    (!includeDrafts && release['draft'] == true);

/// Hidden per-app setting: when a check last read the repository's archived
/// flag (milliseconds since the epoch), so later checks can reuse
/// [App.isArchived] instead of spending another API request (v1.7.4 sync D8).
/// Written by [GitHub.postProcessApp]; Codeberg and Forgejo share it.
const String repoArchivedCheckedAtKey = 'repoArchivedCheckedAt';

class GitHub extends AppSource {
  @override
  Future<App> resolveVersionComparison(App app) async {
    // GitLab/Forgejo reuse release selection but expose different compare APIs.
    if (Uri.tryParse(app.url)?.host.toLowerCase() != 'github.com' ||
        app.installedVersion == null ||
        app.usesVersionCodeAsOsVersion) {
      return app;
    }
    final identity = versionEvidenceIdentity(app);
    final cached = app.additionalSettings[sourceBuildComparisonKey];
    if (cached is Map &&
        cached['identity'] == identity &&
        {
          'ahead',
          'behind',
          'identical',
          'diverged',
        }.contains(cached['status'])) {
      return app;
    }
    final decision = versionDecisionForApp(app);
    if (decision.reason == 'sourceCommitAncestry') return app;
    final latestHash = selectedSourceBuildHash(app);
    final direct = compareVersionStrings(
      app.installedVersion!,
      app.latestVersion,
      latestBuildHash: latestHash,
    );
    if (direct.reason != 'differentBuildHashes') return app;
    final installedHash = releaseBuildHash(app.installedVersion!);
    if (installedHash == null ||
        latestHash == null ||
        installedHash == latestHash) {
      return app;
    }
    Response? response;
    String? requestIdentity;
    var previousFailures = 0;
    try {
      final apiUrl = await convertStandardUrlToAPIUrl(
        app.url,
        app.additionalSettings,
      );
      // Only preference reads are needed here, without device/storage setup.
      final settingsProvider = SettingsProvider()
        ..prefs = await SharedPreferences.getInstance();
      final requestSettings = await buildMergedSettings(
        app.additionalSettings,
        settingsProvider,
      );
      // Changing credentials or a proxy must allow an immediate retry, without
      // persisting those credentials in the comparison evidence.
      requestIdentity = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                apiUrl,
                requestSettings[githubCredsKey] ?? '',
                requestSettings[githubReqPrefixKey] ?? '',
                requestSettings[githubReqPrefixUseTokenKey] == 'true',
                requestSettings['allowInsecure'] == true,
              ]),
            ),
          )
          .toString();
      if (cached is Map &&
          cached['identity'] == identity &&
          cached['requestIdentity'] == requestIdentity &&
          cached['status'] == 'unavailable') {
        final retryAfter = cached['retryAfter'];
        if (retryAfter is int &&
            retryAfter > DateTime.now().millisecondsSinceEpoch) {
          return app;
        }
        final failureCount = cached['failureCount'];
        if (failureCount is int) previousFailures = failureCount.clamp(0, 5);
      }
      // GitHub includes the full changed-file list only on page 1. Page 2
      // retains the overall status and base commit even with no commits on it.
      response = await sourceRequest(
        '$apiUrl/compare/$installedHash...$latestHash?per_page=1&page=2',
        requestSettings,
      );
      if (response.statusCode == 200) {
        final comparison = _jsonObjectFromResponseBody(response.body);
        final status = comparison?['status'];
        final base = comparison?['base_commit'];
        if ({'ahead', 'behind', 'identical', 'diverged'}.contains(status) &&
            base is Map &&
            base['sha'] is String &&
            (base['sha'] as String).toLowerCase().startsWith(installedHash)) {
          return app.copyWith(
            additionalSettings:
                Map<String, dynamic>.from(app.additionalSettings)
                  ..[sourceBuildComparisonKey] = {
                    'identity': identity,
                    'status': status,
                  },
          );
        }
      }
    } catch (_) {
      // Missing/deleted commits, rate limits and network errors leave only this
      // build unresolved; they must not fail an otherwise valid source refresh.
    }

    // Remember failures across refreshes/restarts, but retry transient failures
    // after 1, 2, 4, ... minutes (at most 30). Missing commits get 15 minutes.
    final now = DateTime.now().millisecondsSinceEpoch;
    final delayMinutes = (1 << previousFailures).clamp(
      response?.statusCode == 404 ? 15 : 1,
      30,
    );
    var retryAfter = now + Duration(minutes: delayMinutes).inMilliseconds;
    final retryHeader = response?.headers['retry-after'];
    if (retryHeader != null) {
      final seconds = int.tryParse(retryHeader);
      int? serverRetryAfter;
      if (seconds != null && seconds >= 0) {
        serverRetryAfter = now + Duration(seconds: seconds).inMilliseconds;
      } else {
        try {
          serverRetryAfter = HttpDate.parse(retryHeader).millisecondsSinceEpoch;
        } catch (_) {
          // An invalid header must not discard the local backoff.
        }
      }
      if (serverRetryAfter != null && serverRetryAfter > retryAfter) {
        retryAfter = serverRetryAfter;
      }
    }
    if (response?.statusCode == 429 ||
        response?.headers['x-ratelimit-remaining'] == '0') {
      final reset = int.tryParse(response?.headers['x-ratelimit-reset'] ?? '');
      if (reset != null && reset * 1000 > retryAfter) {
        retryAfter = reset * 1000;
      }
    }
    return app.copyWith(
      additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
        ..[sourceBuildComparisonKey] = {
          'identity': identity,
          'status': 'unavailable',
          'requestIdentity': requestIdentity,
          'retryAfter': retryAfter,
          'failureCount': previousFailures + 1,
        },
    );
  }

  static const String githubCredsKey = 'github-creds';
  static const String githubReqPrefixKey = 'GHReqPrefix';
  static const String githubReqPrefixUseTokenKey = 'GHReqPrefixUseToken';
  static const String enforceAttestationsKey = 'enforceGitHubAttestations';
  static const String buildVerificationModeKey = 'githubBuildVerificationMode';
  static const String buildVerificationOff = 'off';
  static const String buildVerificationAudit = 'audit';
  static const String buildVerificationEnforce = 'enforce';
  static const String validatedPATFingerprintKey =
      'githubValidatedPATFingerprint';

  GitHub({bool hostChanged = false}) {
    name = 'GitHub';
    hosts = ['github.com'];
    appIdInferIsOptional = true;
    // All four alternate version-string sources are offered via the unified
    // versionStringSource dropdown (see SourceProvider.versionStringSourceOptions).
    showReleaseDateAsVersionToggle = true;
    showReleaseTitleAsVersionToggle = true;
    showExtractVersionFromAssetNameToggle = true;
    showReleaseCommitShaAsVersionToggle = true;
    this.hostChanged = hostChanged;
    allowIncludeZips = true;
    allowIncludeTarballs = true;
    canSearch = true;
  }

  @override
  List<GeneratedFormItem> get sourceConfigSettingFormItems => [
    GeneratedFormTextField(
      githubCredsKey,
      label: tr('githubPATLabel'),
      password: true,
      required: false,
      helpUrl: 'https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token',
      assistIcon: Icons.verified_user_outlined,
      assistTooltip: tr('validateGitHubPAT'),
      assistAction: _validatePATFromSettingsForm,
    ),
    GeneratedFormTextField(
      'GHReqPrefix',
      label: tr('GHReqPrefix'),
      hint: 'gh-proxy.com',
      required: false,
      additionalValidators: [
        (value) {
          try {
            if (value != null && Uri.parse(value).scheme.isNotEmpty) {
              throw true;
            }
            if (value != null) {
              Uri.parse('https://$value/api.github.com');
            }
          } catch (e) {
            return tr('invalidInput');
          }
          return null;
        },
      ],
      helpUrl: 'https://github.com/sky22333/hubproxy',
    ),
    // Fork addition: companion to GHReqPrefix. When the proxy is set, the PAT
    // is stripped from proxied requests by default (see getTokenIfAny). Enabling
    // this opts back in to sending the token through the proxy.
    GeneratedFormSwitch(
      'GHReqPrefixUseToken',
      label: tr('GHReqPrefixUseToken'),
      value: false,
    ),
    GeneratedFormSwitch(
      'checkRepoRename',
      label: tr('repoRenamedCheck'),
      value: false,
    ),
  ];

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    [
      GeneratedFormSwitch(
        'includePrereleases',
        label: tr('includePrereleases'),
        value: false,
        turnsOffKeys: const ['verifyLatestTag'],
      ),
    ],
    // Paired with verifyLatestTag like includePrereleases: that check puts
    // the latest published release on top, so a draft could never win.
    [
      GeneratedFormSwitch(
        'includeDrafts',
        label: tr('includeDrafts'),
        value: false,
        turnsOffKeys: const ['verifyLatestTag'],
      ),
    ],
    [
      GeneratedFormSwitch(
        'verifyLatestTag',
        label: tr('verifyLatestTag'),
        turnsOffKeys: const ['includePrereleases', 'includeDrafts'],
      ),
    ],
    AppSource.fallbackToOlderReleasesFormItem,
    [
      GeneratedFormTextField(
        'filterReleaseTitlesByRegEx',
        label: tr('filterReleaseTitlesByRegEx'),
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
        'invertReleaseTitlesFilter',
        label: '${tr('invertRegEx')} (${tr('filterReleaseTitlesByRegEx')})',
        value: false,
      ),
    ],
    [
      GeneratedFormTextField(
        'filterReleaseNotesByRegEx',
        label: tr('filterReleaseNotesByRegEx'),
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
        'invertReleaseNotesFilter',
        label: '${tr('invertRegEx')} (${tr('filterReleaseNotesByRegEx')})',
        value: false,
      ),
    ],
    [
      GeneratedFormDropdown(
        buildVerificationModeKey,
        [
          MapEntry(buildVerificationOff, tr('githubBuildVerificationOff')),
          MapEntry(buildVerificationAudit, tr('githubBuildVerificationAudit')),
          MapEntry(
            buildVerificationEnforce,
            tr('githubBuildVerificationEnforce'),
          ),
        ],
        label: tr('githubBuildVerificationMode'),
        value: buildVerificationOff,
        labelTooltip: tr('githubBuildVerificationTooltip'),
      ),
    ],
    [
      GeneratedFormDropdown(
        'sortMethodChoice',
        [
          MapEntry('date', tr('releaseDate')),
          MapEntry('smartname', tr('smartname')),
          MapEntry('none', tr('none')),
          MapEntry(
            'smartname-datefallback',
            '${tr('smartname')} x ${tr('releaseDate')}',
          ),
          MapEntry('name', tr('name')),
        ],
        label: tr('sortMethod'),
        value: 'date',
      ),
    ],
    [
      GeneratedFormSwitch(
        'useLatestAssetDateAsReleaseDate',
        label: tr('useLatestAssetDateAsReleaseDate'),
        value: false,
      ),
    ],
    // 'releaseTitleAsVersion' is now offered through the unified
    // versionStringSource dropdown (showReleaseTitleAsVersionToggle), not a
    // standalone switch — syncVersionStringSourceSettings keeps the bool in sync.
  ];

  @override
  List<GeneratedFormItem> get searchQuerySettingFormItems => [
    GeneratedFormTextField(
      'minStarCount',
      label: tr('minStarCount'),
      value: '0',
      additionalValidators: [
        (value) {
          try {
            int.parse(value ?? '0');
          } catch (e) {
            return tr('invalidInput');
          }
          return null;
        },
      ],
    ),
  ];

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    // Parsing lives in gradle_app_id.dart so GitLab, Codeberg and SourceHut
    // share it — see the notes there on the Kotlin-DSL gap this closed.
    final String apiUrl = await convertStandardUrlToAPIUrl(
      standardUrl,
      additionalSettings,
    );
    return inferAppIdFromGradleFiles(
      (String path) async {
        final res = await sourceRequest(
          '$apiUrl/contents/$path',
          additionalSettings,
        );
        if (res.statusCode != 200) return null;
        return decodeRepoContentsApiBody(res.body);
      },
      listRepoFilePaths: () async {
        final res = await sourceRequest(
          '$apiUrl/git/trees/HEAD?recursive=1',
          additionalSettings,
        );
        if (res.statusCode != 200) return null;
        return repoFilePathsFromTreeApiBody(res.body);
      },
      onError: (String message) => unawaited(LogsProvider().add(message)),
      // A repo that builds a flavour per distribution channel names the one it
      // publishes here after this host, and that flavour can carry its own
      // applicationId or suffix.
      preferredFlavorNames: const <String>{'github', 'gh'},
    );
  }

  @override
  String sourceSpecificStandardizeURL(
    String url, {
    bool forSelection = false,
  }) => standardizeUrlWithRegex(
    url,
    subdomainPrefix: r'(www\.)?',
    pathPattern: r'/[^/]+/[^/]+',
  );

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    // A request with skipAuth is the retry without the configured token, after
    // GitHub rejected it for this repository (see [sourceRequest], #3211).
    final token = additionalSettings[_skipAuthKey] == true
        ? null
        : await getTokenIfAny(additionalSettings);
    final headers = <String, String>{};
    if (token != null && token.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    }
    if (forAPKDownload == true) {
      headers[HttpHeaders.acceptHeader] = 'application/octet-stream';
    }
    if (headers.isNotEmpty) {
      return headers;
    } else {
      return null;
    }
  }

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    final Response res = await super.sourceRequest(
      url,
      additionalSettings,
      followRedirects: followRedirects,
      postBody: postBody,
    );
    if (additionalSettings[_skipAuthKey] == true) return res;
    final String? token = await getTokenIfAny(additionalSettings);
    // The one retry layer for every API call: a rejected token (401, or a 403
    // whose message blames the token) must not block a public repository.
    // The retry carries skipAuth on a copy: blanking github-creds no longer
    // works, as a blank per-app value now falls back to the global token.
    if ((res.statusCode == 401 || _isAuthRejection(res)) &&
        token != null &&
        token.isNotEmpty) {
      final Map<String, dynamic> unauthSettings = Map<String, dynamic>.from(
        additionalSettings,
      )..[_skipAuthKey] = true;
      final Response retryRes = await super.sourceRequest(
        url,
        unauthSettings,
        followRedirects: followRedirects,
        postBody: postBody,
      );
      if (retryRes.statusCode < 400) {
        unawaited(
          LogsProvider().add(
            'GitHub API returned 401 with stored PAT. Retried unauthenticated successfully. Please check or update your GitHub Personal Access Token in Settings.',
          ),
        );
        return retryRes;
      }
    }
    return res;
  }

  /// Request-local flag (never persisted): send the request without the token.
  static const String _skipAuthKey = 'skipAuth';

  /// Whether [res] is a 401/403 whose JSON body says the configured token is
  /// the problem (e.g. "Resource not accessible by personal access token").
  static bool _isAuthRejection(Response res) {
    if (res.statusCode != 401 && res.statusCode != 403) return false;
    try {
      final message = (jsonDecode(res.body)['message'] as String? ?? '')
          .toLowerCase();
      return message.contains('access token') ||
          message.contains('bad credentials');
    } catch (_) {
      return false;
    }
  }

  Future<String?> getTokenIfAny(Map<String, dynamic> additionalSettings) async {
    final SettingsProvider settingsProvider = SettingsProvider();
    await settingsProvider.initializeSettings();
    final sourceConfig = await getSourceConfigValues(
      additionalSettings,
      settingsProvider,
    );
    String? creds = sourceConfig['github-creds'];
    // Fork addition: only strip the PAT from proxied requests when the user has
    // NOT opted to send it through the proxy (GHReqPrefixUseToken == 'false').
    // The use-token flag is read from the resolved sourceConfig, matching how
    // GHReqPrefix itself is configured as a source-config setting.
    if ((additionalSettings['GHReqPrefix'] as String? ?? '').isNotEmpty &&
        (sourceConfig['GHReqPrefixUseToken'] ?? 'false') == 'false') {
      creds = null;
    }
    if (creds != null) {
      final userNameEndIndex = creds.indexOf(':');
      if (userNameEndIndex > 0) {
        creds = creds.substring(
          userNameEndIndex + 1,
        ); // For old username-included token inputs
      }
      return creds;
    } else {
      return null;
    }
  }

  // ── GitHub build-attestation verification + PAT validation (fork feature) ──
  // The attestation API requires an authenticated request, so verification is
  // only offered once the user has validated a Personal Access Token. Statuses
  // are the githubAttestationStatus* constants from source_provider.

  static String? tokenFromCreds(String? creds) {
    String? token = creds?.trim();
    if (token == null || token.isEmpty) {
      return null;
    }
    final int userNameEndIndex = token.indexOf(':');
    if (userNameEndIndex > 0) {
      token = token.substring(userNameEndIndex + 1);
    }
    return token.trim().isEmpty ? null : token.trim();
  }

  static String? patFingerprint(String? creds) {
    final String? token = tokenFromCreds(creds);
    if (token == null) {
      return null;
    }
    return sha256.convert(utf8.encode(token)).toString();
  }

  static bool hasValidatedPAT(
    String? creds,
    SettingsProvider settingsProvider,
  ) {
    final String? fingerprint = patFingerprint(creds);
    if (fingerprint == null) {
      return false;
    }
    return settingsProvider.getSettingString(validatedPATFingerprintKey) ==
        fingerprint;
  }

  static void clearPATValidation(SettingsProvider settingsProvider) {
    settingsProvider.setSettingString(validatedPATFingerprintKey, '');
  }

  static void storePATValidation(
    String creds,
    SettingsProvider settingsProvider,
  ) {
    final String? fingerprint = patFingerprint(creds);
    if (fingerprint == null) {
      clearPATValidation(settingsProvider);
      return;
    }
    settingsProvider.setSettingString(validatedPATFingerprintKey, fingerprint);
  }

  static Future<String?> validatePAT(String creds) async {
    final String? token = tokenFromCreds(creds);
    if (token == null) {
      return tr('githubPATRequiredForDefaultVerification');
    }
    try {
      final Response response = await get(
        Uri.parse('https://api.github.com/user'),
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer $token',
          HttpHeaders.acceptHeader: 'application/vnd.github+json',
          HttpHeaders.userAgentHeader: 'ObtainX',
        },
      );
      if (response.statusCode == 200) {
        return null;
      }
      if (response.statusCode == 401) {
        return tr('githubPATInvalid');
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        return tr('githubPATValidationRateLimited');
      }
      return tr('githubPATValidationFailed');
    } catch (_) {
      return tr('githubPATValidationFailed');
    }
  }

  static Future<void> _validatePATFromSettingsForm(
    BuildContext context,
    FormValuesTextPatch patch,
    Map<String, dynamic> values,
  ) async {
    final String creds = values[githubCredsKey]?.toString() ?? '';
    final SettingsProvider settingsProvider = context.read<SettingsProvider>();
    final String? error = await validatePAT(creds);
    if (!context.mounted) {
      return;
    }
    if (error == null) {
      storePATValidation(creds, settingsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        buildAppSnackBar(
          context,
          tr('githubPATValidated'),
          type: ToastType.success,
        ),
      );
    } else {
      clearPATValidation(settingsProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(buildAppSnackBar(context, error, type: ToastType.error));
    }
  }

  bool canVerifyAttestations(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) {
    final String? creds =
        additionalSettings[githubCredsKey]?.toString() ??
        settingsProvider.getSettingString(githubCredsKey);
    return hasValidatedPAT(creds, settingsProvider);
  }

  /// The mode the app's own settings ask for, before [buildVerificationMode]
  /// checks there is a validated token to verify with.
  static String configuredBuildVerificationMode(
    Map<String, dynamic> additionalSettings,
  ) {
    final String mode =
        additionalSettings[buildVerificationModeKey]?.toString() ??
        (additionalSettings[enforceAttestationsKey] == true
            ? buildVerificationEnforce
            : buildVerificationOff);
    if (mode != buildVerificationAudit && mode != buildVerificationEnforce) {
      return buildVerificationOff;
    }
    return mode;
  }

  String buildVerificationMode(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) {
    final String mode = configuredBuildVerificationMode(additionalSettings);
    if (mode == buildVerificationOff ||
        !canVerifyAttestations(additionalSettings, settingsProvider)) {
      return buildVerificationOff;
    }
    return mode;
  }

  bool shouldVerifyAttestations(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) {
    return buildVerificationMode(additionalSettings, settingsProvider) !=
        buildVerificationOff;
  }

  bool shouldEnforceAttestations(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) {
    return buildVerificationMode(additionalSettings, settingsProvider) ==
        buildVerificationEnforce;
  }

  Future<String> getAttestationStatusForSha256Digest(
    String standardUrl,
    String sha256Digest,
    Map<String, dynamic> additionalSettings,
  ) async {
    final String digest = sha256Digest.startsWith('sha256:')
        ? sha256Digest.substring('sha256:'.length)
        : sha256Digest;
    if (digest.isEmpty) {
      return githubAttestationStatusError;
    }
    try {
      final Response response = await sourceRequest(
        '${await convertStandardUrlToAPIUrl(standardUrl, additionalSettings)}/attestations/sha256:$digest',
        additionalSettings,
      );
      if (response.statusCode == 404) {
        return githubAttestationStatusUnsupported;
      }
      if (response.statusCode != 200) {
        return githubAttestationStatusError;
      }
      final Map<String, dynamic>? body = _jsonObjectFromResponseBody(
        response.body,
      );
      final Object? attestations = body?['attestations'];
      if (attestations is List && attestations.isNotEmpty) {
        return githubAttestationStatusVerified;
      }
      return githubAttestationStatusUnsupported;
    } catch (_) {
      return githubAttestationStatusError;
    }
  }

  Future<bool?> hasAttestationForSha256Digest(
    String standardUrl,
    String sha256Digest,
    Map<String, dynamic> additionalSettings,
  ) async {
    final String status = await getAttestationStatusForSha256Digest(
      standardUrl,
      sha256Digest,
      additionalSettings,
    );
    if (status == githubAttestationStatusVerified) {
      return true;
    }
    if (status == githubAttestationStatusUnsupported) {
      return false;
    }
    return null;
  }

  @override
  Future<String?> getSourceNote() async {
    if (!hostChanged && (await getTokenIfAny({})) == null) {
      return '${tr('githubSourceNote')} ${hostChanged ? tr('addInfoBelow') : tr('addInfoInSettings')}';
    }
    return null;
  }

  @override
  Future<String> generalReqPrefetchModifier(
    String reqUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    if ((additionalSettings['GHReqPrefix'] as String? ?? '').isNotEmpty) {
      final uri = Uri.parse(reqUrl);
      return 'https://${additionalSettings['GHReqPrefix']}/${uri.toString().substring('https://'.length)}';
    }
    return reqUrl;
  }

  Future<String> getAPIHost(Map<String, dynamic> additionalSettings) async =>
      'https://api.${hosts[0]}';

  Future<String> convertStandardUrlToAPIUrl(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async =>
      '${await getAPIHost(additionalSettings)}/repos${standardUrl.substring('https://${hosts[0]}'.length)}';

  /// Checks if the repository has been renamed or transferred.
  ///
  /// This method explicitly disables automatic redirect following to detect when
  /// GitHub returns a redirect (indicating the repository has moved). A redirect
  /// from the GitHub API for a repository endpoint definitively indicates that
  /// the repository has been renamed or transferred to a different owner.
  ///
  /// Throws [RepositoryRenamedError] if a redirect is detected. Returns the
  /// repository JSON when the request succeeds, so the archived check (D8)
  /// can reuse it instead of sending a second request.
  Future<Map<String, dynamic>?> checkForRepositoryRename(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    Map<String, String> sourceConfigSettingValues,
  ) async {
    if (sourceConfigSettingValues['checkRepoRename'] != 'true') {
      return null;
    }
    final uri = Uri.tryParse(standardUrl);
    final host = uri?.host.toLowerCase() ?? '';
    // Guard against non-GitHub URLs
    if (host != hosts[0] && host != 'www.${hosts[0]}') {
      return null;
    }
    final apiUrl = await convertStandardUrlToAPIUrl(
      standardUrl,
      additionalSettings,
    );
    final Response res = await sourceRequest(
      apiUrl,
      additionalSettings,
      followRedirects: false,
    );
    if (res.statusCode >= 300 && res.statusCode < 400) {
      final String? location =
          res.headers[HttpHeaders.locationHeader.toLowerCase()];
      if (location != null) {
        final Response res2 = await sourceRequest(
          location,
          additionalSettings,
          followRedirects: false,
        );
        String? newUrl;
        try {
          newUrl = jsonDecode(res2.body)['html_url'];
        } catch (e) {
          unawaited(
            LogsProvider().add(
              'Failed to parse redirect response for repo rename: ${e.toString()}',
            ),
          );
        }
        if (newUrl != null) {
          throw RepositoryRenamedError(standardUrl, newUrl);
        }
      }
      return null;
    }
    return res.statusCode == 200 ? _jsonObjectFromResponseBody(res.body) : null;
  }

  /// The repository JSON from [repoApiUrl], or null on any failure: the
  /// archived flag is advisory and must never fail an update check. Goes
  /// through [sourceRequest], the one token-rejection retry layer.
  Future<Map<String, dynamic>?> _fetchRepoInfoQuietly(
    String repoApiUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final Response res = await sourceRequest(repoApiUrl, additionalSettings);
      return res.statusCode == 200
          ? _jsonObjectFromResponseBody(res.body)
          : null;
    } catch (e) {
      unawaited(LogsProvider().add('Failed to fetch repo info: $e'));
      return null;
    }
  }

  static bool _repoIsArchived(Map<String, dynamic> repoInfo) =>
      repoInfo['archived'] == true || repoInfo['disabled'] == true;

  /// How long a read archived flag is trusted before it may be fetched again.
  static const Duration _archivedStatusMaxAge = Duration(days: 7);

  /// The release age past which a repository is worth probing for its
  /// archived flag when the stale-release heuristic itself is off.
  static const int _fallbackStaleReleaseDays = 180;

  /// Set when this check read the repository's archived flag;
  /// [postProcessApp] records it on the app ([repoArchivedCheckedAtKey]).
  /// Safe as instance state: every check gets its own source instance.
  DateTime? _repoArchivedCheckedAt;

  /// The repository's archived flag for update health (#1753, D8), or null to
  /// keep the stored [App.isArchived]. Upstream asks for `/repos/{o}/{r}` on
  /// every check, which doubles GitHub API use (60 requests an hour without a
  /// token). ObtainX reads it only when it costs nothing ([repoInfo], already
  /// fetched by the rename check) or when it can matter: the archive check is
  /// on, the stored flag is older than [_archivedStatusMaxAge], and the
  /// selected release already looks stale (an archived repository can't
  /// publish new releases) or the app was flagged archived before (so an
  /// unarchived repository gets cleared).
  Future<bool?> _resolveArchivedStatus({
    required Map<String, dynamic>? repoInfo,
    required String? repoApiUrl,
    required DateTime? releaseDate,
    required Map<String, dynamic> additionalSettings,
    required SettingsProvider settingsProvider,
  }) async {
    final DateTime now = DateTime.now();
    if (repoInfo != null) {
      _repoArchivedCheckedAt = now;
      return _repoIsArchived(repoInfo);
    }
    if (repoApiUrl == null) return null;
    final UpdateHealthConfig config = resolveUpdateHealthConfig(
      additionalSettings,
      settingsProvider,
    );
    if (!config.archivedEnabled) return null;
    final Object? checkedAt = additionalSettings[repoArchivedCheckedAtKey];
    if (checkedAt is int &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(checkedAt)) <
            _archivedStatusMaxAge) {
      return null;
    }
    final int staleDays = config.staleReleaseDays ?? _fallbackStaleReleaseDays;
    final bool releaseLooksStale =
        releaseDate != null && now.difference(releaseDate).inDays >= staleDays;
    if (!releaseLooksStale && previouslyCheckedApp?.isArchived != true) {
      return null;
    }
    final Map<String, dynamic>? info = await _fetchRepoInfoQuietly(
      repoApiUrl,
      additionalSettings,
    );
    if (info == null) return null;
    _repoArchivedCheckedAt = now;
    return _repoIsArchived(info);
  }

  @override
  App postProcessApp(App app) {
    final DateTime? checkedAt = _repoArchivedCheckedAt;
    if (checkedAt == null) return app;
    return app.copyWith(
      additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
        ..[repoArchivedCheckedAtKey] = checkedAt.millisecondsSinceEpoch,
    );
  }

  @override
  String? changeLogPageFromStandardUrl(String standardUrl) =>
      '$standardUrl/releases';

  List<dynamic> _findReleaseAssetUrls(
    dynamic release,
    bool includeZips,
    bool includeTarballs,
    Map<String, String> sourceConfigSettingValues,
  ) =>
      (release['assets'] as List<dynamic>?)?.map((e) {
        final name = e['name'].toString();
        var url =
            !AppSource.isApkOrContainerFile(
              name,
              includeArchives: includeZips,
              includeTarballs: includeTarballs,
            )
            ? (e['browser_download_url'] ?? e['url'])
            : (e['url'] ?? e['browser_download_url']);
        url = undoGHProxyMod(url, sourceConfigSettingValues);
        e['final_url'] = (e['name'] != null) && (url != null)
            ? MapEntry(e['name'] as String, url as String)
            : const MapEntry('', '');
        return e;
      }).toList() ??
      [];

  DateTime? _getPublishDateFromRelease(dynamic rel) {
    final pub = rel?['published_at'];
    if (pub is String) return DateTime.tryParse(pub);
    final commitCreated = rel?['commit']?['created'];
    if (commitCreated is String) return DateTime.tryParse(commitCreated);
    return null;
  }

  DateTime? _getNewestAssetDateFromRelease(dynamic rel) =>
      newestAssetDateFromRelease(rel);

  DateTime? _getReleaseDateFromRelease(dynamic rel, bool useAssetDate) =>
      !useAssetDate
      ? _getPublishDateFromRelease(rel)
      : _getNewestAssetDateFromRelease(rel);

  void sortGitHubReleases(
    List<dynamic> releases,
    String sortMethod,
    bool useLatestAssetDateAsReleaseDate,
  ) {
    if (sortMethod == 'none') return;

    int compareReleaseDates(DateTime? firstDate, DateTime? secondDate) {
      if (firstDate == null && secondDate == null) return 0;
      if (firstDate == null) return -1;
      if (secondDate == null) return 1;
      return firstDate.compareTo(secondDate);
    }

    final Map<dynamic, DateTime?> dates = {};
    DateTime? releaseDate(dynamic release) {
      return dates.putIfAbsent(
        release,
        () => _getReleaseDateFromRelease(
          release,
          useLatestAssetDateAsReleaseDate,
        ),
      );
    }

    // Natural-name/date ordering only selects a source release when its labels
    // are incomparable. It never supplies evidence for a device update.
    final useVersionOrder =
        sortMethod != 'date' &&
        sortMethod != 'name' &&
        versionsHaveConsistentOrder(
          releases
              .where((release) => release != null)
              .map(
                (release) =>
                    (release['tag_name'] ?? release['name'])?.toString() ?? '',
              ),
        );
    releases.sort((firstRelease, secondRelease) {
      if (firstRelease == null && secondRelease == null) return 0;
      if (firstRelease == null) return -1;
      if (secondRelease == null) return 1;
      if (sortMethod == 'date' ||
          (!useVersionOrder && sortMethod == 'smartname-datefallback')) {
        return compareReleaseDates(
          releaseDate(firstRelease),
          releaseDate(secondRelease),
        );
      }
      final firstName =
          (firstRelease['tag_name'] ?? firstRelease['name'])?.toString() ?? '';
      final secondName =
          (secondRelease['tag_name'] ?? secondRelease['name'])?.toString() ??
          '';
      if (useVersionOrder) {
        final ordered = compareVersionStrings(firstName, secondName).comparison;
        if (ordered != null && ordered != 0) return ordered;
        if (ordered == 0 || sortMethod == 'smartname-datefallback') {
          return compareReleaseDates(
            releaseDate(firstRelease),
            releaseDate(secondRelease),
          );
        }
      }
      final nameComparison = compareAlphaNumeric(
        firstName.toLowerCase(),
        secondName.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;
      return compareReleaseDates(
        releaseDate(firstRelease),
        releaseDate(secondRelease),
      );
    });
  }

  void _positionLatestRelease(List<dynamic> releases, dynamic latestRelease) {
    if (latestRelease == null ||
        (latestRelease['tag_name'] ?? latestRelease['name']) == null ||
        releases.isEmpty ||
        (latestRelease['tag_name'] ?? latestRelease['name']) ==
            (releases[releases.length - 1]['tag_name'] ??
                releases[releases.length - 1]['name'])) {
      return;
    }
    final ind = releases.indexWhere(
      (element) =>
          (latestRelease['tag_name'] ?? latestRelease['name']) ==
          (element['tag_name'] ?? element['name']),
    );
    if (ind >= 0) {
      releases.add(releases.removeAt(ind));
    }
  }

  /// Resolves the commit SHA a release's tag points at (following annotated
  /// tags to their underlying commit), for "release commit SHA as version"
  /// mode. Returns null if it can't be determined.
  Future<String?> getReleaseCommitSha(
    dynamic release,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final String? tagName = release['tag_name'] as String?;
    if (tagName == null || tagName.trim().isEmpty) {
      return null;
    }
    final String apiUrl = await convertStandardUrlToAPIUrl(
      standardUrl,
      additionalSettings,
    );
    final Response refResponse = await sourceRequest(
      '$apiUrl/git/ref/tags/${Uri.encodeComponent(tagName)}',
      additionalSettings,
    );
    if (refResponse.statusCode != 200) {
      return null;
    }
    final Map<String, dynamic>? refBody = _jsonObjectFromResponseBody(
      refResponse.body,
    );
    final dynamic refObject = refBody?['object'];
    if (refObject is! Map<String, dynamic>) {
      return null;
    }
    final String? objectSha = refObject['sha'] as String?;
    final String? objectType = refObject['type'] as String?;
    if (objectSha == null || objectSha.isEmpty) {
      return null;
    }
    if (objectType == 'commit') {
      return objectSha;
    }
    if (objectType != 'tag') {
      return null;
    }
    final Response tagResponse = await sourceRequest(
      '$apiUrl/git/tags/$objectSha',
      additionalSettings,
    );
    if (tagResponse.statusCode != 200) {
      return null;
    }
    final Map<String, dynamic>? tagBody = _jsonObjectFromResponseBody(
      tagResponse.body,
    );
    final dynamic tagObject = tagBody?['object'];
    if (tagObject is! Map<String, dynamic>) {
      return null;
    }
    final String? commitSha = tagObject['sha'] as String?;
    final String? commitType = tagObject['type'] as String?;
    return commitType == 'commit' ? commitSha : null;
  }

  dynamic _selectGitHubTargetRelease({
    required List<dynamic> releases,
    required bool fallbackToOlderReleases,
    required bool includePrereleases,
    required String? regexFilter,
    required String? regexNotesFilter,
    required bool includeZips,
    required bool includeTarballs,
    required bool useLatestAssetDateAsReleaseDate,
    required int minAgeDays,
    required Map<String, dynamic> additionalSettings,
    required Map<String, String> sourceConfigSettingValues,
  }) {
    // Releases passed over for being a prerelease, a draft or too young, so
    // that "don't fall back to older releases" still reaches the first
    // release that qualifies (upstream: drafts used to end the search).
    var releaseSkipped = 0;
    // Newer releases the user's title, notes or APK filters rejected, for
    // update health (#1753). Counted per call, so each min-age pass of the
    // caller reports the count in front of the release it returns.
    var userFilteredOut = 0;
    final titleRegex = regexFilter != null ? RegExp(regexFilter) : null;
    final notesRegex = regexNotesFilter != null
        ? RegExp(regexNotesFilter)
        : null;
    final bool invertTitleFilter =
        additionalSettings['invertReleaseTitlesFilter'] == true;
    final bool invertNotesFilter =
        additionalSettings['invertReleaseNotesFilter'] == true;
    final bool includeDrafts = additionalSettings['includeDrafts'] == true;
    for (int i = 0; i < releases.length; i++) {
      if (!fallbackToOlderReleases && i > releaseSkipped) break;
      if (isReleaseExcluded(
        releases[i],
        includePrereleases: includePrereleases,
        includeDrafts: includeDrafts,
      )) {
        releaseSkipped++;
        continue;
      }
      var nameToFilter = releases[i]['name'] as String?;
      if (nameToFilter == null || nameToFilter.trim().isEmpty) {
        nameToFilter = releases[i]['tag_name']?.toString() ?? '';
      }
      if (titleRegex != null &&
          !passesRegExFilter(
            titleRegex,
            nameToFilter.trim(),
            invert: invertTitleFilter,
          )) {
        userFilteredOut++;
        continue;
      }
      if (notesRegex != null &&
          !passesRegExFilter(
            notesRegex,
            ((releases[i]['body'] as String?) ?? '').trim(),
            invert: invertNotesFilter,
          )) {
        userFilteredOut++;
        continue;
      }
      // Minimum update age (#3303): pass over releases still too young.
      if (isReleaseTooYoung(
        _getReleaseDateFromRelease(
          releases[i],
          useLatestAssetDateAsReleaseDate,
        ),
        minAgeDays,
      )) {
        releaseSkipped++;
        continue;
      }
      final allAssetsWithUrls = _findReleaseAssetUrls(
        releases[i],
        includeZips,
        includeTarballs,
        sourceConfigSettingValues,
      );
      final List<MapEntry<String, String>> allAssetUrls = allAssetsWithUrls
          .map((e) => e['final_url'] as MapEntry<String, String>)
          .toList();
      final apkAssetsWithUrls = allAssetsWithUrls.where((element) {
        final name = (element['final_url'] as MapEntry<String, String>).key;
        return AppSource.isApkOrContainerFile(
          name,
          includeArchives: includeZips,
          includeTarballs: includeTarballs,
        );
      }).toList();

      final filteredApkUrls = filterApks(
        apkAssetsWithUrls
            .map((e) => e['final_url'] as MapEntry<String, String>)
            .toList(),
        additionalSettings['apkFilterRegEx'],
        additionalSettings['invertAPKFilter'],
      );
      final filteredApks = apkAssetsWithUrls
          .where(
            (e) => filteredApkUrls
                .where(
                  (e2) =>
                      e2.key ==
                      (e['final_url'] as MapEntry<String, String>).key,
                )
                .isNotEmpty,
          )
          .toList();

      if (filteredApks.isEmpty && additionalSettings['trackOnly'] != true) {
        userFilteredOut++;
        continue;
      }
      final targetRelease = releases[i];
      targetRelease['apkUrls'] = filteredApkUrls;
      targetRelease['filteredAssets'] = filteredApks;
      // Resolve the version string per the selected version-string source.
      // Asset-name + release-title are resolvable synchronously here; the
      // commit-SHA source needs an async API lookup + standardUrl, so it is
      // resolved by the caller (_fetchReleaseDetails) after selection.
      String? selectedVersionSource;
      if (additionalSettings['extractVersionFromAssetName'] == true) {
        if (filteredApkUrls.isEmpty) {
          throw NoVersionError();
        }
        selectedVersionSource = filteredApkUrls.last.key;
      } else if (additionalSettings['releaseTitleAsVersion'] == true) {
        selectedVersionSource = nameToFilter;
      }
      targetRelease['version'] =
          selectedVersionSource ??
          targetRelease['tag_name'] ??
          targetRelease['name'];
      if (targetRelease['tarball_url'] != null) {
        allAssetUrls.add(
          MapEntry(
            (targetRelease['version'] ?? 'source') + '.tar.gz',
            undoGHProxyMod(
              targetRelease['tarball_url'],
              sourceConfigSettingValues,
            ),
          ),
        );
      }
      if (targetRelease['zipball_url'] != null) {
        allAssetUrls.add(
          MapEntry(
            (targetRelease['version'] ?? 'source') + '.zip',
            undoGHProxyMod(
              targetRelease['zipball_url'],
              sourceConfigSettingValues,
            ),
          ),
        );
      }
      targetRelease['allAssetUrls'] = allAssetUrls;
      targetRelease['newerReleasesFilteredOut'] = userFilteredOut;
      return targetRelease;
    }
    return null;
  }

  /// Fetches and parses GitHub releases, applying sort/filter/prelease settings,
  /// then resolves the best matching release to an [APKDetails] result.
  ///
  /// [repoApiUrl] is the repository's API URL (`/repos/{o}/{r}`) for the
  /// archived check, or null where there is none to ask.
  Future<APKDetails> _fetchReleaseDetails(
    String requestUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings, {
    Function(Response)? onHttpErrorCode,
    String? repoApiUrl,
  }) async {
    final SettingsProvider settingsProvider = SettingsProvider();
    await settingsProvider.initializeSettings();
    final sourceConfigSettingValues = await getSourceConfigValues(
      additionalSettings,
      settingsProvider,
    );
    final Map<String, dynamic>? repoInfo = await checkForRepositoryRename(
      standardUrl,
      additionalSettings,
      sourceConfigSettingValues,
    );
    final bool includePrereleases =
        additionalSettings['includePrereleases'] == true;
    final bool fallbackToOlderReleases =
        additionalSettings['fallbackToOlderReleases'] == true;
    final String? regexFilter =
        (additionalSettings['filterReleaseTitlesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseTitlesByRegEx']
        : null;
    final String? regexNotesFilter =
        (additionalSettings['filterReleaseNotesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseNotesByRegEx']
        : null;
    // Including prereleases or drafts wins over verifyLatestTag (the form
    // pairs them with turnsOffKeys; this covers settings saved before that).
    final bool verifyLatestTag =
        additionalSettings['verifyLatestTag'] == true &&
        !includePrereleases &&
        additionalSettings['includeDrafts'] != true;
    final bool useLatestAssetDateAsReleaseDate =
        additionalSettings['useLatestAssetDateAsReleaseDate'] == true;
    final String sortMethod =
        additionalSettings['sortMethodChoice'] ?? 'smartname-datefallback';
    final bool includeZips = additionalSettings['includeZips'] == true;
    final bool includeTarballs = additionalSettings['includeTarballs'] == true;
    final int minAgeDays = await effectiveMinUpdateAgeDays(
      additionalSettings,
      settingsProvider: settingsProvider,
    );
    dynamic latestRelease;
    if (verifyLatestTag) {
      final uri = Uri.parse(requestUrl);
      final latestUrl = uri.replace(query: null, path: '${uri.path}/latest');
      final Response res = await sourceRequest(
        latestUrl.toString(),
        additionalSettings,
      );
      if (res.statusCode != 200) {
        if (onHttpErrorCode != null) {
          onHttpErrorCode(res);
        }
        throw getObtainiumHttpError(res);
      }
      latestRelease = jsonDecode(res.body);
    }
    final Response res = await sourceRequest(requestUrl, additionalSettings);
    if (res.statusCode == 200) {
      final decoded = jsonDecode(res.body);
      if (decoded is! List) {
        throw NoReleasesError();
      }
      var releases = decoded;
      if (latestRelease != null) {
        final latestTag = latestRelease['tag_name'] ?? latestRelease['name'];
        if (releases
            .where(
              (element) =>
                  (element['tag_name'] ?? element['name']) == latestTag,
            )
            .isEmpty) {
          releases = [latestRelease, ...releases];
        }
      }

      if (sortMethod == 'none') {
        releases = releases.reversed.toList();
      } else {
        sortGitHubReleases(
          releases,
          sortMethod,
          useLatestAssetDateAsReleaseDate,
        );
      }
      _positionLatestRelease(releases, latestRelease);
      releases = releases.reversed.toList();
      // Prefer a release old enough for the minimum update age; if none is,
      // fall back to the newest so the update check can hold it back until it
      // ages.
      dynamic selectTargetRelease(List<dynamic> candidates) {
        for (final int age in minAgeDays > 0 ? [minAgeDays, 0] : [0]) {
          final dynamic selected = _selectGitHubTargetRelease(
            releases: candidates,
            fallbackToOlderReleases: fallbackToOlderReleases,
            includePrereleases: includePrereleases,
            regexFilter: regexFilter,
            regexNotesFilter: regexNotesFilter,
            includeZips: includeZips,
            includeTarballs: includeTarballs,
            useLatestAssetDateAsReleaseDate: useLatestAssetDateAsReleaseDate,
            minAgeDays: age,
            additionalSettings: additionalSettings,
            sourceConfigSettingValues: sourceConfigSettingValues,
          );
          if (selected != null) return selected;
        }
        return null;
      }

      dynamic targetRelease = selectTargetRelease(releases);
      // Fork PR #375 (thejaustin), folded into the v1.7.4 sync: only the
      // first page (100 releases) is read, so a repo that ships many
      // prereleases can push its latest stable release off it. In that case
      // ask for /releases/latest and run it through the same filters and
      // min-age passes. Only when the page holds no published stable release
      // at all: otherwise /latest is already on it and the filters turned it
      // down. Forgejo serves /releases/latest too, so Codeberg shares this.
      dynamic latestFallbackRelease;
      if (targetRelease == null &&
          !includePrereleases &&
          latestRelease == null &&
          releases.isNotEmpty &&
          releases.every(
            (release) =>
                release is Map &&
                (release['prerelease'] == true || release['draft'] == true),
          ) &&
          Uri.parse(requestUrl).path.endsWith('/releases')) {
        final uri = Uri.parse(requestUrl);
        final Response latestRes = await sourceRequest(
          uri.replace(query: null, path: '${uri.path}/latest').toString(),
          additionalSettings,
        );
        if (latestRes.statusCode == 200) {
          final dynamic latest = jsonDecode(latestRes.body);
          if (latest is Map<String, dynamic>) {
            targetRelease = selectTargetRelease([latest]);
            if (targetRelease != null) latestFallbackRelease = latest;
          }
        } else if (latestRes.statusCode != 404) {
          // A 404 means no published release; anything else (a rate limit)
          // is an error of its own, not "no releases".
          if (onHttpErrorCode != null) {
            onHttpErrorCode(latestRes);
          }
          throw getObtainiumHttpError(latestRes);
        }
      }
      if (targetRelease == null) {
        throw NoReleasesError();
      }
      // Resolve commit-SHA-as-version here: it needs an async ref/tag API
      // lookup and standardUrl, so it can't run inside the sync release
      // selector. Overrides the tag-based version chosen there.
      if (additionalSettings['releaseCommitShaAsVersion'] == true) {
        final String? commitSha = await getReleaseCommitSha(
          targetRelease,
          standardUrl,
          additionalSettings,
        );
        if (commitSha == null) {
          throw NoVersionError();
        }
        targetRelease['version'] = commitSha;
      }
      final String? version = targetRelease['version'];
      final DateTime? releaseDate = _getReleaseDateFromRelease(
        targetRelease,
        useLatestAssetDateAsReleaseDate,
      );
      if (version == null || version.isEmpty) {
        throw NoVersionError();
      }
      final changeLog = (targetRelease['body'] ?? '').toString();
      final apkUrls =
          targetRelease['apkUrls'] as List<MapEntry<String, String>>;

      // Advance download size for the preferred APK, read from the GitHub API's
      // per-asset `size` field (no extra network request) — parity with fork
      // main (v2.9.3). This is what shows the update size on the update button;
      // dropping it in the sync is why GitHub (and Codeberg, which delegates
      // here) apps stopped showing a size.
      int? apkSizeBytes;
      if (apkUrls.isNotEmpty) {
        final sizeAssets =
            (targetRelease['filteredAssets'] as List<dynamic>?) ?? [];
        for (final asset in sizeAssets.whereType<Map<String, dynamic>>()) {
          final assetName =
              (asset['final_url'] as MapEntry<String, String>?)?.key;
          if (assetName == apkUrls.last.key) {
            final rawSize = asset['size'];
            if (rawSize is num) apkSizeBytes = rawSize.toInt();
            break;
          }
        }
      }

      // ── GitHub build-attestation status (fork feature) ──────────────────
      // Compute the attestation verdict at CHECK time from the preferred
      // asset's API-provided sha256 `digest`, so the app page can show
      // Verified / Unsupported / Can't-Check immediately — without waiting for
      // the APK to be downloaded (the /attestations lookup only needs the
      // digest, not the bytes). This is what drives the "Security" badge on the
      // update card; dropping it leaves latestAttestationStatus null, which the
      // UI renders as "Can't Check". Do NOT remove — attestation is only
      // otherwise recomputed at install time.
      final bool shouldCheckAttestation = shouldVerifyAttestations(
        additionalSettings,
        settingsProvider,
      );
      String? attestationStatus;
      if (shouldCheckAttestation) {
        final filteredAssets =
            (targetRelease['filteredAssets'] as List<dynamic>?) ?? [];
        Map<String, dynamic>? preferredAsset;
        if (apkUrls.isNotEmpty) {
          for (final asset
              in filteredAssets.whereType<Map<String, dynamic>>()) {
            final assetName =
                (asset['final_url'] as MapEntry<String, String>?)?.key;
            if (assetName == apkUrls.last.key) {
              preferredAsset = asset;
              break;
            }
          }
        }
        final String? preferredAssetDigest =
            preferredAsset?['digest'] as String?;
        // Skip the attestation API round-trip when the upstream release is
        // unchanged and we hold a CONCLUSIVE cached verdict. A GitHub
        // attestation is produced inside the release workflow run that builds
        // the asset and bound to its digest, so for an unchanged release both
        // 'verified' and 'unsupported' (no attestation for this digest) are
        // stable. Only a cached 'error' is re-checked, since that is a
        // transient lookup failure, not a real verdict.
        final App? prevApp = previouslyCheckedApp;
        final bool canReuseCachedAttestation =
            prevApp != null &&
            prevApp.rawLatestVersionFromSource != null &&
            prevApp.rawLatestVersionFromSource == version &&
            prevApp.latestAttestationStatus != null &&
            prevApp.latestAttestationStatus != githubAttestationStatusError;
        attestationStatus = canReuseCachedAttestation
            ? prevApp.latestAttestationStatus
            : preferredAssetDigest != null
            ? await getAttestationStatusForSha256Digest(
                standardUrl,
                preferredAssetDigest,
                additionalSettings,
              )
            : githubAttestationStatusError;
      }

      final List<String> rawReleaseTitleCandidates = <String>[];
      // The /latest fallback release is the oldest one seen, so it goes last.
      for (final rel in [...releases, ?latestFallbackRelease]) {
        if (rel is Map<String, dynamic>) {
          final String? title =
              (rel['name'] as String?)?.trim().isNotEmpty == true
              ? (rel['name'] as String).trim()
              : (rel['tag_name'] as String?)?.trim();
          if (title != null &&
              title.isNotEmpty &&
              !rawReleaseTitleCandidates.contains(title)) {
            rawReleaseTitleCandidates.add(title);
          }
        }
      }

      final bool? isArchived = await _resolveArchivedStatus(
        repoInfo: repoInfo,
        repoApiUrl: repoApiUrl,
        releaseDate: releaseDate,
        additionalSettings: additionalSettings,
        settingsProvider: settingsProvider,
      );

      // No `releaseUrl` (upstream ad1c208e): ObtainX resolves relative
      // changelog links against the repository instead (v1.7.4 sync D21).
      return APKDetails(
        version,
        apkUrls,
        getAppNames(standardUrl),
        releaseDate: releaseDate,
        changeLog: changeLog.isEmpty ? null : changeLog,
        allAssetUrls:
            targetRelease['allAssetUrls'] as List<MapEntry<String, String>>,
        rawReleaseTitleCandidates: rawReleaseTitleCandidates,
        apkSizeBytes: apkSizeBytes,
        attestationStatus: attestationStatus,
        isArchived: isArchived,
        newerReleasesFilteredOut:
            targetRelease['newerReleasesFilteredOut'] as int?,
      );
    } else {
      if (onHttpErrorCode != null) {
        onHttpErrorCode(res);
      }
      throw getObtainiumHttpError(res);
    }
  }

  /// [repoApiUrl]: see [_fetchReleaseDetails].
  Future<APKDetails> fetchReleaseDetailsWithTagFallback(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    Future<String> Function(bool) reqUrlGenerator,
    dynamic Function(Response)? onHttpErrorCode, {
    String? repoApiUrl,
  }) async {
    try {
      return await _fetchReleaseDetails(
        await reqUrlGenerator(false),
        standardUrl,
        additionalSettings,
        onHttpErrorCode: onHttpErrorCode,
        repoApiUrl: repoApiUrl,
      );
    } catch (err) {
      if (err is NoReleasesError && additionalSettings['trackOnly'] == true) {
        return await _fetchReleaseDetails(
          await reqUrlGenerator(true),
          standardUrl,
          additionalSettings,
          onHttpErrorCode: onHttpErrorCode,
          repoApiUrl: repoApiUrl,
        );
      } else {
        rethrowOrWrapError(err);
      }
    }
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final String apiUrl = await convertStandardUrlToAPIUrl(
        standardUrl,
        additionalSettings,
      );
      return await fetchReleaseDetailsWithTagFallback(
        standardUrl,
        additionalSettings,
        (bool useTagUrl) async {
          return '$apiUrl/${useTagUrl ? 'tags' : 'releases'}?per_page=100';
        },
        (Response res) {
          githubErrorCheck(res);
        },
        // The API URL is built for github.com, so an overridden host has none
        // to ask (as upstream).
        repoApiUrl: hostChanged ? null : apiUrl,
      );
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }

  AppNames getAppNames(String standardUrl) {
    final String temp = standardUrl.substring(standardUrl.indexOf('://') + 3);
    final pathStart = temp.indexOf('/');
    if (pathStart < 0) throw InvalidURLError(name);
    final List<String> names = temp.substring(pathStart + 1).split('/');
    if (names.isEmpty || names[0].isEmpty) throw InvalidURLError(name);
    return AppNames(names[0], names.sublist(1).join('/'));
  }

  /// Runs a repository search and preserves star counts in [SearchResultDetails].
  Future<Map<String, SearchResultDetails>> searchCommonWithDetails(
    String query,
    String requestUrl,
    String rootProp, {
    Function(Response)? onHttpErrorCode,
    Map<String, dynamic> querySettings = const {},
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    final Response res = await sourceRequest(requestUrl, additionalSettings);
    if (res.statusCode == 200) {
      final int minStarCount =
          int.tryParse(querySettings['minStarCount']?.toString() ?? '') ?? 0;
      final Map<String, SearchResultDetails> resultsByUrl = {};
      for (final dynamic repoItem
          in (jsonDecode(res.body)[rootProp] as List<dynamic>)) {
        final int? starCount = AppSource.parseSearchStarCount(
          repoItem['stargazers_count'] ?? repoItem['stars_count'],
        );
        if ((starCount ?? 0) >= minStarCount) {
          resultsByUrl[repoItem['html_url'] as String] = SearchResultDetails(
            subtitleLines: [
              repoItem['full_name'] as String,
              ((repoItem['archived'] == true ? '[ARCHIVED] ' : '') +
                  (repoItem['description'] != null
                      ? repoItem['description'] as String
                      : tr('noDescription'))),
            ],
            starCount: starCount,
          );
        }
      }
      return resultsByUrl;
    } else {
      if (onHttpErrorCode != null) {
        onHttpErrorCode(res);
      }
      throw getObtainiumHttpError(res);
    }
  }

  Future<Map<String, List<String>>> searchCommon(
    String query,
    String requestUrl,
    String rootProp, {
    Function(Response)? onHttpErrorCode,
    Map<String, dynamic> querySettings = const {},
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    final Map<String, SearchResultDetails> detailedResults =
        await searchCommonWithDetails(
          query,
          requestUrl,
          rootProp,
          onHttpErrorCode: onHttpErrorCode,
          querySettings: querySettings,
          additionalSettings: additionalSettings,
        );
    return AppSource.subtitleLinesByUrl(detailedResults);
  }

  String undoGHProxyMod(
    String reqUrl,
    Map<String, String> sourceConfigSettingValues,
  ) {
    final ghReqPrefix = sourceConfigSettingValues['GHReqPrefix'];
    if (ghReqPrefix == null || ghReqPrefix.isEmpty) return reqUrl;
    final prefix = 'https://$ghReqPrefix/';
    return reqUrl.startsWith(prefix) ? reqUrl.substring(prefix.length) : reqUrl;
  }

  @override
  Future<Map<String, SearchResultDetails>> searchWithDetails(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final SettingsProvider settingsProvider = SettingsProvider();
    await settingsProvider.initializeSettings();
    final Map<String, String> sourceConfigSettingValues =
        await getSourceConfigValues({}, settingsProvider);
    final Map<String, SearchResultDetails>
    results = await searchCommonWithDetails(
      query,
      '${await getAPIHost({})}/search/repositories?q=${Uri.encodeQueryComponent(query)}&per_page=100',
      'items',
      onHttpErrorCode: (Response res) {
        githubErrorCheck(res);
      },
      querySettings: querySettings,
    );
    if ((sourceConfigSettingValues['GHReqPrefix'] ?? '').isNotEmpty) {
      return {
        for (final MapEntry<String, SearchResultDetails> entry
            in results.entries)
          undoGHProxyMod(entry.key, sourceConfigSettingValues): entry.value,
      };
    }
    return results;
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final Map<String, SearchResultDetails> detailedResults =
        await searchWithDetails(query, querySettings: querySettings);
    return AppSource.subtitleLinesByUrl(detailedResults);
  }

  /// Throws a [RateLimitError] when the failed response [res] says GitHub is
  /// rate limiting, by the rule every source uses ([HttpService.getHttpError]):
  /// a 429, a 403 with a spent quota or a retry time, or "rate limit" or "too
  /// many requests" in the reply. A plain 403 is a refusal and is left to the
  /// caller's error (#344). A rate limit without a retry time says so, rather
  /// than naming a wait GitHub never gave; background checks still wait
  /// [RateLimitError.defaultRetryWaitMinutes].
  void rateLimitErrorCheck(Response res) {
    final ObtainiumError error = getObtainiumHttpError(res);
    if (error is RateLimitError) throw error;
  }

  /// Throws GitHub's real error for a failed API response (#3211). A 401/403
  /// carrying a message (e.g. "Resource not accessible by personal access
  /// token") is that error, not a rate limit, unless the response says it is
  /// one (remaining quota 0, a retry-after, a 429, or "rate limit" in the
  /// message). Everything else goes to [rateLimitErrorCheck].
  void githubErrorCheck(Response res) {
    if (res.statusCode == 401 || res.statusCode == 403) {
      String? message;
      try {
        message = (jsonDecode(res.body)['message'] as String?)?.trim();
      } catch (_) {
        // Not a JSON error body; fall through to the generic handler.
        message = null;
      }
      final bool rateLimited =
          res.headers['x-ratelimit-remaining'] == '0' ||
          res.headers['retry-after'] != null ||
          (message?.toLowerCase().contains('rate limit') ?? false);
      if (message != null && message.isNotEmpty && !rateLimited) {
        throw ObtainiumError(message);
      }
    }
    rateLimitErrorCheck(res);
  }
}
