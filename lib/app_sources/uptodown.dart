import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
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
/// only as a fallback for when content matching finds nothing. A row's `<th>`
/// label ([labelledCells]: lower-cased label → value) wins over both when its
/// value has the expected shape (upstream 52970e18).
({String? appId, String? dateStr, String? extension})
parseUptodownTechnicalFields(
  List<String> cells, {
  Map<String, String> labelledCells = const {},
}) {
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

  final labelledAppId = labelledCells['package name'];
  if (labelledAppId != null &&
      _uptodownPackageIdPattern.hasMatch(labelledAppId)) {
    appId = labelledAppId;
  }
  final labelledExtension = labelledCells['file type']?.toLowerCase();
  if (_uptodownFileExtensions.contains(labelledExtension)) {
    extension = labelledExtension;
  }
  final labelledDate = labelledCells['date'];
  if (labelledDate != null && _tryParseUptodownDate(labelledDate) != null) {
    dateStr = labelledDate;
  }

  // Fallbacks: the offsets the table used before the sha256 row appeared.
  // Guarded, as elementAtOrNull throws on a negative index (upstream
  // 52970e18).
  appId ??= nonEmptyCells.lastOrNull;
  dateStr ??= nonEmptyCells.length >= 5
      ? nonEmptyCells[nonEmptyCells.length - 5]
      : null;
  extension ??=
      (nonEmptyCells.length >= 4
              ? nonEmptyCells[nonEmptyCells.length - 4]
              : null)
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

/// Reads the file URL out of a download-URL response body: the Android app
/// API's, which has the shape the web ajax endpoint used.
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

/// Reads the JWT and its expiry (`exp`, unix seconds) from the app API's
/// login response, or null when the body isn't one.
({String token, int expiresAt})? uptodownSessionFromAuthBody(String body) {
  try {
    final decoded = jsonDecode(body);
    final token = decoded is Map ? decoded['token'] : null;
    if (token is! String) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final expiresAt = claims is Map ? claims['exp'] : null;
    return expiresAt is int ? (token: token, expiresAt: expiresAt) : null;
  } catch (_) {
    return null;
  }
}

bool _isHttpUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

String _uptodownAbsoluteDownloadUrl(String value) =>
    _isHttpUrl(value) ? value : '$_uptodownDownloadUrlPrefix$value';

class Uptodown extends AppSource {
  Uptodown() {
    name = 'Uptodown';
    hosts = ['uptodown.com'];
    allowSubDomains = true;
    naiveStandardVersionDetection = true;
    showReleaseDateAsVersionToggle = true;
    urlsAlwaysHaveExtension = true;
    canSearch = true;
  }

  static const String _browserUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Mobile Safari/537.36';

  // File URLs come from Uptodown's Android app API (upstream #3305): its
  // anonymous login needs no Turnstile token, unlike the web endpoint.
  static const String _apiHost = 'www.uptodown.app';
  static const String _authPath = '/eapi/auth/token';
  static const String _searchUrl = 'https://en.uptodown.com/android/en/s';
  static const String _clientVersion = '739';
  static const String _apiUserAgent =
      'Dalvik/2.1.0 (Linux; U; Android 16; Pixel 8 Pro Build/BP4A.260205.001)';

  /// Anonymous client auth key. Looks like Base64, but isn't used like one
  static const String _hmacKey = 'MDGMXUMdvHJBG/vjdFgmqX6LUdy7ecfwvYNd0gyfOCs=';

  /// Shared by every instance: SourceProvider hands out a fresh source per
  /// lookup, so a per-instance session would log in again for each download.
  static ({String token, int expiresAt})? _session;

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
    final uri = Uri.parse(url);
    if (uri.host == _apiHost) {
      final token = _session?.token;
      return {
        'User-Agent': _apiUserAgent,
        'Identificador': 'Uptodown_Android',
        'Identificador-Version': _clientVersion,
        if (uri.path == _authPath)
          'Content-Type': 'application/x-www-form-urlencoded'
        else if (token != null)
          'Authorization': 'Bearer $token',
      };
    }
    if (url == _searchUrl) {
      return {
        'User-Agent': _apiUserAgent,
        'Content-Type': 'application/x-www-form-urlencoded',
      };
    }
    // Files the app API hands out are fetched the way the app fetches them.
    if (forAPKDownload) return {'User-Agent': _apiUserAgent};
    // Uptodown gates its pages behind a bot check, so present a normal
    // mobile-browser UA there.
    return {'User-Agent': _browserUserAgent};
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    try {
      final res = await sourceRequest(
        _searchUrl,
        querySettings,
        postBody: Uri(queryParameters: {'queryString': query}).query,
      );
      if (res.statusCode != 200) {
        throw getObtainiumHttpError(res);
      }
      final decoded = jsonDecode(res.body);
      final body = decoded is Map ? decoded : null;
      if (body == null || body['success'] != 1) {
        throw ObtainiumError(tr('uptodownSearchError'));
      }
      final data = body['data'];
      final apps = data is Map ? data['apps'] : null;
      final Map<String, List<String>> results = {};
      if (apps is List) {
        for (final app in apps) {
          if (app is! Map || app['platformURL'] != '/android') continue;
          final url = app['url']?.toString();
          final name = app['name']
              ?.toString()
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .trim();
          if (url == null || url.isEmpty || name == null || name.isEmpty) {
            continue;
          }
          final author = app['author']?.toString().trim();
          results[url] = [
            name,
            (author != null && author.isNotEmpty)
                ? author
                : tr('noDescription'),
          ];
        }
      }
      return results;
    } catch (e) {
      rethrowOrWrapError(e);
    }
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
    // `.text`, not `.innerHtml`, so entities and markup don't leak through.
    final String? version = html.querySelector('div.version')?.text.trim();
    final nameElement = html.querySelector('#detail-app-name');
    final String? name = nameElement?.text.trim();
    final String? author = html.querySelector('#author-link')?.text.trim();
    final labelledCells = <String, String>{};
    for (final row in html.querySelectorAll('#technical-information tr')) {
      final label = row.querySelector('th')?.text.trim().toLowerCase();
      if (label == null || label.isEmpty) continue;
      final values = row.querySelectorAll('td');
      final value = values.isEmpty ? null : values.last.text.trim();
      if (value != null && value.isNotEmpty) labelledCells[label] = value;
    }
    final detailCells = html
        .querySelectorAll('#technical-information td')
        .map((cell) => cell.text.trim())
        .where((cell) => cell.isNotEmpty)
        .toList();
    final technicalFields = parseUptodownTechnicalFields(
      detailCells,
      labelledCells: labelledCells,
    );
    final String? fileId =
        html
            .querySelector('#detail-download-button')
            ?.attributes['data-file-id'] ??
        nameElement?.attributes['data-file-id'];
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

    // Path 2 (current): ask the Android app API. The web endpoint the page's
    // own button calls rejects requests without a Turnstile token.
    final appId =
        (downloadButton?.attributes['data-app-id'] ??
                nameElement?.attributes['data-code'])
            ?.trim();
    final fileId =
        (downloadButton?.attributes['data-file-id'] ??
                nameElement?.attributes['data-file-id'])
            ?.trim();
    if (appId == null || appId.isEmpty || fileId == null || fileId.isEmpty) {
      unawaited(
        LogsProvider().add(
          'Uptodown page had no download-button ids: $assetUrl',
          level: LogLevel.error,
        ),
      );
      throw NoAPKError();
    }
    return _resolveDownload(appId, fileId, additionalSettings);
  }

  Future<({String token, int expiresAt})> _getSession(
    Map<String, dynamic> settings, {
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final session = _session;
    if (!forceRefresh && session != null && now < session.expiresAt - 60) {
      return session;
    }
    return await _auth(settings);
  }

  Future<({String token, int expiresAt})> _auth(
    Map<String, dynamic> settings,
  ) async {
    final random = Random();
    final identifier = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000)
        .toString();
    final signature = Hmac(
      sha256,
      utf8.encode(_hmacKey),
    ).convert(utf8.encode(timestamp)).toString();
    final response = await sourceRequest(
      Uri.https(_apiHost, _authPath, {'identifier': identifier}).toString(),
      settings,
      postBody: Uri(
        queryParameters: {
          'identifier': identifier,
          'id_plataforma': '13',
          'lang': 'en',
          'unixtime': timestamp,
          'hmac': signature,
        },
      ).query,
    );
    if (response.statusCode != 200) throw getObtainiumHttpError(response);
    final session = uptodownSessionFromAuthBody(response.body);
    if (session == null) {
      throw ObtainiumError(tr('uptodownInvalidAuthResponse'));
    }
    return _session = session;
  }

  Future<String> _resolveDownload(
    String appId,
    String fileId,
    Map<String, dynamic> settings,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      // A rejected token gets one fresh login.
      await _getSession(settings, forceRefresh: attempt > 0);
      final response = await sourceRequest(
        Uri.https(
          _apiHost,
          '/eapi/apps/$appId/file/$fileId/downloadUrl',
        ).toString(),
        settings,
      );
      if (response.statusCode == 401) continue;
      if (response.statusCode != 200) throw getObtainiumHttpError(response);
      Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        decoded = null;
      }
      if (decoded is! Map || decoded['success'] != 1) {
        throw ObtainiumError(tr('uptodownDownloadError'));
      }
      final downloadUrl = uptodownDownloadUrlFromAjaxBody(response.body);
      if (downloadUrl == null) {
        throw NoAPKError();
      }
      return downloadUrl;
    }
    throw ObtainiumError(tr('uptodownDownloadError'));
  }
}
