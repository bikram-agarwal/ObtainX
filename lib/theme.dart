// Builds the Material 3 Expressive theme for the app.

import 'package:material_ui/material_ui.dart';

/// Builds the app-wide Material 3 Expressive [ThemeData] for a given
/// [colorScheme]. Expressive character lives here (large rounded shapes,
/// emphasized motion, updated M3 component looks) so it propagates to every
/// screen without per-widget styling.
ThemeData buildObtainiumTheme(ColorScheme colorScheme, String? fontFamily) {
  final cardShape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(AppRadii.large),
  );
  const buttonShape = StadiumBorder();
  final dialogShape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(AppRadii.xlarge),
  );
  final fieldShape = RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(AppRadii.medium),
  );

  const pillButtonStyle = ButtonStyle(
    shape: WidgetStatePropertyAll(buttonShape),
    minimumSize: WidgetStatePropertyAll(Size(0, 48)),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    fontFamily: fontFamily,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    cardTheme: CardThemeData(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: cardShape,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(shape: dialogShape),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
      // Keep Flutter's default floating insets, but clear the 48dp navigation
      // pill, its 10dp edge spacing, and an 8dp visual gap.
      insetPadding: const EdgeInsets.fromLTRB(15, 5, 15, 66),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.xlarge),
        ),
      ),
    ),
    appBarTheme: const AppBarThemeData(centerTitle: false),
    expansionTileTheme: ExpansionTileThemeData(
      shape: cardShape,
      collapsedShape: cardShape,
    ),
    listTileTheme: ListTileThemeData(shape: fieldShape),
    chipTheme: const ChipThemeData(shape: StadiumBorder()),
    searchBarTheme: const SearchBarThemeData(
      elevation: WidgetStatePropertyAll(0),
    ),
    filledButtonTheme: const FilledButtonThemeData(style: pillButtonStyle),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: pillButtonStyle),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: pillButtonStyle),
    // Matches upstream (03bef37f). main.dart merges appTextButtonTheme over
    // it, and that style's non-null fields win.
    textButtonTheme: const TextButtonThemeData(style: pillButtonStyle),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(AppRadii.fab),
      ),
      // FAB shadow depth. Tweak these to try different values (M3 default is 6).
      // `elevation` is the resting shadow; the others apply on interaction.
      elevation: 4,
      focusElevation: 6,
      hoverElevation: 8,
      highlightElevation: 6,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
      ),
      menuStyle: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(AppRadii.medium),
          ),
        ),
      ),
    ),
    sliderTheme: SliderThemeData(
      // `year2023: false` opts these components into the updated Material 3
      // appearance. The flag is deprecated by Flutter and will be removed once
      // the new look becomes the framework default, at which point these lines
      // (and the `ignore` directives) can simply be deleted with no visual
      // change. There is no replacement API to migrate to in the meantime.
      // Tracking: https://github.com/flutter/flutter/issues/162186
      // ignore: deprecated_member_use
      year2023: false,
      activeTrackColor: colorScheme.primary,
      inactiveTrackColor: colorScheme.surfaceContainerHighest,
      thumbColor: colorScheme.primary,
      overlayColor: colorScheme.primary.withValues(alpha: 0.12),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      // See the note on `sliderTheme.year2023` above; no replacement API exists
      // and this can be removed once the M3 look is the framework default.
      // Tracking: https://github.com/flutter/flutter/issues/162186
      // ignore: deprecated_member_use
      year2023: false,
    ),
  );
}

/// Corner radius for the outer corners of a connected tile run.
const double connectedTileBigRadius = 24;

/// Corner radius for the inner (joined) corners of a connected tile run.
const double connectedTileSmallRadius = 6;

BorderRadius positionalTileRadius({
  required bool isFirst,
  required bool isLast,
}) {
  return BorderRadius.vertical(
    top: Radius.circular(
      isFirst ? connectedTileBigRadius : connectedTileSmallRadius,
    ),
    bottom: Radius.circular(
      isLast ? connectedTileBigRadius : connectedTileSmallRadius,
    ),
  );
}

abstract final class ExpressiveMotion {
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  static const Duration short = Durations.short4;
  static const Duration medium = Durations.medium2;
}

// Upstream's spacing/radius tokens (790fabb9), kept as shared vocabulary so
// ported upstream code compiles unchanged (v1.7.4 sync, D3). Fork surfaces
// don't use them: card and tile corners go through
// `SettingsProvider.cardCornerRadiusFor` and the `kM3e*` constants in
// theme/m3e_expressive_list.dart, never [AppRadii], whose fixed values would
// bypass the user's card-corner scale. [AppSpacings.sectionGap] is upstream's
// 24, not the fork's old 20; no fork widget reads it.
abstract final class AppSpacings {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const double elementGap = sm;
  static const double sectionGap = xl;
  static const double connectedGap = 3;
  static const double listGap = xs;
}

abstract final class AppPaddings {
  static const EdgeInsets pageHorizontal = EdgeInsets.symmetric(
    horizontal: AppSpacings.lg,
  );
  static const EdgeInsets page = EdgeInsets.fromLTRB(
    AppSpacings.lg,
    0,
    AppSpacings.lg,
    0,
  );
  static const EdgeInsets cardInner = EdgeInsets.all(AppSpacings.lg);
  static const EdgeInsets inputContent = EdgeInsets.symmetric(
    horizontal: AppSpacings.lg,
    vertical: AppSpacings.lg,
  );
  static const EdgeInsets listOuter = EdgeInsets.fromLTRB(
    AppSpacings.md,
    AppSpacings.xs,
    AppSpacings.md,
    AppSpacings.xs,
  );
  static const EdgeInsets rowHorizontal = EdgeInsets.symmetric(
    horizontal: AppSpacings.lg,
  );
  static const EdgeInsets sliderTile = EdgeInsets.fromLTRB(
    AppSpacings.lg,
    AppSpacings.sm,
    AppSpacings.lg,
    AppSpacings.sm,
  );
  static const EdgeInsets sectionHeader = EdgeInsets.fromLTRB(
    AppSpacings.lg,
    AppSpacings.xl,
    AppSpacings.lg,
    AppSpacings.sm,
  );
  static const EdgeInsets listSectionHeader = EdgeInsets.fromLTRB(
    28,
    0,
    28,
    AppSpacings.sm,
  );
}

abstract final class AppRadii {
  static const double inline = 4;
  static const double xs = 8;
  static const double small = 12;
  static const double medium = 16;
  static const double fab = 20;
  static const double large = 24;
  static const double xlarge = 28;
}

abstract final class AppIconSizes {
  static const double small = 16;
  static const double medium = 20;
  static const double large = 24;
}

/// The type style used for section labels throughout the app.
TextStyle? sectionHeaderTextStyle(BuildContext context) => Theme.of(context)
    .textTheme
    .titleMedium
    ?.copyWith(
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.onSurface,
    );
