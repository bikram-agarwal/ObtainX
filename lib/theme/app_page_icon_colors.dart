import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme/app_segmented_button_theme.dart';
import 'package:obtainium/theme/app_switch_theme.dart';
import 'package:provider/provider.dart';

/// Surfaces from [ColorScheme.fromImageProvider] are often very dark in dark mode;
/// blend them toward [ColorScheme.primary] so the hue reads clearly on the app page.
ColorScheme appPageSurfacesWithVisibleAccent(ColorScheme scheme) {
  final double surfaceTint = scheme.brightness == Brightness.dark ? 0.12 : 0.18;
  final double outlineTint = scheme.brightness == Brightness.dark ? 0.18 : 0.28;
  Color tintTowardPrimary(Color base) =>
      Color.lerp(base, scheme.primary, surfaceTint) ?? base;
  Color tintOutline(Color base) =>
      Color.lerp(base, scheme.primary, outlineTint) ?? base;

  if (scheme.brightness == Brightness.dark) {
    return scheme.copyWith(
      surface: tintTowardPrimary(scheme.surface),
      surfaceDim: tintTowardPrimary(scheme.surfaceDim),
      surfaceBright: tintTowardPrimary(scheme.surfaceBright),
      surfaceContainerLowest: tintTowardPrimary(scheme.surfaceContainerLowest),
      surfaceContainerLow: tintTowardPrimary(scheme.surfaceContainerLow),
      surfaceContainer: tintTowardPrimary(scheme.surfaceContainer),
      surfaceContainerHigh: tintTowardPrimary(scheme.surfaceContainerHigh),
      surfaceContainerHighest: tintTowardPrimary(
        scheme.surfaceContainerHighest,
      ),
      outline: tintOutline(scheme.outline),
      outlineVariant: tintOutline(scheme.outlineVariant),
    );
  }
  return scheme.copyWith(
    surfaceContainer: tintTowardPrimary(scheme.surfaceContainer),
    surfaceContainerHigh: tintTowardPrimary(scheme.surfaceContainerHigh),
    surfaceContainerHighest: tintTowardPrimary(scheme.surfaceContainerHighest),
    outlineVariant: tintOutline(scheme.outlineVariant),
  );
}

/// Pulls icon-derived dark schemes a few steps toward black so UI feels less neon.
ColorScheme darkenIconPageSchemeInDarkMode(ColorScheme scheme) {
  if (scheme.brightness != Brightness.dark) return scheme;
  const Color black = Color(0xFF000000);
  Color darken(Color color, double mix) =>
      Color.lerp(color, black, mix) ?? color;

  return scheme.copyWith(
    primary: darken(scheme.primary, 0.08),
    onPrimary: scheme.onPrimary,
    primaryContainer: darken(scheme.primaryContainer, 0.12),
    onPrimaryContainer: scheme.onPrimaryContainer,
    primaryFixed: darken(scheme.primaryFixed, 0.1),
    primaryFixedDim: darken(scheme.primaryFixedDim, 0.1),
    onPrimaryFixed: scheme.onPrimaryFixed,
    onPrimaryFixedVariant: scheme.onPrimaryFixedVariant,
    secondary: darken(scheme.secondary, 0.08),
    onSecondary: scheme.onSecondary,
    secondaryContainer: darken(scheme.secondaryContainer, 0.12),
    onSecondaryContainer: scheme.onSecondaryContainer,
    secondaryFixed: darken(scheme.secondaryFixed, 0.1),
    secondaryFixedDim: darken(scheme.secondaryFixedDim, 0.1),
    onSecondaryFixed: scheme.onSecondaryFixed,
    onSecondaryFixedVariant: scheme.onSecondaryFixedVariant,
    tertiary: darken(scheme.tertiary, 0.08),
    onTertiary: scheme.onTertiary,
    tertiaryContainer: darken(scheme.tertiaryContainer, 0.12),
    onTertiaryContainer: scheme.onTertiaryContainer,
    tertiaryFixed: darken(scheme.tertiaryFixed, 0.1),
    tertiaryFixedDim: darken(scheme.tertiaryFixedDim, 0.1),
    onTertiaryFixed: scheme.onTertiaryFixed,
    onTertiaryFixedVariant: scheme.onTertiaryFixedVariant,
    surface: darken(scheme.surface, 0.14),
    onSurface: scheme.onSurface,
    surfaceDim: darken(scheme.surfaceDim, 0.14),
    surfaceBright: darken(scheme.surfaceBright, 0.12),
    surfaceContainerLowest: darken(scheme.surfaceContainerLowest, 0.14),
    surfaceContainerLow: darken(scheme.surfaceContainerLow, 0.14),
    surfaceContainer: darken(scheme.surfaceContainer, 0.14),
    surfaceContainerHigh: darken(scheme.surfaceContainerHigh, 0.14),
    surfaceContainerHighest: darken(scheme.surfaceContainerHighest, 0.14),
    onSurfaceVariant: scheme.onSurfaceVariant,
    outline: darken(scheme.outline, 0.07),
    outlineVariant: darken(scheme.outlineVariant, 0.09),
    shadow: scheme.shadow,
    scrim: scheme.scrim,
    inverseSurface: scheme.inverseSurface,
    onInverseSurface: scheme.onInverseSurface,
    inversePrimary: scheme.inversePrimary,
    surfaceTint: darken(scheme.surfaceTint, 0.06),
  );
}

Color appPageDeeperSurfaceColor(Color base, Brightness brightness) {
  final double deepen = brightness == Brightness.dark ? 0.055 : 0.045;
  return Color.lerp(base, Colors.black, deepen) ?? base;
}

ThemeData buildAppPageThemedData(
  ThemeData parent,
  ColorScheme pageColorScheme,
) {
  return parent.copyWith(
    colorScheme: pageColorScheme,
    primaryColor: pageColorScheme.primary,
    cardColor: appPageDeeperSurfaceColor(
      pageColorScheme.surfaceContainerHighest,
      pageColorScheme.brightness,
    ),
    segmentedButtonTheme: appSegmentedButtonTheme(pageColorScheme),
    switchTheme: appSwitchTheme(pageColorScheme),
    // Dropdown menus and other overlays sometimes fall back to canvasColor.
    canvasColor: pageColorScheme.surfaceContainerHigh,
    focusColor: pageColorScheme.primary.withValues(alpha: 0.12),
  );
}

final Map<String, ColorScheme> _extractedSchemeCache = {};

// Bound the cache so navigating through a large library doesn't grow it without
// limit; evict oldest-inserted entries (Dart Maps preserve insertion order).
const int _extractedSchemeCacheMax = 64;

// Content-based key: identityHashCode would miss whenever the same icon is
// re-fetched into a new buffer (forcing an expensive ColorScheme re-extraction)
// and could even collide onto a different icon. Both callers are single-icon
// pages, so hashing one icon's bytes per lookup is cheap. Length-prefixed to
// further shrink collision odds.
String _iconSchemeCacheKey(Uint8List iconBytes, Brightness brightness) =>
    '${iconBytes.length}_${Object.hashAll(iconBytes)}_${brightness.name}';

ColorScheme? getCachedColorScheme(Uint8List iconBytes, Brightness brightness) {
  return _extractedSchemeCache[_iconSchemeCacheKey(iconBytes, brightness)];
}

Future<ColorScheme?> loadColorSchemeFromAppIcon({
  required Uint8List iconBytes,
  required Brightness brightness,
}) async {
  final String key = _iconSchemeCacheKey(iconBytes, brightness);
  if (_extractedSchemeCache.containsKey(key)) {
    return _extractedSchemeCache[key];
  }
  try {
    final ColorScheme scheme = await ColorScheme.fromImageProvider(
      provider: MemoryImage(iconBytes),
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    if (_extractedSchemeCache.length >= _extractedSchemeCacheMax) {
      _extractedSchemeCache.remove(_extractedSchemeCache.keys.first);
    }
    _extractedSchemeCache[key] = scheme;
    return scheme;
  } catch (_) {
    return null;
  }
}

/// Same visual shell as section blocks on [AppPage] (rounded card, border, shadow).
BoxDecoration appPageSectionCardDecoration(BuildContext context) {
  final bool isDark = Theme.of(context).brightness == Brightness.dark;
  final ColorScheme colorScheme = Theme.of(context).colorScheme;
  final double cardRadius = SettingsProvider.cardCornerRadiusForScale(
    28,
    context.read<SettingsProvider>().cardCornerScale,
  );
  final double sectionDeepen = isDark ? 0.055 : 0.045;
  final Color defaultSectionFill = isDark
      ? colorScheme.surfaceContainerHighest
      : colorScheme.surfaceContainer;
  final Color fill =
      Color.lerp(defaultSectionFill, Colors.black, sectionDeepen) ??
      defaultSectionFill;
  return BoxDecoration(
    color: fill,
    borderRadius: BorderRadius.circular(cardRadius),
    border: Border.all(color: colorScheme.outlineVariant, width: 1),
    boxShadow: [
      if (isDark)
        BoxShadow(
          color: colorScheme.shadow.withAlpha(180),
          blurRadius: 16,
          spreadRadius: 0,
          offset: const Offset(0, 4),
        )
      else
        BoxShadow(
          color: colorScheme.shadow.withAlpha(40),
          blurRadius: 12,
          offset: const Offset(0, 2),
        ),
    ],
  );
}
