import 'package:obtainium/custom_errors.dart';

/// Ensures the URL is well-formed and starts with HTTPS.
String preStandardizeUrl(String url) {
  final firstDotIndex = url.indexOf('.');
  if (!(firstDotIndex >= 0 && firstDotIndex != url.length - 1) &&
      !url.contains('[')) {
    throw UnsupportedURLError();
  }
  if (!url.toLowerCase().startsWith('http://') &&
      !url.toLowerCase().startsWith('https://')) {
    url = 'https://$url';
  }
  final uri = Uri.tryParse(url);
  final trailingSlash =
      ((uri?.path.endsWith('/') ?? false) ||
          ((uri?.path.isEmpty ?? false) && url.endsWith('/'))) &&
      (uri?.queryParameters.isEmpty ?? false);

  // Only normalize duplicate slashes in the scheme/host/path portion; leave the
  // query string and fragment untouched so any slashes they contain (e.g. a URL
  // passed as a query parameter) aren't mangled.
  var splitIndex = url.length;
  final queryStart = url.indexOf('?');
  if (queryStart >= 0 && queryStart < splitIndex) {
    splitIndex = queryStart;
  }
  final fragmentStart = url.indexOf('#');
  if (fragmentStart >= 0 && fragmentStart < splitIndex) {
    splitIndex = fragmentStart;
  }
  var mainPart = url.substring(0, splitIndex);
  final rest = url.substring(splitIndex);
  mainPart = mainPart
      .split('/')
      .where((e) => e.isNotEmpty)
      .join('/')
      .replaceFirst(':/', '://');
  url = mainPart + (trailingSlash ? '/' : '') + rest;
  return url;
}

/// Strips volatile query parameters and fragments from HTTP(S) asset URLs so
/// rotating CDN tokens do not masquerade as a newly uploaded release asset,
/// while preserving path changes such as `/releases/assets/<id>` or tag paths.
String normalizeAssetUrlForComparison(String rawUrl) {
  String normalizeSingle(String urlPart) {
    final String trimmed = urlPart.trim();
    final Uri? parsedUri = Uri.tryParse(trimmed);
    if (parsedUri == null ||
        (parsedUri.scheme != 'http' && parsedUri.scheme != 'https') ||
        parsedUri.host.isEmpty) {
      return trimmed;
    }
    String cleanUrl = parsedUri.toString();
    final int queryIndex = cleanUrl.indexOf('?');
    if (queryIndex >= 0) {
      cleanUrl = cleanUrl.substring(0, queryIndex);
    }
    final int fragmentIndex = cleanUrl.indexOf('#');
    if (fragmentIndex >= 0) {
      cleanUrl = cleanUrl.substring(0, fragmentIndex);
    }
    return cleanUrl;
  }

  if (rawUrl.contains('\n')) {
    return rawUrl.split('\n').map(normalizeSingle).join('\n');
  }
  return normalizeSingle(rawUrl);
}
