import 'package:flutter/material.dart';

/// Material 3's default [AlertDialog] leaves 24px of pure [actionsPadding]
/// below the action buttons (on top of their own ~40dp touch height and the
/// 24px [contentPadding] bottom already above them) - on a short dialog
/// (a couple of lines of body text) that reads as roughly half the dialog
/// being dead space under two small text buttons. Tightened app-wide here
/// rather than per-dialog so every [AlertDialog] benefits without being
/// touched individually.
DialogThemeData appDialogTheme() {
  return const DialogThemeData(
    actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
  );
}

/// [AlertDialog.contentPadding] has no theme-level equivalent to
/// [appDialogTheme] - it's a constructor param on the widget itself, not
/// something [DialogThemeData] can override - so every [AlertDialog] with a
/// [AlertDialog.content] should pass this explicitly to match the tightened
/// [appDialogTheme] actions row instead of leaving Material 3's default
/// (`EdgeInsets.only(left: 24, top: 16, right: 24, bottom: 24)`) gap above
/// the buttons.
const EdgeInsets appDialogContentPadding = EdgeInsets.fromLTRB(24, 16, 24, 16);
