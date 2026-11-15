import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' show Response;
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gradle_app_id.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings inherited from the delegated GitHub implementation that mean
/// nothing for Forgejo and are never forwarded (upstream 886f8e58, plus the
/// fork's GHReqPrefixUseToken).
const List<String> _githubOnlySettingKeys = [
  'GHReqPrefix',
  'checkRepoRename',
  'GHReqPrefixUseToken',
];

/// Codeberg.org, the Forgejo instance nearly everyone means.
///
/// Split from [Forgejo] rather than carrying both under one adapter so that a
/// name, an icon, a filter and a list group are all just "which source is
/// this" — no per-URL special cases. The API behaviour lives here and
/// [Forgejo] inherits all of it.
class Codeberg extends AppSource {
  static const String _defaultHost = 'codeberg.org';

  /// The Forgejo access token (upstream #2788, v1.6.17 sync D15). Saved
  /// globally for codeberg.org in Settings → Source-specific, or per app for
  /// an overridden host or a [Forgejo] instance.
  static const String tokenKey = 'forgejo-creds';
  static const String tokenHelpUrl =
      'https://forgejo.org/docs/latest/user/api-usage/#authentication';

  /// Whether this source may fall back to the global token. Only codeberg.org's
  /// own source does: [Forgejo] instances and overridden hosts use their
  /// per-app token only, so the codeberg.org token never reaches another host.
  bool readsGlobalToken = true;

  final GitHub _gh = GitHub(hostChanged: true);
  Codeberg() {
    name = 'Codeberg';
    hosts = [_defaultHost];
    canSearch = true;
    // Same deal as GitHub: the repo is right there, so try to read the app id
    // out of it instead of making the user download an APK first. Optional
    // because a Gradle scrape is a guess — see [tryInferringAppId].
    appIdInferIsOptional = true;
  }

  /// Forgejo's contents endpoint is GitHub's, path for path and payload for
  /// payload (base64 `content`), so the shared decoder applies unchanged.
  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    final Uri standardUri = Uri.parse(standardUrl);
    final String repoApiUrl = standardUri
        .replace(path: '/api/v1/repos${standardUri.path}')
        .toString();
    return inferAppIdFromGradleFiles(
      (String path) async {
        final res = await sourceRequest(
          '$repoApiUrl/contents/$path',
          additionalSettings,
        );
        if (res.statusCode != 200) return null;
        return decodeRepoContentsApiBody(res.body);
      },
      listRepoFilePaths: () async {
        final res = await sourceRequest(
          '$repoApiUrl/git/trees/HEAD?recursive=true&per_page=1000',
          additionalSettings,
        );
        if (res.statusCode != 200) return null;
        return repoFilePathsFromTreeApiBody(res.body);
      },
      onError: (String message) => unawaited(LogsProvider().add(message)),
      // See the note on GitHub's call: a per-channel flavour named after this
      // host decides the id its build installs as.
      preferredFlavorNames: const <String>{'codeberg', 'forgejo'},
    );
  }

  /// Forgejo's release API is GitHub-shaped, so nearly all of GitHub's options
  /// apply verbatim — verified against `codeberg.org/api/v1` on 2026-08-18, whose
  /// release payloads carry `tag_name`, `name`, `body`, `prerelease` and
  /// `published_at`, and which serves `/releases/latest` (so "Verify the 'latest'
  /// tag" genuinely works here).
  ///
  /// Build verification is the exception and is filtered out: attestations are a
  /// GitHub-only feature, and [AppsProvider.verifyGitHubAttestation] returns
  /// early on `source is! GitHub`, so the dropdown could never affect anything.
  /// Leaving it visible was worse than useless — the Add-app form's sanitiser is
  /// itself gated on `pickedSource is GitHub`, so on Codeberg every mode looked
  /// selectable and the "needs a validated GitHub PAT" check never ran.
  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => _gh
      .additionalSourceAppSpecificSettingFormItems
      .map(
        (row) => row
            .where((item) => item.key != GitHub.buildVerificationModeKey)
            .toList(),
      )
      .where((row) => row.isNotEmpty)
      .toList();

  @override
  List<GeneratedFormItem> get searchQuerySettingFormItems =>
      _gh.searchQuerySettingFormItems;

  bool get _usesGlobalToken => readsGlobalToken && !hostChanged;

  @override
  List<GeneratedFormItem> get sourceConfigSettingFormItems => [
    GeneratedFormTextField(
      tokenKey,
      label: tr(_usesGlobalToken ? 'codebergTokenLabel' : 'forgejoTokenLabel'),
      password: true,
      required: false,
      helpUrl: tokenHelpUrl,
    ),
  ];

  @override
  Future<Map<String, String>> getSourceConfigValues(
    Map<String, dynamic> additionalSettings,
    SettingsProvider settingsProvider,
  ) async {
    if (_usesGlobalToken) {
      return super.getSourceConfigValues(additionalSettings, settingsProvider);
    }
    final Object? perApp = additionalSettings[tokenKey];
    return {if (perApp is String && perApp.trim().isNotEmpty) tokenKey: perApp};
  }

  /// [settings] without the GitHub-only keys, with the effective token in
  /// GitHub's key so the delegated header logic sends it. A token saved by an
  /// older version under GitHub's key (per app) still counts.
  Future<Map<String, dynamic>> _requestSettings(
    Map<String, dynamic> settings,
  ) async {
    final Map<String, dynamic> cleaned = Map<String, dynamic>.from(settings)
      ..removeWhere((key, _) => _githubOnlySettingKeys.contains(key));
    // Only a stored value is read, so skip SettingsProvider's one-time init.
    final SettingsProvider settingsProvider = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    final Map<String, String> sourceConfig = await getSourceConfigValues(
      cleaned,
      settingsProvider,
    );
    String? token = sourceConfig[tokenKey];
    if (token == null || token.trim().isEmpty) {
      final Object? legacy = cleaned[GitHub.githubCredsKey];
      token = legacy is String ? legacy : null;
    }
    if (token != null && token.trim().isNotEmpty) {
      cleaned[GitHub.githubCredsKey] = token;
    }
    return cleaned;
  }

  /// Whether [url] is on this source's own host. The token is only for that
  /// host: a release asset can link to another one, which must not receive it.
  bool _isOwnHost(String url) {
    final String? host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return false;
    final String own = hosts[0].toLowerCase();
    return host == own || host == 'www.$own';
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    final Map<String, dynamic> settings = await _requestSettings(
      additionalSettings,
    );
    if (!_isOwnHost(url)) settings.remove(GitHub.githubCredsKey);
    return _gh.getRequestHeaders(settings, url, forAPKDownload: forAPKDownload);
  }

  /// Through [_gh], like the API calls, so a rejected token gets the one
  /// unauthenticated retry there (upstream #3211) instead of failing the call.
  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async => _gh.sourceRequest(
    url,
    await _requestSettings(additionalSettings),
    followRedirects: followRedirects,
    postBody: postBody,
  );

  /// Clears GitHub-only keys an app may carry from an Obtainium backup or a
  /// source swap.
  @override
  App postProcessApp(App app) {
    if (!app.additionalSettings.keys.any(_githubOnlySettingKeys.contains)) {
      return app;
    }
    return app.copyWith(
      additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
        ..removeWhere((key, _) => _githubOnlySettingKeys.contains(key)),
    );
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    return standardizeUrlWithRegex(
      url,
      subdomainPrefix: r'(www\.)?',
      pathPattern: r'/[^/]+/[^/]+',
    );
  }

  @override
  String? changeLogPageFromStandardUrl(String standardUrl) =>
      '$standardUrl/releases';

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      return await _gh.fetchReleaseDetailsWithTagFallback(
        standardUrl,
        await _requestSettings(additionalSettings),
        (bool useTagUrl) async {
          final standardUri = Uri.parse(standardUrl);
          final apiPath =
              '/api/v1/repos${standardUri.path}/${useTagUrl ? 'tags' : 'releases'}';
          return standardUri
              .replace(path: apiPath, queryParameters: {'per_page': '100'})
              .toString();
        },
        null,
      );
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final String origin = 'https://${hosts[0]}';
    return _gh.searchCommon(
      query,
      '$origin/api/v1/repos/search?q=${Uri.encodeQueryComponent(query)}&limit=100',
      'data',
      querySettings: querySettings,
      // The saved codeberg.org token, sent without prompting (upstream's
      // search prompt is dropped: it disables result caching for every source).
      additionalSettings: await _requestSettings(const {}),
    );
  }
}

/// Forgejo instances other than Codeberg.org.
///
/// Same API, same behaviour — only the branding and the host list differ, so
/// this is [Codeberg] with a different name. Seeded with the public instances
/// we know about; anything else reaches this adapter through the app's
/// "Override source" setting.
///
/// Not searchable: Forgejo instances share no index, so a search would have to
/// prompt for one, and prompting means includeAdditionalOptsInMainSearch, which
/// disables result caching for every source in the same search. People tracking
/// a repo on a small instance already know its URL and add it directly.
class Forgejo extends Codeberg {
  Forgejo() {
    name = 'Forgejo';
    hosts = ['codefloe.com'];
    canSearch = false;
    readsGlobalToken = false;
  }
}
