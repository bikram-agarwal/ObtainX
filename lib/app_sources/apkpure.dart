import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/html_parse_isolate.dart';
import 'package:obtainium/services/store_icon_resolver.dart';

extension Unique<E, Id> on List<E> {
  List<E> unique([Id Function(E element)? id, bool inplace = true]) {
    final ids = <dynamic>{};
    final list = inplace ? this : List<E>.from(this);
    list.retainWhere((x) => ids.add(id != null ? id(x) : x as Id));
    return list;
  }
}

class APKPure extends AppSource {
  APKPure() {
    name = 'APKPure';
    hosts = ['apkpure.net', 'apkpure.com'];
    allowSubDomains = true;
    naiveStandardVersionDetection = true;
    showReleaseDateAsVersionToggle = true;
    inferAppIdFromUrlPath = true;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
    AppSource.fallbackToOlderReleasesFormItem,
    [
      GeneratedFormSwitch(
        'stayOneVersionBehind',
        label: tr('stayOneVersionBehind'),
        value: false,
      ),
    ],
    [
      GeneratedFormSwitch(
        'useFirstApkOfVersion',
        label: tr('useFirstApkOfVersion'),
        value: true,
      ),
    ],
  ];

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    final RegExp standardUrlRegExB = RegExp(
      '^https?://m.${getSourceRegex(hosts)}(/+[^/]{2})?/+[^/]+/+[^/]+',
      caseSensitive: false,
    );
    RegExpMatch? match = standardUrlRegExB.firstMatch(url);
    if (match != null) {
      final uri = Uri.parse(url);
      url = 'https://${uri.host.substring(2)}${uri.path}';
    }
    final RegExp standardUrlRegExA = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}(/+[^/]{2})?/+[^/]+/+[^/]+',
      caseSensitive: false,
    );
    match = standardUrlRegExA.firstMatch(url);
    if (match == null) {
      throw InvalidURLError(name);
    }
    return match.group(0)!;
  }

  Future<APKDetails> getDetailsForVersion(
    List<Map<String, dynamic>> versionVariants,
    List<String> supportedArchs,
    Map<String, dynamic> additionalSettings,
  ) async {
    final Map<String, int> sizeByName = {};
    var apkUrls = versionVariants
        .map((e) {
          final String? appId = e['package_name']?.toString();
          final String? versionCode = e['version_code']?.toString();
          if (appId == null || versionCode == null) {
            return null;
          }

          List<String> architectures =
              e['native_code']?.cast<String>() ?? <String>[];
          final String architectureString = architectures.join(',');
          if (architectures.contains('universal') ||
              architectures.contains('unlimited')) {
            architectures = [];
          }
          if (additionalSettings['autoApkFilterByArch'] == true &&
              architectures.isNotEmpty &&
              architectures.where((a) => supportedArchs.contains(a)).isEmpty) {
            return null;
          }

          final asset = e['asset'];
          final String? type = asset is Map ? asset['type']?.toString() : null;
          final String? downloadUri = asset is Map
              ? asset['url']?.toString()
              : null;
          if (type == null || downloadUri == null) {
            return null;
          }

          final archSuffix = architectureString.isNotEmpty
              ? '-$architectureString'
              : '';
          final apkName =
              '$appId-$versionCode$archSuffix.${type.toLowerCase()}';
          final rawSize = asset is Map ? asset['size'] : null;
          final int? parsedSize = rawSize is num
              ? rawSize.toInt()
              : int.tryParse(rawSize?.toString() ?? '');
          if (parsedSize != null) {
            sizeByName[apkName] = parsedSize;
          }

          return MapEntry(apkName, downloadUri);
        })
        .nonNulls
        .toList()
        .unique((e) => e.key);

    if (apkUrls.isEmpty) {
      throw NoAPKError();
    }

    final v = versionVariants.first;
    final String? version = v['version_name']?.toString();
    if (version == null || version.isEmpty) {
      throw NoVersionError();
    }
    final String author = v['developer']?.toString() ?? name;
    final String appName = v['title']?.toString() ?? tr('app');
    final DateTime? releaseDate = v['update_date'] != null
        ? DateTime.tryParse(v['update_date'].toString())
        : null;
    String? changeLog = v['whatsnew'];
    if (changeLog != null && changeLog.isEmpty) {
      changeLog = null;
    }

    if (additionalSettings['useFirstApkOfVersion'] == true) {
      apkUrls = [apkUrls.first];
    }

    int? apkSizeBytes = apkUrls.isNotEmpty
        ? sizeByName[apkUrls.last.key]
        : null;
    if (apkUrls.isNotEmpty) {
      try {
        final responseWithClient = await sourceRequestStreamResponse(
          'HEAD',
          apkUrls.last.value,
          null,
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
        // APKPure's API size is a fallback when the CDN does not report length.
      }
    }

    return APKDetails(
      version,
      apkUrls,
      AppNames(author, appName),
      releaseDate: releaseDate,
      changeLog: changeLog,
      apkSizeBytes: apkSizeBytes,
    );
  }

  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    if (forAPKDownload) {
      return null;
    } else {
      try {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        return {
          'Ual-Access-Businessid': 'projecta',
          'Ual-Access-ProjectA':
              '{"device_info":{"os_ver":"${androidInfo.version.sdkInt}"}}',
        };
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to get device info headers: $e',
            level: LogLevel.error,
          ),
        );
        return null;
      }
    }
  }

  /// APKPure's version-history API (used for everything else here) never
  /// returns an icon - `icon_url` comes back empty for every app checked, this
  /// one included - so the only place to get one is the listing page itself.
  /// [normalizeApkPureHost] and [iconUrlFromStoreListingDocument]'s APKPure
  /// branch are the single source of truth for the domain and selector this
  /// needs - see their doc comments; the cross-store icon fallback in
  /// `store_icon_resolver.dart` scrapes the same pages and must stay in sync.
  Future<String?> _fetchIconUrl(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final Uri pageUri = normalizeApkPureHost(Uri.parse(standardUrl));
      final res = await sourceRequest(pageUri.toString(), additionalSettings);
      if (res.statusCode != 200) return null;
      final doc = await parseHtmlOffIsolate(res.body);
      final String? raw = iconUrlFromStoreListingDocument(
        doc,
        pageUri.toString(),
      );
      if (raw == null) return null;
      final Uri resolved = Uri.parse(raw);
      // The page requests a 40px thumbnail (sized for its own tiny icon
      // slot); ObtainX caches icons up to 128px, so ask the same resizing CDN
      // for a size that won't look blurry once scaled back up.
      if (resolved.queryParameters.containsKey('w')) {
        return resolved
            .replace(queryParameters: {...resolved.queryParameters, 'w': '200'})
            .toString();
      }
      return resolved.toString();
    } catch (e) {
      unawaited(
        LogsProvider().add(
          'APKPure icon fetch failed: $e',
          level: LogLevel.error,
        ),
      );
      return null;
    }
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final String? appId = await tryInferringAppId(standardUrl);
      if (appId == null) {
        throw NoReleasesError();
      }

      List<String> supportedArchs;
      try {
        supportedArchs = (await DeviceInfoPlugin().androidInfo).supportedAbis;
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to get supported ABIs: $e',
            level: LogLevel.error,
          ),
        );
        supportedArchs = [];
      }

      final res = await sourceRequest(
        'https://tapi.pureapk.com/v3/get_app_his_version?package_name=$appId&hl=en',
        additionalSettings,
      );
      if (res.statusCode != 200) {
        throw getObtainiumHttpError(res);
      }
      List<Map<String, dynamic>> apks;
      try {
        apks = (jsonDecode(res.body)['version_list'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to parse version list: $e',
            level: LogLevel.error,
          ),
        );
        throw NoReleasesError();
      }

      // group by version
      final List<List<Map<String, dynamic>>> versions = apks
          .fold<Map<String, List<Map<String, dynamic>>>>({}, (
            Map<String, List<Map<String, dynamic>>> val,
            Map<String, dynamic> element,
          ) {
            final v = element['version_name'] as String? ?? '';
            if (!val.containsKey(v)) {
              val[v] = [];
            }
            val[v]?.add(element);
            return val;
          })
          .values
          .toList();

      if (versions.isEmpty) {
        throw NoReleasesError();
      }

      for (var i = 0; i < versions.length; i++) {
        final v = versions[i];
        try {
          if (i == 0 && additionalSettings['stayOneVersionBehind'] == true) {
            if (additionalSettings['fallbackToOlderReleases'] != true &&
                versions.length < 2) {
              throw NoReleasesError();
            }
            continue;
          }
          final APKDetails details = await getDetailsForVersion(
            v,
            supportedArchs,
            additionalSettings,
          );
          if ((previouslyCheckedApp?.iconUrl ?? '').isEmpty) {
            details.iconUrl = await _fetchIconUrl(
              standardUrl,
              additionalSettings,
            );
          }
          return details;
        } catch (e) {
          if (additionalSettings['fallbackToOlderReleases'] != true ||
              i == versions.length - 1) {
            rethrowOrWrapError(e);
          }
        }
      }
      throw NoAPKError();
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }
}
