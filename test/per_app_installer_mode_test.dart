import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/installers/dhizuku_installer.dart';
import 'package:obtainium/installers/external_installer.dart';
import 'package:obtainium/installers/root_installer.dart';
import 'package:obtainium/installers/shizuku_installer.dart';
import 'package:obtainium/installers/stock_installer.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

App _app(Map<String, dynamic> additionalSettings) => App(
  id: 'com.example.app',
  url: 'https://example.com/app',
  author: 'Author',
  name: 'App',
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: additionalSettings,
);

/// An [AppsProvider] carrying only settings, for [AppsProviderInstall]
/// methods that read nothing else.
class _SettingsOnlyAppsProvider implements AppsProvider {
  _SettingsOnlyAppsProvider(this.settingsProvider);

  @override
  SettingsProvider settingsProvider;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('an app with its own install method uses it', () {
    expect(
      installerModeFor(_app({'installerMode': 'shizuku'}), 'system'),
      'shizuku',
    );
    expect(
      installerModeFor(_app({'installerMode': 'system'}), 'root'),
      'system',
    );
    // ObtainX's own modes (D13): Dhizuku and Root are per-app choices too.
    expect(
      installerModeFor(_app({'installerMode': 'dhizuku'}), 'system'),
      'dhizuku',
    );
    expect(
      installerModeFor(_app({'installerMode': 'root'}), 'shizuku'),
      'root',
    );
  });

  test('otherwise the global install method is used', () {
    expect(installerModeFor(null, 'root'), 'root');
    expect(installerModeFor(_app({}), 'shizuku'), 'shizuku');
    expect(
      installerModeFor(_app({'installerMode': ''}), 'external'),
      'external',
    );
    expect(
      installerModeFor(_app({'installerMode': 'bogus'}), 'system'),
      'system',
    );
    // Upstream's old stock key is not an ObtainX mode.
    expect(
      installerModeFor(_app({'installerMode': 'stock'}), 'dhizuku'),
      'dhizuku',
    );
  });

  test('getInstaller follows the app, then the global setting', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    settings.installerMode = 'shizuku';
    final AppsProvider provider = _SettingsOnlyAppsProvider(settings);

    expect(provider.getInstaller(), isA<ShizukuInstaller>());
    expect(provider.getInstaller(_app({})), isA<ShizukuInstaller>());
    expect(
      provider.getInstaller(_app({'installerMode': 'system'})),
      isA<StockInstaller>(),
    );
    expect(
      provider.getInstaller(_app({'installerMode': 'dhizuku'})),
      isA<DhizukuInstaller>(),
    );
    expect(
      provider.getInstaller(_app({'installerMode': 'root'})),
      isA<RootInstaller>(),
    );
    expect(
      provider.getInstaller(_app({'installerMode': 'external'})),
      isA<ExternalInstaller>(),
    );
    expect(
      provider.getInstaller(_app({'installerMode': 'root'})).modeKey,
      'root',
    );
  });
}
