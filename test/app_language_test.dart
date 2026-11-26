// Where Android's per-app language screen replaces the in-app list
// (AppLanguage), a language picked in that list before moves to Android's
// setting without the screen changing language, and Esperanto, which Android
// can't take, is dropped.

import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/main.dart' show esperantoLocale;
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/app_language.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel deviceAppsChannel = MethodChannel(
    'dev.imranr.obtainium/device_apps',
  );
  late List<MethodCall> calls;
  late SettingsProvider settings;

  setUp(() async {
    calls = [];
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    AppLanguage.usesSystemSetting = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceAppsChannel, (MethodCall call) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() {
    AppLanguage.usesSystemSetting = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceAppsChannel, null);
    settings.dispose();
  });

  test(
    'hands an in-app language to Android and keeps it until Android has it',
    () async {
      settings.forcedLocale = const Locale('de');
      await AppLanguage.moveInAppChoiceToSystem(
        settings,
        const Locale('en', 'US'),
      );
      expect(calls.single.method, 'setAppLanguage');
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['languageTag'],
        'de',
      );
      // Still German on screen until Android reports the change.
      expect(settings.forcedLocale, const Locale('de'));

      AppLanguage.onSystemLocaleChanged(settings);
      expect(settings.forcedLocale, isNull);
    },
  );

  test('clears an in-app language Android already shows', () async {
    settings.forcedLocale = const Locale('de');
    await AppLanguage.moveInAppChoiceToSystem(
      settings,
      const Locale('de', 'DE'),
    );
    expect(calls, isEmpty);
    expect(settings.forcedLocale, isNull);
  });

  test('drops Esperanto, which Android cannot take', () async {
    settings.forcedLocale = esperantoLocale;
    await AppLanguage.moveInAppChoiceToSystem(
      settings,
      const Locale('en', 'US'),
    );
    expect(calls, isEmpty);
    expect(settings.forcedLocale, isNull);
  });

  test('leaves the in-app list alone where Android has no screen', () async {
    AppLanguage.usesSystemSetting = false;
    settings.forcedLocale = const Locale('de');
    await AppLanguage.moveInAppChoiceToSystem(
      settings,
      const Locale('en', 'US'),
    );
    AppLanguage.onSystemLocaleChanged(settings);
    expect(calls, isEmpty);
    expect(settings.forcedLocale, const Locale('de'));
  });
}
