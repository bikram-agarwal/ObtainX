import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:html/dom.dart' show Document;
import 'package:http/http.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/html_parse_isolate.dart';
import 'package:obtainium/utils/string_compare.dart';
import 'package:obtainium/version/partial_download_version.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:obtainium/utils/string_compare.dart' show compareAlphaNumeric;

final _releaseFileExtension = RegExp(
  r'\.(?:apk|xapk|apks|zip|tar(?:\.gz)?)$',
  caseSensitive: false,
);
int compareReleaseNames(String first, String second) {
  final decision = compareVersionStrings(
    first.replaceFirst(_releaseFileExtension, ''),
    second.replaceFirst(_releaseFileExtension, ''),
  );
  return decision.comparison ?? compareAlphaNumeric(first, second);
}

List<String> collectAllStringsFromJSONObject(dynamic obj) {
  List<String> extractor(dynamic obj) {
    final results = <String>[];
    if (obj is String) {
      results.add(obj);
    } else if (obj is List) {
      for (final item in obj) {
        results.addAll(extractor(item));
      }
    } else if (obj is Map<String, dynamic>) {
      for (final value in obj.values) {
        results.addAll(extractor(value));
      }
    }

    return results;
  }

  return extractor(obj);
}

List<MapEntry<String, String>> getLinksInLines(String lines) =>
    // Quotes, brackets and angle brackets end a URL found in raw text or code,
    // and trailing punctuation belongs to the text around it (upstream #2816).
    RegExp(r'''(?:(?:http|https|ftp)://)[^\s"'<>()\[\]{}]+''')
        .allMatches(lines)
        .map((match) => match.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), ''))
        .where((url) => url.isNotEmpty)
        .map((url) => MapEntry(url, url.split('/').last))
        .toList();

/// Collects absolute and root-relative URLs found in element attributes
/// (e.g. `<script src="/js/app.js">`), resolved against [reqUrl] (#3294).
List<MapEntry<String, String>> getLinksInHtmlAttributes(
  Document html,
  Uri reqUrl,
) {
  final links = <MapEntry<String, String>>[];
  final absoluteUrlPattern = RegExp(r'^(https?|ftp)://', caseSensitive: false);
  for (final element in html.querySelectorAll('*')) {
    for (final value in element.attributes.values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      if (!absoluteUrlPattern.hasMatch(trimmed) && !trimmed.startsWith('/')) {
        continue;
      }
      final resolved = ensureAbsoluteUrl(trimmed, reqUrl);
      final uri = Uri.tryParse(resolved);
      if (uri == null ||
          !['http', 'https', 'ftp'].contains(uri.scheme.toLowerCase())) {
        continue;
      }
      links.add(MapEntry(resolved, resolved.split('/').last));
    }
  }
  return links;
}

/// Given an HTTP response, grab some links according to the common additional settings
/// (those that apply to intermediate and final steps)
Future<List<MapEntry<String, String>>> grabLinksCommonFromRes(
  Response res,
  Map<String, dynamic> additionalSettings,
) async {
  ensureHttpSuccess(res);
  final reqUrl = res.request?.url ?? Uri.parse('');
  return grabLinksCommon(res.body, reqUrl, additionalSettings);
}

/// Note: keys are URLs, values are filenames (opposite to the AppSource apkUrls)
Future<List<MapEntry<String, String>>> grabLinksCommon(
  String rawBody,
  Uri reqUrl,
  Map<String, dynamic> additionalSettings,
) async {
  final bool matchLinksOutsideATags =
      additionalSettings['matchLinksOutsideATags'] == true;
  final html = await parseHtmlOffIsolate(rawBody);
  List<MapEntry<String, String>> allLinks = html
      .querySelectorAll('a')
      .map(
        (element) => MapEntry(
          element.attributes['href'] ?? '',
          element.text.isNotEmpty
              ? element.text
              : (element.attributes['href'] ?? '').split('/').last,
        ),
      )
      .where((element) => element.key.isNotEmpty)
      .map((e) => MapEntry(ensureAbsoluteUrl(e.key, reqUrl), e.value))
      .toList();
  if (allLinks.isEmpty || matchLinksOutsideATags) {
    // Merge every link source instead of replacing one set with another:
    // <a> links, URLs in the raw text and URLs in element attributes are all
    // valid candidates when [matchLinksOutsideATags] is enabled (#2816).
    final merged = <String, MapEntry<String, String>>{
      for (final link in allLinks) link.key: link,
    };
    void addAll(Iterable<MapEntry<String, String>> links) {
      for (final link in links) {
        merged.putIfAbsent(link.key, () => link);
      }
    }

    if (allLinks.isEmpty) {
      // Decode the body if the response is a JSON
      try {
        final jsonStrings = collectAllStringsFromJSONObject(
          jsonDecode(rawBody),
        );
        var jsonLinks = getLinksInLines(jsonStrings.join('\n'));
        if (jsonLinks.isEmpty) {
          jsonLinks = getLinksInLines(
            jsonStrings
                .map((l) {
                  return ensureAbsoluteUrl(l, reqUrl);
                })
                .join('\n'),
          );
        }
        addAll(jsonLinks);
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to parse HTML links: ${e.toString()}',
            level: LogLevel.warning,
          ),
        );
        addAll(getLinksInLines(rawBody));
      }
    }
    if (matchLinksOutsideATags) {
      addAll(getLinksInLines(rawBody));
      addAll(getLinksInHtmlAttributes(html, reqUrl));
    }
    allLinks = merged.values.toList();
  }
  List<MapEntry<String, String>> links = [];
  final bool skipSort = additionalSettings['skipSort'] == true;
  final bool filterLinkByText = additionalSettings['filterByLinkText'] == true;
  if ((additionalSettings['customLinkFilterRegex'] as String?)?.isNotEmpty ==
      true) {
    final reg = RegExp(additionalSettings['customLinkFilterRegex']);
    links = allLinks.where((element) {
      var link = element.key;
      try {
        link = Uri.decodeFull(element.key);
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to decode URI in HTML filter: ${e.toString()}',
            level: LogLevel.debug,
          ),
        );
      }
      return reg.hasMatch(filterLinkByText ? element.value : link);
    }).toList();
  } else {
    links = allLinks.where((element) {
      var link = element.key;
      try {
        link = Uri.decodeFull(element.key);
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to decode URI in HTML APK filter: ${e.toString()}',
            level: LogLevel.debug,
          ),
        );
      }
      return AppSource.isApkOrContainerFile(
        Uri.parse((filterLinkByText ? element.value : link).trim()).path,
        // Off by default because most pages link a source zip next to the APK;
        // on, it reaches the CI-artifact hosts that only ever serve zips.
        includeArchives: additionalSettings['includeZips'] == true,
      );
    }).toList();
  }
  if (!skipSort) {
    final names = {
      for (final link in links)
        link.key: additionalSettings['sortByLastLinkSegment'] == true
            ? link.key.split('/').where((segment) => segment.isNotEmpty).last
            : link.key,
    };
    final useVersionOrder = versionsHaveConsistentOrder(
      names.values.map((name) => name.replaceFirst(_releaseFileExtension, '')),
    );
    links.sort(
      (first, second) => useVersionOrder
          ? compareReleaseNames(names[first.key]!, names[second.key]!)
          : compareAlphaNumeric(names[first.key]!, names[second.key]!),
    );
  }
  if (additionalSettings['reverseSort'] == true) {
    links = links.reversed.toList();
  }
  return links;
}

String resolveHtmlAssetDisplayName({
  required String downloadUrl,
  required String version,
  String? appName,
  String? linkLabel,
  DownloadResponseMetadata? responseMetadata,
}) {
  final String? responseFileName = responseMetadata?.suggestedFileName;
  if (responseFileName != null) {
    return responseFileName;
  }

  final Uri? finalUri = responseMetadata?.finalUri;
  if (finalUri != null && finalUri.pathSegments.isNotEmpty) {
    final String? finalUrlFileName = sanitizeDownloadFileName(
      finalUri.pathSegments.last,
    );
    if (finalUrlFileName != null &&
        AppSource.isApkOrContainerFile(
          finalUrlFileName,
          includeArchives: true,
          includeTarballs: true,
        )) {
      return finalUrlFileName;
    }
  }

  final Uri downloadUri = Uri.parse(downloadUrl);
  if (downloadUri.pathSegments.isNotEmpty) {
    final String? downloadUrlFileName = sanitizeDownloadFileName(
      downloadUri.pathSegments.last,
    );
    if (downloadUrlFileName != null &&
        AppSource.isApkOrContainerFile(
          downloadUrlFileName,
          includeArchives: true,
          includeTarballs: true,
        )) {
      return downloadUrlFileName;
    }
  }

  final String? sanitizedLinkLabel = sanitizeDownloadFileName(linkLabel);
  if (sanitizedLinkLabel != null &&
      AppSource.isApkOrContainerFile(
        sanitizedLinkLabel,
        includeArchives: true,
        includeTarballs: true,
      )) {
    return sanitizedLinkLabel;
  }

  final String? sanitizedAppName = sanitizeDownloadFileName(appName);
  final String? sanitizedVersion = sanitizeDownloadFileName(version);
  if (sanitizedAppName != null && sanitizedVersion != null) {
    return '$sanitizedAppName-$sanitizedVersion.apk';
  }

  final String fallbackName = downloadUri.pathSegments.isNotEmpty
      ? downloadUri.pathSegments.last
      : downloadUri.origin;
  return '${downloadUrl.hashCode}-$fallbackName';
}

class HTML extends AppSource {
  @override
  List<List<GeneratedFormItem>> get combinedAppSpecificSettingFormItems {
    return super.combinedAppSpecificSettingFormItems.map((r) {
      return r.map((e) {
        if (e.key == 'versionExtractionRegEx') {
          e.label = tr('versionExtractionRegEx');
        }
        if (e.key == 'matchGroupToUse') {
          e.label = tr('matchGroupToUse');
        }
        return e;
      }).toList();
    }).toList();
  }

  List<List<GeneratedFormItem>> get _finalStepFormitems => [
    [
      GeneratedFormTextField(
        'customLinkFilterRegex',
        label: tr('customLinkFilterRegex'),
        hint: 'download/(.*/)?(android|apk|mobile)',
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
        'versionExtractWholePage',
        label: tr('versionExtractWholePage'),
      ),
    ],
  ];

  List<List<GeneratedFormItem>> get _commonFormItems => [
    [GeneratedFormSwitch('filterByLinkText', label: tr('filterByLinkText'))],
    [
      GeneratedFormSwitch(
        'matchLinksOutsideATags',
        label: tr('matchLinksOutsideATags'),
      ),
    ],
    [GeneratedFormSwitch('skipSort', label: tr('skipSort'))],
    [GeneratedFormSwitch('reverseSort', label: tr('takeFirstLink'))],
    [
      GeneratedFormSwitch(
        'sortByLastLinkSegment',
        label: tr('sortByLastLinkSegment'),
      ),
    ],
  ];

  List<List<GeneratedFormItem>> get _intermediateFormItems => [
    [
      GeneratedFormTextField(
        'customLinkFilterRegex',
        label: tr('intermediateLinkRegex'),
        hint: '([0-9]+.)*[0-9]+/\$',
        required: true,
        additionalValidators: [(value) => regExValidator(value)],
      ),
    ],
    [
      GeneratedFormSwitch(
        'autoLinkFilterByArch',
        label: tr('autoLinkFilterByArch'),
        value: false,
      ),
    ],
  ];

  HTML() {
    name = 'HTML';
    suppressStandardVersionExtraction = true;
    // A zip is the only way some hosts can serve a build: GitHub Actions
    // artifacts are auth-walled, so re-hosters like nightly.link hand out
    // `<artifact>.zip`. The download side already unpacks one and installs the
    // APK inside, so only the link filter and these options were missing.
    allowIncludeZips = true;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    [
      GeneratedFormSubForm('intermediateLink', [
        ..._intermediateFormItems,
        ..._commonFormItems,
      ], label: tr('intermediateLink')),
    ],
    _finalStepFormitems[0],
    ..._commonFormItems,
    ..._finalStepFormitems.sublist(1),
    [
      GeneratedFormSubForm(
        'requestHeader',
        [
          [
            GeneratedFormTextField(
              'requestHeader',
              label: tr('requestHeader'),
              required: false,
              additionalValidators: [
                (value) {
                  if ((value ?? 'empty:valid')
                          .split(':')
                          .map((e) => e.trim())
                          .where((e) => e.isNotEmpty)
                          .length <
                      2) {
                    return tr('invalidInput');
                  }
                  return null;
                },
              ],
            ),
          ],
        ],
        label: tr('requestHeader'),
        value: [
          {
            'requestHeader':
                'User-Agent: Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36',
          },
        ],
      ),
    ],
    [
      GeneratedFormDropdown(
        'defaultPseudoVersioningMethod',
        [
          MapEntry('partialAPKHash', tr('partialAPKHash')),
          MapEntry('APKLinkHash', tr('APKLinkHash')),
          const MapEntry('ETag', 'ETag'),
        ],
        label: tr('defaultPseudoVersioningMethod'),
        value: 'partialAPKHash',
      ),
    ],
  ];

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    if (additionalSettings.isEmpty) {
      return null;
    }
    final settings = Map<String, dynamic>.from(additionalSettings);
    if (settings['requestHeader'] is! List ||
        (settings['requestHeader'] as List).isEmpty) {
      settings['requestHeader'] = [];
    }
    final headers = (settings['requestHeader'] as List)
        .where((l) => (l['requestHeader'] as String?)?.isNotEmpty == true)
        .toList();
    final Map<String, String> requestHeaders = {};
    for (int i = 0; i < headers.length; i++) {
      final temp = (headers[i]['requestHeader'] as String).split(':');
      requestHeaders[temp[0].trim()] = temp.sublist(1).join(':').trim();
    }
    return requestHeaders;
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    return url;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      var currentUrl = standardUrl;
      final intermediateLinks =
          ((additionalSettings['intermediateLink'] as List?) ?? <dynamic>[])
              .where(
                (l) =>
                    (l['customLinkFilterRegex'] as String?)?.isNotEmpty == true,
              )
              .toList();
      const int maxIntermediateLinkDepth = 10;
      final int linkCount = intermediateLinks.length.clamp(
        0,
        maxIntermediateLinkDepth,
      );
      for (int i = 0; i < linkCount; i++) {
        var intLinks = await grabLinksCommonFromRes(
          await sourceRequest(currentUrl, additionalSettings),
          intermediateLinks[i],
        );
        // Filter by architecture before the empty check, so filtering away
        // every link reports no release instead of failing on `.last`.
        if (intermediateLinks[i]['autoLinkFilterByArch'] == true) {
          intLinks = await filterApksByArch(intLinks);
        }
        if (intLinks.isEmpty) {
          throw NoReleasesError(note: currentUrl);
        } else {
          currentUrl = intLinks.last.key;
        }
      }
      final uri = Uri.parse(currentUrl);
      List<MapEntry<String, String>> links = [];
      String versionExtractionWholePageString = currentUrl;
      if (additionalSettings['directAPKLink'] != true) {
        final Response res = await sourceRequest(
          currentUrl,
          additionalSettings,
        );
        versionExtractionWholePageString = res.body
            .split('\r\n')
            .join('\n')
            .split('\n')
            .join('\\n');
        links = await grabLinksCommonFromRes(res, additionalSettings);
        links = filterApks(
          links,
          additionalSettings['apkFilterRegEx'],
          additionalSettings['invertAPKFilter'],
        );
        if (links.isEmpty) {
          throw NoReleasesError(note: currentUrl);
        }
      } else {
        links = [MapEntry(currentUrl, currentUrl)];
      }
      final MapEntry<String, String> selectedLink = links.last;
      final String rel = selectedLink.key;
      var relDecoded = rel;
      try {
        relDecoded = Uri.decodeFull(rel);
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to decode URI for version extraction: ${e.toString()}',
            level: LogLevel.debug,
          ),
        );
      }
      String? version;
      version = extractVersion(
        additionalSettings['versionExtractionRegEx'] as String?,
        additionalSettings['matchGroupToUse'] as String?,
        additionalSettings['versionExtractWholePage'] == true
            ? versionExtractionWholePageString
            : relDecoded,
      );
      final apkReqHeaders = await getRequestHeaders(
        additionalSettings,
        rel,
        forAPKDownload: true,
      );
      // Read when a probe runs, not before: a page that names its version
      // needs no settings. Only a stored value is read, so skip
      // SettingsProvider's one-time init.
      Future<bool> readCertificatePinning() async =>
          (SettingsProvider()..prefs = await SharedPreferences.getInstance())
              .enableCertificatePinning;
      DownloadResponseMetadata? downloadMetadata;
      void captureDownloadMetadata(DownloadResponseMetadata metadata) {
        downloadMetadata ??= metadata;
      }

      if (version == null &&
          additionalSettings['defaultPseudoVersioningMethod'] == 'ETag') {
        version = await checkETagHeader(
          rel,
          headers: apkReqHeaders,
          allowInsecure: additionalSettings['allowInsecure'] == true,
          certificatePinning: await readCertificatePinning(),
          onResponseMetadata: captureDownloadMetadata,
        );
        if (version == null || version.isEmpty) {
          throw NoVersionError();
        }
      }
      if (version == null) {
        if (additionalSettings['defaultPseudoVersioningMethod'] ==
            'APKLinkHash') {
          version = rel.hashCode.toString();
          additionalSettings.remove(partialDownloadFingerprintKey);
        } else {
          final saved = additionalSettings[partialDownloadFingerprintKey];
          final savedFingerprint = saved is Map && saved['url'] == rel
              ? saved['fingerprint']
              : null;
          final parsedSize = savedFingerprint is String
              ? int.tryParse(
                  savedFingerprint.split(':').elementAtOrNull(1) ?? '',
                )
              : null;
          final savedSize =
              parsedSize != null && parsedSize >= 128 && parsedSize <= 1024
              ? parsedSize
              : null;
          final fingerprint = await checkPartialDownloadHashDynamic(
            rel,
            // Keep an established prefix size. Shrinking an unstable response
            // would change the fingerprint even if the APK had not changed.
            startingSize: savedSize ?? 1024,
            lowerLimit: savedSize ?? 128,
            headers: apkReqHeaders,
            allowInsecure: additionalSettings['allowInsecure'] == true,
            certificatePinning: await readCertificatePinning(),
            onResponseMetadata: captureDownloadMetadata,
          );
          version = resolvePartialDownloadVersion(
            fingerprint: fingerprint,
            downloadUrl: rel,
            settings: additionalSettings,
            previousVersion:
                previouslyCheckedApp?.rawLatestVersionFromSource ??
                previouslyCheckedApp?.latestVersion,
            samePreviousDownload:
                previouslyCheckedApp?.apkUrls.any(
                      (asset) => asset.value == rel,
                    ) ==
                    true &&
                previouslyCheckedApp
                        ?.additionalSettings['defaultPseudoVersioningMethod'] ==
                    additionalSettings['defaultPseudoVersioningMethod'],
          );
        }
      } else {
        additionalSettings.remove(partialDownloadFingerprintKey);
      }
      final bool ambiguousDownloadUrl = !AppSource.isApkOrContainerFile(
        Uri.parse(rel).path,
        includeArchives: true,
        includeTarballs: true,
      );
      String? cachedDisplayName;
      if (ambiguousDownloadUrl &&
          previouslyCheckedApp?.latestVersion == version) {
        final String legacyDisplayName = resolveHtmlAssetDisplayName(
          downloadUrl: rel,
          version: version,
        );
        for (final MapEntry<String, String> apkUrl
            in previouslyCheckedApp!.apkUrls) {
          if (apkUrl.value == rel &&
              apkUrl.key.isNotEmpty &&
              apkUrl.key != legacyDisplayName) {
            cachedDisplayName = apkUrl.key;
            break;
          }
        }
      }
      if (ambiguousDownloadUrl &&
          downloadMetadata == null &&
          cachedDisplayName == null) {
        try {
          downloadMetadata = await probeDownloadResponseMetadata(
            rel,
            headers: apkReqHeaders,
            allowInsecure: additionalSettings['allowInsecure'] == true,
            certificatePinning: await readCertificatePinning(),
          );
        } catch (error) {
          unawaited(
            LogsProvider().add(
              'Failed to resolve HTML download filename: $error',
              level: LogLevel.debug,
            ),
          );
        }
      }
      final String assetDisplayName =
          cachedDisplayName ??
          resolveHtmlAssetDisplayName(
            downloadUrl: rel,
            version: version,
            appName: previouslyCheckedApp?.finalName,
            linkLabel: selectedLink.value,
            responseMetadata: downloadMetadata,
          );
      return APKDetails(version, [
        MapEntry(assetDisplayName, rel),
      ], AppNames(uri.host, tr('app')));
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }
}
