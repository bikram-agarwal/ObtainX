import 'package:flutter/material.dart';

class AppSegmentedButton<T> extends StatelessWidget {
  const AppSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.style,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool multiSelectionEnabled;
  final bool emptySelectionAllowed;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<T>(
      segments: segments,
      selected: selected,
      onSelectionChanged: onSelectionChanged,
      multiSelectionEnabled: multiSelectionEnabled,
      emptySelectionAllowed: emptySelectionAllowed,
      showSelectedIcon: false,
      style: style ?? const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }
}

class AppSegmentedButtonLabel extends StatelessWidget {
  const AppSegmentedButtonLabel(this.text, {super.key, this.fontSize});

  final String text;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: fontSize == null ? null : TextStyle(fontSize: fontSize),
    );
  }
}

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
