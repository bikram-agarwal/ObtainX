import 'package:flutter/material.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:provider/provider.dart';

/// Material 3 expressive grouped-list radii and gaps (matches apps tab list).
const double kM3eOuterRadius = 14.0;
const double kM3eInnerRadius = 4.0;
const double kM3eItemGap = 3.0;

/// Outer radius for elevated grouped surfaces such as apps-list groups.
const double kM3eGroupCardRadius = 20.0;

/// Gap between expansion group header and first row in apps list body.
const double kM3eHeaderToFirstCardGap = 3.0;

enum M3eListGroupPosition { first, middle, last, only }

/// Corner radii for one row in a vertical stack. Use [flatListBody]: true for
/// rows inside a settings/import-style card or ungrouped apps list runs.
BorderRadius m3eListGroupItemRadius(
  M3eListGroupPosition position, {
  required bool flatListBody,
  double outerRadius = kM3eOuterRadius,
}) {
  if (flatListBody) {
    return switch (position) {
      M3eListGroupPosition.first => BorderRadius.only(
        topLeft: Radius.circular(outerRadius),
        topRight: Radius.circular(outerRadius),
        bottomLeft: const Radius.circular(kM3eInnerRadius),
        bottomRight: const Radius.circular(kM3eInnerRadius),
      ),
      M3eListGroupPosition.middle => BorderRadius.circular(kM3eInnerRadius),
      M3eListGroupPosition.last => BorderRadius.only(
        topLeft: const Radius.circular(kM3eInnerRadius),
        topRight: const Radius.circular(kM3eInnerRadius),
        bottomLeft: Radius.circular(outerRadius),
        bottomRight: Radius.circular(outerRadius),
      ),
      M3eListGroupPosition.only => BorderRadius.only(
        topLeft: Radius.circular(outerRadius),
        topRight: Radius.circular(outerRadius),
        bottomLeft: Radius.circular(outerRadius),
        bottomRight: Radius.circular(outerRadius),
      ),
    };
  }
  return switch (position) {
    M3eListGroupPosition.first => BorderRadius.circular(kM3eInnerRadius),
    M3eListGroupPosition.middle => BorderRadius.circular(kM3eInnerRadius),
    M3eListGroupPosition.last => BorderRadius.only(
      topLeft: const Radius.circular(kM3eInnerRadius),
      topRight: const Radius.circular(kM3eInnerRadius),
      bottomLeft: Radius.circular(outerRadius),
      bottomRight: Radius.circular(outerRadius),
    ),
    M3eListGroupPosition.only => BorderRadius.only(
      topLeft: const Radius.circular(kM3eInnerRadius),
      topRight: const Radius.circular(kM3eInnerRadius),
      bottomLeft: Radius.circular(outerRadius),
      bottomRight: Radius.circular(outerRadius),
    ),
  };
}

M3eListGroupPosition m3eFlatStackSlotPosition(int index, int itemCount) {
  if (itemCount <= 1) return M3eListGroupPosition.only;
  if (index == 0) return M3eListGroupPosition.first;
  if (index == itemCount - 1) return M3eListGroupPosition.last;
  return M3eListGroupPosition.middle;
}

Color m3eGroupedListRowFill(ColorScheme scheme) {
  if (scheme.usesPureBlackBackgrounds) return Colors.black;
  return Color.lerp(scheme.surfaceContainer, scheme.primary, 0.08)!;
}

Color m3eGroupedListBackdropFill(ColorScheme scheme) => scheme.surface;

BorderSide m3ePureBlackOutlineSide(ColorScheme scheme, {double alpha = 0.18}) {
  if (!scheme.usesPureBlackBackgrounds) {
    return BorderSide.none;
  }
  return BorderSide(color: scheme.onSurface.withValues(alpha: alpha));
}

/// Tighter [DropdownMenu] anchor field (language, backup scope, etc.).
ThemeData m3eCompactDropdownTheme(ThemeData base) {
  return base.copyWith(
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
  );
}

Widget m3eCompactDropdownScope({
  required BuildContext context,
  required Widget child,
}) {
  return Theme(data: m3eCompactDropdownTheme(Theme.of(context)), child: child);
}

/// Central Material 3 expressive row stack for settings-style grouped lists.
Widget m3eExpressiveSettingsCard({
  required BuildContext context,
  required ColorScheme colorScheme,
  required List<Widget> items,
  double itemGap = kM3eItemGap,
}) {
  final ThemeData theme = Theme.of(context);
  final SettingsProvider settingsProvider = context.read<SettingsProvider>();
  final double cardCornerScale = settingsProvider.cardCornerScale;
  final double itemOuterRadius = SettingsProvider.cardCornerRadiusForScale(
    kM3eOuterRadius,
    cardCornerScale,
  );
  final BorderSide blackThemeOutlineSide = m3ePureBlackOutlineSide(
    colorScheme,
    alpha: 0.22,
  );
  return Theme(
    data: theme.copyWith(dividerColor: Colors.transparent),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int itemIndex = 0; itemIndex < items.length; itemIndex++) ...[
          if (itemIndex > 0) SizedBox(height: itemGap),
          Material(
            color: m3eGroupedListRowFill(colorScheme),
            shape: RoundedRectangleBorder(
              borderRadius: m3eListGroupItemRadius(
                m3eFlatStackSlotPosition(itemIndex, items.length),
                flatListBody: true,
                outerRadius: itemOuterRadius,
              ),
              side: blackThemeOutlineSide,
            ),
            clipBehavior: Clip.antiAlias,
            child: items[itemIndex],
          ),
        ],
      ],
    ),
  );
}
