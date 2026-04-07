import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:provider/provider.dart';

/// FilePipe-style accent row: default, Material You, presets, saved hex, add.
class ThemeAccentSettingsSection extends StatelessWidget {
  const ThemeAccentSettingsSection({super.key});

  static const double _swatchSize = 52;
  static const double _innerSize = 44;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final SettingsProvider settings = context.watch<SettingsProvider>();

    Future<void> showAddHexDialog() async {
      final TextEditingController controller = TextEditingController();
      try {
        await showDialog<void>(
          context: context,
          builder: (BuildContext dialogContext) {
            return StatefulBuilder(
              builder: (BuildContext ctx, StateSetter setDialogState) {
                final ColorScheme dialogScheme = Theme.of(ctx).colorScheme;
                final String? normalizedHex =
                    normalizeCustomSeedHexOrNull(controller.text);
                final Color? parsedColor =
                    colorFromNormalizedHex(normalizedHex);
                final bool isInvalid =
                    controller.text.isNotEmpty && parsedColor == null;

                return AlertDialog(
                  title: Text(tr('settingsCustomSeedDialogTitle')),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 44,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: parsedColor ??
                              dialogScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: dialogScheme.outlineVariant,
                            width: 1.5,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: isInvalid
                            ? Text(
                                tr('invalid'),
                                style: TextStyle(
                                  color: dialogScheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        tr('settingsCustomSeedRowHint'),
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              color: dialogScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: controller,
                        decoration: InputDecoration(
                          hintText: '#RRGGBB',
                          labelText: tr('settingsCustomSeedHint'),
                        ),
                        autofocus: true,
                        textCapitalization: TextCapitalization.characters,
                        onChanged: (_) => setDialogState(() {}),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(tr('cancel')),
                    ),
                    TextButton(
                      onPressed: parsedColor != null
                          ? () {
                              settings.addCustomSeedHex(controller.text);
                              Navigator.of(dialogContext).pop();
                            }
                          : null,
                      child: Text(tr('ok')),
                    ),
                  ],
                );
              },
            );
          },
        );
      } finally {
        controller.dispose();
      }
    }

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

    final bool paletteEnabled =
        settings.appAccentColorSource != AppAccentColorSource.materialYou;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('settingsThemeColorsHint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            tr('settingsCustomSeedRowHint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: _swatchSize,
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
                      selected: _customHexSelected(settings, storedHex),
                      onTap: () => settings.selectSavedCustomSeedHex(storedHex),
                      onLongPress: () => confirmRemoveHex(storedHex),
                    ),
                  ),
                _AddCustomHexSwatch(onTap: showAddHexDialog),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr('settingsPaletteStyle'),
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (int paletteIndex = 0;
                    paletteIndex < AppThemePaletteStyleX.all.length;
                    paletteIndex++) ...[
                  if (paletteIndex > 0) const SizedBox(width: 8),
                  FilterChip(
                    label: Text(
                      tr(
                        'themePalette_${AppThemePaletteStyleX.all[paletteIndex].name}',
                      ),
                    ),
                    selected: settings.appThemePaletteStyle ==
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
        ],
      ),
    );
  }

  bool _customHexSelected(SettingsProvider settings, String storedHex) {
    if (settings.appAccentColorSource != AppAccentColorSource.custom) {
      return false;
    }
    final String? activeNorm =
        normalizeCustomSeedHexOrNull(settings.activeCustomSeedHex);
    final String? storedNorm = normalizeCustomSeedHexOrNull(storedHex);
    if (activeNorm != null && storedNorm != null) {
      return activeNorm == storedNorm;
    }
    return settings.activeCustomSeedHex.trim() == storedHex.trim();
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
            width: ThemeAccentSettingsSection._swatchSize,
            height: ThemeAccentSettingsSection._swatchSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: borderColor,
                width: selected ? 3 : 1,
              ),
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
    const double inner = ThemeAccentSettingsSection._innerSize;
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
          child: Container(
            width: inner,
            height: inner,
            color: fill,
          ),
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
            width: ThemeAccentSettingsSection._swatchSize,
            height: ThemeAccentSettingsSection._swatchSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: borderColor,
                width: selected ? 3 : 1,
              ),
            ),
            alignment: Alignment.center,
            child: ClipOval(
              child: Container(
                width: ThemeAccentSettingsSection._innerSize,
                height: ThemeAccentSettingsSection._innerSize,
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
  const _AddCustomHexSwatch({required this.onTap});

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
            width: ThemeAccentSettingsSection._swatchSize,
            height: ThemeAccentSettingsSection._swatchSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.35),
              ),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.add,
              size: 26,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
