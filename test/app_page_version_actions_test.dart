import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final Map<String, AppInMemory> apps = {};
  @override
  final Map<String, ({String? title, String message})> appPageErrors = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

App _app(String installed, String latest, {bool trackOnly = true}) {
  return App(
    id: 'com.google.android.aicore',
    url: trackOnly
        ? 'https://www.apkmirror.com/apk/google-inc/aicore/'
        : 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    apkSizeBytes: 40 * 1024 * 1024,
    additionalSettings: {'trackOnly': trackOnly, 'versionDetection': 'auto'},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final Map<String, dynamic> translations;
  late final Uint8List icon;
  late SharedPreferences preferences;
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    icon = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'matchAppPageToIconColors': false,
      'checkUpdateOnDetailPage': false,
      'showAppWebpage': false,
      'updateButtonsAtTopOfAppPage': true,
    });
    preferences = await SharedPreferences.getInstance();
  });

  for (final (installed, latest, verdict) in [
    ('1.2.3', 'v1.2.3', AppVersionDisplayVerdict.sameVersion),
    ('v1.2.3', '1.2.3', AppVersionDisplayVerdict.sameVersion),
    ('V1.2.3', '1.2.3', AppVersionDisplayVerdict.sameVersion),
    ('v1.2.3-rc1', '1.2.3-rc1', AppVersionDisplayVerdict.sameVersion),
    ('v1.2.3-rc1', '1.2.3', AppVersionDisplayVerdict.updateAvailable),
    ('1.2.3-foss', '1.2.3', AppVersionDisplayVerdict.effectivelyEqual),
  ]) {
    test('details verdict for $installed / $latest', () {
      expect(appVersionVerdictForDisplay(_app(installed, latest)), verdict);
    });
  }

  for (final (installed, latest, trackOnly) in [
    (
      '0.release.prod_aicore_20260723.00_RC11.964081323',
      '20260723.00_RC11.964081323',
      true,
    ),
    (
      'C.6.playstore.pixel9.961955194',
      'B.28.playstore.oemfull.969713662',
      true,
    ),
    ('1.5.5 (4D91B33C)', '1.5.5-ced5040c', false),
  ]) {
    testWidgets('manual actions during another download: $installed', (
      tester,
    ) async {
      final settings = SettingsProvider()..prefs = preferences;
      Localization.load(
        const Locale('en'),
        translations: Translations(translations),
      );
      final provider = _Apps();
      final model = _app(installed, latest, trackOnly: trackOnly);
      provider.apps[model.id] = AppInMemory(model, null, null, icon);
      final other = AppInMemory(
        model.copyWith(id: 'org.example.other'),
        null,
        null,
        icon,
      );
      provider.apps[other.app.id] = other;
      addTearDown(provider.dispose);
      addTearDown(settings.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 1600);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppsProvider>.value(value: provider),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          child: MaterialApp(home: AppPage(appId: model.id)),
        ),
      );
      await tester.pumpAndSettle();

      final updateButton = find.widgetWithText(FilledButton, 'Update · 40 MB');
      final markButton = find.widgetWithText(FilledButton, tr('markUpdated'));
      final skipButton = find.widgetWithText(TextButton, tr('skipVersion'));
      expect(tester.widget<FilledButton>(updateButton).onPressed, isNotNull);

      other.downloadProgress = 0.3;
      provider.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(updateButton).onPressed,
        trackOnly ? isNotNull : isNull,
      );
      expect(tester.widget<TextButton>(skipButton).onPressed, isNotNull);
      if (trackOnly) {
        expect(tester.widget<FilledButton>(markButton).onPressed, isNotNull);
      }

      other.downloadProgress = null;
      provider.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(updateButton).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
