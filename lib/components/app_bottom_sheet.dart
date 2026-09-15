import 'dart:math' as math;
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';

/// Presents [builder] as a modal bottom sheet with the app's standard chrome:
/// the themed M3 Expressive shape, the framework drag handle, and (optionally)
/// full width on large
/// screens.
///
/// Pair the builder result with [AppSheetContent] or [AppSheetScaffold] so the
/// body caps just below the status bar, scrolls once it would exceed that, and
/// clears the keyboard and system nav bar. Call sites must **not**
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
    // The handle is drawn by _AppSheetChrome instead of the framework so it can
    // yield its 48dp strip back to the content on a short viewport.
    showDragHandle: false,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    backgroundColor: backgroundColor,
    // Full width overrides the M3 default that caps sheet width on wide screens.
    constraints: fullWidth
        ? const BoxConstraints(maxWidth: double.infinity)
        : null,
    builder: (BuildContext sheetContext) {
      final Widget sheet = builder(sheetContext);
      return Padding(
        // Keep the sheet itself above the keyboard. Putting this inset inside
        // the scroll view only adds hidden space below the focused field and
        // leaves the visible content behind the keyboard.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: _AppSheetChrome(
          enableDrag: enableDrag,
          child: fullWidth
              ? sheet
              : MediaQuery.removePadding(
                  context: sheetContext,
                  removeLeft: true,
                  removeRight: true,
                  child: sheet,
                ),
        ),
      );
    },
  );
}

/// The drag handle and the top clearance above a sheet's content.
///
/// This replaces the framework's own handle so that a sheet squeezed by the
/// keyboard can spend that 48dp strip on its body instead: on a landscape phone
/// the strip is a third of everything the sheet has left. Dragging the sheet
/// body still dismisses it, so nothing is lost but the grip affordance.
class _AppSheetChrome extends StatelessWidget {
  const _AppSheetChrome({required this.child, required this.enableDrag});

  final Widget child;
  final bool enableDrag;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool tight =
            constraints.maxHeight <
            _appSheetTightHeight + kMinInteractiveDimension;
        final bool showHandle = enableDrag && !tight;
        // Read the status bar off the view: showModalBottomSheet strips the top
        // padding from the sheet's MediaQuery (its own height cap is meant to
        // keep the sheet clear of it), but a sheet squeezed by the keyboard does
        // reach the top of the screen.
        final FlutterView view = View.of(context);
        final double statusBarInset =
            view.viewPadding.top / view.devicePixelRatio;
        return Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[
            // Kept in the same slot in both layouts: swapping children in and
            // out of a Stack re-parents the sheet below it, which would rebuild
            // whatever the user is typing in and drop its focus.
            SizedBox(
              height: kMinInteractiveDimension,
              child: showHandle ? const _AppSheetDragHandle() : null,
            ),
            Padding(
              padding: EdgeInsets.only(
                top: showHandle
                    ? kMinInteractiveDimension
                    // Without the handle the content would start at the sheet's
                    // very top edge, so it takes over the status-bar clearance.
                    : (tight ? statusBarInset : 0),
              ),
              child: child,
            ),
          ],
        );
      },
    );
  }
}

/// Mirrors the framework's M3 bottom-sheet drag handle.
class _AppSheetDragHandle extends StatelessWidget {
  const _AppSheetDragHandle();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Size handleSize =
        theme.bottomSheetTheme.dragHandleSize ?? const Size(32, 4);
    return Semantics(
      container: true,
      button: true,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onTap: () => Navigator.maybePop(context),
      child: Center(
        child: Container(
          height: handleSize.height,
          width: handleSize.width,
          decoration: BoxDecoration(
            color:
                theme.bottomSheetTheme.dragHandleColor ??
                theme.colorScheme.onSurfaceVariant,
            borderRadius: BorderRadius.circular(handleSize.height / 2),
          ),
        ),
      ),
    );
  }
}

double _appSheetMaxHeight(BuildContext context) {
  final MediaQueryData mediaQuery = MediaQuery.of(context);
  final double byFraction =
      mediaQuery.size.height * AppSheetContent.maxHeightFraction;
  final double byClearance =
      mediaQuery.size.height - mediaQuery.viewPadding.top - 56;
  return byFraction < byClearance ? byFraction : byClearance;
}

/// Content height below which a sheet has to trade chrome for body height.
///
/// A landscape phone with the keyboard open leaves roughly 100dp for sheet
/// content, while a header (~56dp) plus an action row (~56dp) already exceeds
/// that. Under this threshold [AppSheetScaffold] tightens the action row's own
/// padding and touch targets so the body keeps enough room to show a field.
const double _appSheetTightHeight = 240;

/// Shared structure for sheets that need a fixed header and action area around
/// a separately scrollable body.
///
/// This owns the height cap, safe-area handling, footer treatment, and system
/// navigation inset. Specialized sheets provide only their content and actions.
class AppSheetScaffold extends StatefulWidget {
  const AppSheetScaffold({
    super.key,
    required this.header,
    this.body,
    this.bodyChildren,
    this.footer,
    this.expand = false,
    this.headerPadding = const EdgeInsets.fromLTRB(20, 0, 20, 8),
    this.bodyPadding = EdgeInsets.zero,
    this.footerPadding = const EdgeInsets.fromLTRB(16, 8, 16, 8),
  }) : assert(
         (body == null) != (bodyChildren == null),
         'Pass exactly one of body or bodyChildren.',
       );

  final Widget header;

  /// The body, when the call site brings its own scroll view (a [ListView], a
  /// [SingleChildScrollView], …).
  ///
  /// Prefer [bodyChildren] where the body is just a column of widgets: owning
  /// the scroll view lets this scaffold scroll the header along with the body,
  /// which is what keeps short viewports usable (see [_appSheetTightHeight]).
  final Widget? body;

  /// The body as a column of widgets this scaffold scrolls itself, together
  /// with [header].
  final List<Widget>? bodyChildren;

  final Widget? footer;

  /// Whether the sheet should fill its available height even when its body is
  /// short. Reading and large selection surfaces generally opt into this.
  final bool expand;

  final EdgeInsetsGeometry headerPadding;
  final EdgeInsetsGeometry bodyPadding;
  final EdgeInsets footerPadding;

  @override
  State<AppSheetScaffold> createState() => _AppSheetScaffoldState();
}

class _AppSheetScaffoldState extends State<AppSheetScaffold> {
  /// Stable identities for the two sections that can change place in the tree
  /// when a [body] sheet runs out of height. Without them the subtree is rebuilt
  /// rather than moved, which drops the focus (and the scroll offset) of
  /// whatever the user was typing in as the keyboard opens.
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _bodyKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // padding, not viewPadding: an open keyboard covers the system nav bar, and
    // showAppModalSheet has already lifted the whole sheet above the keyboard,
    // so re-adding the nav-bar inset here would only eat height the body needs.
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // The incoming constraint already accounts for the keyboard and for
          // the drag handle the framework overlays on top of the sheet, so it —
          // not the MediaQuery cap alone — is the real height budget.
          final double maxHeight = math.min(
            _appSheetMaxHeight(context),
            constraints.maxHeight,
          );
          final bool tight =
              widget.footer != null && maxHeight < _appSheetTightHeight;
          final Widget headerSection = KeyedSubtree(
            key: _headerKey,
            child: Padding(padding: widget.headerPadding, child: widget.header),
          );
          final Widget? footerSection = widget.footer == null
              ? null
              : Material(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      widget.footerPadding.left,
                      tight ? 4 : widget.footerPadding.top,
                      widget.footerPadding.right,
                      (tight ? 4 : widget.footerPadding.bottom) + bottomInset,
                    ),
                    // A tight sheet buys body height back from the action row:
                    // padding first, then the buttons' own density. 40dp targets
                    // match what appTextButtonTheme already ships app-wide.
                    child: tight
                        ? Theme(
                            data: theme.copyWith(
                              visualDensity: VisualDensity.compact,
                            ),
                            child: widget.footer!,
                          )
                        : widget.footer,
                  ),
                );

          // A body this scaffold owns scrolls together with the header, in every
          // viewport. One scrolling surface that never has to be restructured is
          // what lets a focused field keep its focus — and its scroll position —
          // while the keyboard shrinks the sheet around it.
          if (widget.bodyChildren != null) {
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SizedBox(
                height: widget.expand ? maxHeight : null,
                child: Column(
                  mainAxisSize: widget.expand
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            headerSection,
                            KeyedSubtree(
                              key: _bodyKey,
                              child: Padding(
                                padding: widget.bodyPadding,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: widget.bodyChildren!,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ?footerSection,
                  ],
                ),
              ),
            );
          }

          final Widget bodySection = KeyedSubtree(
            key: _bodyKey,
            child: Padding(padding: widget.bodyPadding, child: widget.body),
          );
          if (tight) {
            // The call site owns the body's scroll view, so the header can only
            // get out of the way by scrolling above a bounded slice of it.
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          headerSection,
                          SizedBox(height: maxHeight, child: bodySection),
                        ],
                      ),
                    ),
                  ),
                  footerSection!,
                ],
              ),
            );
          }
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SizedBox(
              height: widget.expand ? maxHeight : null,
              child: Column(
                mainAxisSize: widget.expand
                    ? MainAxisSize.max
                    : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  headerSection,
                  if (widget.expand)
                    Expanded(child: bodySection)
                  else
                    Flexible(child: bodySection),
                  ?footerSection,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The standard body for [showAppModalSheet]: a min-sized [Column] of
/// [children] inside a height-capped, inset-aware scroll view.
///
/// * Height hugs the content up to ([MediaQuery] height − status bar − 12);
///   shorter content produces a shorter sheet (no dead space), taller content
///   scrolls.
/// * The sheet boundary tracks the keyboard while bottom padding clears the
///   system nav bar, so focused fields can scroll into the visible area.
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
  /// the system nav-bar inset, except while the keyboard covers that bar.
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
    final double maxHeight = _appSheetMaxHeight(context);
    // padding, not viewPadding: see AppSheetScaffold — an open keyboard covers
    // the nav bar, and the sheet is already lifted above the keyboard.
    final double bottomInset = mq.padding.bottom;
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
