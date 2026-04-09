import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/theme_accent_settings_section.dart'
    show buildThemeAccentSettingsCardItems;
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';

enum _ThemeBrightnessSegment { system, light, dark, black }

_ThemeBrightnessSegment _segmentForSettings(SettingsProvider settings) {
  if (settings.useBlackTheme) return _ThemeBrightnessSegment.black;
  switch (settings.theme) {
    case ThemeSettings.system:
      return _ThemeBrightnessSegment.system;
    case ThemeSettings.light:
      return _ThemeBrightnessSegment.light;
    case ThemeSettings.dark:
      return _ThemeBrightnessSegment.dark;
  }
}

void _applyThemeSegment(
  SettingsProvider settings,
  _ThemeBrightnessSegment segment,
) {
  switch (segment) {
    case _ThemeBrightnessSegment.black:
      settings.useBlackTheme = true;
      settings.theme = ThemeSettings.dark;
      break;
    case _ThemeBrightnessSegment.system:
      settings.useBlackTheme = false;
      settings.theme = ThemeSettings.system;
      break;
    case _ThemeBrightnessSegment.light:
      settings.useBlackTheme = false;
      settings.theme = ThemeSettings.light;
      break;
    case _ThemeBrightnessSegment.dark:
      settings.useBlackTheme = false;
      settings.theme = ThemeSettings.dark;
      break;
  }
}

/// One M3E row each (for [settingsCard] item list).
List<Widget> buildThemesSettingsCardItems(
  BuildContext context,
  Future<AndroidDeviceInfo> androidInfoFuture,
) {
  final SettingsProvider settings = context.watch<SettingsProvider>();

  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<_ThemeBrightnessSegment>(
          segments: [
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.system,
              label: Text(
                tr('followSystem'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              icon: const Icon(Icons.brightness_auto_outlined, size: 18),
            ),
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.light,
              label: Text(
                tr('light'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              icon: const Icon(Icons.light_mode_outlined, size: 18),
            ),
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.dark,
              label: Text(
                tr('dark'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              icon: const Icon(Icons.dark_mode_outlined, size: 18),
            ),
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.black,
              label: Text(
                tr('settingsThemeBlackShort'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              icon: const Icon(Icons.square_outlined, size: 18),
            ),
          ],
          selected: <_ThemeBrightnessSegment>{
            _segmentForSettings(settings),
          },
          onSelectionChanged: (Set<_ThemeBrightnessSegment> selected) {
            if (selected.isEmpty) return;
            _applyThemeSegment(settings, selected.first);
          },
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              vertical: 10,
              horizontal: 4,
            ),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ),
    ),
    ...buildThemeAccentSettingsCardItems(androidInfoFuture),
    SwitchListTile(
      title: Text(tr('settingsGradientBackground')),
      value: settings.useGradientBackground,
      onChanged: (bool value) {
        settings.useGradientBackground = value;
      },
    ),
    SwitchListTile(
      title: Text(tr('settingsProgressiveBlur')),
      value: settings.progressiveBlurEnabled,
      onChanged: (bool value) {
        settings.progressiveBlurEnabled = value;
      },
    ),
    SwitchListTile(
      title: Text(tr('matchAppPageToIconColors')),
      value: settings.matchAppPageToIconColors,
      onChanged: (bool value) {
        settings.matchAppPageToIconColors = value;
      },
    ),
  ];
}
