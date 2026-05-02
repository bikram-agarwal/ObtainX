import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:http/http.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/html_parse_isolate.dart';

// TEMP APKMIRROR SIZE DEBUG: keep enabled until APKMirror size refresh is confirmed.
const bool apkMirrorSizeDebugLoggingEnabled = true;
const String _apkMirrorSizeDebugPrefix = 'OBTAINX-APK-SIZE-DEBUG';

class _ApkMirrorSizeCandidate {
  final String key;
  final String url;
  final int sizeBytes;
  final bool isBundle;

  const _ApkMirrorSizeCandidate({
    required this.key,
    required this.url,
    required this.sizeBytes,
    required this.isBundle,
  });
}

Future<void> _logApkMirrorSizeDebug(String message) async {
  if (!apkMirrorSizeDebugLoggingEnabled) {
    return;
  }
  try {
    await LogsProvider(runDefaultClear: false).add(
      '$_apkMirrorSizeDebugPrefix APKMirror: $message',
      level: LogLevels.debug,
    );
  } catch (_) {
    // Debug logging must never affect update checks.
  }
}

/// Image and static asset URL suffixes that appear in page HTML after a string
/// that looks like `com.vendor.app`, e.g. `com.google.android.calendar.png`.
const _apkMirrorTrailingNonPackageSegments = <String>{
  'avif',
  'bmp',
  'gif',
  'ico',
  'jpeg',
  'jpg',
  'png',
  'svg',
  'webp',
};

const _apkMirrorCanonicalAppSlugByAlias = <String, String>{
  'youtube-music-android-automotive': 'youtube-music',
  'youtube-music-wear-os': 'youtube-music',
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
String? releaseUrlFromApkMirrorFeedBodyForItemIndex(
  String body,
  int itemIndex,
) {
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
Future<String?> iconUrlFromApkMirrorAppPageHtml(
  String html,
  String pageUrl,
) async {
  final doc = await parseHtmlOffIsolate(html);
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

int? apkSizeBytesFromApkMirrorSizeText(String sizeText) {
  final match = RegExp(
    r'([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB)',
    caseSensitive: false,
  ).firstMatch(sizeText);
  if (match == null) {
    return null;
  }
  final double? sizeNumber = double.tryParse(match.group(1)!);
  if (sizeNumber == null) {
    return null;
  }
  final String unit = match.group(2)!.toUpperCase();
  double multiplier = 1;
  if (unit == 'KB') {
    multiplier = 1024;
  } else if (unit == 'MB') {
    multiplier = 1024 * 1024;
  } else if (unit == 'GB') {
    multiplier = 1024 * 1024 * 1024;
  }
  return (sizeNumber * multiplier).round();
}

Future<int?> apkSizeBytesFromApkMirrorReleasePageHtml(String html) async {
  final pageText = (await parseHtmlOffIsolate(html)).body?.text ?? html;
  final exactBytesMatch = RegExp(
    r'\(([0-9][0-9,]*)\s*bytes\)',
    caseSensitive: false,
  ).firstMatch(pageText);
  if (exactBytesMatch != null) {
    return int.tryParse(exactBytesMatch.group(1)!.replaceAll(',', ''));
  }

  final directDownloadSizeTexts = RegExp(
    r'Download[^\n]*,\s*([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB)',
    caseSensitive: false,
  ).allMatches(pageText).map((match) => match.group(0)!).toSet().toList();
  if (directDownloadSizeTexts.isNotEmpty) {
    return apkSizeBytesFromApkMirrorSizeText(directDownloadSizeTexts.first);
  }

  final fileSizeTexts = RegExp(
    r'File size:\s*([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB)',
    caseSensitive: false,
  ).allMatches(pageText).map((match) => match.group(0)!).toSet().toList();
  if (fileSizeTexts.isNotEmpty) {
    return apkSizeBytesFromApkMirrorSizeText(fileSizeTexts.first);
  }
  return null;
}

String? _apkMirrorSameReleaseDownloadPageUrlFromElement(
  html_dom.Element linkElement,
  String releasePageUrl,
) {
  final href = linkElement.attributes['href']?.trim();
  if (href == null || href.isEmpty) {
    return null;
  }
  final releaseUri = Uri.parse(releasePageUrl);
  final resolvedUri = releaseUri.resolve(href).removeFragment();
  final resolvedPathWithSlash = resolvedUri.path.endsWith('/')
      ? resolvedUri.path
      : '${resolvedUri.path}/';
  final resolved = resolvedUri.replace(path: resolvedPathWithSlash).toString();
  final releasePrefix = releasePageUrl.endsWith('/')
      ? releasePageUrl
      : '$releasePageUrl/';
  if (!resolved.startsWith(releasePrefix)) {
    return null;
  }
  final resolvedPath = Uri.parse(resolved).path;
  if (!resolvedPath.endsWith('-apk-download/') &&
      !resolvedPath.endsWith('-apk-download')) {
    return null;
  }
  return resolved;
}

String _apkMirrorNormalizedText(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _apkMirrorTextIncludesVariantHint(String text) {
  return RegExp(
    r'\b(APK|BUNDLE|arm64-v8a|armeabi-v7a|arm-v7a|x86_64|x86)\b',
    caseSensitive: false,
  ).hasMatch(text);
}

String _apkMirrorDownloadPageKeyFromLinkElement(html_dom.Element linkElement) {
  final linkText = _apkMirrorNormalizedText(linkElement.text);
  html_dom.Element? parent = linkElement.parent;
  String bestText = linkText;
  for (int depth = 0; depth < 6 && parent != null; depth++) {
    final candidateText = _apkMirrorNormalizedText('$linkText ${parent.text}');
    if (RegExp(
      r'\b(arm64-v8a|armeabi-v7a|arm-v7a|x86_64|x86)\b',
      caseSensitive: false,
    ).hasMatch(candidateText)) {
      return candidateText;
    }
    if (_apkMirrorTextIncludesVariantHint(candidateText)) {
      bestText = candidateText;
    }
    parent = parent.parent;
  }
  return bestText.isNotEmpty ? bestText : linkElement.outerHtml;
}

Future<List<MapEntry<String, String>>>
_apkMirrorDownloadPageUrlEntriesFromReleasePageHtml(
  String html,
  String releasePageUrl,
) async {
  final doc = await parseHtmlOffIsolate(html);
  final Map<String, int> weightedUrls = {};
  final Map<String, String> urlKeys = {};
  for (final linkElement in doc.querySelectorAll('a[href]')) {
    final resolved = _apkMirrorSameReleaseDownloadPageUrlFromElement(
      linkElement,
      releasePageUrl,
    );
    if (resolved == null) {
      continue;
    }
    final normalizedParentText = _apkMirrorDownloadPageKeyFromLinkElement(
      linkElement,
    );
    var weight = 50;
    if (RegExp(r'(^|\s)APK(\s|$)').hasMatch(normalizedParentText)) {
      weight -= 20;
    }
    if (RegExp(r'(^|\s)BUNDLE(\s|$)').hasMatch(normalizedParentText)) {
      weight += 20;
    }
    final existingWeight = weightedUrls[resolved];
    if (existingWeight == null || weight < existingWeight) {
      weightedUrls[resolved] = weight;
      urlKeys[resolved] = normalizedParentText;
    }
  }
  final sortedEntries = weightedUrls.entries.toList()
    ..sort((left, right) {
      final weightCompare = left.value.compareTo(right.value);
      if (weightCompare != 0) {
        return weightCompare;
      }
      return left.key.compareTo(right.key);
    });
  return sortedEntries
      .map((entry) => MapEntry(urlKeys[entry.key] ?? entry.key, entry.key))
      .toList();
}

Future<List<String>> apkMirrorDownloadPageUrlsFromReleasePageHtml(
  String html,
  String releasePageUrl,
) async {
  return (await _apkMirrorDownloadPageUrlEntriesFromReleasePageHtml(
    html,
    releasePageUrl,
  )).map((entry) => entry.value).toList();
}

List<String> apkMirrorFallbackDownloadPageUrlsFromReleasePageUrl(
  String releasePageUrl,
) {
  final releaseUri = Uri.parse(releasePageUrl);
  if (releaseUri.pathSegments.isEmpty) {
    return [];
  }
  final releaseSlug = releaseUri.pathSegments.reversed.firstWhere(
    (pathSegment) {
      return pathSegment.isNotEmpty;
    },
    orElse: () {
      return '';
    },
  );
  if (releaseSlug.isEmpty) {
    return [];
  }
  final downloadSlugBase = releaseSlug.endsWith('-release')
      ? releaseSlug.substring(0, releaseSlug.length - '-release'.length)
      : releaseSlug;
  final releasePagePrefix = releasePageUrl.endsWith('/')
      ? releasePageUrl
      : '$releasePageUrl/';
  final List<String> candidates = [];
  for (var candidateIndex = 1; candidateIndex <= 20; candidateIndex++) {
    final suffix = candidateIndex == 1 ? '' : '-$candidateIndex';
    candidates.add(
      '$releasePagePrefix$downloadSlugBase$suffix-android-apk-download/',
    );
  }
  return candidates;
}

Future<bool> apkMirrorDownloadPageHtmlIsBundle(String html) async {
  final pageText = (await parseHtmlOffIsolate(html)).body?.text ?? html;
  return RegExp(
    r'Download\s+APK\s+Bundle',
    caseSensitive: false,
  ).hasMatch(pageText);
}

Future<String> _apkMirrorDownloadPageKeyFromHtml(
  String html,
  String url,
) async {
  final doc = await parseHtmlOffIsolate(html);
  final titleText = doc.querySelector('title')?.text;
  final headingText =
      doc.querySelector('h1')?.text ?? doc.querySelector('h2')?.text;
  final pageText = doc.body?.text ?? html;
  final key = _apkMirrorNormalizedText(
    [?titleText, ?headingText, pageText].join(' '),
  );
  return key.isNotEmpty ? key : url;
}

Future<List<MapEntry<String, String>>> _filterApkMirrorDownloadPageEntries(
  List<MapEntry<String, String>> downloadPageEntries,
  Map<String, dynamic> additionalSettings,
) async {
  var filteredEntries = filterApks(
    downloadPageEntries,
    additionalSettings['apkFilterRegEx'],
    additionalSettings['invertAPKFilter'],
  );
  if (additionalSettings['autoApkFilterByArch'] == true) {
    filteredEntries = await filterApksByArch(filteredEntries);
  }
  return filteredEntries;
}

Future<List<_ApkMirrorSizeCandidate>> _filterApkMirrorSizeCandidates(
  List<_ApkMirrorSizeCandidate> candidates,
  Map<String, dynamic> additionalSettings,
) async {
  if (candidates.isEmpty) {
    return candidates;
  }
  final filteredEntries = await _filterApkMirrorDownloadPageEntries(
    candidates
        .map((candidate) => MapEntry(candidate.key, candidate.url))
        .toList(),
    additionalSettings,
  );
  final filteredUrls = filteredEntries.map((entry) => entry.value).toSet();
  return candidates.where((candidate) {
    return filteredUrls.contains(candidate.url);
  }).toList();
}

_ApkMirrorSizeCandidate? _pickApkMirrorSizeCandidate(
  List<_ApkMirrorSizeCandidate> candidates,
) {
  if (candidates.isEmpty) {
    return null;
  }
  final apkCandidates = candidates.where((candidate) {
    return !candidate.isBundle;
  }).toList();
  if (apkCandidates.isNotEmpty) {
    return apkCandidates.first;
  }
  return candidates.first;
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
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 15; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 ObtainX/${(await getInstalledInfo(obtainiumId))?.versionName ?? '1.0.0'}',
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
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
    final standardizedUrl = match.group(0)!;
    final lowerStandardizedUrl = standardizedUrl.toLowerCase();
    for (final aliasEntry in _apkMirrorCanonicalAppSlugByAlias.entries) {
      final aliasSuffix = '/${aliasEntry.key}';
      if (lowerStandardizedUrl.endsWith(aliasSuffix)) {
        return '${standardizedUrl.substring(0, standardizedUrl.length - aliasSuffix.length)}/${aliasEntry.value}';
      }
    }
    return standardizedUrl;
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
    await _logApkMirrorSizeDebug(
      'start standardUrl=$standardUrl feedStatus=${res.statusCode} feedBytes=${res.body.length} fallbackToOlderReleases=$fallbackToOlderReleases filter=${regexFilter ?? "<none>"}',
    );
    if (res.statusCode == 200) {
      final itemInnerBlocks = RegExp(
        r'<item>([\s\S]*?)</item>',
        caseSensitive: false,
      ).allMatches(res.body).map((match) => match.group(1)!).toList();
      await _logApkMirrorSizeDebug(
        'feed parsed itemInnerBlocks=${itemInnerBlocks.length}',
      );

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
        for (
          int scanIndex = 0;
          scanIndex < itemInnerBlocks.length;
          scanIndex++
        ) {
          collectReleaseTitleCandidate(
            titleFromApkMirrorRssItemInner(itemInnerBlocks[scanIndex]),
          );
        }
        final RegExp? titleFilterPattern = regexFilter != null
            ? RegExp(regexFilter)
            : null;
        String? chosenBlock;
        for (
          int itemIndex = 0;
          itemIndex < itemInnerBlocks.length;
          itemIndex++
        ) {
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
        final parsedItems = (await parseHtmlOffIsolate(
          res.body,
        )).querySelectorAll('item');
        for (int scanIndex = 0; scanIndex < parsedItems.length; scanIndex++) {
          collectReleaseTitleCandidate(
            parsedItems[scanIndex].querySelector('title')?.innerHtml,
          );
        }
        dynamic targetRelease;
        int chosenParsedItemIndex = -1;
        for (int itemIndex = 0; itemIndex < parsedItems.length; itemIndex++) {
          if (!fallbackToOlderReleases && itemIndex > 0) break;
          final nameToFilter = parsedItems[itemIndex]
              .querySelector('title')
              ?.innerHtml;
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
      final String? releasePageUrlBeforeValidation = releasePageUrl;
      if (releasePageUrl != null &&
          !releasePageUrl.startsWith('$standardUrl/')) {
        releasePageUrl = null;
      }
      await _logApkMirrorSizeDebug(
        'selected title=${titleString ?? "<null>"} releasePageUrlRaw=${releasePageUrlBeforeValidation ?? "<null>"} releasePageUrl=${releasePageUrl ?? "<null>"} releaseDate=${releaseDate?.toIso8601String() ?? "<null>"}',
      );
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

      int? apkSizeBytes;
      String? downloadPageUrl;
      final List<_ApkMirrorSizeCandidate> sizeCandidates = [];
      if (releasePageUrl != null) {
        try {
          var releasePageProvidedDownloadEntries = false;
          var filteredReleaseDownloadEntries = <MapEntry<String, String>>[];
          final releasePageResponse = await sourceRequest(
            releasePageUrl,
            additionalSettings,
          );
          await _logApkMirrorSizeDebug(
            'release page status=${releasePageResponse.statusCode} bytes=${releasePageResponse.body.length} url=$releasePageUrl',
          );
          if (releasePageResponse.statusCode == 200) {
            apkSizeBytes = await apkSizeBytesFromApkMirrorReleasePageHtml(
              releasePageResponse.body,
            );
            await _logApkMirrorSizeDebug(
              'release page parsedSize=${apkSizeBytes?.toString() ?? "<null>"}',
            );
            final downloadPageEntries =
                await _apkMirrorDownloadPageUrlEntriesFromReleasePageHtml(
                  releasePageResponse.body,
                  releasePageUrl,
                );
            releasePageProvidedDownloadEntries = downloadPageEntries.isNotEmpty;
            filteredReleaseDownloadEntries =
                await _filterApkMirrorDownloadPageEntries(
                  downloadPageEntries,
                  additionalSettings,
                );
            await _logApkMirrorSizeDebug(
              'download candidates count=${downloadPageEntries.length} filtered=${filteredReleaseDownloadEntries.length} first=${filteredReleaseDownloadEntries.take(5).map((entry) => entry.value).join(" | ")}',
            );
            var checkedDownloadCandidates = 0;
            for (final candidateDownloadPageEntry
                in filteredReleaseDownloadEntries) {
              checkedDownloadCandidates += 1;
              final downloadPageResponse = await sourceRequest(
                candidateDownloadPageEntry.value,
                additionalSettings,
              );
              if (checkedDownloadCandidates <= 8) {
                await _logApkMirrorSizeDebug(
                  'download candidate #$checkedDownloadCandidates status=${downloadPageResponse.statusCode} bytes=${downloadPageResponse.body.length} key=${candidateDownloadPageEntry.key} url=${candidateDownloadPageEntry.value}',
                );
              }
              if (downloadPageResponse.statusCode != 200) {
                continue;
              }
              final candidateSize =
                  await apkSizeBytesFromApkMirrorReleasePageHtml(
                    downloadPageResponse.body,
                  );
              if (checkedDownloadCandidates <= 8) {
                await _logApkMirrorSizeDebug(
                  'download candidate #$checkedDownloadCandidates parsedSize=${candidateSize?.toString() ?? "<null>"}',
                );
              }
              if (candidateSize == null) {
                continue;
              }
              final candidateIsBundle = await apkMirrorDownloadPageHtmlIsBundle(
                downloadPageResponse.body,
              );
              sizeCandidates.add(
                _ApkMirrorSizeCandidate(
                  key: candidateDownloadPageEntry.key,
                  url: candidateDownloadPageEntry.value,
                  sizeBytes: candidateSize,
                  isBundle: candidateIsBundle,
                ),
              );
            }
          }
          if (sizeCandidates.isEmpty &&
              (!releasePageProvidedDownloadEntries ||
                  filteredReleaseDownloadEntries.isNotEmpty)) {
            final fallbackDownloadPageUrls =
                apkMirrorFallbackDownloadPageUrlsFromReleasePageUrl(
                  releasePageUrl,
                );
            await _logApkMirrorSizeDebug(
              'fallback download candidates count=${fallbackDownloadPageUrls.length} first=${fallbackDownloadPageUrls.take(5).join(" | ")}',
            );
            var consecutiveMissedFallbackCandidates = 0;
            var checkedFallbackDownloadCandidates = 0;
            for (final fallbackDownloadPageUrl in fallbackDownloadPageUrls) {
              checkedFallbackDownloadCandidates += 1;
              final fallbackDownloadPageResponse = await sourceRequest(
                fallbackDownloadPageUrl,
                additionalSettings,
              );
              if (checkedFallbackDownloadCandidates <= 8) {
                await _logApkMirrorSizeDebug(
                  'fallback download candidate #$checkedFallbackDownloadCandidates status=${fallbackDownloadPageResponse.statusCode} bytes=${fallbackDownloadPageResponse.body.length} url=$fallbackDownloadPageUrl',
                );
              }
              if (fallbackDownloadPageResponse.statusCode != 200) {
                consecutiveMissedFallbackCandidates += 1;
                final missLimit = sizeCandidates.isEmpty ? 5 : 3;
                if (consecutiveMissedFallbackCandidates >= missLimit) {
                  break;
                }
                continue;
              }
              consecutiveMissedFallbackCandidates = 0;
              final fallbackCandidateSize =
                  await apkSizeBytesFromApkMirrorReleasePageHtml(
                    fallbackDownloadPageResponse.body,
                  );
              if (checkedFallbackDownloadCandidates <= 8) {
                await _logApkMirrorSizeDebug(
                  'fallback download candidate #$checkedFallbackDownloadCandidates parsedSize=${fallbackCandidateSize?.toString() ?? "<null>"}',
                );
              }
              if (fallbackCandidateSize == null) {
                continue;
              }
              final fallbackCandidateIsBundle =
                  await apkMirrorDownloadPageHtmlIsBundle(
                    fallbackDownloadPageResponse.body,
                  );
              sizeCandidates.add(
                _ApkMirrorSizeCandidate(
                  key: await _apkMirrorDownloadPageKeyFromHtml(
                    fallbackDownloadPageResponse.body,
                    fallbackDownloadPageUrl,
                  ),
                  url: fallbackDownloadPageUrl,
                  sizeBytes: fallbackCandidateSize,
                  isBundle: fallbackCandidateIsBundle,
                ),
              );
            }
          }
          final filteredSizeCandidates = await _filterApkMirrorSizeCandidates(
            sizeCandidates,
            additionalSettings,
          );
          final pickedSizeCandidate = _pickApkMirrorSizeCandidate(
            filteredSizeCandidates,
          );
          if (pickedSizeCandidate != null) {
            apkSizeBytes = pickedSizeCandidate.sizeBytes;
            downloadPageUrl = pickedSizeCandidate.url;
            await _logApkMirrorSizeDebug(
              'picked download candidate bundle=${pickedSizeCandidate.isBundle} filteredCandidates=${filteredSizeCandidates.length} size=${pickedSizeCandidate.sizeBytes} key=${pickedSizeCandidate.key} url=${pickedSizeCandidate.url}',
            );
          }
        } catch (error) {
          await _logApkMirrorSizeDebug(
            'release/download size path error=${error.toString()}',
          );
          // Size is optional; keep track-only update checks resilient.
        }
      }

      // Fetch icon from the app's main listing page (optional).
      String? iconUrl;
      try {
        final pageRes = await sourceRequest(standardUrl, additionalSettings);
        await _logApkMirrorSizeDebug(
          'listing page status=${pageRes.statusCode} bytes=${pageRes.body.length} url=$standardUrl',
        );
        if (pageRes.statusCode == 200) {
          iconUrl = await iconUrlFromApkMirrorAppPageHtml(
            pageRes.body,
            standardUrl,
          );
          await _logApkMirrorSizeDebug(
            'listing page iconUrl=${iconUrl ?? "<null>"}',
          );
        }
      } catch (error) {
        await _logApkMirrorSizeDebug(
          'listing page path error=${error.toString()}',
        );
        // Icon is optional – ignore errors.
      }

      await _logApkMirrorSizeDebug(
        'return version=$version changeLog=${downloadPageUrl ?? releasePageUrl ?? "<null>"} finalSize=${apkSizeBytes?.toString() ?? "<null>"}',
      );

      return APKDetails(
        version,
        [],
        getAppNames(standardUrl),
        releaseDate: releaseDate,
        changeLog: downloadPageUrl ?? releasePageUrl,
        iconUrl: iconUrl,
        rawReleaseTitleCandidates: rawReleaseTitleCandidates,
        apkSizeBytes: apkSizeBytes,
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
