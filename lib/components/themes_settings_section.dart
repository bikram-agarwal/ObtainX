import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/theme_accent_settings_section.dart'
    show buildThemeAccentSettingsCardItems;
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/widgets/help_hint_icon.dart';
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
  // Narrow watch: this section only reflects six theme-related toggles.
  // Without this, every settings notify rebuilt the whole themes card.
  context.select<SettingsProvider, int>(
    (s) => Object.hash(
      s.useBlackTheme,
      s.theme,
      s.useGradientBackground,
      s.progressiveBlurEnabled,
      s.matchAppPageToIconColors,
      s.reduceVisualEffects,
    ),
  );
  final SettingsProvider settings = context.read<SettingsProvider>();

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
          selected: <_ThemeBrightnessSegment>{_segmentForSettings(settings)},
          onSelectionChanged: (Set<_ThemeBrightnessSegment> selected) {
            if (selected.isEmpty) return;
            _applyThemeSegment(settings, selected.first);
          },
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
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
    ListTile(
      title: Text(tr('settingsProgressiveBlur')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HelpHintIcon(
            message: tr('settingsProgressiveBlurSubtitle'),
            padding: EdgeInsets.zero,
          ),
          Switch(
            value: settings.progressiveBlurEnabled,
            onChanged: settings.reduceVisualEffects
                ? null
                : (bool value) {
                    settings.progressiveBlurEnabled = value;
                  },
          ),
        ],
      ),
      // Hard-disabled when the master "reduce visual effects" switch is
      // on - no point letting users toggle a control that won't take
      // effect.
      onTap: settings.reduceVisualEffects
          ? null
          : () {
              settings.progressiveBlurEnabled =
                  !settings.progressiveBlurEnabled;
            },
    ),
    SwitchListTile(
      title: Text(tr('matchAppPageToIconColors')),
      value: settings.matchAppPageToIconColors,
      onChanged: (bool value) {
        settings.matchAppPageToIconColors = value;
      },
    ),
    // Master "low-fidelity mode" toggle. Forces blur off and skips the
    // OpenContainer container-transform morph for apps-list -> AppPage
    // navigation. Single-switch escape hatch for users on weaker
    // hardware who report frame-rate drops.
    ListTile(
      title: Text(tr('settingsReduceVisualEffects')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HelpHintIcon(
            message: tr('settingsReduceVisualEffectsSubtitle'),
            padding: EdgeInsets.zero,
          ),
          Switch(
            value: settings.reduceVisualEffects,
            onChanged: (bool value) {
              settings.reduceVisualEffects = value;
            },
          ),
        ],
      ),
      onTap: () {
        settings.reduceVisualEffects = !settings.reduceVisualEffects;
      },
    ),
  ];
}
