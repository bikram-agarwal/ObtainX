import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;
import 'package:obtainium/services/html_parse_isolate.dart';

const Duration _storeListingIconFetchTimeout = Duration(seconds: 10);

const String _storeListingUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36';

bool isApkPureHost(String host) => host.contains('apkpure');

/// APKPure's `.net` domain sits behind a Cloudflare bot challenge that a
/// plain HTTP request can't pass; `.com` serves the same catalog without one.
/// Every APKPure fetch in this app should go through this first, regardless
/// of which domain a listing URL happens to carry.
Uri normalizeApkPureHost(Uri uri) =>
    isApkPureHost(uri.host) ? uri.replace(host: 'apkpure.com') : uri;

/// A cached/constructed APKPure URL is only useful if it has the site's
/// required `<name-slug>/<package>` shape. A past bug (an empty-titled
/// catalog stub - see `BulkImportService.checkApkPure`) could produce a
/// slug-less single-segment URL that 404s on the real site; every place that
/// trusts a stored APKPure URL should check this first, so a malformed entry
/// is treated as if it had never been cached rather than needing a one-time
/// migration to purge it.
bool isWellFormedApkPureUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.pathSegments.where((segment) => segment.isNotEmpty).length >= 2;
}

/// Absolute raster icon URL from a store listing HTML document.
///
/// APKPure gets a dedicated branch: its `og:image` is a page screenshot, not
/// the icon, and a bare `img.icon` selector matches APKPure's own site-logo
/// image rather than the app's - both would be silently wrong, not merely
/// absent. The real icon is the lone `<span class="app-icon"><img ...></span>`
/// next to the `<h1>` app name, distinct from the "similar apps" carousel
/// further down the page (which never wraps its images in that span).
String? iconUrlFromStoreListingDocument(Document doc, String pageUrl) {
  final Uri pageUri = Uri.parse(pageUrl);
  final String? raw = isApkPureHost(pageUri.host)
      ? doc.querySelector('span.app-icon img')?.attributes['src']
      : doc.querySelector('meta[property="og:image"]')?.attributes['content'] ??
            doc
                .querySelector('meta[name="twitter:image"]')
                ?.attributes['content'] ??
            doc
                .querySelector('meta[name="twitter:image:src"]')
                ?.attributes['content'] ??
            doc.querySelector('img.package-icon')?.attributes['src'] ??
            doc.querySelector('img[alt="Icon image"]')?.attributes['src'] ??
            doc.querySelector('img.icon')?.attributes['src'];
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  return pageUri.resolveUri(Uri.parse(raw.trim())).toString();
}

/// Same as [iconUrlFromStoreListingDocument] for a raw HTML string.
String? iconUrlFromStoreListingHtml(String html, String pageUrl) {
  return iconUrlFromStoreListingDocument(parse(html), pageUrl);
}

Future<String?> iconUrlFromStoreListingHtmlOffIsolate(
  String html,
  String pageUrl,
) async {
  final Document doc = await parseHtmlOffIsolate(html);
  return iconUrlFromStoreListingDocument(doc, pageUrl);
}

/// Fetches [listingUrl] and extracts a raster icon URL from the page.
Future<String?> fetchIconUrlFromStoreListingPage(String listingUrl) async {
  try {
    final Uri uri = normalizeApkPureHost(Uri.parse(listingUrl));
    final http.Response response = await http
        .get(uri, headers: {'User-Agent': _storeListingUserAgent})
        .timeout(_storeListingIconFetchTimeout);
    if (response.statusCode != 200) {
      return null;
    }
    return await iconUrlFromStoreListingHtmlOffIsolate(
      response.body,
      uri.toString(),
    );
  } catch (_) {
    return null;
  }
}

/// Resolves a missing-app icon from other-store metadata, in preference order:
/// APKMirror API icon, then listing pages APKMirror -> F-Droid -> APKPure ->
/// Play Store. Stops at the first URL that yields an icon.
Future<String?> resolveIconUrlFromOtherStores({
  String? apkMirrorIconUrl,
  String? apkMirrorListingUrl,
  String? fdroidListingUrl,
  String? apkPureListingUrl,
  String? playStoreListingUrl,
  Future<String?> Function(String listingUrl) fetchListingIconUrl =
      fetchIconUrlFromStoreListingPage,
}) async {
  final String? trimmedApkMirrorIcon = apkMirrorIconUrl?.trim();
  if (trimmedApkMirrorIcon != null && trimmedApkMirrorIcon.isNotEmpty) {
    return trimmedApkMirrorIcon;
  }
  for (final String? listingUrl in <String?>[
    apkMirrorListingUrl,
    fdroidListingUrl,
    apkPureListingUrl,
    playStoreListingUrl,
  ]) {
    final String? trimmedListingUrl = listingUrl?.trim();
    if (trimmedListingUrl == null || trimmedListingUrl.isEmpty) {
      continue;
    }
    final String? listingIconUrl = await fetchListingIconUrl(trimmedListingUrl);
    if (listingIconUrl != null && listingIconUrl.trim().isNotEmpty) {
      return listingIconUrl.trim();
    }
  }
  return null;
}
