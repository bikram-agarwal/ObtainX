import 'package:flutter/material.dart';

/// Flutter's default M3 [TextButton] reserves a 48dp-tall touch target
/// ([MaterialTapTargetSize.padded]) even though the visible label is only
/// ~20dp tall - on a dialog's compact action row that invisible padding is
/// the single biggest contributor to the "half the dialog is empty space
/// under two small buttons" look (bigger than [DialogThemeData.actionsPadding]
/// itself, which only wraps the row - see app_dialog_theme.dart). Shrinking
/// the tap target app-wide fixes every dialog's action row without touching
/// each dialog individually; [TextButton] is used almost exclusively for
/// dialog actions and a handful of inline links in this app, so the effect
/// is scoped in practice even though the theme token isn't dialog-specific.
TextButtonThemeData appTextButtonTheme() {
  return TextButtonThemeData(
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 36),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}
