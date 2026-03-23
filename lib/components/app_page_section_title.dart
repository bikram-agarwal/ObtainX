import 'package:flutter/material.dart';

/// Shared ALL CAPS section title for app cards and additional-options section cards.
/// Slightly larger than default [TextTheme.labelSmall].
TextStyle? appPageCardSectionTitleTextStyle(
  BuildContext context, {
  Color? color,
}) {
  final ThemeData theme = Theme.of(context);
  return theme.textTheme.labelSmall?.copyWith(
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    fontSize: 13.5,
    height: 1.3,
    color: color ?? theme.colorScheme.onSurfaceVariant,
  );
}

Widget appPageCardSectionHeaderLabel(
  BuildContext context,
  String title, {
  Color? color,
}) {
  return Text(
    title.toUpperCase(),
    style: appPageCardSectionTitleTextStyle(context, color: color),
  );
}
