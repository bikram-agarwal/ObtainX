import 'dart:async';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gradle_app_id.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// Codeberg.org, the Forgejo instance nearly everyone means.
///
/// Split from [Forgejo] rather than carrying both under one adapter so that a
/// name, an icon, a filter and a list group are all just "which source is
/// this" — no per-URL special cases. The API behaviour lives here and
/// [Forgejo] inherits all of it.
class Codeberg extends AppSource {
  final GitHub _gh = GitHub(hostChanged: true);
  Codeberg() {
    name = 'Codeberg';
    hosts = ['codeberg.org'];
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
        additionalSettings,
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
  }
}
