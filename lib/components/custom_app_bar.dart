import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:provider/provider.dart';

class CustomAppBar extends StatefulWidget {
  const CustomAppBar({
    super.key,
    required this.title,
    this.leading,
    this.actions,
    this.bottom,
    this.searchWidget,
    this.titleStyle,
  });

  final String title;

  /// Toolbar leading widget (e.g. back). When null, no leading slot is shown.
  final Widget? leading;
  final List<Widget>? actions;

  /// Optional widget pinned below the flexible title (e.g. a search field).
  /// Pass a [PreferredSizeWidget] such as [PreferredSize].
  final PreferredSizeWidget? bottom;

  /// When provided, replaces the expanding-title layout with a compact inline
  /// row: [Title text]  [Expanded(searchWidget)]  [actions].
  final Widget? searchWidget;

  /// Optional style override for the compact layout title.
  final TextStyle? titleStyle;

  @override
  State<CustomAppBar> createState() => _CustomAppBarState();
}

class _CustomAppBarState extends State<CustomAppBar> {
  // Single BackdropFilter pass + colour tint gradient. See
  // [ProgressiveTopEdgeOverlay] for the rationale: the previous two-layer
  // implementation cost ~2x as much GPU per frame and produced 30 fps
  // drops on mid-range Android during apps-list scroll. The colour tint
  // gradient handles the "progressive" feel that the second blur used to
  // provide.
  static const double _blurSigma = 4.0;

  /// Progressive-blur widget passed straight to [SliverAppBar.flexibleSpace]
  /// (not [FlexibleSpaceBar.background]) so it never fades during collapse.
  /// Wrapped in [RepaintBoundary] to isolate the blur layer's composition
  /// from neighbouring widgets' dirty rects.
  Widget _buildBlur(Color overlayColor) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: _blurSigma,
                  sigmaY: _blurSigma,
                ),
                child: const SizedBox.expand(),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      overlayColor,
                      overlayColor.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final TextStyle titleBaseLarge = Theme.of(context).textTheme.titleLarge!;
    final TextStyle resolvedCompactTitle =
        (widget.titleStyle ??
                Theme.of(context).appBarTheme.titleTextStyle ??
                titleBaseLarge)
            .copyWith(color: colorScheme.onSurface);

    // [Selector] instead of [context.watch] so that the persistent app
    // bar — which sits on every page — only rebuilds when this single
    // setting flips, not on every unrelated SettingsProvider notify
    // (categories, swipe actions, sort changes, etc.).
    final bool blurEnabled = context.select<SettingsProvider, bool>(
      (s) => s.progressiveBlurEnabled,
    );

    final Color solidHeaderColor = colorScheme.surface;

    Widget? blurWidget;
    if (blurEnabled) {
      blurWidget = _buildBlur(colorScheme.schemeProgressiveBlurOverlayTint);
    }

    if (widget.searchWidget != null) {
      // Compact layout — blur passed straight as flexibleSpace so the
      // toolbar title/actions render on top of it, not behind it.
      return SliverAppBar(
        pinned: true,
        automaticallyImplyLeading: false,
        leading: widget.leading,
        actions: widget.actions,
        titleSpacing: 0,
        bottom: widget.bottom,
        elevation: 0,
        scrolledUnderElevation: 0,
        shadowColor: Colors.transparent,
        backgroundColor:
            blurEnabled ? Colors.transparent : solidHeaderColor,
        surfaceTintColor:
            blurEnabled ? Colors.transparent : colorScheme.surfaceTint,
        forceMaterialTransparency: blurEnabled,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        actionsIconTheme: IconThemeData(color: colorScheme.onSurface),
        flexibleSpace: blurWidget,
        title: Padding(
          padding: EdgeInsets.only(
            left: widget.leading != null ? 0 : 20,
            right: 4,
          ),
          child: Row(
            children: [
              // Wrapping the title in [AnimatedSize] gives the Row layout
              // a smoothly-tweened width when the title's intrinsic width
              // changes (e.g. when [titleStyle] flips between titleLarge
              // and titleSmall as the search bar expands/collapses).
              // Without it, every animation frame of the implicit
              // text-style transition re-runs the Text widget's intrinsic
              // width measurement, and the Row reflows discretely - that's
              // what produced the stutter as the search bar reached the
              // title and the title had to give up space.
              //
              // [AnimatedDefaultTextStyle]'s default curve is
              // [Curves.linear], which makes the size shift feel
              // mechanical. Switching to [Curves.fastEaseInToSlowEaseOut]
              // matches the M3-emphasized motion curve we use elsewhere
              // for page transitions.
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.fastEaseInToSlowEaseOut,
                alignment: AlignmentDirectional.centerStart,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.fastEaseInToSlowEaseOut,
                  style: resolvedCompactTitle,
                  child: Text(widget.title),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: widget.searchWidget!),
            ],
          ),
        ),
      );
    }

    // Default (large expanding title) — blur is the bottom layer of a Stack
    // used as flexibleSpace. FlexibleSpaceBar sits on top and handles title
    // animation. This avoids FlexibleSpaceBar.background's fade-out, which
    // would make the blur invisible as soon as the user starts scrolling.
    //
    // When [leading] is set, inset the collapsed title past the toolbar
    // leading slot so it does not draw under the back button.
    final EdgeInsetsDirectional expandingTitlePadding =
        EdgeInsetsDirectional.only(
      start: widget.leading != null ? kToolbarHeight + 8 : 20,
      end: 20,
      top: 16,
      bottom: 16,
    );
    final Widget flexibleSpace = blurWidget != null
        ? Stack(
            fit: StackFit.expand,
            children: [
              blurWidget,
              FlexibleSpaceBar(
                titlePadding: expandingTitlePadding,
                title: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge!.copyWith(
                        color: colorScheme.onSurface,
                      ),
                ),
              ),
            ],
          )
        : FlexibleSpaceBar(
            titlePadding: expandingTitlePadding,
            title: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge!.copyWith(
                    color: colorScheme.onSurface,
                  ),
            ),
          );

    return SliverAppBar(
      pinned: true,
      automaticallyImplyLeading: false,
      leading: widget.leading,
      leadingWidth: widget.leading != null ? kToolbarHeight : null,
      actions: widget.actions,
      expandedHeight: 100,
      bottom: widget.bottom,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      backgroundColor:
          blurEnabled ? Colors.transparent : solidHeaderColor,
      surfaceTintColor:
          blurEnabled ? Colors.transparent : colorScheme.surfaceTint,
      forceMaterialTransparency: blurEnabled,
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      actionsIconTheme: IconThemeData(color: colorScheme.onSurface),
      flexibleSpace: flexibleSpace,
    );
  }
}
