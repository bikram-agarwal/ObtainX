import 'package:flutter/material.dart';

SegmentedButtonThemeData appSegmentedButtonTheme(ColorScheme colorScheme) {
  final Color selectedFill = Color.lerp(
    colorScheme.primaryContainer,
    colorScheme.primary,
    0.18,
  )!;

  return SegmentedButtonThemeData(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return selectedFill;
        }
        return null;
      }),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return colorScheme.onPrimaryContainer;
        }
        return colorScheme.onSurface;
      }),
      iconColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return colorScheme.onPrimaryContainer;
        }
        return colorScheme.onSurfaceVariant;
      }),
      side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
        if (states.contains(WidgetState.disabled)) {
          return null;
        }
        if (states.contains(WidgetState.selected)) {
          return BorderSide(color: colorScheme.primary, width: 1);
        }
        return BorderSide(color: colorScheme.outlineVariant, width: 1);
      }),
    ),
  );
}
