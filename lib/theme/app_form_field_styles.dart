import 'package:flutter/material.dart';

/// Rounded outlined field style used on additional options and app edit screens.
InputDecoration appPageOutlinedInputDecoration(
  BuildContext context, {
  required String? labelText,
  String? hintText,
  bool isDense = false,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final BorderRadius radius = BorderRadius.circular(12);
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    floatingLabelBehavior: labelText == null
        ? FloatingLabelBehavior.never
        : FloatingLabelBehavior.auto,
    filled: true,
    fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
    isDense: isDense,
    contentPadding: isDense
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 12)
        : const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(borderRadius: radius),
    enabledBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: scheme.primary, width: 2),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: scheme.error),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: scheme.error, width: 2),
    ),
  );
}
