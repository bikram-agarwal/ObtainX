import 'dart:math' show sqrt;
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
  // Two layers balance look vs GPU cost while scrolling (each layer is a
  // BackdropFilter pass over content under the app bar).
  static const int _layers = 2;
  static final double _sigmaPerLayer = 7.0 / sqrt(_layers.toDouble());

  /// Progressive-blur widget that fills its parent via [FractionallySizedBox]
  /// — no LayoutBuilder, no extra layout passes.
  ///
  /// Passed directly as [SliverAppBar.flexibleSpace] (not as
  /// [FlexibleSpaceBar.background]) so it never fades during collapse.
  Widget _buildBlur(Color overlayColor) {
    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (int i = 1; i <= _layers; i++)
              Align(
                alignment: Alignment.topCenter,
                child: FractionallySizedBox(
                  widthFactor: 1.0,
                  heightFactor: i / _layers,
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: _sigmaPerLayer,
                        sigmaY: _sigmaPerLayer,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
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

    final bool blurEnabled =
        context.watch<SettingsProvider>().progressiveBlurEnabled;

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
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: resolvedCompactTitle,
                child: Text(widget.title),
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
