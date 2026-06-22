import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/html_parse_isolate.dart';

String? _yamlScalarValue(Iterable<String> lines, String key) {
  final String prefix = '$key:';
  for (final String line in lines) {
    final String trimmed = line.trim();
    if (!trimmed.startsWith(prefix)) {
      continue;
    }
    return _stripYamlScalarQuotes(trimmed.substring(prefix.length).trim());
  }
  return null;
}

String _stripYamlScalarQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

String? _fdroidDisplayString(Object? rawValue) {
  if (rawValue is String) {
    final String trimmed = rawValue.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (rawValue is Map) {
    for (final String localeKey in const <String>['en-US', 'en']) {
      final String? localized = _fdroidDisplayString(rawValue[localeKey]);
      if (localized != null) {
        return localized;
      }
    }
    for (final Object? value in rawValue.values) {
      final String? localized = _fdroidDisplayString(value);
      if (localized != null) {
        return localized;
      }
    }
  }
  return null;
}

String? _fdroidDisplayNameFromHtml(String html) {
  for (final RegExp pattern in <RegExp>[
    RegExp(
      r'''<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']''',
      caseSensitive: false,
    ),
    RegExp(
      r'<title[^>]*>([^<]+)</title>',
      caseSensitive: false,
      multiLine: true,
    ),
  ]) {
    final RegExpMatch? match = pattern.firstMatch(html);
    final String? title = match?.group(1)?.trim();
    if (title?.isNotEmpty == true) {
      final String displayName = title!.split('|').first.trim();
      if (displayName.isNotEmpty) {
        return displayName;
      }
    }
  }
  return null;
}

class FDroid extends AppSource {
  FDroid() {
    hosts = ['f-droid.org'];
    name = tr('fdroid');
    naiveStandardVersionDetection = true;
    canSearch = true;
    additionalSourceAppSpecificSettingFormItems = [
      [
        GeneratedFormTextField(
          'filterVersionsByRegEx',
          label: tr('filterVersionsByRegEx'),
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
          'trySelectingSuggestedVersionCode',
          label: tr('trySelectingSuggestedVersionCode'),
          defaultValue: true,
        ),
      ],
      [
        GeneratedFormSwitch(
          'autoSelectHighestVersionCode',
          label: tr('autoSelectHighestVersionCode'),
        ),
      ],
      [
        GeneratedFormSwitch(
          'enforceReproducibleBuilds',
          label: tr('enforceReproducibleBuilds'),
          labelTooltip: tr('reproducibleBuildsTooltip'),
          defaultValue: false,
        ),
      ],
    ];
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    RegExp standardUrlRegExB = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}/+[^/]+/+packages/+[^/]+',
      caseSensitive: false,
    );
    RegExpMatch? match = standardUrlRegExB.firstMatch(url);
    if (match != null) {
      url =
          'https://${Uri.parse(match.group(0)!).host}/packages/${Uri.parse(url).pathSegments.where((s) => s.trim().isNotEmpty).last}';
    }
    RegExp standardUrlRegExA = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}/+packages/+[^/]+',
      caseSensitive: false,
    );
    match = standardUrlRegExA.firstMatch(url);
    if (match == null) {
      throw InvalidURLError(name);
    }
    return match.group(0)!;
  }

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    return Uri.parse(standardUrl).pathSegments.last;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    String? appId = await tryInferringAppId(standardUrl);
    String host = Uri.parse(standardUrl).host;
    var details = await getAPKUrlsFromFDroidPackagesAPIResponse(
      await sourceRequest(
        'https://$host/api/v1/packages/$appId',
        additionalSettings,
      ),
      'https://$host/repo/$appId',
      standardUrl,
      name,
      additionalSettings: additionalSettings,
    );
    final bool canUseOfficialMetadata =
        !hostChanged ||
        hostIdenticalDespiteAnyChange ||
        host == 'f-droid.org' ||
        host == 'www.f-droid.org';
    // Skip the per-refresh fdroiddata metadata YAML fetch (gitlab.com) only when
    // the upstream release is unchanged AND the cached verdict is the terminal
    // 'verified' state. An F-Droid build's reproducible status can flip from
    // no_data / not_reproducible to verified hours after a release WITHOUT a
    // versionCode change (the reproducible-build verification completes after
    // the initial publish). So every non-verified status must keep re-checking
    // to catch that flip; only 'verified' (which does not revert) is reused.
    // This is never worse than always fetching, and saves the call for the
    // already-verified majority.
    final App? prevApp = previouslyCheckedApp;
    final bool canReuseCachedMetadata =
        prevApp != null &&
        prevApp.rawLatestVersionFromSource != null &&
        prevApp.rawLatestVersionFromSource == details.version &&
        prevApp.latestReproducibleStatus == reproducibleBuildStatusVerified;
    if (canUseOfficialMetadata && canReuseCachedMetadata) {
      details.reproducibleStatus = prevApp.latestReproducibleStatus;
      details.isReproducible = reproducibleBuildBoolFromStatus(
        prevApp.latestReproducibleStatus,
      );
      if (prevApp.changeLog?.isNotEmpty == true) {
        details.changeLog = prevApp.changeLog;
      }
      if (prevApp.author.trim().isNotEmpty) {
        details.names.author = prevApp.author;
      }
    } else if (canUseOfficialMetadata) {
      try {
        var res = await sourceRequest(
          'https://gitlab.com/fdroid/fdroiddata/-/raw/master/metadata/$appId.yml',
          additionalSettings,
        );
        if (res.statusCode != 200 &&
            details.reproducibleStatus != reproducibleBuildStatusVerified) {
          details.reproducibleStatus = reproducibleBuildStatusError;
          details.isReproducible = null;
        }
        if (res.statusCode == 200) {
          var lines = res.body.split('\n');
          final String? authorName = _yamlScalarValue(lines, 'AuthorName');
          if (authorName?.isNotEmpty == true) {
            details.names.author = authorName!;
          }

          final String? displayName =
              _yamlScalarValue(lines, 'Name') ??
              _yamlScalarValue(lines, 'AutoName');
          if (displayName?.isNotEmpty == true) {
            details.names.name = displayName!;
          }

          final bool hasBinaries =
              _yamlScalarValue(lines, 'Binaries')?.isNotEmpty == true;
          details.reproducibleStatus = hasBinaries
              ? reproducibleBuildStatusVerified
              : reproducibleBuildStatusNoData;
          details.isReproducible = reproducibleBuildBoolFromStatus(
            details.reproducibleStatus,
          );

          final String? changelogUrl = _yamlScalarValue(lines, 'Changelog');
          if (changelogUrl?.isNotEmpty == true) {
            details.changeLog = changelogUrl!;
            bool isGitHub = false;
            bool isGitLab = false;
            try {
              GitHub(
                hostChanged: true,
              ).sourceSpecificStandardizeURL(details.changeLog!);
              isGitHub = true;
            } catch (e) {
              //
            }
            try {
              GitLab(
                hostChanged: true,
              ).sourceSpecificStandardizeURL(details.changeLog!);
              isGitLab = true;
            } catch (e) {
              //
            }
            if ((isGitHub || isGitLab) &&
                (details.changeLog?.indexOf('/blob/') ?? -1) >= 0) {
              details.changeLog = (await sourceRequest(
                details.changeLog!.replaceFirst('/blob/', '/raw/'),
                additionalSettings,
              )).body;
            }
          }
        }
      } catch (e) {
        if (details.reproducibleStatus != reproducibleBuildStatusVerified) {
          details.reproducibleStatus = reproducibleBuildStatusError;
          details.isReproducible = null;
        }
      }
      if ((details.changeLog?.length ?? 0) > 2048) {
        details.changeLog = '${details.changeLog!.substring(0, 2048)}...';
      }
    }
    return details;
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    Response res = await sourceRequest(
      'https://search.${hosts[0]}/?q=${Uri.encodeQueryComponent(query)}',
      {},
    );
    if (res.statusCode == 200) {
      Map<String, List<String>> urlsWithDescriptions = {};
      (await parseHtmlOffIsolate(
        res.body,
      )).querySelectorAll('.package-header').forEach((e) {
        String? url = e.attributes['href'];
        if (url != null) {
          try {
            standardizeUrl(url);
          } catch (e) {
            url = null;
          }
        }
        if (url != null) {
          urlsWithDescriptions[url] = [
            e.querySelector('.package-name')?.text.trim() ?? '',
            e.querySelector('.package-summary')?.text.trim() ??
                tr('noDescription'),
          ];
        }
      });
      return urlsWithDescriptions;
    } else {
      throw getObtainiumHttpError(res);
    }
  }

  Future<APKDetails> getAPKUrlsFromFDroidPackagesAPIResponse(
    Response res,
    String apkUrlPrefix,
    String standardUrl,
    String sourceName, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    var autoSelectHighestVersionCode =
        additionalSettings['autoSelectHighestVersionCode'] == true;
    var trySelectingSuggestedVersionCode =
        additionalSettings['trySelectingSuggestedVersionCode'] == true;
    var filterVersionsByRegEx =
        (additionalSettings['filterVersionsByRegEx'] as String?)?.isNotEmpty ==
            true
        ? additionalSettings['filterVersionsByRegEx']
        : null;
    var apkFilterRegEx =
        (additionalSettings['apkFilterRegEx'] as String?)?.isNotEmpty == true
        ? additionalSettings['apkFilterRegEx']
        : null;
    if (res.statusCode == 200) {
      var response = jsonDecode(res.body);
      List<dynamic> releases = response['packages'] ?? [];
      if (apkFilterRegEx != null) {
        releases = releases.where((rel) {
          String apk = '${apkUrlPrefix}_${rel['versionCode']}.apk';
          return filterApks(
            [MapEntry(apk, apk)],
            apkFilterRegEx,
            false,
          ).isNotEmpty;
        }).toList();
      }
      if (releases.isEmpty) {
        throw NoReleasesError();
      }
      final List<String> rawVersionNameCandidates = <String>[];
      for (final release in releases) {
        final String? versionName = release['versionName']?.toString().trim();
        if (versionName == null ||
            versionName.isEmpty ||
            rawVersionNameCandidates.contains(versionName)) {
          continue;
        }
        rawVersionNameCandidates.add(versionName);
      }
      String? version;
      Iterable<dynamic> releaseChoices = [];
      // Grab the versionCode suggested if the user chose to do that
      // Only do so at this stage if the user has no release filter
      if (trySelectingSuggestedVersionCode &&
          response['suggestedVersionCode'] != null &&
          filterVersionsByRegEx == null) {
        final String suggestedVersionCodeText = response['suggestedVersionCode']
            .toString();
        var suggestedReleases = releases.where(
          (element) =>
              element['versionCode'].toString() == suggestedVersionCodeText,
        );
        if (suggestedReleases.isNotEmpty) {
          releaseChoices = suggestedReleases;
          version = suggestedReleases.first['versionName']?.toString();
        }
      }
      // Apply the release filter if any
      if (filterVersionsByRegEx?.isNotEmpty == true) {
        version = null;
        releaseChoices = [];
        for (final release in releases) {
          if (RegExp(
            filterVersionsByRegEx!,
          ).hasMatch(release['versionName']?.toString() ?? '')) {
            version = release['versionName']?.toString();
            break;
          }
        }
        if (version == null) {
          throw NoVersionError();
        }
      }
      // Default to the highest version
      version ??= releases[0]['versionName']?.toString();
      if (version == null) {
        throw NoVersionError();
      }
      // If a suggested release was not already picked, pick all those with the selected version
      if (releaseChoices.isEmpty) {
        releaseChoices = releases.where(
          (element) => element['versionName']?.toString() == version,
        );
      }
      // For the remaining releases, use the toggles to auto-select one if possible
      if (releaseChoices.length > 1) {
        if (autoSelectHighestVersionCode) {
          releaseChoices = [releaseChoices.first];
        } else if (trySelectingSuggestedVersionCode &&
            response['suggestedVersionCode'] != null) {
          final String suggestedVersionCodeText =
              response['suggestedVersionCode'].toString();
          var suggestedReleases = releaseChoices.where(
            (element) =>
                element['versionCode'].toString() == suggestedVersionCodeText,
          );
          if (suggestedReleases.isNotEmpty) {
            releaseChoices = suggestedReleases;
          }
        }
      }
      if (releaseChoices.isEmpty) {
        throw NoReleasesError();
      }
      List<String> apkUrls = releaseChoices
          .map((e) => '${apkUrlPrefix}_${e['versionCode']}.apk')
          .toList();
      final uniqueApkUrls = apkUrls.toSet().toList();
      // Skip the per-check APK-size HEAD and the package-page fetch (icon/name)
      // when the upstream version is unchanged since the last check. getApp()
      // reuses the previous apkSizeBytes / iconUrl / name in that case (its
      // `?? currentApp` fallbacks), so these network round-trips would just be
      // wasted work on a no-op refresh.
      final App? prevApp = previouslyCheckedApp;
      final bool versionUnchanged =
          prevApp != null &&
          prevApp.rawLatestVersionFromSource != null &&
          prevApp.rawLatestVersionFromSource == version;
      int? apkSizeBytes;
      if (uniqueApkUrls.isNotEmpty && !versionUnchanged) {
        try {
          final headers = await getRequestHeaders(
            additionalSettings,
            uniqueApkUrls.last,
            forAPKDownload: true,
          );
          final responseWithClient = await sourceRequestStreamResponse(
            'HEAD',
            uniqueApkUrls.last,
            headers,
            additionalSettings,
          );
          final headResponse = responseWithClient.value.value;
          final contentLength = headResponse.contentLength;
          if (headResponse.statusCode >= 200 &&
              headResponse.statusCode < 300 &&
              contentLength >= 0) {
            apkSizeBytes = contentLength;
          }
          responseWithClient.value.key.close();
        } catch (_) {
          // File size is optional; update detection should still succeed.
        }
      }
      String? iconUrl;
      final String packageLabel;
      final Object? rawPackageName = response['packageName'];
      if (rawPackageName is String && rawPackageName.trim().isNotEmpty) {
        packageLabel = rawPackageName.trim();
      } else {
        final String? queryAppId = Uri.parse(
          standardUrl,
        ).queryParameters['appId']?.trim();
        if (queryAppId != null && queryAppId.isNotEmpty) {
          packageLabel = queryAppId;
        } else {
          packageLabel = Uri.parse(standardUrl).pathSegments.last;
        }
      }
      String appName = _fdroidDisplayString(response['name']) ?? packageLabel;
      final String pageHost = Uri.parse(standardUrl).host;
      final bool canUseOfficialPackagePage =
          !hostChanged ||
          hostIdenticalDespiteAnyChange ||
          pageHost == 'f-droid.org' ||
          pageHost == 'www.f-droid.org';
      if (canUseOfficialPackagePage && !versionUnchanged) {
        try {
          final pkgName = packageLabel;
          if (pageHost == 'f-droid.org' || pageHost == 'www.f-droid.org') {
            final pageRes = await sourceRequest(
              'https://$pageHost/packages/$pkgName/',
              additionalSettings,
            );
            if (pageRes.statusCode == 200) {
              final String? htmlTitleName = _fdroidDisplayNameFromHtml(
                pageRes.body,
              );
              if (htmlTitleName?.isNotEmpty == true) {
                appName = htmlTitleName!;
              }
              final doc = await parseHtmlOffIsolate(pageRes.body);
              iconUrl =
                  doc
                      .querySelector('meta[property="og:image"]')
                      ?.attributes['content'] ??
                  doc.querySelector('img.package-icon')?.attributes['src'];
              final String? parsedName =
                  doc.querySelector('h1.package-name')?.text.trim() ??
                  doc.querySelector('h3.package-name')?.text.trim() ??
                  doc.querySelector('.package-title h1')?.text.trim() ??
                  doc.querySelector('.package-title h3')?.text.trim();
              if (parsedName != null && parsedName.isNotEmpty) {
                appName = parsedName;
              } else if (htmlTitleName?.isNotEmpty != true) {
                final String? titleText =
                    doc
                        .querySelector('meta[property="og:title"]')
                        ?.attributes['content']
                        ?.trim() ??
                    doc.querySelector('title')?.text.trim();
                if (titleText != null && titleText.isNotEmpty) {
                  final parts = titleText.split('|');
                  if (parts.isNotEmpty) {
                    final String nameFromTitle = parts.first.trim();
                    if (nameFromTitle.isNotEmpty) {
                      appName = nameFromTitle;
                    }
                  }
                }
              }
            }
          }
        } catch (e) {
          // Icon is optional
        }
      }
      final bool hasBinaries =
          response['binaries'] != null ||
          (releaseChoices.isNotEmpty &&
              releaseChoices.first['binaries'] != null);
      final String reproducibleStatus = hasBinaries
          ? reproducibleBuildStatusVerified
          : reproducibleBuildStatusNoData;
      return APKDetails(
        version,
        getApkUrlsFromUrls(uniqueApkUrls),
        AppNames(sourceName, appName),
        iconUrl: iconUrl,
        rawReleaseTitleCandidates: rawVersionNameCandidates,
        apkSizeBytes: apkSizeBytes,
        isReproducible: reproducibleBuildBoolFromStatus(reproducibleStatus),
        reproducibleStatus: reproducibleStatus,
      );
    } else {
      throw getObtainiumHttpError(res);
    }
  }
}
