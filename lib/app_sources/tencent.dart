import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class Tencent extends AppSource {
  Tencent() {
    name = tr('tencentAppStore');
    hosts = ['sj.qq.com'];
    naiveStandardVersionDetection = true;
    showReleaseDateAsVersionToggle = true;
    canSearch = true;
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    RegExp standardUrlRegEx = RegExp(
      '^https?://${getSourceRegex(hosts)}/appdetail/[^/]+',
      caseSensitive: false,
    );
    var match = standardUrlRegEx.firstMatch(url);
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
    String appId = (await tryInferringAppId(standardUrl))!;
    String baseHost = Uri.parse(
      standardUrl,
    ).host.split('.').reversed.toList().sublist(0, 2).reversed.join('.');

    var res = await sourceRequest(
      'https://a.app.$baseHost/o/simple.jsp?pkgname=$appId',
      additionalSettings,
      followRedirects: false,
    );

    if (res.statusCode == 200) {
      dynamic json;
      try {
        json = jsonDecode(
          res.body
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.startsWith('window.systemData='))
              .first
              .substring(18),
        )['appDetail'];
      } catch (e) {
        throw NoReleasesError();
      }
      if (json == null) {
        throw NoReleasesError();
      }
      var version = json['versionName'];
      var apkUrl = json['apkUrl64'];
      apkUrl ??= json['apkUrl'];
      if (apkUrl == null) {
        throw NoAPKError();
      }
      var appName = json['appName'];
      var author = json['author'];
      var apkName =
          Uri.parse(apkUrl).queryParameters['fsname'] ??
          '${appId}_$version.apk';

      var iconUrl = json['iconUrl']?.toString();
      int? apkSizeBytes;
      try {
        var rawSize = json['fileSize']?['bytes'];
        if (rawSize != null) {
          apkSizeBytes = int.parse(rawSize.toString());
        }
      } catch (_) {}

      return APKDetails(
        version,
        [MapEntry(apkName, apkUrl)],
        AppNames(author, appName),
        iconUrl: iconUrl,
        apkSizeBytes: apkSizeBytes,
      );
    } else {
      throw getObtainiumHttpError(res);
    }
  }

  @override
  Future<Map<String, List<String>>> search(
    String query, {
    Map<String, dynamic> querySettings = const {},
  }) async {
    var body = {
      'head': {
        'cmd': 'dc_pcyyb_official',
        'authInfo': {'businessId': 'AuthName'},
        'deviceInfo': {'platformType': 2, 'platform': 1},
        'userInfo': {'guid': '1933d8ef-501b-49a7-89a0-46cbcb38a122'},
        'expSceneIds': '',
        'hostAppInfo': {'scene': 'search_result'},
      },
      'body': {
        'bid': 'yybhome',
        'offset': 0,
        'size': 10,
        'preview': false,
        'listS': {
          'region': {
            'repStr': ['CN'],
          },
          'keyword': {
            'repStr': [query],
          },
        },
        'layout': 'yybn_search_result_list',
      },
    };
    var res = await sourceRequest(
      'https://yybadaccess.3g.qq.com/v2/dc_pcyyb_official',
      querySettings,
      postBody: body,
    );
    if (res.statusCode != 200) {
      throw getObtainiumHttpError(res);
    }
    var json = jsonDecode(res.body);
    if (json['ret'] != 0) {
      throw NoReleasesError();
    }
    Map<String, List<String>> results = {};
    var components = json['data']?['components'] as List<dynamic>?;
    if (components != null && components.isNotEmpty) {
      var itemData = components[0]?['data']?['itemData'] as List<dynamic>?;
      if (itemData != null) {
        for (var item in itemData) {
          var pkgName = item['pkg_name']?.toString();
          if (pkgName == null || pkgName.isEmpty) continue;
          var url = 'https://sj.qq.com/appdetail/$pkgName';
          try {
            url = standardizeUrl(url);
          } catch (_) {
            continue;
          }
          var name = item['name']?.toString() ?? '';
          var desc = item['developer']?.toString() ?? tr('noDescription');
          results[url] = [name, desc];
        }
      }
    }
    return results;
  }
}
