import 'dart:io' show HttpHeaders;

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' show Response;
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class IzzyOnDroid extends AppSource {
  late FDroid fd;

  static const String _officialRepoUrl = 'https://apt.izzysoft.de/fdroid/repo';

  /// Canonical user-facing URL for one app (matches Izzy web index APK pages).
  static const String _izzyIndexApkBase =
      'https://apt.izzysoft.de/fdroid/index/apk/';

  IzzyOnDroid() {
    hosts = ['izzysoft.de'];
    fd = FDroid();
    name = tr('izzyOnDroid');
    canSearch = true;
    additionalSourceAppSpecificSettingFormItems =
        fd.additionalSourceAppSpecificSettingFormItems;
    allowSubDomains = true;
  }

  /// Izzy mirrors expect a normal F-Droid client user agent; bare Dart clients
  /// can get connection failures on some networks.
  @override
  Future<Map<String, String>?> getRequestHeaders(
    Map<String, dynamic> additionalSettings,
    String url, {
    bool forAPKDownload = false,
  }) async {
    final Uri? parsed = Uri.tryParse(url);
    if (parsed == null) {
      return null;
    }
    final String host = parsed.host.toLowerCase();
    if (host.endsWith('izzysoft.de')) {
      return <String, String>{
        HttpHeaders.userAgentHeader: 'F-Droid/1.0 (+https://f-droid.org)',
      };
    }
    return null;
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    final RegExp standardUrlRegExA = RegExp(
      '^https?://android.${getSourceRegex(hosts)}/repo/apk/[^/]+',
      caseSensitive: false,
    );
    final RegExpMatch? matchA = standardUrlRegExA.firstMatch(url);
    if (matchA != null) {
      return matchA.group(0)!;
    }
    final RegExp standardUrlRegExB = RegExp(
      '^https?://apt.${getSourceRegex(hosts)}/fdroid/index/apk/[^/]+',
      caseSensitive: false,
    );
    final RegExpMatch? matchB = standardUrlRegExB.firstMatch(url);
    if (matchB != null) {
      final Uri parsedLegacy = Uri.parse(matchB.group(0)!);
      final String apkFileName = parsedLegacy.pathSegments.last;
      if (apkFileName.toLowerCase().endsWith('.apk')) {
        return '${parsedLegacy.scheme}://${parsedLegacy.host}/fdroid/repo/$apkFileName';
      }
      return matchB.group(0)!;
    }
    final RegExp standardUrlRegExC = RegExp(
      '^https?://apt.${getSourceRegex(hosts)}/fdroid/repo/[^/]+\\.apk\$',
      caseSensitive: false,
    );
    final RegExpMatch? matchC = standardUrlRegExC.firstMatch(url);
    if (matchC != null) {
      return matchC.group(0)!;
    }
    throw InvalidURLError(name);
  }

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    final String? fromSettings = additionalSettings['appId'] as String?;
    if (fromSettings != null && fromSettings.isNotEmpty) {
      return fromSettings;
    }
    final Uri parsed = Uri.parse(standardUrl);
    final String? fromQuery = parsed.queryParameters['appId']?.trim();
    if (fromQuery != null && fromQuery.isNotEmpty) {
      return fromQuery;
    }
    final List<String> segments = parsed.pathSegments;
    for (int indexSegmentIndex = 0;
        indexSegmentIndex < segments.length;
        indexSegmentIndex++) {
      if (segments[indexSegmentIndex].toLowerCase() != 'index') {
        continue;
      }
      if (indexSegmentIndex + 2 >= segments.length) {
        continue;
      }
      if (segments[indexSegmentIndex + 1].toLowerCase() != 'apk') {
        continue;
      }
      final String apkOrId = segments[indexSegmentIndex + 2];
      if (apkOrId.toLowerCase().endsWith('.apk')) {
        final String baseName = apkOrId.substring(0, apkOrId.length - 4);
        final RegExpMatch? versionSuffix =
            RegExp(r'^(.+)_([0-9]+)$').firstMatch(baseName);
        if (versionSuffix != null) {
          return versionSuffix.group(1);
        }
        return baseName;
      }
      return apkOrId;
    }
    final String lastSegment = parsed.pathSegments.last;
    if (lastSegment.endsWith('.apk')) {
      final String baseName = lastSegment.substring(0, lastSegment.length - 4);
      final RegExpMatch? versionSuffix =
          RegExp(r'^(.+)_([0-9]+)$').firstMatch(baseName);
      if (versionSuffix != null) {
        return versionSuffix.group(1);
      }
    }
    return fd.tryInferringAppId(
      standardUrl,
      additionalSettings: additionalSettings,
    );
  }

  @override
  App endOfGetAppChanges(App app) {
    String? appId = isTempId(app) ? null : app.id;
    final Uri uri = Uri.parse(app.url);
    appId ??= uri.queryParameters['appId']?.trim();
    if (appId == null || appId.isEmpty) {
      final List<String> segments = uri.pathSegments;
      for (int indexSegmentIndex = 0;
          indexSegmentIndex < segments.length;
          indexSegmentIndex++) {
        if (segments[indexSegmentIndex].toLowerCase() != 'index') {
          continue;
        }
        if (indexSegmentIndex + 2 >= segments.length) {
          continue;
        }
        if (segments[indexSegmentIndex + 1].toLowerCase() != 'apk') {
          continue;
        }
        String candidate = segments[indexSegmentIndex + 2];
        if (candidate.toLowerCase().endsWith('.apk')) {
          final String baseName = candidate.substring(0, candidate.length - 4);
          final RegExpMatch? versionSuffix =
              RegExp(r'^(.+)_([0-9]+)$').firstMatch(baseName);
          candidate = versionSuffix?.group(1) ?? baseName;
        }
        appId = candidate;
        break;
      }
    }
    if (appId != null && appId.isNotEmpty) {
      app.url = '$_izzyIndexApkBase$appId';
      app.additionalSettings['appIdOrName'] = appId;
      app.id = appId;
    }
    return app;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    String? appIdOrName = additionalSettings['appIdOrName'] as String?;
    final Uri standardUri = Uri.parse(standardUrl);
    if (standardUri.queryParameters['appId']?.trim().isNotEmpty == true) {
      appIdOrName = standardUri.queryParameters['appId']!.trim();
    }
    appIdOrName ??=
        await tryInferringAppId(standardUrl, additionalSettings: additionalSettings);
    if (appIdOrName == null || appIdOrName.isEmpty) {
      throw NoReleasesError();
    }
    additionalSettings['appIdOrName'] = appIdOrName;
    final Response indexResponse = await fdroidRepoRequestIndexWithVariants(
      sourceRequest,
      _officialRepoUrl,
      additionalSettings,
    );
    if (indexResponse.statusCode != 200) {
      throw getObtainiumHttpError(indexResponse);
    }
    return await FDroidRepo.apkDetailsFromIndexXmlResponse(
      indexResponse,
      appIdOrName,
      additionalSettings,
      name,
    );
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    final Map<String, dynamic> mergedSettings = {
      ...querySettings,
      'url': _officialRepoUrl,
    };
    String? repoUrl = mergedSettings['url'] as String?;
    if (repoUrl == null) {
      throw NoReleasesError();
    }
    final FDroidRepo urlNormalizer = FDroidRepo();
    repoUrl = urlNormalizer.removeQueryParamsFromUrl(
      urlNormalizer.standardizeUrl(repoUrl),
    );
    final Response indexResponse = await fdroidRepoRequestIndexWithVariants(
      sourceRequest,
      repoUrl,
      mergedSettings,
    );
    if (indexResponse.statusCode != 200) {
      throw getObtainiumHttpError(indexResponse);
    }
    final Map<String, List<String>> parsed =
        await FDroidRepo.parseIndexXmlSearchResults(indexResponse, query);
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final MapEntry<String, List<String>> entry in parsed.entries) {
      final String? packageId =
          Uri.parse(entry.key).queryParameters['appId']?.trim();
      if (packageId != null && packageId.isNotEmpty) {
        out['$_izzyIndexApkBase$packageId'] = entry.value;
      } else {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }
}
