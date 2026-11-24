import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/html_parse_isolate.dart';

class Farsroid extends AppSource {
  Farsroid() {
    hosts = ['farsroid.com'];
    name = 'Farsroid';
    // 'releaseTitleAsVersion' is offered via the unified versionStringSource
    // dropdown, not a standalone switch (parity with fork main).
    showReleaseTitleAsVersionToggle = true;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems => [
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
    return standardizeUrlWithRegex(
      url,
      subdomainPrefix: r'([^\.]+\.)',
      pathPattern: r'/[^/]+',
    );
  }

  /// LiteSpeed's reCAPTCHA gate, served in place of the app page (the one
  /// request since upstream #3489). Checked before the status code, since
  /// the gate isn't known to always answer 200.
  void _throwIfBotVerification(http.Response res) {
    if (res.body.contains('lsrecaptcha-form') ||
        res.body.contains('/.lsrecap/recaptcha')) {
      throw BotVerificationError(name);
    }
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final String appName = Uri.parse(standardUrl).pathSegments.last;

      final res = await sourceRequest(standardUrl, additionalSettings);
      _throwIfBotVerification(res);
      if (res.statusCode != 200) {
        throw getObtainiumHttpError(res);
      }
      final html = await parseHtmlOffIsolate(res.body);
      // The page carries its download links as base64 JSON split across
      // `data-j` attributes; the old download-box API is gone (upstream
      // #3489).
      final dlinks = html.querySelectorAll('#secure-json [data-j]');
      if (dlinks.isEmpty) {
        throw NoReleasesError();
      }
      final base64 = dlinks.map((n) => n.attributes['data-j'] ?? '').join();
      var version =
          html.querySelector('h3.version-name')?.text.trim().split(' ').last ??
          '';

      if (base64.isEmpty || version.isEmpty) {
        throw NoVersionError();
      }

      List<dynamic>? farsroidJson;
      try {
        farsroidJson =
            jsonDecode(utf8.decode(base64Decode(base64))) as List<dynamic>?;
      } catch (e) {
        unawaited(
          LogsProvider().add(
            'Failed to decode Farsroid JSON: $e',
            level: LogLevel.error,
          ),
        );
        throw NoAPKError();
      }
      final requestUrl = res.request?.url;
      if (requestUrl == null) throw NoAPKError();
      var apkLinks =
          farsroidJson
              ?.map((l) => l?['url'] as String? ?? '')
              .where((l) => l.isNotEmpty)
              .map((l) => ensureAbsoluteUrl(l, requestUrl))
              .where((l) => AppSource.isApkOrContainerFile(l))
              .map((l) => MapEntry(Uri.parse(l).pathSegments.last, l))
              .toList() ??
          <MapEntry<String, String>>[];

      apkLinks = filterApks(
        apkLinks,
        additionalSettings['apkFilterRegEx'],
        additionalSettings['invertAPKFilter'],
      );
      if (apkLinks.isEmpty) {
        throw NoAPKError();
      }
      // The single-APK paths below pick from these: the arch filter now keeps
      // universal APKs as alternatives next to the ABI match (v1.7.4 sync
      // D12), and picking one of those would switch apps to the universal
      // build (useFirstApkOfVersion) or fail with "no version"
      // (releaseTitleAsVersion).
      var singleApkCandidates = apkLinks;
      if (additionalSettings['autoApkFilterByArch'] == true) {
        apkLinks = await filterApksByArch(apkLinks);
        final abiSpecificLinks = apkLinks
            .where((link) => !ApkFilterService.isUniversalApkName(link.key))
            .toList();
        singleApkCandidates = abiSpecificLinks.isNotEmpty
            ? abiSpecificLinks
            : apkLinks;
      }
      if (additionalSettings['useFirstApkOfVersion'] == true) {
        // The first APK named after the version (upstream #3489), among the
        // ABI matches above.
        apkLinks = singleApkCandidates = [
          singleApkCandidates.firstWhere(
            (l) => l.key.toLowerCase().contains(version.toLowerCase()),
            orElse: () => singleApkCandidates.first,
          ),
        ];
      }

      if (additionalSettings['releaseTitleAsVersion'] == true) {
        if (singleApkCandidates.length != 1) {
          throw NoVersionError();
        }
        version = singleApkCandidates.single.key;
      }

      return APKDetails(version, apkLinks, AppNames(name, appName));
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }
}
