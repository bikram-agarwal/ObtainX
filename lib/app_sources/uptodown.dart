import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/html_parse_isolate.dart';

/// Uptodown serves its technical-information table in English regardless of the
/// locale subdomain we normalize to, so release dates must be parsed with an
/// English locale. Parsing with the *device* locale made every date fail on
/// non-English devices (e.g. pt-BR saw 'Aug 11, 2026' as unparseable) and spam
/// the log with one error per format attempt.
const List<String> _uptodownDateLocales = ['en_US', 'en'];

/// 'd' also accepts a zero-padded day, so these cover both 'Aug 1, 2026' and
/// 'Aug 11, 2026' in short and long month spellings.
const List<String> _uptodownDatePatterns = ['MMM d, yyyy', 'MMMM d, yyyy'];

/// Uptodown hands out the final file under this prefix. The ajax endpoint and
/// the older `data-url` button attribute both return only the trailing path.
const String _uptodownDownloadUrlPrefix = 'https://dw.uptodown.com/dwn/';

/// File extensions Uptodown lists in the technical-information table.
const List<String> _uptodownFileExtensions = ['apk', 'xapk', 'apks', 'apkm'];

/// A package id such as `com.xiaoji.egggame`: starts with a letter and contains
/// at least one dot. Deliberately rejects version strings ('3.6.5', leading
/// digit), sizes ('42.5 MB', space) and sha256 digests (no dot).
final RegExp _uptodownPackageIdPattern = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$',
);

/// Parses an Uptodown date without logging, for callers that are probing a cell
/// to find out *whether* it is a date.
DateTime? _tryParseUptodownDate(String dateString) {
  for (final locale in _uptodownDateLocales) {
    for (final pattern in _uptodownDatePatterns) {
      try {
        return DateFormat(pattern, locale).parseStrict(dateString);
      } catch (_) {
        // Try the next locale/pattern combination.
      }
    }
  }
  // Last resort: the ambient locale, in case intl has no data for 'en_US'.
  for (final pattern in _uptodownDatePatterns) {
    try {
      return DateFormat(pattern).parseStrict(dateString);
    } catch (_) {
      // Fall through to the caller's null handling.
    }
  }
  return null;
}

DateTime? parseUptodownDate(String? dateString) {
  if (dateString == null) return null;
  final trimmed = dateString.trim();
  if (trimmed.isEmpty) return null;
  final parsed = _tryParseUptodownDate(trimmed);
  if (parsed != null) return parsed;
  // Log once for the whole attempt, not once per format tried.
  unawaited(
    LogsProvider().add(
      'Failed to parse Uptodown release date: $trimmed',
      level: LogLevel.error,
    ),
  );
  return null;
}

/// Pulls the package id, release date and file extension out of the cells of
/// Uptodown's `#technical-information` table.
///
/// Uptodown has already changed this table once (a sha256 row was added), which
/// silently shifted the fixed offsets the old implementation relied on. So each
/// field is identified by its *content* first, with the historical offsets kept
/// only as a fallback for when content matching finds nothing.
({String? appId, String? dateStr, String? extension})
parseUptodownTechnicalFields(List<String> cells) {
  final nonEmptyCells = cells
      .map((cell) => cell.trim())
      .where((cell) => cell.isNotEmpty)
      .toList();

  // The package id is the last row of the table, so prefer the last match in
  // case an earlier cell happens to look dotted-identifier-ish.
  String? appId;
  for (final cell in nonEmptyCells) {
    if (_uptodownPackageIdPattern.hasMatch(cell)) {
      appId = cell;
    }
  }

  String? extension;
  for (final cell in nonEmptyCells) {
    final lowered = cell.toLowerCase();
    if (_uptodownFileExtensions.contains(lowered)) {
      extension = lowered;
      break;
    }
  }

  String? dateStr;
  for (final cell in nonEmptyCells) {
    if (_tryParseUptodownDate(cell) != null) {
      dateStr = cell;
      break;
    }
  }

  // Fallbacks: the offsets the table used before the sha256 row appeared.
  appId ??= nonEmptyCells.lastOrNull;
  dateStr ??= nonEmptyCells.elementAtOrNull(nonEmptyCells.length - 5);
  extension ??= nonEmptyCells
      .elementAtOrNull(nonEmptyCells.length - 4)
      ?.toLowerCase();

  return (appId: appId, dateStr: dateStr, extension: extension);
}

/// Expands whatever Uptodown put on the download button into a full file URL.
///
/// Legacy pages carried the trailing path in `data-url` (and sometimes an
/// already-absolute `data-url-ext`). Current pages carry neither, but Uptodown's
/// own `download.js` still honours them, so we keep the path.
String? uptodownDirectApkUrl({String? dataUrl, String? dataUrlExt}) {
  final trimmedDataUrl = dataUrl?.trim();
  if (trimmedDataUrl != null && trimmedDataUrl.isNotEmpty) {
    return _uptodownAbsoluteDownloadUrl(trimmedDataUrl);
  }
  final trimmedDataUrlExt = dataUrlExt?.trim();
  // `data-url-ext` is only usable when it is already a full URL; relative
  // values there point at a store wrapper page, not at a file.
  if (trimmedDataUrlExt != null && _isHttpUrl(trimmedDataUrlExt)) {
    return trimmedDataUrlExt;
  }
  return null;
}

/// Builds the endpoint Uptodown's download button calls to mint a file URL.
String? uptodownAjaxDownloadUrl(String origin, String? appId, String? fileId) {
  final trimmedAppId = appId?.trim();
  final trimmedFileId = fileId?.trim();
  if (trimmedAppId == null || trimmedAppId.isEmpty) return null;
  if (trimmedFileId == null || trimmedFileId.isEmpty) return null;
  final trimmedOrigin = origin.endsWith('/')
      ? origin.substring(0, origin.length - 1)
      : origin;
  if (trimmedOrigin.isEmpty) return null;
  return '$trimmedOrigin/ajax/app/$trimmedAppId/file/$trimmedFileId/download-url';
}

/// Reads the file URL out of the ajax response body.
///
/// Success bodies nest it as `{"data": {"downloadURL": "..."}}`; a top-level
/// `downloadURL` is accepted too. Error bodies look like
/// `{"success":0,"errorCode":-51,"errorMsg":"Bad Request"}` and yield null.
String? uptodownDownloadUrlFromAjaxBody(String body) {
  dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final nested = decoded['data'];
  final candidates = <dynamic>[
    if (nested is Map) nested['downloadURL'],
    decoded['downloadURL'],
  ];
  for (final candidate in candidates) {
    if (candidate is String && candidate.trim().isNotEmpty) {
      return _uptodownAbsoluteDownloadUrl(candidate.trim());
    }
  }
  return null;
}

bool _isHttpUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

String _uptodownAbsoluteDownloadUrl(String value) =>
    _isHttpUrl(value) ? value : '$_uptodownDownloadUrlPrefix$value';

String? _uptodownOriginOf(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) return null;
  return '${parsed.scheme}://${parsed.host}';
}

class Uptodown extends AppSource {
  Uptodown() {
    name = 'Uptodown';
    hosts = ['uptodown.com'];
    allowSubDomains = true;
    naiveStandardVersionDetection = true;
    showReleaseDateAsVersionToggle = true;
    urlsAlwaysHaveExtension = true;
  }

  static const String _browserUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Mobile Safari/537.36';

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    url = url.replaceFirst(
      RegExp(r'\.([a-z]{2,3})\.uptodown\.', caseSensitive: false),
      '.en.uptodown.',
    );
    return '${standardizeUrlWithRegex(url, subdomainPrefix: r'([^\\.]+\.)+', pathPattern: '')}/android/download';
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    // Uptodown gates both its pages and its ajax endpoint behind a bot check, so
    // present a normal mobile-browser UA everywhere.
    final headers = <String, String>{'User-Agent': _browserUserAgent};
    if (url.contains('/ajax/app/')) {
      headers['Accept'] = 'application/json';
      headers['X-Requested-With'] = 'XMLHttpRequest';
      final origin = _uptodownOriginOf(url);
      if (origin != null) {
        headers['Referer'] = '$origin/android/download';
      }
    }
    return headers;
  }

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    return (await getAppDetailsFromPage(
      standardUrl,
      additionalSettings,
    ))['appId'];
  }

  Future<Map<String, String?>> getAppDetailsFromPage(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final res = await sourceRequest(standardUrl, additionalSettings);
    if (res.statusCode != 200) {
      throw getObtainiumHttpError(res);
    }
    final html = await parseHtmlOffIsolate(res.body);
    final String? version = html.querySelector('div.version')?.innerHtml;
    final nameElement = html.querySelector('#detail-app-name');
    final String? name = nameElement?.innerHtml.trim();
    final String? author = html.querySelector('#author-link')?.innerHtml.trim();
    final detailCells = html
        .querySelectorAll('#technical-information td')
        .map((cell) => cell.text.trim())
        .where((cell) => cell.isNotEmpty)
        .toList();
    final technicalFields = parseUptodownTechnicalFields(detailCells);
    final String? fileId =
        nameElement?.attributes['data-file-id'] ??
        html
            .querySelector('#detail-download-button')
            ?.attributes['data-file-id'];
    return Map.fromEntries([
      MapEntry('version', version),
      MapEntry('appId', technicalFields.appId),
      MapEntry('name', name),
      MapEntry('author', author),
      MapEntry('dateStr', technicalFields.dateStr),
      MapEntry('fileId', fileId),
      MapEntry('extension', technicalFields.extension),
    ]);
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final appDetails = await getAppDetailsFromPage(
        standardUrl,
        additionalSettings,
      );
      final version = appDetails['version'];
      final appId = appDetails['appId'];
      final fileId = appDetails['fileId'];
      final extension = appDetails['extension'];
      if (version == null || version.isEmpty) {
        throw NoVersionError();
      }
      if (fileId == null) {
        throw NoAPKError();
      }
      final apkUrl = '$standardUrl/$fileId-x';
      if (appId == null) {
        throw NoReleasesError();
      }
      final String appName = appDetails['name'] ?? tr('app');
      final String author = appDetails['author'] ?? name;
      final String? dateStr = appDetails['dateStr'];
      DateTime? relDate;
      if (dateStr != null) {
        relDate = parseUptodownDate(dateStr);
      }
      return APKDetails(
        version,
        [
          MapEntry(
            '$appId.${(extension != null && extension.isNotEmpty) ? extension : 'apk'}',
            apkUrl,
          ),
        ],
        AppNames(author, appName),
        releaseDate: relDate,
      );
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }

  @override
  Future<String> assetUrlPrefetchModifier(
    String assetUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final res = await sourceRequest(assetUrl, additionalSettings);
    if (res.statusCode != 200) {
      throw getObtainiumHttpError(res);
    }
    final html = await parseHtmlOffIsolate(res.body);
    final downloadButton = html.querySelector('#detail-download-button');
    final nameElement = html.querySelector('#detail-app-name');

    // Path 1 (legacy): the button used to carry the file path directly.
    final legacyUrl = uptodownDirectApkUrl(
      dataUrl: downloadButton?.attributes['data-url'],
      dataUrlExt: downloadButton?.attributes['data-url-ext'],
    );
    if (legacyUrl != null) {
      return legacyUrl;
    }

    // Path 2 (current): ask the endpoint the button's own script calls.
    final appId =
        downloadButton?.attributes['data-app-id'] ??
        nameElement?.attributes['data-code'];
    final fileId =
        downloadButton?.attributes['data-file-id'] ??
        nameElement?.attributes['data-file-id'];
    final ajaxUrl = uptodownAjaxDownloadUrl(
      _uptodownOriginOf(assetUrl) ?? 'https://${hosts[0]}',
      appId,
      fileId,
    );
    if (ajaxUrl == null) {
      unawaited(
        LogsProvider().add(
          'Uptodown page had no download-button ids: $assetUrl',
          level: LogLevel.error,
        ),
      );
      throw NoAPKError();
    }
    // Mirrors what the page's own button reports: this flag distinguishes a
    // direct file from a store wrapper, so use the value from the page we
    // fetched rather than inferring it from the file extension.
    final onlyXapk = downloadButton?.attributes['data-only-xapk'] == '1';
    final ajaxRes = await sourceRequest(
      ajaxUrl,
      additionalSettings,
      postBody: {'token': '', 'onlyXapk': onlyXapk},
    );
    if (ajaxRes.statusCode != 200) {
      unawaited(
        LogsProvider().add(
          'Uptodown download-url HTTP ${ajaxRes.statusCode} for $ajaxUrl',
          level: LogLevel.error,
        ),
      );
      throw getObtainiumHttpError(ajaxRes);
    }
    final downloadUrl = uptodownDownloadUrlFromAjaxBody(ajaxRes.body);
    if (downloadUrl == null) {
      unawaited(
        LogsProvider().add(
          'Uptodown download-url response had no downloadURL for $ajaxUrl',
          level: LogLevel.error,
        ),
      );
      throw NoAPKError();
    }
    return downloadUrl;
  }
}
