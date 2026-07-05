import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:obtainium/app_sources/app_package_formats.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

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

class GitHub extends AppSource {
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
    hosts = ['github.com'];
    appIdInferIsOptional = true;
    showReleaseDateAsVersionToggle = true;
    showReleaseTitleAsVersionToggle = true;
    showExtractVersionFromAssetNameToggle = true;
    showReleaseCommitShaAsVersionToggle = true;
    this.hostChanged = hostChanged;
    allowIncludeZips = true;
    allowIncludeTarballs = true;

    sourceConfigSettingFormItems = [
      GeneratedFormTextField(
        githubCredsKey,
        label: tr('githubPATLabel'),
        password: true,
        required: false,
        assistIcon: Icons.verified_user_outlined,
        assistTooltip: tr('validateGitHubPAT'),
        assistAction: _validatePATFromSettingsForm,
      ),
      GeneratedFormTextField(
        githubReqPrefixKey,
        label: tr('GHReqPrefix'),
        hint: 'gh-proxy.org',
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
        suffixIcon: IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          onPressed: () => launchUrlString(
            'https://github.com/sky22333/hubproxy',
            mode: LaunchMode.externalApplication,
          ),
          tooltip: tr('about'),
        ),
      ),
      GeneratedFormSwitch(
        githubReqPrefixUseTokenKey,
        label: tr('GHReqPrefixUseToken'),
        defaultValue: false,
      ),
      GeneratedFormSwitch(
        'checkRepoRename',
        label: tr('repoRenamedCheck'),
        defaultValue: true,
      ),
    ];

    additionalSourceAppSpecificSettingFormItems = [
      [
        GeneratedFormSwitch(
          'includePrereleases',
          label: tr('includePrereleases'),
          defaultValue: false,
        ),
      ],
      [GeneratedFormSwitch('verifyLatestTag', label: tr('verifyLatestTag'))],
      [
        GeneratedFormSwitch(
          'fallbackToOlderReleases',
          label: tr('fallbackToOlderReleases'),
          defaultValue: true,
        ),
      ],
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
        GeneratedFormDropdown(
          buildVerificationModeKey,
          [
            MapEntry(buildVerificationOff, tr('githubBuildVerificationOff')),
            MapEntry(
              buildVerificationAudit,
              tr('githubBuildVerificationAudit'),
            ),
            MapEntry(
              buildVerificationEnforce,
              tr('githubBuildVerificationEnforce'),
            ),
          ],
          label: tr('githubBuildVerificationMode'),
          defaultValue: buildVerificationOff,
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
          defaultValue: 'date',
        ),
      ],
      [
        GeneratedFormSwitch(
          'useLatestAssetDateAsReleaseDate',
          label: tr('useLatestAssetDateAsReleaseDate'),
          defaultValue: false,
        ),
      ],
    ];

    canSearch = true;
    searchQuerySettingFormItems = [
      GeneratedFormTextField(
        'minStarCount',
        label: tr('minStarCount'),
        defaultValue: '0',
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
  }

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
          HttpHeaders.userAgentHeader: 'Obtainium',
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('githubPATValidated'))));
    } else {
      clearPATValidation(settingsProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
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

  String buildVerificationMode(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) {
    final String mode =
        additionalSettings[buildVerificationModeKey]?.toString() ??
        (additionalSettings[enforceAttestationsKey] == true
            ? buildVerificationEnforce
            : buildVerificationOff);
    if (mode != buildVerificationAudit && mode != buildVerificationEnforce) {
      return buildVerificationOff;
    }
    if (!canVerifyAttestations(additionalSettings, settingsProvider)) {
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

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    const possibleBuildGradleLocations = [
      '/app/build.gradle',
      'android/app/build.gradle',
      'src/app/build.gradle',
    ];
    for (var path in possibleBuildGradleLocations) {
      try {
        var res = await sourceRequest(
          '${await convertStandardUrlToAPIUrl(standardUrl, additionalSettings)}/contents/$path',
          additionalSettings,
        );
        if (res.statusCode == 200) {
          try {
            var body = jsonDecode(res.body);
            var trimmedLines = utf8
                .decode(
                  base64.decode(
                    body['content'].toString().split('\n').join(''),
                  ),
                )
                .split('\n')
                .map((e) => e.trim());
            var appIds = trimmedLines.where(
              (l) =>
                  l.startsWith('applicationId "') ||
                  l.startsWith('applicationId \''),
            );
            appIds = appIds.map(
              (appId) => appId.split(
                appId.startsWith('applicationId "') ? '"' : '\'',
              )[1],
            );
            appIds = appIds
                .map((appId) {
                  if (appId.startsWith('\${') && appId.endsWith('}')) {
                    appId = trimmedLines
                        .where(
                          (l) => l.startsWith(
                            'def ${appId.substring(2, appId.length - 1)}',
                          ),
                        )
                        .first;
                    appId = appId.split(appId.contains('"') ? '"' : '\'')[1];
                  }
                  return appId;
                })
                .where((appId) => appId.isNotEmpty);
            if (appIds.length == 1) {
              return appIds.first;
            }
          } catch (err) {
            LogsProvider().add(
              'Error parsing build.gradle from ${res.request!.url.toString()}: ${err.toString()}',
            );
          }
        }
      } catch (err) {
        // Ignore - ID will be extracted from the APK
      }
    }
    return null;
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    RegExp standardUrlRegEx = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}/[^/]+/[^/]+',
      caseSensitive: false,
    );
    RegExpMatch? match = standardUrlRegEx.firstMatch(url);
    if (match == null) {
      throw InvalidURLError(name);
    }
    return match.group(0)!;
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    var sourceConfig = await _reqSourceConfig(additionalSettings);
    var token = await getTokenIfAny(sourceConfig);
    var headers = <String, String>{};
    if (token != null && token.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Token $token';
    }
    var prefix = sourceConfig[githubReqPrefixKey] ?? '';
    if (forAPKDownload == true && prefix.isEmpty) {
      headers[HttpHeaders.acceptHeader] = 'application/octet-stream';
    }
    if (headers.isNotEmpty) {
      return headers;
    } else {
      return null;
    }
  }

  Future<String?> getTokenIfAny(Map<String, String> sourceConfig) async {
    String? creds = sourceConfig[githubCredsKey];
    if ((sourceConfig[githubReqPrefixKey] ?? '').isNotEmpty &&
        (sourceConfig[githubReqPrefixUseTokenKey] ?? 'false') == 'false') {
      creds = null;
    }
    return tokenFromCreds(creds);
  }

  // getSourceConfigValues needs an initialized SettingsProvider. The per-request
  // hooks below (request headers, prefetch modifiers, update checks, search)
  // each used to construct one and run initializeSettings() on every call.
  // Initialize a single instance once and reuse it — reads go through the
  // SharedPreferences singleton, so the values stay current.
  static SettingsProvider? _reqSettingsProvider;
  Future<SettingsProvider> _reqSettings() async {
    var sp = _reqSettingsProvider;
    if (sp == null) {
      sp = SettingsProvider();
      await sp.initializeSettings();
      _reqSettingsProvider = sp;
    }
    return sp;
  }

  Future<Map<String, String>> _reqSourceConfig(
    Map<String, dynamic> additionalSettings,
  ) async {
    return getSourceConfigValues(additionalSettings, await _reqSettings());
  }

  @override
  Future<String?> getSourceNote() async {
    final sourceConfig = await _reqSourceConfig({});
    if (!hostChanged && (await getTokenIfAny(sourceConfig)) == null) {
      return '${tr('githubSourceNote')} ${hostChanged ? tr('addInfoBelow') : tr('addInfoInSettings')}';
    }
    return null;
  }

  @override
  Future<String> assetUrlPrefetchModifier(
    String assetUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    var sourceConfig = await _reqSourceConfig(additionalSettings);
    var prefix = sourceConfig[githubReqPrefixKey] ?? '';
    if (prefix.isNotEmpty && !assetUrl.startsWith('https://$prefix/')) {
      return 'https://$prefix/$assetUrl';
    }
    return assetUrl;
  }

  @override
  Future<String> generalReqPrefetchModifier(
    String reqUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    var sourceConfig = await _reqSourceConfig(additionalSettings);
    if ((sourceConfig[githubReqPrefixKey] ?? '').isNotEmpty) {
      return 'https://${sourceConfig[githubReqPrefixKey]}/$reqUrl';
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

  /// Checks if the repository has been renamed or transferred.
  ///
  /// This method explicitly disables automatic redirect following to detect when
  /// GitHub returns a redirect (indicating the repository has moved). A redirect
  /// from the GitHub API for a repository endpoint definitively indicates that
  /// the repository has been renamed or transferred to a different owner.
  ///
  /// Throws [RepositoryRenamedError] if a redirect is detected.
  Future<void> checkForRepositoryRename(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    Map<String, String> sourceConfigSettingValues,
  ) async {
    if (sourceConfigSettingValues['checkRepoRename'] == "false") {
      return;
    }
    var uri = Uri.tryParse(standardUrl);
    var host = uri?.host.toLowerCase() ?? '';
    // Guard against non-GitHub URLs
    if (host != hosts[0] && host != 'www.${hosts[0]}') {
      return;
    }
    var apiUrl = await convertStandardUrlToAPIUrl(
      standardUrl,
      additionalSettings,
    );
    Response res = await sourceRequest(
      apiUrl,
      additionalSettings,
      followRedirects: false,
    );
    if (res.statusCode >= 300 && res.statusCode < 400) {
      String? location = res.headers[HttpHeaders.locationHeader.toLowerCase()];
      if (location != null) {
        Response res2 = await sourceRequest(
          location,
          additionalSettings,
          followRedirects: false,
        );
        String? newUrl;
        try {
          newUrl = jsonDecode(res2.body)['html_url'];
        } catch (e) {
          // Unexpected - ignore (keep old URL)
        }
        if (newUrl != null) {
          throw RepositoryRenamedError(standardUrl, newUrl);
        }
      }
    }
  }

  @override
  String? changeLogPageFromStandardUrl(String standardUrl) =>
      '$standardUrl/releases';

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

  Future<APKDetails> getLatestAPKDetailsCommon(
    String requestUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings, {
    Function(Response)? onHttpErrorCode,
  }) async {
    final settingsProvider = await _reqSettings();
    var sourceConfigSettingValues = await getSourceConfigValues(
      additionalSettings,
      settingsProvider,
    );
    await checkForRepositoryRename(
      standardUrl,
      additionalSettings,
      sourceConfigSettingValues,
    );
    bool includePrereleases = additionalSettings['includePrereleases'] == true;
    bool fallbackToOlderReleases =
        additionalSettings['fallbackToOlderReleases'] == true;
    String? regexFilter =
        (additionalSettings['filterReleaseTitlesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseTitlesByRegEx']
        : null;
    String? regexNotesFilter =
        (additionalSettings['filterReleaseNotesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseNotesByRegEx']
        : null;
    // Compile the user filter patterns once, not once per release in the loop
    // below (a release list can be long, and identical patterns were being
    // recompiled on every iteration).
    final RegExp? releaseTitleFilter = regexFilter != null
        ? RegExp(regexFilter)
        : null;
    final RegExp? releaseNotesFilter = regexNotesFilter != null
        ? RegExp(regexNotesFilter)
        : null;
    bool verifyLatestTag = additionalSettings['verifyLatestTag'] == true;
    bool useLatestAssetDateAsReleaseDate =
        additionalSettings['useLatestAssetDateAsReleaseDate'] == true;
    final bool shouldCheckAttestation = shouldVerifyAttestations(
      additionalSettings,
      settingsProvider,
    );
    String sortMethod =
        additionalSettings['sortMethodChoice'] ?? 'smartname-datefallback';
    bool includeZips = additionalSettings['includeZips'] == true;
    bool includeTarballs = additionalSettings['includeTarballs'] == true;
    dynamic latestRelease;
    if (verifyLatestTag) {
      var temp = requestUrl.split('?');
      Response res = await sourceRequest(
        '${temp[0]}/latest${temp.length > 1 ? '?${temp.sublist(1).join('?')}' : ''}',
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
    Response res = await sourceRequest(requestUrl, additionalSettings);
    if (res.statusCode == 200) {
      var releases = jsonDecode(res.body) as List<dynamic>;
      if (latestRelease != null) {
        var latestTag = latestRelease['tag_name'] ?? latestRelease['name'];
        if (releases
            .where(
              (element) =>
                  (element['tag_name'] ?? element['name']) == latestTag,
            )
            .isEmpty) {
          releases = [latestRelease, ...releases];
        }
      }

      var prefix = sourceConfigSettingValues[githubReqPrefixKey] ?? '';
      var hasGHReqPrefix = prefix.isNotEmpty;
      findReleaseAssetUrls(dynamic release) =>
          (release['assets'] as List<dynamic>?)?.map((e) {
            var name = e['name'].toString();
            var url =
                !isInstallable(
                      name,
                      includeZips: includeZips,
                      includeTarballs: includeTarballs,
                    ) ||
                    hasGHReqPrefix
                ? (e['browser_download_url'] ?? e['url'])
                : (e['url'] ?? e['browser_download_url']);
            url = undoGHProxyMod(url, sourceConfigSettingValues);
            e['final_url'] = (e['name'] != null) && (url != null)
                ? MapEntry(e['name'] as String, url as String)
                : const MapEntry('', '');
            return e;
          }).toList() ??
          [];

      DateTime? getPublishDateFromRelease(dynamic rel) =>
          rel?['published_at'] != null
          ? DateTime.parse(rel['published_at'])
          : rel?['commit']?['created'] != null
          ? DateTime.parse(rel['commit']['created'])
          : null;
      DateTime? getNewestAssetDateFromRelease(dynamic rel) {
        var allAssets = rel['assets'] as List<dynamic>?;
        var filteredAssets = rel['filteredAssets'] as List<dynamic>?;
        var t = (filteredAssets ?? allAssets)
            ?.map((e) {
              return e?['updated_at'] != null
                  ? DateTime.parse(e['updated_at'])
                  : null;
            })
            .where((e) => e != null)
            .toList();
        t?.sort((a, b) => b!.compareTo(a!));
        if (t?.isNotEmpty == true) {
          return t!.first;
        }
        return null;
      }

      DateTime? getReleaseDateFromRelease(dynamic rel, bool useAssetDate) =>
          !useAssetDate
          ? getPublishDateFromRelease(rel)
          : getNewestAssetDateFromRelease(rel);

      if (sortMethod == 'none') {
        releases = releases.reversed.toList();
      } else {
        releases.sort((a, b) {
          // See #478 and #534
          if (a == b) {
            return 0;
          } else if (a == null) {
            return -1;
          } else if (b == null) {
            return 1;
          } else {
            var nameA = a['tag_name'] ?? a['name'];
            var nameB = b['tag_name'] ?? b['name'];
            var stdFormats = findStandardFormatsForVersion(
              nameA,
              false,
            ).intersection(findStandardFormatsForVersion(nameB, false));
            if (sortMethod == 'date' ||
                (sortMethod == 'smartname-datefallback' &&
                    stdFormats.isEmpty)) {
              return (getReleaseDateFromRelease(
                        a,
                        useLatestAssetDateAsReleaseDate,
                      ) ??
                      DateTime(1))
                  .compareTo(
                    getReleaseDateFromRelease(
                          b,
                          useLatestAssetDateAsReleaseDate,
                        ) ??
                        DateTime(0),
                  );
            } else {
              if (sortMethod != 'name' && stdFormats.isNotEmpty) {
                var reg = RegExp(stdFormats.last);
                var matchA = reg.firstMatch(nameA);
                var matchB = reg.firstMatch(nameB);
                return compareAlphaNumeric(
                  (nameA as String).substring(matchA!.start, matchA.end),
                  (nameB as String).substring(matchB!.start, matchB.end),
                );
              } else {
                // 'name'
                return compareAlphaNumeric(
                  (nameA as String),
                  (nameB as String),
                );
              }
            }
          }
        });
      }
      if (latestRelease != null &&
          (latestRelease['tag_name'] ?? latestRelease['name']) != null &&
          releases.isNotEmpty &&
          latestRelease !=
              (releases[releases.length - 1]['tag_name'] ??
                  releases[0]['name'])) {
        var ind = releases.indexWhere(
          (element) =>
              (latestRelease['tag_name'] ?? latestRelease['name']) ==
              (element['tag_name'] ?? element['name']),
        );
        if (ind >= 0) {
          releases.add(releases.removeAt(ind));
        }
      }
      releases = releases.reversed.toList();
      final List<String> rawReleaseTitleCandidates = <String>[];
      for (
        int titleIndex = 0;
        titleIndex < releases.length && rawReleaseTitleCandidates.length < 40;
        titleIndex++
      ) {
        if (releases[titleIndex]['draft'] == true) {
          continue;
        }
        if (!includePrereleases && releases[titleIndex]['prerelease'] == true) {
          continue;
        }
        var candidateTitle = releases[titleIndex]['name'] as String?;
        if (candidateTitle == null || candidateTitle.trim().isEmpty) {
          candidateTitle = releases[titleIndex]['tag_name'] as String?;
        }
        if (candidateTitle == null) {
          continue;
        }
        final String trimmedTitle = candidateTitle.trim();
        if (trimmedTitle.isEmpty) {
          continue;
        }
        if (!rawReleaseTitleCandidates.contains(trimmedTitle)) {
          rawReleaseTitleCandidates.add(trimmedTitle);
        }
      }
      dynamic targetRelease;
      var prerrelsSkipped = 0;
      for (int i = 0; i < releases.length; i++) {
        if (!fallbackToOlderReleases && i > prerrelsSkipped) break;
        if (!includePrereleases && releases[i]['prerelease'] == true) {
          prerrelsSkipped++;
          continue;
        }
        if (releases[i]['draft'] == true) {
          // Draft releases not supported
          continue;
        }
        var nameToFilter = releases[i]['name'] as String?;
        if (nameToFilter == null || nameToFilter.trim().isEmpty) {
          // Some leave titles empty so tag is used
          nameToFilter = releases[i]['tag_name'] as String;
        }
        if (releaseTitleFilter != null &&
            !releaseTitleFilter.hasMatch(nameToFilter.trim())) {
          continue;
        }
        if (releaseNotesFilter != null &&
            !releaseNotesFilter.hasMatch(
              ((releases[i]['body'] as String?) ?? '').trim(),
            )) {
          continue;
        }
        var allAssetsWithUrls = findReleaseAssetUrls(releases[i]);
        List<MapEntry<String, String>> allAssetUrls = allAssetsWithUrls
            .map((e) => e['final_url'] as MapEntry<String, String>)
            .toList();
        var apkAssetsWithUrls = allAssetsWithUrls.where((element) {
          var name = (element['final_url'] as MapEntry<String, String>).key;
          return isInstallable(
            name,
            includeZips: includeZips,
            includeTarballs: includeTarballs,
          );
        }).toList();

        var filteredApkUrls = filterApks(
          apkAssetsWithUrls
              .map((e) => e['final_url'] as MapEntry<String, String>)
              .toList(),
          additionalSettings['apkFilterRegEx'],
          additionalSettings['invertAPKFilter'],
        );
        var filteredApks = apkAssetsWithUrls
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
          continue;
        }
        targetRelease = releases[i];
        targetRelease['apkUrls'] = filteredApkUrls;
        targetRelease['filteredAssets'] = filteredApks;
        final String versionStringSource = getVersionStringSource(
          additionalSettings,
        );
        String? selectedVersionSource;
        if (versionStringSource == versionStringSourceAssetName) {
          if (filteredApkUrls.isEmpty) {
            throw NoVersionError();
          }
          selectedVersionSource = filteredApkUrls.last.key;
        } else if (versionStringSource == versionStringSourceReleaseTitle) {
          selectedVersionSource = nameToFilter;
        } else if (versionStringSource == versionStringSourceReleaseDate) {
          selectedVersionSource = getReleaseDateFromRelease(
            targetRelease,
            useLatestAssetDateAsReleaseDate,
          )?.toUtc().toIso8601String();
          if (selectedVersionSource == null) {
            throw NoVersionError();
          }
        } else if (versionStringSource == versionStringSourceReleaseCommitSha) {
          selectedVersionSource = await getReleaseCommitSha(
            targetRelease,
            standardUrl,
            additionalSettings,
          );
          if (selectedVersionSource == null) {
            throw NoVersionError();
          }
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
        break;
      }
      if (targetRelease == null) {
        throw NoReleasesError();
      }
      String? version = targetRelease['version'];

      DateTime? releaseDate = getReleaseDateFromRelease(
        targetRelease,
        useLatestAssetDateAsReleaseDate,
      );
      if (version == null) {
        throw NoVersionError();
      }
      var changeLog = (targetRelease['body'] ?? '').toString();
      final apkUrls =
          targetRelease['apkUrls'] as List<MapEntry<String, String>>;
      // Build a name→size map from the filtered asset objects so we can look
      // up the size of whichever APK ends up being preferred.
      final filteredAssets =
          (targetRelease['filteredAssets'] as List<dynamic>?) ?? [];
      final Map<String, int> sizeByName = {
        for (final e in filteredAssets)
          if (e['name'] != null && e['size'] != null)
            e['name'] as String: (e['size'] as num).toInt(),
      };
      // Default preferred index is the last APK (mirrors getApp() behaviour).
      final int? apkSizeBytes = apkUrls.isNotEmpty
          ? sizeByName[apkUrls.last.key]
          : null;
      Map<String, dynamic>? preferredAsset;
      if (apkUrls.isNotEmpty) {
        for (final asset in filteredAssets.whereType<Map<String, dynamic>>()) {
          if (asset['name'] != null && asset['name'] == apkUrls.last.key) {
            preferredAsset = asset;
            break;
          }
        }
      }
      final String? preferredAssetDigest = preferredAsset?['digest'] as String?;
      // Skip the attestation API round-trip when the upstream release is
      // unchanged and we hold a CONCLUSIVE cached verdict. Unlike F-Droid's
      // reproducible status (which flips no_data -> verified asynchronously
      // after publish), a GitHub attestation is produced inside the release
      // workflow run that builds the asset and bound to its digest, so for an
      // unchanged release both 'verified' and 'unsupported' (no attestation for
      // this digest) are stable. Only a cached 'error' is re-checked, since
      // that is a transient lookup failure, not a real verdict.
      final App? prevApp = previouslyCheckedApp;
      final bool canReuseCachedAttestation =
          prevApp != null &&
          prevApp.rawLatestVersionFromSource != null &&
          prevApp.rawLatestVersionFromSource == version &&
          prevApp.latestAttestationStatus != null &&
          prevApp.latestAttestationStatus != githubAttestationStatusError;
      final String? attestationStatus = !shouldCheckAttestation
          ? null
          : canReuseCachedAttestation
          ? prevApp.latestAttestationStatus
          : preferredAssetDigest != null
          ? await getAttestationStatusForSha256Digest(
              standardUrl,
              preferredAssetDigest,
              additionalSettings,
            )
          : githubAttestationStatusError;
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
      );
    } else {
      if (onHttpErrorCode != null) {
        onHttpErrorCode(res);
      }
      throw getObtainiumHttpError(res);
    }
  }

  Future<APKDetails> getLatestAPKDetailsCommon2(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
    Future<String> Function(bool) reqUrlGenerator,
    dynamic Function(Response)? onHttpErrorCode,
  ) async {
    try {
      return await getLatestAPKDetailsCommon(
        await reqUrlGenerator(false),
        standardUrl,
        additionalSettings,
        onHttpErrorCode: onHttpErrorCode,
      );
    } catch (err) {
      if (err is NoReleasesError && additionalSettings['trackOnly'] == true) {
        return await getLatestAPKDetailsCommon(
          await reqUrlGenerator(true),
          standardUrl,
          additionalSettings,
          onHttpErrorCode: onHttpErrorCode,
        );
      } else {
        rethrow;
      }
    }
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return await getLatestAPKDetailsCommon2(
      standardUrl,
      additionalSettings,
      (bool useTagUrl) async {
        return '${await convertStandardUrlToAPIUrl(standardUrl, additionalSettings)}/${useTagUrl ? 'tags' : 'releases'}?per_page=100';
      },
      (Response res) {
        rateLimitErrorCheck(res);
      },
    );
  }

  AppNames getAppNames(String standardUrl) {
    String temp = standardUrl.substring(standardUrl.indexOf('://') + 3);
    List<String> names = temp.substring(temp.indexOf('/') + 1).split('/');
    return AppNames(names[0], names.sublist(1).join('/'));
  }

  Future<Map<String, List<String>>> searchCommon(
    String query,
    String requestUrl,
    String rootProp, {
    Function(Response)? onHttpErrorCode,
    Map<String, dynamic> querySettings = const {},
  }) async {
    Response res = await sourceRequest(requestUrl, {});
    if (res.statusCode == 200) {
      int minStarCount = querySettings['minStarCount'] != null
          ? int.parse(querySettings['minStarCount'])
          : 0;
      Map<String, List<String>> urlsWithDescriptions = {};
      for (var e in (jsonDecode(res.body)[rootProp] as List<dynamic>)) {
        if ((e['stargazers_count'] ?? e['stars_count'] ?? 0) >= minStarCount) {
          urlsWithDescriptions.addAll({
            e['html_url'] as String: [
              e['full_name'] as String,
              ((e['archived'] == true ? '[ARCHIVED] ' : '') +
                  (e['description'] != null
                      ? e['description'] as String
                      : tr('noDescription'))),
            ],
          });
        }
      }
      return urlsWithDescriptions;
    } else {
      if (onHttpErrorCode != null) {
        onHttpErrorCode(res);
      }
      throw getObtainiumHttpError(res);
    }
  }

  String undoGHProxyMod(
    String reqUrl,
    Map<String, String> sourceConfigSettingValues,
  ) {
    var prefix = sourceConfigSettingValues[githubReqPrefixKey] ?? '';
    if (prefix.isEmpty) return reqUrl;
    var proxyPrefix = 'https://$prefix/';
    if (reqUrl.startsWith(proxyPrefix)) {
      return reqUrl.substring(proxyPrefix.length);
    }
    return reqUrl;
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    var sourceConfigSettingValues = await _reqSourceConfig({});
    var results = await searchCommon(
      query,
      '${await getAPIHost({})}/search/repositories?q=${Uri.encodeQueryComponent(query)}&per_page=100',
      'items',
      onHttpErrorCode: (Response res) {
        rateLimitErrorCheck(res);
      },
      querySettings: querySettings,
    );
    if ((sourceConfigSettingValues[githubReqPrefixKey] ?? '').isNotEmpty) {
      Map<String, List<String>> results2 = {};
      results.forEach((k, v) {
        results2[undoGHProxyMod(k, sourceConfigSettingValues)] = v;
      });
      return results2;
    } else {
      return results;
    }
  }

  void rateLimitErrorCheck(Response res) {
    if (res.headers['x-ratelimit-remaining'] == '0') {
      throw RateLimitError(
        (int.parse(res.headers['x-ratelimit-reset'] ?? '1800000000') / 60000000)
            .round(),
      );
    }
  }
}
