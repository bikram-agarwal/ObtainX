import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:obtainium/components/theme_accent_settings_section.dart'
    show buildThemeAccentSettingsCardItems;
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/components/tv_slider_wrapper.dart';
import 'package:obtainium/theme/app_segmented_button_theme.dart';
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
      settings.setThemeAppearance(
        theme: ThemeSettings.dark,
        useBlackTheme: true,
      );
      break;
    case _ThemeBrightnessSegment.system:
      settings.setThemeAppearance(
        theme: ThemeSettings.system,
        useBlackTheme: false,
      );
      break;
    case _ThemeBrightnessSegment.light:
      settings.setThemeAppearance(
        theme: ThemeSettings.light,
        useBlackTheme: false,
      );
      break;
    case _ThemeBrightnessSegment.dark:
      settings.setThemeAppearance(
        theme: ThemeSettings.dark,
        useBlackTheme: false,
      );
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
      s.shadingIntensity,
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
        child: AppSegmentedButton<_ThemeBrightnessSegment>(
          segments: [
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.system,
              label: AppSegmentedButtonLabel(
                tr('followSystem'),
                fontSize: 11.5,
              ),
              icon: const Icon(Icons.brightness_auto_outlined, size: 18),
            ),
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.light,
              label: AppSegmentedButtonLabel(tr('light'), fontSize: 11.5),
              icon: const Icon(Icons.light_mode_outlined, size: 18),
            ),
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.dark,
              label: AppSegmentedButtonLabel(tr('dark'), fontSize: 11.5),
              icon: const Icon(Icons.dark_mode_outlined, size: 18),
            ),
            ButtonSegment<_ThemeBrightnessSegment>(
              value: _ThemeBrightnessSegment.black,
              label: AppSegmentedButtonLabel(
                tr('settingsThemeBlackShort'),
                fontSize: 11.5,
              ),
              icon: const Icon(Icons.square_outlined, size: 18),
            ),
          ],
          selected: <_ThemeBrightnessSegment>{_segmentForSettings(settings)},
          onSelectionChanged: (Set<_ThemeBrightnessSegment> selected) {
            if (selected.isEmpty) return;
            _applyThemeSegment(settings, selected.first);
          },
          style: SegmentedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ),
    ),
    ...buildThemeAccentSettingsCardItems(androidInfoFuture),
    _ShadingIntensityTile(settings: settings),
    ListTile(
      title: Text(tr('settingsGradientBackground')),
      trailing: IgnorePointer(
        ignoring: settings.useBlackTheme,
        child: Switch(
          value: settings.useBlackTheme
              ? false
              : settings.useGradientBackground,
          onChanged: settings.useBlackTheme
              ? null
              : (bool value) {
                  settings.useGradientBackground = value;
                },
        ),
      ),
      onTap: () {
        if (settings.useBlackTheme) {
          const String snackbarMessageKey =
              'settingsGradientDisabledInBlackTheme';
          final String snackbarMessage =
              trExists(snackbarMessageKey, context: context)
              ? tr(snackbarMessageKey)
              : 'Can not enable in black theme';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(snackbarMessage),
              duration: const Duration(seconds: 4),
            ),
          );
          return;
        }
        settings.useGradientBackground = !settings.useGradientBackground;
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

class _ShadingIntensityTile extends StatefulWidget {
  const _ShadingIntensityTile({required this.settings});

  final SettingsProvider settings;

  @override
  State<_ShadingIntensityTile> createState() => _ShadingIntensityTileState();
}

class _ShadingIntensityTileState extends State<_ShadingIntensityTile> {
  late final FocusNode _sliderFocusNode;

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
    final bool enabled = !widget.settings.useBlackTheme;
    final Color titleColor = enabled
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: 0.38);
    final Color subtitleColor = enabled
        ? colorScheme.onSurfaceVariant
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.38);
    final double sliderValue = widget.settings.shadingIntensity;
    final isTV = context.read<SettingsProvider>().isTV;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('settingsShadingIntensity'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(color: titleColor),
                ),
              ),
              Text(
                _shadingIntensityLabel(sliderValue),
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: titleColor),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            tr('settingsShadingIntensitySubtitle'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: subtitleColor),
          ),
          const SizedBox(height: 10),
          TVSliderWrapper(
            value: sliderValue,
            min: 0,
            max: 2,
            divisions: 20,
            onChanged: enabled
                ? (double value) {
                    widget.settings.shadingIntensity = value;
                  }
                : (double value) {},
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 16,
                trackShape: const _ShadingGappedTrackShape(),
                thumbShape: const _ShadingVerticalBarThumbShape(),
                tickMarkShape: const RoundSliderTickMarkShape(
                  tickMarkRadius: 3,
                ),
                activeTickMarkColor: colorScheme.onPrimary,
                inactiveTickMarkColor: colorScheme.primary,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
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
                        widget.settings.shadingIntensity = value;
                      }
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _shadingIntensityLabel(double value) {
  return '${(value * 100).round()}%';
}

class _ShadingVerticalBarThumbShape extends SliderComponentShape {
  const _ShadingVerticalBarThumbShape();

  static const double _width = 4;
  static const double _height = 28;
  static const double _radius = 2;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(_width, _height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Rect trackRect = sliderTheme.trackShape!.getPreferredRect(
      parentBox: parentBox,
      offset: Offset.zero,
      sliderTheme: sliderTheme,
      isEnabled: enableAnimation.value > 0,
      isDiscrete: isDiscrete,
    );
    final double trackHeight = trackRect.height;
    final double trackWidth = trackRect.width;
    Offset alignedCenter = center;
    if (trackWidth > trackHeight) {
      final double valueRatio = textDirection == TextDirection.rtl
          ? 1.0 - value
          : value;
      final double alignedX =
          trackRect.left +
          valueRatio * (trackWidth - trackHeight) +
          trackHeight / 2;
      alignedCenter = Offset(alignedX, center.dy);
    }
    final Canvas canvas = context.canvas;
    final Paint paint = Paint()
      ..color = sliderTheme.thumbColor ?? Colors.white
      ..style = PaintingStyle.fill;
    final RRect thumb = RRect.fromRectAndRadius(
      Rect.fromCenter(center: alignedCenter, width: _width, height: _height),
      const Radius.circular(_radius),
    );
    canvas.drawRRect(thumb, paint);
  }
}

class _ShadingGappedTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _ShadingGappedTrackShape();

  static const int _divisions = 20;
  static const double _gap = 4;
  static const double _radius = 8;
  static const double _tickRadius = 2.75;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final Canvas canvas = context.canvas;
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    double thumbX = thumbCenter.dx;
    final double trackHeight = trackRect.height;
    final double trackWidth = trackRect.width;
    if (trackWidth > trackHeight) {
      final double valueRatio = ((thumbCenter.dx - trackRect.left) / trackWidth)
          .clamp(0.0, 1.0);
      thumbX =
          trackRect.left +
          valueRatio * (trackWidth - trackHeight) +
          trackHeight / 2;
    }

    final Paint activePaint = Paint()
      ..color = sliderTheme.activeTrackColor ?? Colors.blue;
    final Paint inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor ?? Colors.grey;

    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
          trackRect.left,
          trackRect.top,
          thumbX - _gap,
          trackRect.bottom,
        ),
        topLeft: const Radius.circular(_radius),
        bottomLeft: const Radius.circular(_radius),
      ),
      activePaint,
    );

    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
          thumbX + _gap,
          trackRect.top,
          trackRect.right,
          trackRect.bottom,
        ),
        topRight: const Radius.circular(_radius),
        bottomRight: const Radius.circular(_radius),
      ),
      inactivePaint,
    );

    final Paint tickPaint = Paint()..style = PaintingStyle.fill;
    for (int tickIndex = 1; tickIndex < _divisions; tickIndex++) {
      final double tickRatio = tickIndex / _divisions;
      final double tickX =
          trackRect.left +
          tickRatio * (trackWidth - trackHeight) +
          trackHeight / 2;
      final bool isActive = textDirection == TextDirection.rtl
          ? tickX > thumbX
          : tickX < thumbX;
      tickPaint.color = isActive
          ? sliderTheme.activeTickMarkColor ??
                sliderTheme.activeTrackColor ??
                Colors.white
          : sliderTheme.inactiveTickMarkColor ??
                sliderTheme.inactiveTrackColor ??
                Colors.grey;
      canvas.drawCircle(
        Offset(tickX, trackRect.center.dy),
        _tickRadius,
        tickPaint,
      );
    }
  }
}
