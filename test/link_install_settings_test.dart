import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/import_from_url_list.dart';
import 'package:obtainium/providers/source_provider.dart';

// A link import can't choose how an app installs (v1.7.4 sync D13): the
// per-app install method a shared app carries is left out; the rest is kept.
void main() {
  App linked(Map<String, dynamic> settings) => App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    latestVersion: '1.0',
    preferredApkIndex: 0,
    additionalSettings: settings,
  );

  test('drops the install method, keeps the other settings', () {
    final App app = linked({
      'installerMode': 'root',
      'includePrereleases': true,
    });

    final App imported = withoutLinkInstallSettings(app);

    expect(imported.additionalSettings.containsKey('installerMode'), isFalse);
    expect(imported.additionalSettings['includePrereleases'], isTrue);
    // The shared app itself is left as it was.
    expect(app.additionalSettings['installerMode'], 'root');
  });

  test('an app without one is returned as it is', () {
    final App app = linked({'includePrereleases': true});
    expect(withoutLinkInstallSettings(app), same(app));
  });
}
