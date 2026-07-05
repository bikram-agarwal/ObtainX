import 'package:flutter/material.dart';

const BorderRadius _kSheetRadius = BorderRadius.vertical(
  top: Radius.circular(20),
);

/// Presents [builder] as a modal bottom sheet with the app's standard chrome:
/// a rounded top, an M3 drag handle, and (optionally) full width on large
/// screens.
///
/// Pair the builder result with [AppSheetContent] so the body hugs its own
/// height, caps just below the status bar, scrolls once it would exceed that,
/// and clears the keyboard and system nav bar. Call sites must **not**
/// re-implement handles, height caps, scroll views, padding, or inset math —
/// that all lives here so every sheet behaves identically.
Future<T?> showAppModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool fullWidth = false,
  Color? backgroundColor,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    backgroundColor: backgroundColor,
    // Full width overrides the M3 default that caps sheet width on wide screens.
    constraints: fullWidth
        ? const BoxConstraints(maxWidth: double.infinity)
        : null,
    shape: const RoundedRectangleBorder(borderRadius: _kSheetRadius),
    builder: (BuildContext sheetContext) {
      final Widget sheet = builder(sheetContext);
      final ColorScheme colorScheme = Theme.of(sheetContext).colorScheme;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          fullWidth
              ? sheet
              : MediaQuery.removePadding(
                  context: sheetContext,
                  removeLeft: true,
                  removeRight: true,
                  child: sheet,
                ),
        ],
      );
    },
  );
}

/// The standard body for [showAppModalSheet]: a min-sized [Column] of
/// [children] inside a height-capped, inset-aware scroll view.
///
/// * Height hugs the content up to ([MediaQuery] height − status bar − 12);
///   shorter content produces a shorter sheet (no dead space), taller content
///   scrolls.
/// * Bottom padding tracks the keyboard when open, otherwise the system nav
///   bar, so content is never hidden behind either.
/// * Horizontal padding plus a left/right [SafeArea] keep content clear of
///   landscape display cutouts.
class AppSheetContent extends StatelessWidget {
  const AppSheetContent({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 16),
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  /// Fraction of the screen height the sheet may occupy before its content
  /// starts to scroll. Kept below 1 so the drag handle and a sliver of scrim
  /// always sit clear of the status bar (otherwise dragging the handle catches
  /// the system notification panel instead of the sheet).
  static const double maxHeightFraction = 0.90;

  /// The sheet body, laid out as a vertical column.
  final List<Widget> children;

  /// Padding around the column. The bottom value is automatically extended by
  /// the keyboard / nav-bar inset.
  final EdgeInsets padding;

  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    // Cap at [maxHeightFraction] of the screen, but never so tall that the drag
    // handle would ride up behind the status bar. The fraction alone is not
    // enough in landscape, where the screen is short and 10% headroom is only a
    // few pixels — so also keep a fixed clearance below the top system inset and
    // use whichever limit is more restrictive.
    final double byFraction = mq.size.height * maxHeightFraction;
    final double byClearance = mq.size.height - mq.viewPadding.top - 56;
    final double maxHeight = byFraction < byClearance
        ? byFraction
        : byClearance;
    // Keyboard when it's open, otherwise the system nav bar.
    final double bottomInset = mq.viewInsets.bottom > 0
        ? mq.viewInsets.bottom
        : mq.viewPadding.bottom;
    return SafeArea(
      top: false,
      bottom: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            padding.left,
            padding.top,
            padding.right,
            padding.bottom + bottomInset,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAxisAlignment,
            children: children,
          ),
        ),
      ),
    );
  }
}
