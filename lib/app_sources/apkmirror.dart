import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:html/parser.dart';
import 'package:http/http.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// Image and static asset URL suffixes that appear in page HTML after a string
/// that looks like `com.vendor.app`, e.g. `com.google.android.calendar.png`.
const _apkMirrorTrailingNonPackageSegments = <String>{
  'avif', 'bmp', 'gif', 'ico', 'jpeg', 'jpg', 'png', 'svg', 'webp',
};

String _apkMirrorNormalizeInferredPackageCandidate(String rawCandidate) {
  var normalized = rawCandidate;
  while (true) {
    final lastDotIndex = normalized.lastIndexOf('.');
    if (lastDotIndex <= 0) break;
    final tailSegment = normalized.substring(lastDotIndex + 1).toLowerCase();
    if (_apkMirrorTrailingNonPackageSegments.contains(tailSegment)) {
      normalized = normalized.substring(0, lastDotIndex);
    } else {
      break;
    }
  }
  return normalized;
}

/// RSS puts the release URL in `<link>https://...</link>`. The HTML parser
/// treats `<link>` as void, so [parse] drops that text. Read from raw XML.
String? releaseUrlFromApkMirrorRssItemInner(String itemInnerXml) {
  final linkText = RegExp(
    r'<link>([^<]+)</link>',
    caseSensitive: false,
  ).firstMatch(itemInnerXml);
  if (linkText != null) {
    final url = linkText.group(1)!.trim();
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
  }
  final linkHref = RegExp(
    r'''<link[^>]+href=["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(itemInnerXml);
  if (linkHref != null) {
    final url = linkHref.group(1)!.trim();
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
  }
  final guidMatch = RegExp(
    r'<guid[^>]*>([^<]+)</guid>',
    caseSensitive: false,
  ).firstMatch(itemInnerXml);
  if (guidMatch != null) {
    final url = guidMatch.group(1)!.trim();
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
  }
  return null;
}

/// When [itemInnerBlocks] is empty, HTML-parsed item index still matches the
/// Nth `<item>...</item>` region in raw XML for link extraction.
String? releaseUrlFromApkMirrorFeedBodyForItemIndex(String body, int itemIndex) {
  if (itemIndex < 0) return null;
  final segments = body.split(RegExp(r'<item\b[^>]*>', caseSensitive: false));
  if (itemIndex + 1 >= segments.length) return null;
  final afterItemOpen = segments[itemIndex + 1];
  final lower = afterItemOpen.toLowerCase();
  final closeIdx = lower.indexOf('</item>');
  if (closeIdx < 0) return null;
  return releaseUrlFromApkMirrorRssItemInner(
    afterItemOpen.substring(0, closeIdx),
  );
}

String? titleFromApkMirrorRssItemInner(String itemInnerXml) {
  Match? titleMatch = RegExp(
    r'<title>\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*</title>',
    caseSensitive: false,
  ).firstMatch(itemInnerXml);
  if (titleMatch != null) {
    return titleMatch.group(1)?.trim();
  }
  titleMatch = RegExp(
    r'<title>([^<]*)</title>',
    caseSensitive: false,
  ).firstMatch(itemInnerXml);
  return titleMatch?.group(1)?.trim();
}

/// Resolves Open Graph / Twitter image URL from an APKMirror app listing page.
String? iconUrlFromApkMirrorAppPageHtml(String html, String pageUrl) {
  final doc = parse(html);
  String? raw =
      doc.querySelector('meta[property="og:image"]')?.attributes['content'] ??
          doc.querySelector('meta[name="twitter:image"]')?.attributes['content'] ??
          doc
              .querySelector('meta[name="twitter:image:src"]')
              ?.attributes['content'];
  if (raw == null || raw.trim().isEmpty) return null;
  final baseUri = Uri.parse(pageUrl);
  return baseUri.resolveUri(Uri.parse(raw.trim())).toString();
}

DateTime? releaseDateFromApkMirrorRssItemInner(String itemInnerXml) {
  final pubDateMatch = RegExp(
    r'<pubDate>([^<]+)</pubDate>',
    caseSensitive: false,
  ).firstMatch(itemInnerXml);
  final raw = pubDateMatch?.group(1)?.trim();
  if (raw == null || raw.isEmpty) return null;
  try {
    return HttpDate.parse(raw);
  } catch (_) {
    try {
      final parts = raw.split(RegExp(r'\s+'));
      if (parts.length >= 5) {
        return HttpDate.parse('${parts.sublist(0, 5).join(' ')} GMT');
      }
    } catch (_) {}
  }
  return null;
}

/// Known Android ABI strings to detect from APKMirror variant URLs/text.
const _knownAndroidArchs = [
  'arm64-v8a',
  'armeabi-v7a',
  'x86_64',
  'x86',
  'universal',
];

/// Extracts an arch label from an APKMirror variant URL slug.
/// E.g. `.../chrome-124-arm64-v8a-android-apk-download/` → `arm64-v8a`
String? _extractArchFromApkMirrorUrl(String url) {
  final lower = url.toLowerCase();
  for (final arch in _knownAndroidArchs) {
    if (lower.contains(arch)) return arch;
  }
  return null;
}

/// Parses APK variant rows from an APKMirror release page.
///
/// Returns a list of entries where the key is a display label containing arch
/// info (used by [filterApksByArch] for auto-filtering) and the value is the
/// absolute URL of the variant detail/download page.
List<MapEntry<String, String>> _parseApkMirrorVariants(
  String html,
  String releasePageUrl,
) {
  final doc = parse(html);
  final baseUri = Uri.tryParse(releasePageUrl);
  final results = <MapEntry<String, String>>[];
  final seenUrls = <String>{};

  String resolveHref(String href) {
    if (href.startsWith('http')) return href;
    if (baseUri != null) return baseUri.resolve(href).toString();
    return 'https://www.apkmirror.com$href';
  }

  // Strategy 1: variants table rows (class "table-row headerFont")
  for (final row in doc.querySelectorAll('div.table-row.headerFont')) {
    final cells = row.querySelectorAll('div.table-cell');
    if (cells.isEmpty) continue;

    // Determine type from badge span or first-cell link text
    final badgeEl = row.querySelector('.apkm-badge');
    final typeText =
        (badgeEl?.text ?? cells[0].querySelector('a')?.text ?? '').trim().toUpperCase();
    // Only include plain APK (skip XAPK, APKS, Bundle, etc.)
    if (typeText != 'APK') continue;

    // The download-page link is inside the first cell
    final downloadLink =
        cells[0].querySelector('a[href*="-apk-download"]') ??
        cells[0].querySelector('a[href*="download"]');
    if (downloadLink == null) continue;

    final href = downloadLink.attributes['href'] ?? '';
    if (href.isEmpty) continue;

    final variantUrl = resolveHref(href);
    if (!seenUrls.add(variantUrl)) continue;

    final arch = cells.length > 1 ? cells[1].text.trim() : '';
    final dpi = cells.length > 2 ? cells[2].text.trim() : '';

    final parts = [arch, dpi]
        .where((s) => s.isNotEmpty && s != '-' && s.toLowerCase() != 'nodpi')
        .toList();
    final displayKey = parts.isEmpty ? 'APK' : parts.join(' - ');

    results.add(MapEntry(displayKey, variantUrl));
  }

  // Strategy 2: fallback – find all "-android-apk-download" links on the page
  if (results.isEmpty) {
    for (final a in doc.querySelectorAll('a[href*="-android-apk-download"]')) {
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty) continue;

      final variantUrl = resolveHref(href);
      if (!seenUrls.add(variantUrl)) continue;

      final arch = _extractArchFromApkMirrorUrl(variantUrl);
      final displayKey = arch ?? 'APK';
      results.add(MapEntry(displayKey, variantUrl));
    }
  }

  return results;
}

/// Fetches an APKMirror variant detail page and returns the direct APK
/// download URL (the `download.php?id=…&key=…` link).
///
/// Returns `null` if the page cannot be fetched or the link is not found.
Future<String?> _getApkMirrorDownloadUrl(
  String variantPageUrl,
  Map<String, dynamic> additionalSettings,
  Future<Response> Function(String, Map<String, dynamic>) sourceRequest,
) async {
  try {
    final res = await sourceRequest(variantPageUrl, additionalSettings);
    if (res.statusCode != 200) return null;

    final doc = parse(res.body);
    final baseUri = Uri.tryParse(variantPageUrl);

    String resolveHref(String href) {
      if (href.startsWith('http')) return href;
      if (href.startsWith('?')) {
        return '${variantPageUrl.split('?')[0]}$href';
      }
      if (baseUri != null) return baseUri.resolve(href).toString();
      return 'https://www.apkmirror.com$href';
    }

    // Primary: APKMirror download.php link with key parameter
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (href.contains('download.php') && href.contains('key=')) {
        return resolveHref(href);
      }
    }

    // Fallback: any link with key= that looks like a download action
    for (final a in doc.querySelectorAll('a[href*="key="]')) {
      final href = a.attributes['href'] ?? '';
      final text = a.text.toLowerCase();
      final rel = a.attributes['rel'] ?? '';
      if (text.contains('download') ||
          rel.contains('nofollow') ||
          a.classes.any((c) => c.toLowerCase().contains('download'))) {
        return resolveHref(href);
      }
    }
  } catch (_) {}
  return null;
}

class APKMirror extends AppSource {
  APKMirror() {
    hosts = ['apkmirror.com'];
    enforceTrackOnly = true;
    showReleaseDateAsVersionToggle = true;
    appIdInferIsOptional = true;

    additionalSourceAppSpecificSettingFormItems = [
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
        GeneratedFormSwitch(
          'enableDirectDownload',
          label: tr('enableDirectDownload'),
          defaultValue: false,
        ),
      ],
    ];
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    return {
      "User-Agent":
          "ObtainX/${(await getInstalledInfo(obtainiumId))?.versionName ?? '1.0.0'}",
    };
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    RegExp standardUrlRegEx = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}/apk/[^/]+/[^/]+',
      caseSensitive: false,
    );
    RegExpMatch? match = standardUrlRegEx.firstMatch(url);
    if (match == null) {
      throw InvalidURLError(name);
    }
    return match.group(0)!;
  }

  @override
  String? changeLogPageFromStandardUrl(String standardUrl) =>
      '$standardUrl/#whatsnew';

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    Response res = await sourceRequest(standardUrl, additionalSettings);
    if (res.statusCode != 200) return null;
    const packagePattern = r'com(?:\.[a-zA-Z0-9_]+){2,}';
    final packageFullMatch = RegExp('^$packagePattern\$');
    for (final match in RegExp(packagePattern).allMatches(res.body)) {
      final candidate = _apkMirrorNormalizeInferredPackageCandidate(
        match.group(0)!,
      );
      if (candidate.length >= 10 &&
          !candidate.startsWith('com.apkmirror') &&
          !candidate.contains('apkmirror') &&
          packageFullMatch.hasMatch(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    bool fallbackToOlderReleases =
        additionalSettings['fallbackToOlderReleases'] == true;
    String? regexFilter =
        (additionalSettings['filterReleaseTitlesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseTitlesByRegEx']
        : null;
    Response res = await sourceRequest(
      '$standardUrl/feed/',
      additionalSettings,
    );
    if (res.statusCode == 200) {
      final itemInnerBlocks = RegExp(
        r'<item>([\s\S]*?)</item>',
        caseSensitive: false,
      ).allMatches(res.body).map((match) => match.group(1)!).toList();

      String? titleString;
      String? releasePageUrl;
      DateTime? releaseDate;

      if (itemInnerBlocks.isNotEmpty) {
        final RegExp? titleFilterPattern =
            regexFilter != null ? RegExp(regexFilter) : null;
        String? chosenBlock;
        for (int itemIndex = 0; itemIndex < itemInnerBlocks.length; itemIndex++) {
          if (!fallbackToOlderReleases && itemIndex > 0) break;
          final block = itemInnerBlocks[itemIndex];
          final nameToFilter = titleFromApkMirrorRssItemInner(block);
          if (titleFilterPattern != null &&
              nameToFilter != null &&
              !titleFilterPattern.hasMatch(nameToFilter.trim())) {
            continue;
          }
          chosenBlock = block;
          titleString = nameToFilter;
          break;
        }
        if (chosenBlock != null) {
          releasePageUrl = releaseUrlFromApkMirrorRssItemInner(chosenBlock);
          releaseDate = releaseDateFromApkMirrorRssItemInner(chosenBlock);
        }
      } else {
        final parsedItems = parse(res.body).querySelectorAll('item');
        dynamic targetRelease;
        int chosenParsedItemIndex = -1;
        for (int itemIndex = 0; itemIndex < parsedItems.length; itemIndex++) {
          if (!fallbackToOlderReleases && itemIndex > 0) break;
          final nameToFilter =
              parsedItems[itemIndex].querySelector('title')?.innerHtml;
          if (regexFilter != null &&
              nameToFilter != null &&
              !RegExp(regexFilter).hasMatch(nameToFilter.trim())) {
            continue;
          }
          targetRelease = parsedItems[itemIndex];
          chosenParsedItemIndex = itemIndex;
          break;
        }
        titleString = targetRelease?.querySelector('title')?.innerHtml;
        final dateString = targetRelease
            ?.querySelector('pubDate')
            ?.innerHtml
            .split(' ')
            .sublist(0, 5)
            .join(' ');
        releaseDate = dateString != null
            ? HttpDate.parse('$dateString GMT')
            : null;
        if (chosenParsedItemIndex >= 0) {
          releasePageUrl = releaseUrlFromApkMirrorFeedBodyForItemIndex(
            res.body,
            chosenParsedItemIndex,
          );
        }
      }
      String? version = titleString
          ?.substring(
            RegExp('[0-9]').firstMatch(titleString)?.start ?? 0,
            RegExp(' by ').allMatches(titleString).last.start,
          )
          .trim();
      if (version == null || version.isEmpty) {
        version = titleString;
      }
      if (version == null || version.isEmpty) {
        throw NoVersionError();
      }

      // Fetch icon from the app's main listing page (optional).
      String? iconUrl;
      try {
        final pageRes = await sourceRequest(standardUrl, additionalSettings);
        if (pageRes.statusCode == 200) {
          iconUrl = iconUrlFromApkMirrorAppPageHtml(pageRes.body, standardUrl);
        }
      } catch (_) {
        // Icon is optional – ignore errors.
      }

      // When direct download is enabled, scrape variant APK URLs from the
      // release page so the user can download without leaving the app.
      List<MapEntry<String, String>> apkUrls = [];
      if (additionalSettings['enableDirectDownload'] == true &&
          releasePageUrl != null) {
        try {
          final releaseRes =
              await sourceRequest(releasePageUrl, additionalSettings);
          if (releaseRes.statusCode == 200) {
            final variants =
                _parseApkMirrorVariants(releaseRes.body, releasePageUrl);
            if (variants.isNotEmpty) {
              // Resolve final download URLs for all variants in parallel.
              final futures = variants.map((variant) async {
                final url = await _getApkMirrorDownloadUrl(
                  variant.value,
                  additionalSettings,
                  sourceRequest,
                );
                return url != null ? MapEntry(variant.key, url) : null;
              }).toList();
              final resolved = await Future.wait(futures);
              apkUrls = resolved.nonNulls.toList();
            }
          }
        } catch (_) {
          // Fall back to track-only behaviour (empty apkUrls).
        }
      }

      return APKDetails(
        version,
        apkUrls,
        getAppNames(standardUrl),
        releaseDate: releaseDate,
        changeLog: releasePageUrl,
        iconUrl: iconUrl,
      );
    } else {
      throw getObtainiumHttpError(res);
    }
  }

  AppNames getAppNames(String standardUrl) {
    String temp = standardUrl.substring(standardUrl.indexOf('://') + 3);
    List<String> names = temp.substring(temp.indexOf('/') + 1).split('/');
    return AppNames(names[1], names[2]);
  }
}
