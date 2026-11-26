import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:http/http.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/http/obtainx_user_agent.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/host_request_gate.dart';
import 'package:obtainium/services/html_parse_isolate.dart';
import 'package:obtainium/utils/min_update_age.dart';

/// Single consolidated debug-logging flag for the APKMirror size code path.
///
/// One global, referenced by the lazy size resolver here, by
/// [SourceProvider.getApp] (to log the size that survived the update-check
/// merge), and by the AppPage button-rendering code (to log how the size
/// surfaces in the UI). When `false`, every guarded block short-circuits
/// without doing any work, so leaving the flag turned off has zero cost
/// in release builds.
const bool apkMirrorSizeDebug = false;
const String _apkMirrorSizeDebugPrefix = 'OBTAINX-APK-SIZE-DEBUG';

/// The user-agent token APKMirror's Cloudflare rule lets through to its
/// *HTML* pages (release page, `-apk-download/` page, app listing).
///
/// Page requests send it ([APKMirror.getRequestHeaders]), and so does bulk
/// import's `app_exists` API call (`BulkImportService.checkApkMirror`), which
/// also carries APKUpdater's API credential. The `/feed/` RSS allowlists
/// ObtainX by name since #339 (2026-10-13), so feed requests identify as
/// `ObtainX/<version> (+repo)`, which APKMirror's admin asked for.
/// Pages are different: on 2026-11-20 a first page request with the ObtainX
/// UA got a 403 `cf-mitigated: challenge`, while the size walk and "What's
/// new" still loaded with this token. So pages keep it, with ObtainX's name
/// and version appended so APKMirror can attribute (and, if they want, block)
/// the traffic, until the admin replies (v1.7.4 sync D2 final). Don't add new
/// uses of it, and don't "fix" pages back to a browser UA: that gets a
/// challenge every time.
///
/// Measured 2026-08-18: the page rule is a substring test on `APKUpdater`;
/// `APKUpdater-v3.5.9 ObtainX/x.y.z` returns 200, the old browser UA 403.
const String apkMirrorAllowlistedUserAgentToken = 'APKUpdater-v3.5.9';

/// [apkMirrorAllowlistedUserAgentToken] with ObtainX's own name and version
/// appended. Never bare (#339): an unreadable version becomes
/// [obtainXUserAgentFallbackVersion], as in [obtainXIdentifyingUserAgent].
String apkMirrorUserAgent([String? obtainXVersion]) {
  final String version = obtainXVersion?.trim() ?? '';
  return '$apkMirrorAllowlistedUserAgentToken ObtainX/'
      '${version.isEmpty ? obtainXUserAgentFallbackVersion : version}';
}

/// The running ObtainX version for APKMirror's user-agents, or null when it
/// can't be read.
///
/// Read once per launch: it can't change while ObtainX runs, and every page
/// request needs it, while a read is a package lookup over a platform channel.
/// A failed read isn't kept, so the next request tries again.
Future<String?> apkMirrorObtainXVersion() async =>
    _apkMirrorObtainXVersion ??= (await getInstalledInfo(
      obtainiumId,
      includeOwnDebugBuild: true,
    ))?.versionName;
String? _apkMirrorObtainXVersion;

/// Requests in flight to apkmirror.com at once, across every caller that
/// goes through [HostRequestGate] (APKMirror asked for 1-2, #339).
const int apkMirrorMaxConcurrentRequests = 2;

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
  if (!apkMirrorSizeDebug) {
    return;
  }
  try {
    await LogsProvider(runDefaultClear: false).add(
      '$_apkMirrorSizeDebugPrefix APKMirror: $message',
      level: LogLevel.debug,
    );
  } catch (_) {
    // Debug logging must never affect callers.
  }
}

const _apkMirrorCanonicalAppSlugByAlias = <String, String>{
  'youtube-music-android-automotive': 'youtube-music',
  'youtube-music-wear-os': 'youtube-music',
};

final RegExp _apkMirrorPackagePattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
);

/// The package an APKMirror listing page is for, or null if it doesn't say.
///
/// Read from the page's "View on Play Store" button (`details?id=<package>`).
/// Checked on live pages 2026-09-24: it's there even for apps Google doesn't
/// list on the store (Pixel Launcher). Every page also carries an ad linking
/// to another app's store page (ML Manager), so only the button counts.
///
/// The fallback is the `og:image` filename, which ends in `_<package>` for
/// newer icons. Older ones are just a hash (Play Store, WebView, Firefox).
Future<String?> apkMirrorPackageFromListingPageHtml(String html) async {
  final doc = await parseHtmlOffIsolate(html);
  final String? storeHref = doc
      .querySelector('a[title="View on Play Store"]')
      ?.attributes['href'];
  final Uri? storeUri = Uri.tryParse(storeHref?.trim() ?? '');
  final String? storeId = storeUri?.host == 'play.google.com'
      ? storeUri!.queryParameters['id']
      : null;
  if (storeId != null && _apkMirrorPackagePattern.hasMatch(storeId)) {
    return storeId;
  }
  return apkMirrorPackageFromIconUrl(
    doc.querySelector('meta[property="og:image"]')?.attributes['content'],
  );
}

/// The package an APKMirror icon URL names, or null for a hash-only icon.
///
/// Newer icons are named `<hash>_<package>.png`; the feed's copies add a size
/// suffix (`…_<package>-384x384.png`), stripped first (upstream bb782a74).
/// Everything after the *first* `_` is the package, not just the last
/// `_`-segment as upstream reads it: package names may contain `_`
/// (`…_org.mozilla.firefox_beta` is Firefox Beta, not Firefox).
String? apkMirrorPackageFromIconUrl(String? iconUrl) {
  final List<String> iconPath =
      Uri.tryParse(iconUrl?.trim() ?? '')?.pathSegments ?? const [];
  if (iconPath.isEmpty) return null;
  final String fileName = iconPath.last;
  final int extension = fileName.lastIndexOf('.');
  final String stem =
      (extension > 0 ? fileName.substring(0, extension) : fileName)
          .replaceFirst(RegExp(r'-\d+x\d+$'), '');
  final int underscore = stem.indexOf('_');
  if (underscore < 0) return null;
  final String iconId = stem.substring(underscore + 1);
  return _apkMirrorPackagePattern.hasMatch(iconId) ? iconId : null;
}

/// The app icon in an APKMirror feed (or one feed item): the first
/// `<img src>` of the `content:encoded` HTML. Every item carries it, so the
/// listing page isn't needed for the icon (#339).
String? apkMirrorIconUrlFromFeedXml(String feedXml) {
  final String? src = RegExp(
    r'''<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(feedXml)?.group(1)?.trim();
  if (src == null ||
      !(src.startsWith('https://') || src.startsWith('http://'))) {
    return null;
  }
  return src;
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

bool _apkMirrorIsWhatsNewHeading(String text) =>
    text.toLowerCase().startsWith("what's new in ");

bool _apkMirrorIsChangeLogStopHeading(String text) {
  final lowerText = text.toLowerCase();
  return lowerText.startsWith('about ') ||
      lowerText.startsWith('download ') ||
      lowerText.contains(' screenshots') ||
      lowerText.contains(' trailer');
}

bool _apkMirrorIsChangeLogNoise(String text) {
  final lowerText = text.toLowerCase();
  return lowerText == 'advertisement' ||
      lowerText.startsWith('verified safe to install') ||
      lowerText == 'scroll to available downloads' ||
      lowerText == 'a more recent upload may be available below!';
}

String _apkMirrorBlockText(html_dom.Element element) {
  final parts = <String>[];
  for (final child in element.children) {
    if (child.localName == 'ul' || child.localName == 'ol') {
      parts.addAll(
        child
            .querySelectorAll('li')
            .map((item) => _apkMirrorNormalizedText(item.text))
            .where((text) => text.isNotEmpty)
            .map((text) => '- $text'),
      );
    } else {
      final text = _apkMirrorNormalizedText(child.text);
      if (text.isNotEmpty) parts.add(text);
    }
  }
  if (parts.isNotEmpty) {
    return parts.join('\n');
  }
  return _apkMirrorNormalizedText(element.text);
}

String? _apkMirrorChangeLogFromPageText(String pageText) {
  final lines = pageText
      .split('\n')
      .map(_apkMirrorNormalizedText)
      .where((line) => line.isNotEmpty)
      .toList();
  final startIndex = lines.indexWhere(_apkMirrorIsWhatsNewHeading);
  if (startIndex < 0) return null;
  final changeLogLines = <String>[];
  for (int lineIndex = startIndex + 1; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex];
    if (_apkMirrorIsChangeLogStopHeading(line)) break;
    if (_apkMirrorIsChangeLogNoise(line)) continue;
    changeLogLines.add(line);
  }
  final changeLog = changeLogLines.join('\n').trim();
  return changeLog.isEmpty ? null : changeLog;
}

Future<String?> apkMirrorChangeLogFromReleasePageHtml(String html) async {
  final doc = await parseHtmlOffIsolate(html);
  html_dom.Element? whatsNewHeading;
  for (final heading in doc.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    if (_apkMirrorIsWhatsNewHeading(_apkMirrorNormalizedText(heading.text))) {
      whatsNewHeading = heading;
      break;
    }
  }
  if (whatsNewHeading != null) {
    final changeLogParts = <String>[];
    html_dom.Element? sibling = whatsNewHeading.nextElementSibling;
    while (sibling != null) {
      final text = _apkMirrorBlockText(sibling);
      if (_apkMirrorIsChangeLogStopHeading(text)) break;
      if (text.isNotEmpty && !_apkMirrorIsChangeLogNoise(text)) {
        changeLogParts.add(text);
      }
      sibling = sibling.nextElementSibling;
    }
    final changeLog = changeLogParts.join('\n\n').trim();
    if (changeLog.isNotEmpty) return changeLog;
  }
  return _apkMirrorChangeLogFromPageText(doc.body?.text ?? html);
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

Future<bool> apkMirrorDownloadPageHtmlIsBundle(String html) async {
  final pageText = (await parseHtmlOffIsolate(html)).body?.text ?? html;
  return RegExp(
    r'Download\s+APK\s+Bundle',
    caseSensitive: false,
  ).hasMatch(pageText);
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
    // The arch filter now keeps universal variants as alternatives next to
    // the ABI match (v1.7.4 sync D12). The size shown stays the ABI-specific
    // variant's, so universal ones drop out while another variant remains,
    // which also skips fetching their download pages.
    filteredEntries = await filterApksByArch(filteredEntries);
    final abiSpecificEntries = filteredEntries
        .where((entry) => !ApkFilterService.isUniversalApkName(entry.key))
        .toList();
    if (abiSpecificEntries.isNotEmpty) {
      filteredEntries = abiSpecificEntries;
    }
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
  return _apkMirrorPubDate(pubDateMatch?.group(1));
}

/// Parses an RSS `pubDate`, also when its zone isn't spelled `GMT`.
DateTime? _apkMirrorPubDate(String? pubDate) {
  final raw = pubDate?.trim();
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

String? apkMirrorVersionFromTitle(String? title) {
  if (title == null) return null;
  final authorStart = title.lastIndexOf(' by ');
  final label = (authorStart < 0 ? title : title.substring(0, authorStart))
      .trim();
  final systemVersion = RegExp(
    r'(?<![a-z0-9.])(?:(?:[a-z]\.)?\d+\.(?:playstore\.[a-z0-9_-]+|odad-stub)\.\d{6,}|(?:stargate\.android_)?\d{8}_\d+_rc\d+\.release_[a-z_]+)$',
    caseSensitive: false,
  ).firstMatch(label);
  if (systemVersion != null) return systemVersion.group(0);
  final release = releaseVersionPattern.firstMatch(label);
  if (release != null) return label.substring(release.start).trim();
  final digit = RegExp(r'\d').firstMatch(label);
  return digit == null ? label : label.substring(digit.start).trim();
}

/// [url] with its path ending in `/`. APKMirror's canonical page URLs do, and
/// a URL without the slash costs a 301 first (#339).
String _apkMirrorWithTrailingSlash(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.path.endsWith('/')) return url;
  return uri.replace(path: '${uri.path}/').toString();
}

/// The APKMirror maintainers do not allow for directly downloading APKs (PR #44)
class APKMirror extends AppSource {
  APKMirror() {
    name = 'APKMirror';
    hosts = ['apkmirror.com'];
    enforceTrackOnly = true;
    // Track-only controls opening the store page; installed packages still
    // participate in the shared device-version comparison.
    naiveStandardVersionDetection = true;
    showReleaseDateAsVersionToggle = true;
    appIdInferIsOptional = true;
    inferAppIdEvenWhenTrackOnly = true;
    // #339: at most 2 requests in flight to apkmirror.com across all update
    // workers, page requests at least 1 s apart, and a request class that got
    // a challenge or a rate limit fails fast until the block ends.
    enableHostRequestGate = true;
    maxConcurrentRequestsPerHost = apkMirrorMaxConcurrentRequests;
  }

  /// One lazy size walk per release, per isolate (#339), keyed
  /// `listingKey|releasePageUrl`. Static because [SourceProvider.getSource]
  /// hands out a fresh source per call. It holds the walk itself, so reopening
  /// the app page (or a second page racing the first) reuses the result,
  /// failures included, instead of walking the release pages again.
  static final Map<String, Future<int?>> _sizeWalks = {};

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    AppSource.fallbackToOlderReleasesFormItem,
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
        'invertReleaseTitlesFilter',
        label: '${tr('invertRegEx')} (${tr('filterReleaseTitlesByRegEx')})',
        value: false,
      ),
    ],
  ];

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    final String? version = await apkMirrorObtainXVersion();
    final Uri? uri = Uri.tryParse(url);
    final bool isFeed =
        uri != null && HostRequestGate.requestClassFor(uri) == 'feed';
    return {
      // Lowercase key: sourceRequest adds its default UA unless a
      // 'user-agent' is present in any casing.
      'user-agent': isFeed
          // The feed allowlists ObtainX by name (#339).
          ? obtainXIdentifyingUserAgent(version, obtainiumUrl)
          // Pages still need the token; see [apkMirrorAllowlistedUserAgentToken].
          : apkMirrorUserAgent(version),
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
    };
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    // Adopt upstream's base helper for the core standardization, then apply
    // the fork-only canonical-slug alias remapping on top (e.g. the
    // youtube-music automotive/wear-os slugs both collapse to youtube-music).
    final standardizedUrl = standardizeUrlWithRegex(
      url,
      subdomainPrefix: r'(www\.)?',
      pathPattern: r'/apk/[^/]+/[^/]+',
    );
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

  /// The fallback for apps whose feed icon is only a hash, so the feed doesn't
  /// name the package ([APKDetails.appId] is null): reads the listing page,
  /// see [apkMirrorPackageFromListingPageHtml]. [SourceProvider.getApp] asks
  /// only when an app is added, since a known ID is kept. A failed read means
  /// a temporary ID, not a failed add.
  ///
  /// The `app_exists` API can't do this: it's a *reverse* lookup (you post
  /// `pnames` and get app links back). The authoritative route, measured
  /// 2026-08-18, is the **302 `Location`** of `download.php`, whose filename
  /// encodes the package, e.g.
  /// `com.android.chrome_151.0.7922.139-792213933_25lang_2feat_<md5>_apkmirror.com.apkm`,
  /// but reaching it takes a request per page on the way.
  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    try {
      final Response res = await sourceRequest(
        _apkMirrorWithTrailingSlash(standardUrl),
        additionalSettings,
      );
      if (res.statusCode != 200) return null;
      return await apkMirrorPackageFromListingPageHtml(res.body);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      return await _getLatestAPKDetails(standardUrl, additionalSettings);
    } catch (e) {
      // As before this wrapper: a network failure reaches the update worker
      // as itself, which retries TLS handshakes to the same host.
      if (isTransientNetworkError(e)) rethrow;
      rethrowOrWrapError(e);
    }
  }

  Future<APKDetails> _getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    final bool fallbackToOlderReleases =
        additionalSettings['fallbackToOlderReleases'] == true;
    final String? regexFilter =
        (additionalSettings['filterReleaseTitlesByRegEx'] as String?)
                ?.isNotEmpty ==
            true
        ? additionalSettings['filterReleaseTitlesByRegEx']
        : null;
    final bool invertTitleFilter =
        additionalSettings['invertReleaseTitlesFilter'] == true;
    final Response res = await sourceRequest(
      '$standardUrl/feed/',
      additionalSettings,
    );
    if (res.statusCode != 200) {
      throw getObtainiumHttpError(res);
    }
    final int minAgeDays = await effectiveMinUpdateAgeDays(additionalSettings);
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
    String? iconUrl;

    if (itemInnerBlocks.isNotEmpty) {
      for (int scanIndex = 0; scanIndex < itemInnerBlocks.length; scanIndex++) {
        collectReleaseTitleCandidate(
          titleFromApkMirrorRssItemInner(itemInnerBlocks[scanIndex]),
        );
      }
      final RegExp? titleFilterPattern = regexFilter != null
          ? RegExp(regexFilter)
          : null;
      String? chosenBlock;
      String? tooYoungBlock;
      int releaseSkipped = 0;
      for (int itemIndex = 0; itemIndex < itemInnerBlocks.length; itemIndex++) {
        // Releases skipped as too young don't count as the latest one.
        if (!fallbackToOlderReleases && itemIndex > releaseSkipped) break;
        final block = itemInnerBlocks[itemIndex];
        final nameToFilter = titleFromApkMirrorRssItemInner(block);
        if (titleFilterPattern != null &&
            nameToFilter != null &&
            !passesRegExFilter(
              titleFilterPattern,
              nameToFilter.trim(),
              invert: invertTitleFilter,
            )) {
          continue;
        }
        if (isReleaseTooYoung(
          releaseDateFromApkMirrorRssItemInner(block),
          minAgeDays,
        )) {
          tooYoungBlock ??= block;
          releaseSkipped++;
          continue;
        }
        chosenBlock = block;
        break;
      }
      // No release old enough: use the newest so the provider can suppress
      // it until it ages.
      chosenBlock ??= tooYoungBlock;
      if (chosenBlock == null) {
        throw NoReleasesError(
          note: regexFilter != null ? tr('noMatchingReleaseFound') : null,
        );
      }
      titleString = titleFromApkMirrorRssItemInner(chosenBlock);
      releasePageUrl = releaseUrlFromApkMirrorRssItemInner(chosenBlock);
      releaseDate = releaseDateFromApkMirrorRssItemInner(chosenBlock);
      iconUrl = apkMirrorIconUrlFromFeedXml(chosenBlock);
    } else {
      final parsedItems = (await parseHtmlOffIsolate(res.body))
          .querySelectorAll('item');
      for (int scanIndex = 0; scanIndex < parsedItems.length; scanIndex++) {
        collectReleaseTitleCandidate(
          parsedItems[scanIndex].querySelector('title')?.innerHtml,
        );
      }
      int chosenParsedItemIndex = -1;
      int tooYoungParsedItemIndex = -1;
      int releaseSkipped = 0;
      for (int itemIndex = 0; itemIndex < parsedItems.length; itemIndex++) {
        // Releases skipped as too young don't count as the latest one.
        if (!fallbackToOlderReleases && itemIndex > releaseSkipped) break;
        final nameToFilter = parsedItems[itemIndex]
            .querySelector('title')
            ?.innerHtml;
        if (regexFilter != null &&
            nameToFilter != null &&
            !passesRegExFilter(
              RegExp(regexFilter),
              nameToFilter.trim(),
              invert: invertTitleFilter,
            )) {
          continue;
        }
        if (isReleaseTooYoung(
          _apkMirrorPubDate(
            parsedItems[itemIndex].querySelector('pubDate')?.innerHtml,
          ),
          minAgeDays,
        )) {
          if (tooYoungParsedItemIndex < 0) tooYoungParsedItemIndex = itemIndex;
          releaseSkipped++;
          continue;
        }
        chosenParsedItemIndex = itemIndex;
        break;
      }
      // No release old enough: use the newest so the provider can suppress
      // it until it ages.
      if (chosenParsedItemIndex < 0) {
        chosenParsedItemIndex = tooYoungParsedItemIndex;
      }
      if (chosenParsedItemIndex < 0) {
        throw NoReleasesError(
          note: regexFilter != null ? tr('noMatchingReleaseFound') : null,
        );
      }
      final targetRelease = parsedItems[chosenParsedItemIndex];
      titleString = targetRelease.querySelector('title')?.innerHtml;
      releaseDate = _apkMirrorPubDate(
        targetRelease.querySelector('pubDate')?.innerHtml,
      );
      releasePageUrl = releaseUrlFromApkMirrorFeedBodyForItemIndex(
        res.body,
        chosenParsedItemIndex,
      );
    }
    if (releasePageUrl != null && !releasePageUrl.startsWith('$standardUrl/')) {
      releasePageUrl = null;
    }
    if (releasePageUrl != null) {
      releasePageUrl = _apkMirrorWithTrailingSlash(releasePageUrl);
    }
    String? version = apkMirrorVersionFromTitle(titleString);
    if (version == null || version.isEmpty) {
      version = titleString;
    }
    if (version == null || version.isEmpty) {
      throw NoVersionError();
    }

    // The icon and, for newer icons, the package come from the feed itself.
    // The listing page used to be fetched on every check for the icon (feed
    // + 301 + listing HTML per app), which APKMirror's admin flagged (#339);
    // it's now read only when an app is added and its icon is hash-only
    // ([tryInferringAppId]).
    iconUrl ??= apkMirrorIconUrlFromFeedXml(res.body);

    // [apkSizeBytes] is intentionally not resolved here. The APKMirror size
    // walk is expensive (1 release page + 1 GET per download candidate, per
    // app, per refresh) and the result is only ever shown as " · 43 MB" on
    // the AppPage. It is therefore resolved lazily by AppPage on first
    // open via [resolveLatestApkSizeBytes], and persisted onto the App via
    // [AppsProvider.saveApps] so subsequent opens hit the in-memory copy.
    return APKDetails(
      version,
      [],
      getAppNames(standardUrl),
      releaseDate: releaseDate,
      changeLog: releasePageUrl,
      iconUrl: iconUrl,
      appId: apkMirrorPackageFromIconUrl(iconUrl),
      rawReleaseTitleCandidates: rawReleaseTitleCandidates,
      releaseTitle: titleString,
    );
  }

  AppNames getAppNames(String standardUrl) {
    final String temp = standardUrl.substring(standardUrl.indexOf('://') + 3);
    final pathStart = temp.indexOf('/');
    if (pathStart < 0 || pathStart + 1 >= temp.length) {
      throw InvalidURLError(name);
    }
    final List<String> names = temp.substring(pathStart + 1).split('/');
    if (names.length < 3) throw InvalidURLError(name);
    return AppNames(names[1], names[2]);
  }

  /// Lazy resolver: walks the release page → ranked download pages → picks
  /// the smallest non-bundle APK and returns its size in bytes. The result
  /// is intended to be persisted onto the app's [App.apkSizeBytes] and
  /// stays valid until [App.latestVersion] changes - at which point
  /// [SourceProvider.getApp] clears the size and the next AppPage open
  /// re-runs this walk.
  ///
  /// Returns null when:
  /// - [releasePageUrl] is null or empty (e.g. older app records that
  ///   haven't run an update check since the new schema landed),
  /// - the release page returns non-200,
  /// - none of the download candidates resolve a size, or
  /// - any HTTP error along the walk surfaces (caught and logged).
  ///
  /// Honors the same per-app filtering as the install path
  /// (`apkFilterRegEx`, `invertAPKFilter`, `autoApkFilterByArch`) so the
  /// reported size matches what the user would actually download.
  ///
  /// Walks each release at most once per [listingKey] (see [_sizeWalks]);
  /// later calls get the first walk's result. The exception is a walk the
  /// request gate stopped before anything was sent (a page challenge is still
  /// blocking): that one may run again once the block is over.
  Future<int?> resolveLatestApkSizeBytes({
    required String? releasePageUrl,
    required Map<String, dynamic> additionalSettings,
    String? listingKey,
  }) {
    if (releasePageUrl == null || releasePageUrl.isEmpty) {
      return Future.value(null);
    }
    final String walkKey = '${listingKey ?? ''}|$releasePageUrl';
    final Future<int?>? previousWalk = _sizeWalks[walkKey];
    if (previousWalk != null) return previousWalk;
    return _sizeWalks[walkKey] = _walkLatestApkSize(
      _apkMirrorWithTrailingSlash(releasePageUrl),
      additionalSettings,
      onNothingSent: () => _sizeWalks.remove(walkKey),
    );
  }

  Future<int?> _walkLatestApkSize(
    String releasePageUrl,
    Map<String, dynamic> additionalSettings, {
    required void Function() onNothingSent,
  }) async {
    try {
      final Response releasePageResponse;
      try {
        releasePageResponse = await sourceRequest(
          releasePageUrl,
          additionalSettings,
        );
      } on RateLimitError {
        onNothingSent();
        rethrow;
      }
      await _logApkMirrorSizeDebug(
        'lazy release page status=${releasePageResponse.statusCode} bytes=${releasePageResponse.body.length} url=$releasePageUrl',
      );
      if (releasePageResponse.statusCode != 200) {
        return null;
      }
      // Best-effort: a release page often lists the picked APK's size
      // directly without us having to walk the per-variant download pages.
      final int? releasePageSize =
          await apkSizeBytesFromApkMirrorReleasePageHtml(
            releasePageResponse.body,
          );
      final downloadPageEntries =
          await _apkMirrorDownloadPageUrlEntriesFromReleasePageHtml(
            releasePageResponse.body,
            releasePageUrl,
          );
      final filteredEntries = await _filterApkMirrorDownloadPageEntries(
        downloadPageEntries,
        additionalSettings,
      );
      // No actual download links on the release page → only what we found
      // textually counts. We DO NOT fall back to URL-pattern guessing -
      // that path made up to 20 speculative HTTP requests per app per
      // refresh and the success rate was abysmal.
      if (filteredEntries.isEmpty) {
        return releasePageSize;
      }
      final List<_ApkMirrorSizeCandidate> sizeCandidates = [];
      for (final candidateDownloadPageEntry in filteredEntries) {
        final downloadPageResponse = await sourceRequest(
          candidateDownloadPageEntry.value,
          additionalSettings,
        );
        if (downloadPageResponse.statusCode != 200) {
          continue;
        }
        final candidateSize = await apkSizeBytesFromApkMirrorReleasePageHtml(
          downloadPageResponse.body,
        );
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
      final filteredSizeCandidates = await _filterApkMirrorSizeCandidates(
        sizeCandidates,
        additionalSettings,
      );
      final pickedSizeCandidate = _pickApkMirrorSizeCandidate(
        filteredSizeCandidates,
      );
      if (pickedSizeCandidate != null) {
        await _logApkMirrorSizeDebug(
          'lazy picked bundle=${pickedSizeCandidate.isBundle} size=${pickedSizeCandidate.sizeBytes} key=${pickedSizeCandidate.key} url=${pickedSizeCandidate.url}',
        );
        return pickedSizeCandidate.sizeBytes;
      }
      return releasePageSize;
    } catch (error) {
      await _logApkMirrorSizeDebug('lazy resolver error=${error.toString()}');
      return null;
    }
  }
}
