import 'package:flutter/material.dart';

SwitchThemeData appSwitchTheme(ColorScheme colorScheme) {
  final Color enabledOffAccent = Color.lerp(
    colorScheme.onSurfaceVariant,
    colorScheme.primary,
    colorScheme.brightness == Brightness.dark ? 0.42 : 0.50,
  )!;

  return SwitchThemeData(
    thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
      if (states.contains(WidgetState.selected)) {
        return Icon(Icons.check_rounded, color: colorScheme.primary, size: 16);
      }
      return null;
    }),
    thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.disabled) ||
          states.contains(WidgetState.selected)) {
        return null;
      }
      return enabledOffAccent;
    }),
    trackOutlineColor: WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.disabled)) {
        return null;
      }
      if (states.contains(WidgetState.selected)) {
        return Colors.transparent;
      }
      return enabledOffAccent;
    }),
  );
}
