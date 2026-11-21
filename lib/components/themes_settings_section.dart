import 'package:obtainium/components/m3e_slider_theme.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/theme_accent_settings_section.dart'
    show buildThemeAccentSettingsCardItems;
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/components/tv_slider_wrapper.dart';
import 'package:obtainium/components/ui_widgets.dart'
    show AppSwitch, AppSwitchListTile, ExplainedWhenOff;
import 'package:obtainium/theme/app_segmented_button_theme.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:obtainium/widgets/help_hint_icon.dart';
import 'package:provider/provider.dart';

/// One M3E row each (for [settingsCard] item list).
List<Widget> buildThemesSettingsCardItems(
  BuildContext context,
  Future<AndroidDeviceInfo> androidInfoFuture,
) {
  // Narrow watch: this section only reflects theme-related settings.
  // Without this, every settings notify rebuilt the whole themes card.
  context.select<SettingsProvider, int>(
    (s) => Object.hash(
      s.useBlackTheme,
      s.blackThemeActive,
      s.theme,
      s.useGradientBackground,
      s.shadingIntensity,
      s.progressiveBlurEnabled,
      s.matchAppPageToIconColors,
      s.reduceVisualEffects,
    ),
  );
  final SettingsProvider settings = context.read<SettingsProvider>();

  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(
        kM3eSettingsCardHorizontalInset,
        8,
        kM3eSettingsCardHorizontalInset,
        8,
      ),
      child: SizedBox(
        width: double.infinity,
        child: AppSegmentedButton<ThemeSettings>(
          segments: [
            ButtonSegment<ThemeSettings>(
              value: ThemeSettings.system,
              label: AppSegmentedButtonLabel(
                tr('followSystem'),
                fontSize: 11.5,
              ),
              icon: const Icon(Icons.brightness_auto_outlined, size: 18),
            ),
            ButtonSegment<ThemeSettings>(
              value: ThemeSettings.light,
              label: AppSegmentedButtonLabel(tr('light'), fontSize: 11.5),
              icon: const Icon(Icons.light_mode_outlined, size: 18),
            ),
            ButtonSegment<ThemeSettings>(
              value: ThemeSettings.dark,
              label: AppSegmentedButtonLabel(tr('dark'), fontSize: 11.5),
              icon: const Icon(Icons.dark_mode_outlined, size: 18),
            ),
          ],
          selected: <ThemeSettings>{settings.theme},
          onSelectionChanged: (Set<ThemeSettings> selected) {
            if (selected.isEmpty) return;
            settings.theme = selected.first;
          },
          style: const ButtonStyle(
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            ),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.padded,
            side: WidgetStatePropertyAll(BorderSide.none),
          ),
        ),
      ),
    ),
    if (settings.theme != ThemeSettings.light)
      AppSwitchListTile(
        title: Text(tr('useBlackTheme')),
        value: settings.useBlackTheme,
        onChanged: (bool value) {
          settings.useBlackTheme = value;
        },
      ),
    ...buildThemeAccentSettingsCardItems(androidInfoFuture),
    _ShadingIntensityTile(settings: settings),
    AppSwitchListTile(
      title: Text(tr('settingsGradientBackground')),
      value: settings.useGradientBackground,
      onChanged: settings.reduceVisualEffects || settings.blackThemeActive
          ? null
          : (bool value) {
              settings.useGradientBackground = value;
            },
    ),
    ListTile(
      enabled: !settings.reduceVisualEffects,
      title: Text(tr('settingsProgressiveBlur')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HelpHintIcon(
            message: tr('settingsProgressiveBlurSubtitle'),
            padding: EdgeInsets.zero,
          ),
          AppSwitch(
            semanticLabel: tr('settingsProgressiveBlur'),
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
    AppSwitchListTile(
      title: Text(tr('matchAppPageToIconColors')),
      value: settings.matchAppPageToIconColors,
      onChanged: settings.reduceVisualEffects
          ? null
          : (bool value) {
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
          AppSwitch(
            semanticLabel: tr('settingsReduceVisualEffects'),
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

class _ShadingIntensityTile extends StatefulWidget {
  const _ShadingIntensityTile({required this.settings});

  final SettingsProvider settings;

  @override
  State<_ShadingIntensityTile> createState() => _ShadingIntensityTileState();
}

class _ShadingIntensityTileState extends State<_ShadingIntensityTile> {
  late final FocusNode _sliderFocusNode;

  // Live drag value; committed to settings only on drag end so the (expensive)
  // live re-shading doesn't run every frame and stutter — matches the other
  // sliders (e.g. the bg-update-interval slider in settings.dart).
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    _sliderFocusNode = FocusNode(canRequestFocus: false, skipTraversal: true);
  }

  @override
  void dispose() {
    _sliderFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool enabled = !widget.settings.blackThemeActive;
    final double sliderValue = _dragValue ?? widget.settings.shadingIntensity;
    final isTV = context.read<SettingsProvider>().isTV;

    final Color textColor = enabled
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: 0.38);
    return ExplainedWhenOff(
      reason: enabled ? null : tr('settingsGradientDisabledInBlackTheme'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kM3eSettingsCardHorizontalInset,
          10,
          kM3eSettingsCardHorizontalInset,
          12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('settingsShadingIntensity'),
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: textColor),
                  ),
                ),
                Text(
                  _shadingIntensityLabel(sliderValue),
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: textColor),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              tr('settingsShadingIntensitySubtitle'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            TVSliderWrapper(
              enabled: enabled,
              value: sliderValue,
              min: 0,
              max: 2,
              divisions: 20,
              onChanged: (double value) {
                setState(() => _dragValue = value);
              },
              onChangeEnd: (double value) {
                widget.settings.shadingIntensity = value;
                setState(() => _dragValue = null);
              },
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 16,
                  trackShape: const M3eGappedTrackShape(),
                  thumbShape: const M3eVerticalBarThumbShape(),
                  activeTickMarkColor: colorScheme.onPrimary,
                  inactiveTickMarkColor: colorScheme.primary,
                  disabledActiveTrackColor: colorScheme.onSurface.withValues(
                    alpha: 0.38,
                  ),
                  disabledInactiveTrackColor: colorScheme.onSurface.withValues(
                    alpha: 0.12,
                  ),
                  disabledThumbColor: colorScheme.onSurface.withValues(
                    alpha: 0.38,
                  ),
                  disabledActiveTickMarkColor: colorScheme.onSurface.withValues(
                    alpha: 0.38,
                  ),
                  disabledInactiveTickMarkColor: colorScheme.onSurface
                      .withValues(alpha: 0.38),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  focusNode: isTV ? _sliderFocusNode : null,
                  value: sliderValue,
                  min: 0,
                  max: 2,
                  divisions: 20,
                  label: _shadingIntensityLabel(sliderValue),
                  onChanged: enabled
                      ? (double value) {
                          setState(() => _dragValue = value);
                        }
                      : null,
                  onChangeEnd: enabled
                      ? (double value) {
                          widget.settings.shadingIntensity = value;
                          setState(() => _dragValue = null);
                        }
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _shadingIntensityLabel(double value) {
  return '${(value * 100).round()}%';
}
