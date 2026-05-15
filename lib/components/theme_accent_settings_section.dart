import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:provider/provider.dart';

const double _kAccentSwatchSize = 52;
const double _kAccentInnerSize = 44;

/// One M3E card row each (swatches with label, palette).
List<Widget> buildThemeAccentSettingsCardItems(
  Future<AndroidDeviceInfo> androidInfoFuture,
) {
  return <Widget>[
    const _ThemeAccentSwatchesItem(),
    _ThemeAccentPaletteItem(androidInfoFuture: androidInfoFuture),
  ];
}

class _ThemeAccentSwatchesItem extends StatefulWidget {
  const _ThemeAccentSwatchesItem();

  @override
  State<_ThemeAccentSwatchesItem> createState() =>
      _ThemeAccentSwatchesItemState();
}

class _ThemeAccentSwatchesItemState extends State<_ThemeAccentSwatchesItem> {
  bool _customColorPickerExpanded = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // Narrow subscription — only rebuilds the swatches grid when a
    // custom-seed hex is added/removed/selected or the accent source
    // changes.
    context.select<SettingsProvider, int>(
      (s) => Object.hash(
        s.appAccentColorSource,
        s.activeCustomSeedHex,
        Object.hashAll(s.savedCustomSeedHexes),
      ),
    );
    final SettingsProvider settings = context.read<SettingsProvider>();

    Future<void> confirmRemoveHex(String hex) async {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text(tr('settingsCustomSeedRemoveTitle')),
            content: Text(tr('settingsCustomSeedRemoveMessage')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(tr('cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(tr('remove')),
              ),
            ],
          );
        },
      );
      if (ok == true) settings.removeCustomSeedHex(hex);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('settingsThemeColorsHint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: _kAccentSwatchSize,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final AppAccentColorSource source
                    in AppAccentColorSourceX.accentPickerOrder)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _AccentSourceSwatch(
                      source: source,
                      selected: settings.appAccentColorSource == source,
                      onTap: () {
                        settings.appAccentColorSource = source;
                      },
                    ),
                  ),
                for (final String storedHex in settings.savedCustomSeedHexes)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _CustomHexSwatch(
                      hex: storedHex,
                      selected: _customHexSwatchSelected(settings, storedHex),
                      onTap: () => settings.selectSavedCustomSeedHex(storedHex),
                      onLongPress: () => confirmRemoveHex(storedHex),
                    ),
                  ),
                _AddCustomHexSwatch(
                  expanded: _customColorPickerExpanded,
                  onTap: () {
                    setState(() {
                      _customColorPickerExpanded = !_customColorPickerExpanded;
                    });
                  },
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _customColorPickerExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _CustomColorSliderPanel(
                      seedHex: _sliderSeedHexForSettings(settings, scheme),
                      onPreviewColor: settings.previewCustomSeedHex,
                      onSaveColor: settings.addCustomSeedHex,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

bool _customHexSwatchSelected(SettingsProvider settings, String storedHex) {
  if (settings.appAccentColorSource != AppAccentColorSource.custom) {
    return false;
  }
  final String? activeNorm = normalizeCustomSeedHexOrNull(
    settings.activeCustomSeedHex,
  );
  final String? storedNorm = normalizeCustomSeedHexOrNull(storedHex);
  if (activeNorm != null && storedNorm != null) {
    return activeNorm == storedNorm;
  }
  return settings.activeCustomSeedHex.trim() == storedHex.trim();
}

String _sliderSeedHexForSettings(
  SettingsProvider settings,
  ColorScheme scheme,
) {
  if (settings.appAccentColorSource == AppAccentColorSource.custom) {
    final String? active = normalizeCustomSeedHexOrNull(
      settings.activeCustomSeedHex,
    );
    if (active != null) return active;
  }
  final Color? seed = settings.appAccentColorSource.seedOrNull;
  return colorToCanonicalHex(seed ?? scheme.primary);
}

const double _kCustomHexChipWidth = 84;
const Duration _kCustomHexDebounce = Duration(milliseconds: 450);

class _CustomColorSliderPanel extends StatefulWidget {
  const _CustomColorSliderPanel({
    required this.seedHex,
    required this.onPreviewColor,
    required this.onSaveColor,
  });

  final String seedHex;
  final ValueChanged<String> onPreviewColor;
  final ValueChanged<String> onSaveColor;

  @override
  State<_CustomColorSliderPanel> createState() =>
      _CustomColorSliderPanelState();
}

class _CustomColorSliderPanelState extends State<_CustomColorSliderPanel> {
  late String _selectedHex;
  late final TextEditingController _hexController;
  final FocusNode _hexFocusNode = FocusNode();
  final Object _hexTapRegionGroup = Object();
  Timer? _hexDebounce;
  bool _hexEditing = false;

  @override
  void initState() {
    super.initState();
    _selectedHex = _normalizedOrDefault(widget.seedHex);
    _hexController = TextEditingController();
    _syncHexController();
  }

  @override
  void didUpdateWidget(covariant _CustomColorSliderPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String nextHex = _normalizedOrDefault(widget.seedHex);
    if (nextHex == _selectedHex) return;
    _hexDebounce?.cancel();
    setState(() {
      _selectedHex = nextHex;
      _syncHexController();
    });
  }

  @override
  void dispose() {
    _hexDebounce?.cancel();
    _hexController.dispose();
    _hexFocusNode.dispose();
    super.dispose();
  }

  String _normalizedOrDefault(String raw) {
    return normalizeCustomSeedHexOrNull(raw) ??
        colorToCanonicalHex(obtainiumThemeColor);
  }

  void _syncHexController() {
    final String text = _selectedHex.substring(1);
    _hexController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _startHexEditing() {
    _hexDebounce?.cancel();
    _syncHexController();
    setState(() {
      _hexEditing = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _hexFocusNode.requestFocus();
    });
  }

  String _finishHexEditing() {
    _hexDebounce?.cancel();
    if (!_hexEditing) return _selectedHex;

    final String? normalized = normalizeCustomSeedHexOrNull(
      _hexController.text,
    );
    if (normalized != null) {
      _selectedHex = normalized;
      widget.onPreviewColor(normalized);
    }
    _syncHexController();
    setState(() {
      _hexEditing = false;
    });
    return _selectedHex;
  }

  void _scheduleHexPreview() {
    _hexDebounce?.cancel();
    final String raw = _hexController.text;
    if (raw.length != 6) return;
    _hexDebounce = Timer(_kCustomHexDebounce, () {
      if (!mounted) return;
      final String? normalized = normalizeCustomSeedHexOrNull(raw);
      if (normalized == null) return;
      setState(() {
        _selectedHex = normalized;
      });
      widget.onPreviewColor(normalized);
    });
  }

  void _handleSliderChanged(String hex) {
    _hexDebounce?.cancel();
    final String normalized = _normalizedOrDefault(hex);
    setState(() {
      _selectedHex = normalized;
      _syncHexController();
    });
  }

  void _rejectHexInput() {
    HapticFeedback.vibrate();
    SystemSound.play(SystemSoundType.alert);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 18, 18, 22),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('settingsCustomSeedSliderTitle'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _buildHexChip(context),
              const SizedBox(width: 8),
              SizedBox(
                width: 42,
                height: 42,
                child: IconButton.filledTonal(
                  tooltip: tr('ok'),
                  onPressed: () {
                    final String hex = _finishHexEditing();
                    widget.onSaveColor(hex);
                  },
                  icon: const Icon(Icons.check_rounded),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _HueColorSlider(
            hex: _selectedHex,
            onChanged: _handleSliderChanged,
            onChangeEnd: (String hex) {
              _handleSliderChanged(hex);
              widget.onPreviewColor(hex);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHexChip(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle textStyle =
        (theme.textTheme.labelLarge ??
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))
            .copyWith(
              color: scheme.onSurfaceVariant,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
            );

    final BoxDecoration decoration = BoxDecoration(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: scheme.outlineVariant),
    );

    if (!_hexEditing) {
      return SizedBox(
        width: _kCustomHexChipWidth,
        height: 36,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: _startHexEditing,
            child: DecoratedBox(
              decoration: decoration,
              child: Center(
                child: Text(_selectedHex, maxLines: 1, style: textStyle),
              ),
            ),
          ),
        ),
      );
    }

    return TapRegion(
      groupId: _hexTapRegionGroup,
      onTapOutside: (_) => _finishHexEditing(),
      child: SizedBox(
        width: _kCustomHexChipWidth,
        height: 36,
        child: DecoratedBox(
          decoration: decoration,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text('#', style: textStyle),
                Expanded(
                  child: TextField(
                    controller: _hexController,
                    focusNode: _hexFocusNode,
                    inputFormatters: [
                      _HexInputFormatter(onReject: _rejectHexInput),
                    ],
                    maxLines: 1,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.done,
                    style: textStyle,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      counterText: '',
                      isCollapsed: true,
                    ),
                    onChanged: (_) => _scheduleHexPreview(),
                    onEditingComplete: _finishHexEditing,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HexInputFormatter extends TextInputFormatter {
  const _HexInputFormatter({required this.onReject});

  final VoidCallback onReject;

  static final RegExp _validHex = RegExp(r'^[0-9a-fA-F]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length > 6 || !_validHex.hasMatch(newValue.text)) {
      onReject();
      return oldValue;
    }

    final String upperText = newValue.text.toUpperCase();
    int clampOffset(int offset) => offset.clamp(0, upperText.length).toInt();
    return TextEditingValue(
      text: upperText,
      selection: TextSelection(
        baseOffset: clampOffset(newValue.selection.baseOffset),
        extentOffset: clampOffset(newValue.selection.extentOffset),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
      composing: TextRange.empty,
    );
  }
}

class _HueColorSlider extends StatelessWidget {
  const _HueColorSlider({
    required this.hex,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String hex;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color selectedColor =
        colorFromNormalizedHex(normalizeCustomSeedHexOrNull(hex)) ??
        scheme.primary;
    final double hue = _hueFromHexColor(hex);

    return SizedBox(
      height: 52,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: _HueSliderTrackBackground(
                value: (hue / 360).clamp(0, 1).toDouble(),
                gapColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 28,
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              secondaryActiveTrackColor: Colors.transparent,
              disabledActiveTrackColor: Colors.transparent,
              disabledInactiveTrackColor: Colors.transparent,
              thumbColor: selectedColor,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const _HueSliderThumbShape(),
              tickMarkShape: SliderTickMarkShape.noTickMark,
            ),
            child: Slider(
              min: 0,
              max: 360,
              value: hue.clamp(0, 360).toDouble(),
              onChanged: (double value) => onChanged(_colorHexFromHue(value)),
              onChangeEnd: (double value) =>
                  onChangeEnd(_colorHexFromHue(value)),
            ),
          ),
        ],
      ),
    );
  }
}

class _HueSliderTrackBackground extends StatelessWidget {
  const _HueSliderTrackBackground({
    required this.value,
    required this.gapColor,
  });

  final double value;
  final Color gapColor;
  static const double _trackHeight = 28;
  static const double _gapWidth = 16;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double thumbRadius = _HueSliderThumbShape.width / 2;
        final double usableWidth = (width - _HueSliderThumbShape.width).clamp(
          0.0,
          double.infinity,
        );
        final double gapCenter = thumbRadius + usableWidth * value;

        return Center(
          child: SizedBox(
            height: _trackHeight,
            width: double.infinity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_trackHeight / 2),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: _kHueSliderColors),
                    ),
                  ),
                  Positioned(
                    left: gapCenter - _gapWidth / 2,
                    width: _gapWidth,
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: gapColor),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

const List<Color> _kHueSliderColors = [
  Color(0xFFF54545),
  Color(0xFFF5F545),
  Color(0xFF45F545),
  Color(0xFF45F5F5),
  Color(0xFF4545F5),
  Color(0xFFF545F5),
  Color(0xFFF54545),
];

String _colorHexFromHue(double hue) {
  final double normalizedHue = hue >= 360 ? 0 : hue.clamp(0, 360).toDouble();
  return colorToCanonicalHex(
    HSVColor.fromAHSV(1, normalizedHue, 0.72, 0.96).toColor(),
  );
}

double _hueFromHexColor(String hex) {
  final Color? color = colorFromNormalizedHex(
    normalizeCustomSeedHexOrNull(hex),
  );
  if (color == null) return 0;
  return HSVColor.fromColor(color).hue;
}

class _HueSliderThumbShape extends SliderComponentShape {
  const _HueSliderThumbShape();

  static const double width = 4;
  static const double _height = 48;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(width, _height);
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
    final Color color = sliderTheme.thumbColor ?? Colors.white;
    final Rect rect = Rect.fromCenter(
      center: center,
      width: width,
      height: _height,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2)),
      Paint()..color = color,
    );
  }
}

class _ThemeAccentPaletteItem extends StatelessWidget {
  const _ThemeAccentPaletteItem({required this.androidInfoFuture});

  final Future<AndroidDeviceInfo> androidInfoFuture;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // Narrow watch: this section reflects only the accent source and
    // palette-style selector.
    context.select<SettingsProvider, int>(
      (s) => Object.hash(s.appAccentColorSource, s.appThemePaletteStyle),
    );
    final SettingsProvider settings = context.read<SettingsProvider>();
    final bool paletteEnabled =
        settings.appAccentColorSource != AppAccentColorSource.materialYou;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('settingsPaletteStyle'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (
                  int paletteIndex = 0;
                  paletteIndex < AppThemePaletteStyleX.all.length;
                  paletteIndex++
                ) ...[
                  if (paletteIndex > 0) const SizedBox(width: 8),
                  FilterChip(
                    label: Text(
                      tr(
                        'themePalette_${AppThemePaletteStyleX.all[paletteIndex].name}',
                      ),
                    ),
                    selected:
                        settings.appThemePaletteStyle ==
                        AppThemePaletteStyleX.all[paletteIndex],
                    onSelected: paletteEnabled
                        ? (bool selected) {
                            if (selected) {
                              settings.appThemePaletteStyle =
                                  AppThemePaletteStyleX.all[paletteIndex];
                            }
                          }
                        : null,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ],
            ),
          ),
          FutureBuilder<AndroidDeviceInfo>(
            future: androidInfoFuture,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<AndroidDeviceInfo> snapshot,
                ) {
                  final int sdkInt = snapshot.data?.version.sdkInt ?? 0;
                  if (sdkInt >= 31) return const SizedBox.shrink();
                  if (settings.appAccentColorSource !=
                      AppAccentColorSource.materialYou) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      tr('settingsMaterialYouHint'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
          ),
        ],
      ),
    );
  }
}

class _AccentSourceSwatch extends StatelessWidget {
  const _AccentSourceSwatch({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final AppAccentColorSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color borderColor = selected
        ? scheme.primary
        : scheme.outline.withValues(alpha: 0.35);
    return Semantics(
      button: true,
      selected: selected,
      label: tr('accentSource_${source.name}'),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: _kAccentSwatchSize,
            height: _kAccentSwatchSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: borderColor, width: selected ? 3 : 1),
            ),
            alignment: Alignment.center,
            child: _AccentCircleContent(source: source),
          ),
        ),
      ),
    );
  }
}

class _AccentCircleContent extends StatelessWidget {
  const _AccentCircleContent({required this.source});

  final AppAccentColorSource source;

  @override
  Widget build(BuildContext context) {
    const double inner = _kAccentInnerSize;
    switch (source) {
      case AppAccentColorSource.appDefault:
        return ClipOval(
          child: SizedBox(
            width: inner,
            height: inner,
            child: Row(
              children: [
                Expanded(child: Container(color: const Color(0xFF1B5EA8))),
                Expanded(child: Container(color: const Color(0xFF576270))),
                Expanded(child: Container(color: const Color(0xFF006874))),
              ],
            ),
          ),
        );
      case AppAccentColorSource.materialYou:
        return SizedBox(
          width: inner,
          height: inner,
          child: Icon(
            Icons.palette_outlined,
            size: 28,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      default:
        final Color? seed = source.seedOrNull;
        final Color fill =
            seed ?? Theme.of(context).colorScheme.surfaceContainerHighest;
        return ClipOval(
          child: Container(width: inner, height: inner, color: fill),
        );
    }
  }
}

class _CustomHexSwatch extends StatelessWidget {
  const _CustomHexSwatch({
    required this.hex,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final String hex;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color borderColor = selected
        ? scheme.primary
        : scheme.outline.withValues(alpha: 0.35);
    final Color fill =
        colorFromNormalizedHex(normalizeCustomSeedHexOrNull(hex) ?? '') ??
        scheme.surfaceContainerHighest;
    return Semantics(
      button: true,
      selected: selected,
      label: hex,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          customBorder: const CircleBorder(),
          child: Container(
            width: _kAccentSwatchSize,
            height: _kAccentSwatchSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: borderColor, width: selected ? 3 : 1),
            ),
            alignment: Alignment.center,
            child: ClipOval(
              child: Container(
                width: _kAccentInnerSize,
                height: _kAccentInnerSize,
                color: fill,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddCustomHexSwatch extends StatelessWidget {
  const _AddCustomHexSwatch({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: tr('settingsCustomSeedDialogTitle'),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: _kAccentSwatchSize,
            height: _kAccentSwatchSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
            ),
            alignment: Alignment.center,
            child: Icon(
              expanded ? Icons.keyboard_arrow_down_rounded : Icons.add,
              size: 26,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
