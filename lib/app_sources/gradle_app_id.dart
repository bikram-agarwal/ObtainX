/// Shared Android application-id extraction for the source-code-hosting
/// sources (GitHub, GitLab, Codeberg/Forgejo, SourceHut).
///
/// Upstream only had this on GitHub, and only for Groovy `build.gradle` files
/// containing `applicationId "com.foo"`. That misses the modern default: an
/// Android project generated today uses the Kotlin DSL, so the file is
/// `build.gradle.kts` and the line reads `applicationId = "com.foo"`. Both
/// halves of the mismatch matter — verified 2026-08-18 against two real GitLab
/// Android apps (Aurora Store, F-Droid client): each declares
/// `applicationId = "..."` in `app/build.gradle.kts`, and `app/build.gradle`
/// 404s, so the old scrape found nothing for either.
///
/// Every host here exposes a way to read one file out of a repo, so the only
/// per-source difference is how to fetch the text. That fetch is passed in as a
/// callback and the parsing lives here once.
library;

import 'dart:convert';

/// Candidate build-file paths, ordered most-likely-first so the common case
/// costs a single request. `.kts` precedes the Groovy name at each location
/// because new projects default to it.
const List<String> gradleAppIdCandidatePaths = <String>[
  'app/build.gradle.kts',
  'app/build.gradle',
  'android/app/build.gradle.kts',
  'android/app/build.gradle',
  'src/app/build.gradle.kts',
  'src/app/build.gradle',
];

/// The Android *library* plugin, in both the `id("com.android.library")` and
/// version-catalog `alias(libs.plugins.android.library)` spellings - the
/// `android.library` tail is what the two have in common.
final RegExp _androidLibraryPlugin = RegExp(
  r'(?<![A-Za-z0-9_])android\.library(?![A-Za-z0-9_])',
);

/// Matches a package id: at least two dot-separated identifier segments.
final RegExp _packageIdPattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$',
);

/// `applicationId` / `namespace`, optionally followed by `=` (Kotlin DSL) then a
/// single- or double-quoted value.
///
/// Deliberately not anchored to the start of the line: single-line blocks like
/// `debug { applicationId = "com.x" }` are legal and common. Both boundaries are
/// guarded instead, which is what keeps the neighbours out.
/// `applicationIdSuffix ".debug"` is blocked by the trailing lookahead, and
/// `testApplicationId "com.x.test"` (a real Gradle property, naming the *test*
/// package) by the leading lookbehind. An interpolation such as
/// `appAuthRedirectScheme: "${applicationId}"` never matches because a quote has
/// to follow the keyword.
RegExp _declarationPattern(String keyword) => RegExp(
  '(?<![A-Za-z0-9_])$keyword(?![A-Za-z0-9_])\\s*=?\\s*'
  '(?:"([^"]*)"|\'([^\']*)\')',
);

/// `def x = "y"` (Groovy) or `val`/`var`/`const val`/`private val x = "y"`
/// (Kotlin). Unanchored for the same reason, with a boundary before the keyword
/// so an identifier ending in `val`/`var` cannot pose as a declaration.
RegExp _variablePattern(String name) => RegExp(
  '(?<![A-Za-z0-9_])(?:def|val|var)\\s+${RegExp.escape(name)}\\s*=\\s*'
  '(?:"([^"]*)"|\'([^\']*)\')',
);

bool _isComment(String line) =>
    line.startsWith('//') || line.startsWith('*') || line.startsWith('/*');

/// Resolves `${name}` / `$name` against a `def`/`val`/`var` declaration in the
/// same file. Returns null when the reference cannot be resolved, so an
/// unresolved placeholder is never mistaken for a real id.
String? _resolveInterpolation(String rawValue, List<String> trimmedLines) {
  if (!rawValue.contains(r'$')) {
    return rawValue;
  }
  final RegExpMatch? reference = RegExp(
    r'^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$',
  ).firstMatch(rawValue);
  if (reference == null) {
    // Something more complex than a bare variable (concatenation, a function
    // call, `${rootProject.foo}`): not worth guessing at.
    return null;
  }
  final RegExp declaration = _variablePattern(reference.group(1)!);
  for (final String line in trimmedLines) {
    if (_isComment(line)) continue;
    final RegExpMatch? match = declaration.firstMatch(line);
    if (match != null) {
      return match.group(1) ?? match.group(2);
    }
  }
  return null;
}

Set<String> _collectDeclaredValues(String keyword, List<String> trimmedLines) {
  final RegExp pattern = _declarationPattern(keyword);
  final Set<String> found = <String>{};
  for (final String line in trimmedLines) {
    if (_isComment(line)) continue;
    final RegExpMatch? match = pattern.firstMatch(line);
    if (match == null) continue;
    final String? raw = match.group(1) ?? match.group(2);
    if (raw == null || raw.isEmpty) continue;
    final String? resolved = _resolveInterpolation(raw, trimmedLines);
    if (resolved != null && _packageIdPattern.hasMatch(resolved)) {
      found.add(resolved);
    }
  }
  return found;
}

/// Extracts one unambiguous application id from the text of a Gradle build
/// file, or null.
///
/// Returns null when the file declares several *different* ids — that is a
/// product-flavour setup and picking one arbitrarily would silently attach the
/// app to the wrong package. Repeated declarations of the same id (a common
/// debug/release split) collapse to one and are fine; upstream's raw
/// list-length check rejected those.
///
/// `namespace` is consulted in two cases: when no `applicationId` is declared at
/// all (the id then defaults to the namespace), and as the sole tie-break when
/// flavours declare several ids and the namespace matches one of them.
String? appIdFromGradleFileContents(String contents) {
  final List<String> trimmedLines = contents
      .split('\n')
      .map((String line) => line.trim())
      .toList();
  final Set<String> applicationIds = _collectDeclaredValues(
    'applicationId',
    trimmedLines,
  );
  final Set<String> namespaces = _collectDeclaredValues(
    'namespace',
    trimmedLines,
  );
  if (applicationIds.length == 1) {
    return applicationIds.first;
  }
  if (applicationIds.length > 1) {
    // Several flavours declare different ids. Picking one arbitrarily would
    // silently bind the app to the wrong package, so only one tie-break is
    // allowed: if `namespace` is declared and matches one of the candidates,
    // that candidate is the default-variant id and the others are overrides.
    // Real example (Gadgetbridge on Codeberg, checked 2026-08-18): the file
    // declares nodomain.freeyourgadget.gadgetbridge *and*
    // com.espruino.gadgetbridge, with namespace equal to the former, which is
    // what the main release actually installs as.
    if (namespaces.length == 1 && applicationIds.contains(namespaces.first)) {
      return namespaces.first;
    }
    return null;
  }
  // No applicationId at all: under the Android Gradle Plugin the installed
  // package id then defaults to the namespace, so this is the answer rather
  // than a guess - but only for an application module. A library module's
  // namespace merely names its R class, and returning that would bind the app
  // to a package nothing ever installs. Real example (NextCloudTalkNext on
  // Codefloe, checked 2026-08-25): a `designsystem` module sitting beside the
  // real app declares namespace com.nextcloud.talk.redux.designsystem.
  if (namespaces.length != 1) {
    return null;
  }
  for (final String line in trimmedLines) {
    // `apply false` in a root build file declares a plugin for the subprojects
    // to apply; it does not make the root itself a library.
    if (_isComment(line) || line.contains('apply false')) continue;
    if (_androidLibraryPlugin.hasMatch(line)) return null;
  }
  return namespaces.first;
}

/// The repo's Gradle build files, most-likely-to-be-the-application first.
///
/// A file whose own directory reads like an app module (`app`, `composeApp`,
/// `androidApp`) comes first, then shallower paths, then alphabetically so the
/// order is stable. Generated `build/` output and `buildSrc` convention
/// plugins are dropped - neither ships an application id.
List<String> gradleBuildFilePathsByLikelihood(Iterable<String> repoFilePaths) {
  final List<String> buildFiles = repoFilePaths.where((String path) {
    final List<String> segments = path.split('/');
    if (segments.last != 'build.gradle' &&
        segments.last != 'build.gradle.kts') {
      return false;
    }
    return !segments
        .sublist(0, segments.length - 1)
        .any((String segment) => segment == 'build' || segment == 'buildSrc');
  }).toList();
  buildFiles.sort((String left, String right) {
    final List<String> leftSegments = left.split('/');
    final List<String> rightSegments = right.split('/');
    final bool leftIsAppModule =
        leftSegments.length > 1 &&
        leftSegments[leftSegments.length - 2].toLowerCase().contains('app');
    final bool rightIsAppModule =
        rightSegments.length > 1 &&
        rightSegments[rightSegments.length - 2].toLowerCase().contains('app');
    if (leftIsAppModule != rightIsAppModule) {
      return leftIsAppModule ? -1 : 1;
    }
    if (leftSegments.length != rightSegments.length) {
      return leftSegments.length - rightSegments.length;
    }
    return left.compareTo(right);
  });
  return buildFiles;
}

/// Paths of every file in a GitHub-style `git/trees?recursive` payload.
///
/// Shared by GitHub and Forgejo, whose responses match field for field
/// (verified against api.github.com and codefloe.com's Forgejo 16.0.3 on
/// 2026-08-25). A `truncated` response is still usable - it is simply a
/// partial list, and the walk that follows tolerates missing files.
List<String>? repoFilePathsFromTreeApiBody(String responseBody) {
  final dynamic body = jsonDecode(responseBody);
  if (body is! Map) return null;
  final dynamic tree = body['tree'];
  if (tree is! List) return null;
  return tree
      .whereType<Map>()
      .where((Map entry) => entry['type'] == 'blob')
      .map((Map entry) => entry['path'])
      .whereType<String>()
      .toList();
}

/// Decodes the base64 `content` field of a GitHub-style "repo contents" API
/// response. Shared by GitHub and Codeberg/Forgejo, whose payloads are
/// identical in shape (verified against `codeberg.org/api/v1` on 2026-08-18).
String? decodeRepoContentsApiBody(String responseBody) {
  final dynamic body = jsonDecode(responseBody);
  if (body is! Map) return null;
  final dynamic content = body['content'];
  if (content is! String || content.isEmpty) return null;
  return utf8.decode(base64.decode(content.split('\n').join('')));
}

/// Tries each of [gradleAppIdCandidatePaths] via [fetchFileContents] and returns
/// the first unambiguous application id.
///
/// [fetchFileContents] returns the file's text, or null when it does not exist;
/// throwing is also treated as "not found" so one unreachable path cannot abort
/// the whole walk. Errors are reported through [onError] for logging only.
///
/// The candidate paths only cover an Android project laid out the conventional
/// way. When none of them holds an id and the host can list the repo's files
/// ([listRepoFilePaths]), the search widens to the build files actually in the
/// repo - which is what finds an app that lives somewhere like
/// `mobile_clients/Android/composeApp`. That listing costs an extra request,
/// so it is only fetched once the cheap paths have all missed, and at most
/// [maxDiscoveredFilesToRead] of the files it turns up are read.
Future<String?> inferAppIdFromGradleFiles(
  Future<String?> Function(String path) fetchFileContents, {
  void Function(String message)? onError,
  List<String> candidatePaths = gradleAppIdCandidatePaths,
  Future<List<String>?> Function()? listRepoFilePaths,
  int maxDiscoveredFilesToRead = 5,
}) async {
  Future<String?> firstAppIdAmong(Iterable<String> paths) async {
    for (final String path in paths) {
      try {
        final String? contents = await fetchFileContents(path);
        if (contents == null || contents.isEmpty) continue;
        final String? appId = appIdFromGradleFileContents(contents);
        if (appId != null) return appId;
      } catch (err) {
        onError?.call('Could not read $path while inferring app ID: $err');
      }
    }
    return null;
  }

  final String? conventionalAppId = await firstAppIdAmong(candidatePaths);
  if (conventionalAppId != null || listRepoFilePaths == null) {
    return conventionalAppId;
  }
  try {
    final List<String>? repoFilePaths = await listRepoFilePaths();
    if (repoFilePaths == null) return null;
    return await firstAppIdAmong(
      gradleBuildFilePathsByLikelihood(repoFilePaths)
          .where((String path) => !candidatePaths.contains(path))
          .take(maxDiscoveredFilesToRead),
    );
  } catch (err) {
    onError?.call('Could not list repo files while inferring app ID: $err');
    return null;
  }
}
