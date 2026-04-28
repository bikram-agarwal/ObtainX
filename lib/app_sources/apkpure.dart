import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

extension Unique<E, Id> on List<E> {
  List<E> unique([Id Function(E element)? id, bool inplace = true]) {
    final ids = <dynamic>{};
    var list = inplace ? this : List<E>.from(this);
    list.retainWhere((x) => ids.add(id != null ? id(x) : x as Id));
    return list;
  }
}

class APKPure extends AppSource {
  APKPure() {
    hosts = ['apkpure.net', 'apkpure.com'];
    allowSubDomains = true;
    naiveStandardVersionDetection = true;
    showReleaseDateAsVersionToggle = true;
    additionalSourceAppSpecificSettingFormItems = [
      [
        GeneratedFormSwitch(
          'fallbackToOlderReleases',
          label: tr('fallbackToOlderReleases'),
          defaultValue: true,
        ),
      ],
      [
        GeneratedFormSwitch(
          'stayOneVersionBehind',
          label: tr('stayOneVersionBehind'),
          defaultValue: false,
        ),
      ],
      [
        GeneratedFormSwitch(
          'useFirstApkOfVersion',
          label: tr('useFirstApkOfVersion'),
          defaultValue: true,
        ),
      ],
    ];
  }

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    RegExp standardUrlRegExB = RegExp(
      '^https?://m.${getSourceRegex(hosts)}(/+[^/]{2})?/+[^/]+/+[^/]+',
      caseSensitive: false,
    );
    RegExpMatch? match = standardUrlRegExB.firstMatch(url);
    if (match != null) {
      var uri = Uri.parse(url);
      url = 'https://${uri.host.substring(2)}${uri.path}';
    }
    RegExp standardUrlRegExA = RegExp(
      '^https?://(www\\.)?${getSourceRegex(hosts)}(/+[^/]{2})?/+[^/]+/+[^/]+',
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

  Future<APKDetails> getDetailsForVersion(
    List<Map<String, dynamic>> versionVariants,
    List<String> supportedArchs,
    Map<String, dynamic> additionalSettings,
  ) async {
    final Map<String, int> sizeByName = {};
    var apkUrls = versionVariants
        .map((versionVariant) {
          String appId = versionVariant['package_name'];
          String versionCode = versionVariant['version_code'];

          List<String> architectures = versionVariant['native_code']
              ?.cast<String>();
          String architectureString = architectures.join(',');
          if (architectures.contains("universal") ||
              architectures.contains("unlimited")) {
            architectures = [];
          }
          if (additionalSettings['autoApkFilterByArch'] == true &&
              architectures.isNotEmpty &&
              architectures.where((a) => supportedArchs.contains(a)).isEmpty) {
            return null;
          }

          final asset = versionVariant['asset'];
          String type = asset['type'];
          String downloadUri = asset['url'];
          final apkName =
              '$appId-$versionCode-$architectureString.${type.toLowerCase()}';
          final rawSize = asset['size'];
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

    // get version details from first variant
    var v = versionVariants.first;
    String version = v['version_name'];
    String author = v['developer'];
    String appName = v['title'];
    DateTime releaseDate = DateTime.parse(v['update_date']);
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
      return {
        "Ual-Access-Businessid": "projecta",
        "Ual-Access-ProjectA":
            '{"device_info":{"os_ver":"${((await DeviceInfoPlugin().androidInfo).version.sdkInt)}"}}',
      };
    }
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    String appId = (await tryInferringAppId(standardUrl))!;

    List<String> supportedArchs =
        (await DeviceInfoPlugin().androidInfo).supportedAbis;

    // request versions from API
    var res = await sourceRequest(
      "https://tapi.pureapk.com/v3/get_app_his_version?package_name=$appId&hl=en",
      additionalSettings,
    );
    if (res.statusCode != 200) {
      throw getObtainiumHttpError(res);
    }
    List<Map<String, dynamic>> apks = jsonDecode(
      res.body,
    )['version_list'].cast<Map<String, dynamic>>();

    // group by version
    List<List<Map<String, dynamic>>> versions = apks
        .fold<Map<String, List<Map<String, dynamic>>>>({}, (
          Map<String, List<Map<String, dynamic>>> val,
          Map<String, dynamic> element,
        ) {
          String v = element['version_name'];
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
      var v = versions[i];
      try {
        if (i == 0 && additionalSettings['stayOneVersionBehind'] == true) {
          throw NoReleasesError();
        }
        return await getDetailsForVersion(
          v,
          supportedArchs,
          additionalSettings,
        );
      } catch (e) {
        if (additionalSettings['fallbackToOlderReleases'] != true ||
            i == versions.length - 1) {
          rethrow;
        }
      }
    }
    throw NoAPKError();
  }
}
