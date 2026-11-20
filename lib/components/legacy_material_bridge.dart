// Theme bridge for packages that still build with the framework's Material
// library (`package:flutter/material.dart`, deprecated from Flutter 3.50).
//
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as legacy;
import 'package:material_ui/material_ui.dart';

/// Gives [child], a widget from a package still on `package:flutter/material`,
/// the app's theme.
///
/// The app builds with `material_ui`, whose [Theme] is a different class from
/// the framework's. A package widget that calls the framework's `Theme.of`
/// (today flutter_markdown_plus, and expressive_loading_indicator when it is
/// given no colour) finds no theme of its own above it and paints with the
/// framework defaults (the baseline purple scheme, default text and card
/// colours). This maps the nearest material_ui [Theme] into a framework one.
///
/// Wrap the legacy widget itself, not an ancestor high up: the mapping reads
/// the *nearest* material_ui theme, so the per-app page themes (app page,
/// options page) still reach it. The `MaterialApp.builder` in main.dart also
/// wraps the whole app once, as a fallback for any legacy widget not wrapped
/// at its site.
///
/// Where a legacy widget takes every colour it reads as a parameter
/// (expressive_refresh's indicator, progress_indicator_m3e's linear bar), the
/// call site passes them from the material_ui theme instead; the wavy bar
/// rebuilds every animation frame, so that also keeps the mapping off the
/// frame path.
///
/// Theme only. material_ui's own MaterialUiCompatibilityBridge also builds a
/// new [Localizations] scope, which re-runs easy_localization's asynchronous
/// delegate and leaves the subtree blank for a frame each time it is inserted.
/// The framework's Material localizations are already app-wide here
/// (easy_localization's `localizationDelegates` include them).
class LegacyMaterialBridge extends StatelessWidget {
  const LegacyMaterialBridge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return legacy.Theme(data: legacyThemeFor(Theme.of(context)), child: child);
  }
}

final Expando<legacy.ThemeData> _legacyThemes = Expando<legacy.ThemeData>(
  'legacyThemes',
);

/// The framework [legacy.ThemeData] for a material_ui [theme], built once per
/// [ThemeData] instance. The app's themes are memoized and `Theme.of` caches
/// its localized copy, so repeated builds reuse the same mapping.
legacy.ThemeData legacyThemeFor(ThemeData theme) =>
    _legacyThemes[theme] ??= _mapToLegacy(theme);

// Field list from material_ui's MaterialUiCompatibilityBridge (colour scheme,
// text theme, density, platform), plus the card, divider and primary colours
// flutter_markdown_plus reads for its fallback style sheet, so changelogs
// keep the app's card and divider colours.
legacy.ThemeData _mapToLegacy(ThemeData theme) {
  final ColorScheme scheme = theme.colorScheme;
  final TextTheme textTheme = theme.textTheme;
  return legacy.ThemeData(
    platform: theme.platform,
    visualDensity: legacy.VisualDensity(
      horizontal: theme.visualDensity.horizontal,
      vertical: theme.visualDensity.vertical,
    ),
    colorScheme: legacy.ColorScheme(
      brightness: scheme.brightness,
      primary: scheme.primary,
      onPrimary: scheme.onPrimary,
      primaryContainer: scheme.primaryContainer,
      onPrimaryContainer: scheme.onPrimaryContainer,
      secondary: scheme.secondary,
      onSecondary: scheme.onSecondary,
      secondaryContainer: scheme.secondaryContainer,
      onSecondaryContainer: scheme.onSecondaryContainer,
      tertiary: scheme.tertiary,
      onTertiary: scheme.onTertiary,
      tertiaryContainer: scheme.tertiaryContainer,
      onTertiaryContainer: scheme.onTertiaryContainer,
      error: scheme.error,
      onError: scheme.onError,
      errorContainer: scheme.errorContainer,
      onErrorContainer: scheme.onErrorContainer,
      surface: scheme.surface,
      onSurface: scheme.onSurface,
      surfaceDim: scheme.surfaceDim,
      surfaceBright: scheme.surfaceBright,
      surfaceContainerLowest: scheme.surfaceContainerLowest,
      surfaceContainerLow: scheme.surfaceContainerLow,
      surfaceContainer: scheme.surfaceContainer,
      surfaceContainerHigh: scheme.surfaceContainerHigh,
      surfaceContainerHighest: scheme.surfaceContainerHighest,
      onSurfaceVariant: scheme.onSurfaceVariant,
      outline: scheme.outline,
      outlineVariant: scheme.outlineVariant,
      shadow: scheme.shadow,
      scrim: scheme.scrim,
      inverseSurface: scheme.inverseSurface,
      onInverseSurface: scheme.onInverseSurface,
      inversePrimary: scheme.inversePrimary,
      surfaceTint: scheme.surfaceTint,
    ),
    textTheme: legacy.TextTheme(
      displayLarge: textTheme.displayLarge,
      displayMedium: textTheme.displayMedium,
      displaySmall: textTheme.displaySmall,
      headlineLarge: textTheme.headlineLarge,
      headlineMedium: textTheme.headlineMedium,
      headlineSmall: textTheme.headlineSmall,
      titleLarge: textTheme.titleLarge,
      titleMedium: textTheme.titleMedium,
      titleSmall: textTheme.titleSmall,
      bodyLarge: textTheme.bodyLarge,
      bodyMedium: textTheme.bodyMedium,
      bodySmall: textTheme.bodySmall,
      labelLarge: textTheme.labelLarge,
      labelMedium: textTheme.labelMedium,
      labelSmall: textTheme.labelSmall,
    ),
    primaryColor: theme.primaryColor,
    cardColor: theme.cardColor,
    cardTheme: legacy.CardThemeData(color: theme.cardTheme.color),
    dividerColor: theme.dividerColor,
  );
}
