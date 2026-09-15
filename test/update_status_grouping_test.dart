import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/source_provider.dart';

App _app({String? installed, required String latest}) {
  return App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    additionalSettings: {'versionDetection': 'standard'},
  );
}

void main() {
  test('every verdict has exactly one update-status group', () {
    expect(
      updateStatusGroupOrder.toSet(),
      AppVersionDisplayVerdict.values.toSet(),
    );
    expect(
      updateStatusGroupOrder.length,
      AppVersionDisplayVerdict.values.length,
    );
  });

  test('groups run from most to least actionable', () {
    expect(updateStatusGroupOrder, [
      AppVersionDisplayVerdict.updateAvailable,
      AppVersionDisplayVerdict.uncertain,
      AppVersionDisplayVerdict.newerOnDevice,
      AppVersionDisplayVerdict.effectivelyEqual,
      AppVersionDisplayVerdict.sameVersion,
      AppVersionDisplayVerdict.notInstalled,
    ]);
  });

  test('apps land in the group their details-page stripe shows', () {
    final Map<AppVersionDisplayVerdict, App> appsByVerdict = {
      AppVersionDisplayVerdict.updateAvailable: _app(
        installed: '1.2.3',
        latest: '1.2.4',
      ),
      AppVersionDisplayVerdict.uncertain: _app(
        installed: 'stable',
        latest: 'nightly',
      ),
      AppVersionDisplayVerdict.newerOnDevice: _app(
        installed: '1.2.4',
        latest: '1.2.3',
      ),
      AppVersionDisplayVerdict.effectivelyEqual: _app(
        installed: '1.2.3-foss',
        latest: '1.2.3',
      ),
      AppVersionDisplayVerdict.sameVersion: _app(
        installed: '1.2.3',
        latest: 'v1.2.3',
      ),
      AppVersionDisplayVerdict.notInstalled: _app(latest: '1.2.3'),
    };

    appsByVerdict.forEach((verdict, app) {
      expect(
        appVersionVerdictForDisplay(app),
        verdict,
        reason: 'app grouped under the wrong update status',
      );
    });
  });
}
