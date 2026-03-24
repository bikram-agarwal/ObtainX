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

      final List<String> rawReleaseTitleCandidates = <String>[];
      void collectReleaseTitleCandidate(String? title) {
        if (title == null) {
          return;
        }
        final String trimmed = title.trim();
        if (trimmed.isEmpty) {
          return;
        }
        if (rawReleaseTitleCandidates.length >= 40) {
          return;
        }
        if (!rawReleaseTitleCandidates.contains(trimmed)) {
          rawReleaseTitleCandidates.add(trimmed);
        }
      }

      String? titleString;
      String? releasePageUrl;
      DateTime? releaseDate;

      if (itemInnerBlocks.isNotEmpty) {
        for (int scanIndex = 0; scanIndex < itemInnerBlocks.length; scanIndex++) {
          collectReleaseTitleCandidate(
            titleFromApkMirrorRssItemInner(itemInnerBlocks[scanIndex]),
          );
        }
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
        for (int scanIndex = 0; scanIndex < parsedItems.length; scanIndex++) {
          collectReleaseTitleCandidate(
            parsedItems[scanIndex].querySelector('title')?.innerHtml,
          );
        }
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

      return APKDetails(
        version,
        [],
        getAppNames(standardUrl),
        releaseDate: releaseDate,
        changeLog: releasePageUrl,
        iconUrl: iconUrl,
        rawReleaseTitleCandidates: rawReleaseTitleCandidates,
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
