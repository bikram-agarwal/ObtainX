import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/themes_settings_section.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_page_icon_colors.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  @override
  final Map<String, ({String? title, String message})> appPageErrors = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> translations;
  late Uint8List icon;
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    icon = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
    for (final brightness in Brightness.values) {
      expect(
        await loadColorSchemeFromAppIcon(
          iconBytes: icon,
          brightness: brightness,
        ),
        isNotNull,
      );
    }
  });
  setUp(() {
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    SharedPreferences.setMockInitialValues({
      'matchAppPageToIconColors': true,
      'reduceVisualEffects': true,
      'checkUpdateOnDetailPage': false,
      'showAppWebpage': false,
      'useGradientBackground': false,
      'progressiveBlurEnabled': false,
    });
  });

  for (final additionalOptions in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '${additionalOptions ? "options" : "details"} uses global colors with reduced effects (${brightness.name})',
        (tester) async {
          final settings = SettingsProvider()
            ..prefs = await SharedPreferences.getInstance();
          final provider = _Apps();
          addTearDown(settings.dispose);
          addTearDown(provider.dispose);
          const model = App(
            id: 'org.example.app',
            url: 'https://github.com/example/app',
            author: 'Example',
            name: 'Example',
            installedVersion: '1.0.0',
            latestVersion: '1.1.0',
            preferredApkIndex: 0,
            additionalSettings: {'trackOnly': true},
          );
          provider.apps[model.id] = AppInMemory(model, null, null, icon);
          final globalColors = ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: brightness,
          );
          final iconColors = darkenIconPageSchemeInDarkMode(
            appPageSurfacesWithVisibleAccent(
              getCachedColorScheme(icon, brightness)!,
            ),
          );
          expect(iconColors.primary, isNot(globalColors.primary));
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<SettingsProvider>.value(value: settings),
                ChangeNotifierProvider<AppsProvider>.value(value: provider),
              ],
              child: MaterialApp(
                theme: ThemeData(colorScheme: globalColors),
                home: additionalOptions
                    ? AdditionalOptionsPage(appId: model.id)
                    : AppPage(appId: model.id),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
            globalColors,
          );

          settings.reduceVisualEffects = false;
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
            iconColors,
          );

          settings.reduceVisualEffects = true;
          // Check the first frame, before the post-frame color cleanup rebuild.
          await tester.pump();
          expect(
            Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
            globalColors,
          );
          await tester.pumpAndSettle();
          settings.reduceVisualEffects = false;
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(find.byType(Scaffold))).colorScheme,
            iconColors,
          );
          expect(settings.prefs!.getBool('matchAppPageToIconColors'), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('forced-off theme settings share disabled labels and switches', (
    tester,
  ) async {
    final settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    addTearDown(settings.dispose);
    final androidInfo = Completer<AndroidDeviceInfo>();
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => SingleChildScrollView(
                child: Column(
                  children: buildThemesSettingsCardItems(
                    context,
                    androidInfo.future,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.widgetWithText(
      SwitchListTile,
      translations['matchAppPageToIconColors'] as String,
    );
    expect(tester.widget<SwitchListTile>(row).value, isFalse);
    expect(tester.widget<SwitchListTile>(row).onChanged, isNull);
    final disabledLabelColor = DefaultTextStyle.of(
      tester.element(
        find.text(translations['matchAppPageToIconColors'] as String),
      ),
    ).style.color;
    for (final translationKey in [
      'settingsGradientBackground',
      'settingsProgressiveBlur',
      'matchAppPageToIconColors',
    ]) {
      final title = translations[translationKey] as String;
      final tile = find.widgetWithText(ListTile, title);
      expect(tester.widget<ListTile>(tile).enabled, isFalse);
      expect(tester.widget<ListTile>(tile).onTap, isNull);
      expect(
        DefaultTextStyle.of(tester.element(find.text(title))).style.color,
        disabledLabelColor,
      );
      final toggle = tester.widget<Switch>(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      expect(toggle.value, isFalse);
      expect(toggle.onChanged, isNull);
    }

    settings.reduceVisualEffects = false;
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(row).value, isTrue);
    expect(tester.widget<SwitchListTile>(row).onChanged, isNotNull);
    expect(settings.prefs!.getBool('matchAppPageToIconColors'), isTrue);
    for (final translationKey in [
      'settingsGradientBackground',
      'settingsProgressiveBlur',
      'matchAppPageToIconColors',
    ]) {
      final tile = find.widgetWithText(
        ListTile,
        translations[translationKey] as String,
      );
      expect(tester.widget<ListTile>(tile).enabled, isTrue);
      expect(tester.widget<ListTile>(tile).onTap, isNotNull);
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: tile, matching: find.byType(Switch)),
            )
            .onChanged,
        isNotNull,
      );
    }

    settings.theme = ThemeSettings.dark;
    settings.useBlackTheme = true;
    await tester.pumpAndSettle();
    final gradient = find.widgetWithText(
      ListTile,
      translations['settingsGradientBackground'] as String,
    );
    expect(tester.widget<ListTile>(gradient).enabled, isFalse);
    expect(tester.widget<ListTile>(gradient).onTap, isNull);
    expect(
      tester
          .widget<Switch>(
            find.descendant(of: gradient, matching: find.byType(Switch)),
          )
          .onChanged,
      isNull,
    );
    expect(
      DefaultTextStyle.of(
        tester.element(
          find.text(translations['settingsGradientBackground'] as String),
        ),
      ).style.color,
      disabledLabelColor,
    );
    settings.useBlackTheme = false;
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(gradient).enabled, isTrue);
    expect(settings.useGradientBackground, isFalse);
    expect(tester.takeException(), isNull);
  });
}
