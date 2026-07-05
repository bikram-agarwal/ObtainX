import 'package:flutter/material.dart';
import 'package:obtainium/theme/app_form_field_styles.dart';

double appDropdownMenuWidth(
  BuildContext context,
  Iterable<String> labels, {
  TextStyle? style,
  double horizontalPadding = 64,
  double minWidth = 120,
  double maxWidthInset = 48,
}) {
  double maxTextWidth = 0;
  for (final String label in labels) {
    final textPainter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    if (textPainter.width > maxTextWidth) {
      maxTextWidth = textPainter.width;
    }
  }
  return (maxTextWidth + horizontalPadding).clamp(
    minWidth,
    MediaQuery.sizeOf(context).width - maxWidthInset,
  );
}

Widget appDropdownField<T>({
  Key? key,
  required BuildContext context,
  required T? value,
  required List<DropdownMenuItem<T>> items,
  required void Function(T? value) onChanged,
  String? labelText,
  bool enabled = true,
  double borderRadius = 12,
  double? menuWidth,
  bool isDense = true,
  InputDecoration? decoration,
}) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme scheme = theme.colorScheme;
  final TextStyle? dropdownTextStyle = theme.textTheme.bodyLarge?.copyWith(
    color: scheme.onSurface,
  );
  final InputDecoration fieldDecoration =
      decoration ??
      appPageOutlinedInputDecoration(
        context,
        labelText: labelText,
        borderRadius: borderRadius,
      );

  return FormField<T>(
    key: key,
    initialValue: value,
    builder: (FormFieldState<T> fieldState) {
      return ButtonTheme(
        alignedDropdown: true,
        child: InputDecorator(
          decoration: fieldDecoration.copyWith(errorText: fieldState.errorText),
          isEmpty: fieldState.value == null,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: fieldState.value,
              isExpanded: true,
              isDense: isDense,
              menuWidth: menuWidth,
              dropdownColor: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(borderRadius),
              style: dropdownTextStyle,
              iconEnabledColor: scheme.onSurfaceVariant,
              iconDisabledColor: scheme.onSurface.withValues(alpha: 0.38),
              items: items,
              onChanged: enabled
                  ? (T? newValue) {
                      fieldState.didChange(newValue);
                      onChanged(newValue);
                    }
                  : null,
            ),
          ),
        ),
      );
    },
  );
}
