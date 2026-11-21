import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:obtainium/locale_resolution.dart';
import 'package:obtainium/main.dart'
    show esperantoLocale, fallbackLocale, supportedLocales;
import 'package:obtainium/providers/settings_provider.dart';

/// Who picks ObtainX's language.
///
/// On Android 13+, Android has a per-app language screen, and where the device
/// can open it, it replaces ObtainX's own language list: one setting instead
/// of two that could disagree, and the date order follows it (#355). Elsewhere
/// (Android 8-12, and devices without the screen, such as some TV builds) the
/// in-app list stays.
///
/// Esperanto is only in the in-app list: Android can't offer it (see
/// android/app/src/main/res/xml/locales_config.xml), so where Android's screen
/// takes over, it is no longer available.
class AppLanguage {
  static const MethodChannel _channel = MethodChannel(
    'dev.imranr.obtainium/device_apps',
  );

  /// Whether Android's per-app language screen replaces the in-app list.
  /// Set once at startup by [init].
  static bool usesSystemSetting = false;

  static Future<void> init() async {
    try {
      usesSystemSetting =
          await _channel.invokeMethod<bool>('appLanguageSettingsAvailable') ??
          false;
    } on PlatformException {
      usesSystemSetting = false;
    } on MissingPluginException {
      usesSystemSetting = false;
    }
  }

  static Future<void> openSystemSettings() async {
    try {
      await _channel.invokeMethod<bool>('openAppLanguageSettings');
    } on PlatformException {
      // Nothing to open; [usesSystemSetting] said there was.
    } on MissingPluginException {
      // Non-Android builds have no such screen.
    }
  }

  /// Moves a language picked in the in-app list, before Android's screen took
  /// over, to Android's setting, so nobody's language changes with the update.
  ///
  /// The in-app choice keeps showing until Android reports the new language
  /// ([onSystemLocaleChanged]): clearing it first would flash the phone's
  /// language. Esperanto, which Android can't take, is dropped, and ObtainX
  /// follows Android's setting from then on. [platformLocale] is the locale
  /// Android reports now.
  static Future<void> moveInAppChoiceToSystem(
    SettingsProvider settings,
    Locale platformLocale,
  ) async {
    if (!usesSystemSetting) return;
    final Locale? inAppChoice = settings.forcedLocale;
    if (inAppChoice == null) return;
    final bool androidCanTakeIt = inAppChoice != esperantoLocale;
    final bool alreadyShown =
        resolveBestSupportedLocale(
          deviceLocale: platformLocale,
          supportedLocales: [for (final e in supportedLocales) e.key],
          fallbackLocale: fallbackLocale,
        ) ==
        inAppChoice;
    if (!androidCanTakeIt || alreadyShown) {
      settings.forcedLocale = null;
      return;
    }
    try {
      await _channel.invokeMethod<bool>('setAppLanguage', <String, String>{
        'languageTag': inAppChoice.toLanguageTag(),
      });
    } on PlatformException {
      // Tried again at the next start; the in-app choice still applies.
    } on MissingPluginException {
      // Unreachable: [usesSystemSetting] is only true on Android.
    }
  }

  /// Android reported a language change. Where Android's screen has taken
  /// over, an in-app choice left from before is cleared, so ObtainX shows the
  /// language Android now has: the one [moveInAppChoiceToSystem] handed over,
  /// or one the user picked in Android's settings.
  static void onSystemLocaleChanged(SettingsProvider settings) {
    if (usesSystemSetting && settings.forcedLocale != null) {
      settings.forcedLocale = null;
    }
  }
}
