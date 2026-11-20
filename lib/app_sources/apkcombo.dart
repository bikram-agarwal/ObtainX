import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

/// APKCombo is gone: upstream deleted the source when the domain lapsed
/// (7d89128a, #3468), and apkcombo.com now answers with a Cloudflare Access
/// login, apparently under a new owner. ObtainX keeps this tombstone instead
/// (v1.7.4 sync D19) so apps already tracked from APKCombo still load under
/// its name and can be moved with the store swap. Without it they would fall
/// to the HTML source (scraping whatever the domain now serves), and apps
/// with `overrideSource: 'APKCombo'` would fail to load at all.
///
/// It never sends a request: checks, adds and downloads fail with
/// [apkComboRetiredError]. Don't "restore" the scraper.
class APKCombo extends AppSource {
  APKCombo() {
    name = 'APKCombo';
    hosts = ['apkcombo.com'];
    retired = true;
    allowOverride = false;
    // Kept so the stored settings of existing apps keep their shape.
    showReleaseDateAsVersionToggle = true;
    inferAppIdFromUrlPath = true;
  }

  static ObtainiumError apkComboRetiredError() =>
      ObtainiumError(tr('apkComboRetired'));

  @override
  String sourceSpecificStandardizeURL(
    String url, {
    bool forSelection = false,
  }) => standardizeUrlWithRegex(
    url,
    subdomainPrefix: '(www\\.)?',
    pathPattern: '/+[^/]+/+[^/]+',
  );

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    throw apkComboRetiredError();
  }

  @override
  Future<String> assetUrlPrefetchModifier(
    String assetUrl,
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    throw apkComboRetiredError();
  }
}
