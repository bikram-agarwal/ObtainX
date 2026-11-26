import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';
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
    this.matchGradientBackground = false,
    this.progressiveBlurOverlayColor,
    this.onTitleTap,
    this.titleTapSemanticsHint,
  });

  final String title;

  /// Toolbar leading widget (e.g. back). When null, no leading slot is shown.
  final Widget? leading;
  final List<Widget>? actions;

  /// Optional widget pinned below the flexible title (e.g. a search field).
  /// Pass a [PreferredSizeWidget] such as [PreferredSize].
  final PreferredSizeWidget? bottom;

  /// When provided, replaces the expanding-title layout with a compact inline
  /// row. The title and search field use the same bounded slot, with the caller
  /// showing one at a time, while [actions] remain fixed at the end.
  final Widget? searchWidget;

  /// Optional style override for the compact layout title.
  final TextStyle? titleStyle;

  /// Whether the non-blurred app bar should sample the page gradient behind it.
  final bool matchGradientBackground;

  /// Optional tint override for progressive blur.
  final Color? progressiveBlurOverlayColor;

  /// Compact layout only: makes the title text itself (not the space beside
  /// it) a button. The apps pages refresh on it (v1.7.5 sync U1).
  final VoidCallback? onTitleTap;

  /// TalkBack's "double-tap to …" for [onTitleTap].
  final String? titleTapSemanticsHint;

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
  // Kept gentle on purpose: the uniform single-pass blur is just a light
  // frost, and the progressive colour-tint gradient (opaque top → transparent
  // bottom) carries the "progressive" feel. See ProgressiveTopEdgeOverlay for
  // why graduated multi-pass blur is deliberately avoided (GPU cost).
  static const double _blurSigma = 3.0;

  // Room the title's ripple takes on each side of the text. On the leading
  // side the ripple is shifted back by as much, so a tappable title sits
  // where a plain one does (see [_compactTitle] for pages with a back button).
  static const double _titleTapInset = 8;

  Widget _compactTitle(BuildContext context) {
    final Widget text = Text(
      widget.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final VoidCallback? onTitleTap = widget.onTitleTap;
    if (onTitleTap == null) return text;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    // With a leading back button the title starts right at the button's
    // slot, so the ripple gets no room (and no shift) on that side: shifting
    // it would cover the back button's touch area, and a tap there would
    // refresh instead of going back.
    final double startInset = widget.leading == null ? _titleTapInset : 0;
    // Only the text is the button: left-aligned and sized to the title, so
    // the empty space beside it stays inert. TalkBack reads e.g. "Apps,
    // button, double-tap to refresh".
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Transform.translate(
        offset: Offset(rtl ? startInset : -startInset, 0),
        // No `container: true`: the button flag, tap and hint must annotate
        // the app bar's own title node, which is the route's heading and names
        // the page for TalkBack. A separate node took the label away from it
        // (v1.7.5 sync Phase C).
        child: Semantics(
          button: true,
          onTapHint: widget.titleTapSemanticsHint,
          child: InkWell(
            onTap: onTitleTap,
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: EdgeInsetsDirectional.only(
                start: startInset,
                end: _titleTapInset,
                top: 6,
                bottom: 6,
              ),
              child: text,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBlur(Color overlayColor) {
    return ScrollLinkedProgressiveBlur(
      overlayColor: overlayColor,
      blurSigma: _blurSigma,
    );
  }

  Widget _buildGradientBackground(
    BuildContext context,
    ColorScheme colorScheme,
  ) {
    final double pageHeight = MediaQuery.sizeOf(context).height;

    return IgnorePointer(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return OverflowBox(
              alignment: Alignment.topCenter,
              minWidth: constraints.maxWidth,
              maxWidth: constraints.maxWidth,
              minHeight: pageHeight,
              maxHeight: pageHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: colorScheme.schemePageBackgroundGradient,
                ),
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: pageHeight,
                ),
              ),
            );
          },
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
    // bar - which sits on every page - only rebuilds when these specific
    // settings flip, not on every unrelated SettingsProvider notify
    // (categories, swipe actions, sort changes, etc.).
    final bool blurEnabled = context.select<SettingsProvider, bool>(
      (settings) => settings.progressiveBlurEnabled,
    );
    final Widget headerBackground;
    if (blurEnabled) {
      headerBackground = _buildBlur(
        widget.progressiveBlurOverlayColor ??
            colorScheme.schemeProgressiveBlurOverlayTint,
      );
    } else if (widget.matchGradientBackground) {
      headerBackground = _buildGradientBackground(context, colorScheme);
    } else {
      headerBackground = ColoredBox(color: colorScheme.surface);
    }
    final bool transparentAppBar =
        blurEnabled || widget.matchGradientBackground;

    if (widget.searchWidget != null) {
      // Compact layout - draw the header background as flexibleSpace so the
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
        backgroundColor: transparentAppBar
            ? Colors.transparent
            : colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        forceMaterialTransparency: transparentAppBar,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        actionsIconTheme: IconThemeData(color: colorScheme.onSurface),
        flexibleSpace: headerBackground,
        // Directional, so a right-to-left layout gets the same 20 px start
        // inset; the title tap's ripple shift relies on it (Phase C).
        title: Padding(
          padding: EdgeInsetsDirectional.only(
            start: widget.leading != null ? 0 : 20,
            end: 4,
          ),
          child: Row(
            children: [
              if (widget.title.isNotEmpty) ...[
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.fastEaseInToSlowEaseOut,
                    style: resolvedCompactTitle,
                    child: _compactTitle(context),
                  ),
                ),
                const SizedBox(width: 10),
              ] else
                Expanded(child: widget.searchWidget!),
            ],
          ),
        ),
      );
    }

    // Default (large expanding title) - header background is the bottom layer
    // of a Stack used as flexibleSpace. FlexibleSpaceBar sits on top and handles title
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
    final Widget flexibleSpace = widget.title.isEmpty
        ? headerBackground
        : Stack(
            fit: StackFit.expand,
            children: [
              headerBackground,
              FlexibleSpaceBar(
                titlePadding: expandingTitlePadding,
                title: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge!
                      .copyWith(color: colorScheme.onSurface),
                ),
              ),
            ],
          );

    return SliverAppBar(
      pinned: true,
      automaticallyImplyLeading: false,
      leading: widget.leading,
      leadingWidth: widget.leading != null ? kToolbarHeight : null,
      actions: widget.actions,
      expandedHeight: widget.title.isEmpty ? null : 100,
      bottom: widget.bottom,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      backgroundColor: transparentAppBar
          ? Colors.transparent
          : colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      forceMaterialTransparency: transparentAppBar,
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      actionsIconTheme: IconThemeData(color: colorScheme.onSurface),
      flexibleSpace: flexibleSpace,
    );
  }
}

class ScrollLinkedProgressiveBlur extends StatefulWidget {
  final Color overlayColor;
  final double blurSigma;

  const ScrollLinkedProgressiveBlur({
    super.key,
    required this.overlayColor,
    required this.blurSigma,
  });

  @override
  State<ScrollLinkedProgressiveBlur> createState() =>
      _ScrollLinkedProgressiveBlurState();
}

class _ScrollLinkedProgressiveBlurState
    extends State<ScrollLinkedProgressiveBlur> {
  ScrollPosition? _scrollPosition;
  double _opacity = 1.0;
  // Last quantized ramp value we built a subtree for, and that subtree.
  double _lastT = -1;
  Widget _cached = const SizedBox.shrink();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (identical(position, _scrollPosition)) return;
    _scrollPosition?.removeListener(_onScroll);
    _scrollPosition = position;
    _opacity = _scrollOpacity();
    position?.addListener(_onScroll);
  }

  double _scrollOpacity() {
    final position = _scrollPosition;
    if (position == null) return 1.0;
    if (!position.hasPixels) return 0.0;
    return ((position.pixels / 36.0).clamp(0.0, 1.0) * 100).round() / 100;
  }

  void _onScroll() {
    final opacity = _scrollOpacity();
    if (opacity == _opacity) return;
    setState(() => _opacity = opacity);
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_onScroll);
    super.dispose();
  }

  @override
  void didUpdateWidget(ScrollLinkedProgressiveBlur oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A theme change (tint) or a blur-strength change invalidates the cache.
    if (oldWidget.overlayColor != widget.overlayColor ||
        oldWidget.blurSigma != widget.blurSigma) {
      _lastT = -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _contentFor(_opacity);
  }

  /// Returns the blur subtree for ramp value [t], reusing the cached instance
  /// when [t] is unchanged. Past the 36px fade-in ramp `t` is pinned at 1.0, so
  /// without this the [AnimatedBuilder] rebuilt an identical BackdropFilter +
  /// ImageFilter + LinearGradient on the UI thread every single scroll frame.
  /// Returning the *identical* widget instance lets Flutter skip the subtree
  /// rebuild entirely. (The backdrop blur still re-rasterizes over the moving
  /// content on the raster thread — that is inherent to a live blur.)
  Widget _contentFor(double t) {
    // The scroll listener quantizes the fade and stops scheduling rebuilds
    // once it reaches full opacity. Live background pixels still get blurred.
    if (t == _lastT) return _cached;
    _lastT = t;
    _cached = _buildBlurContent(t);
    return _cached;
  }

  Widget _buildBlurContent(double opacity) {
    if (opacity <= 0.0) return const SizedBox.shrink();

    // Ramp the fade-in via the blur sigma and the tint's alpha rather than
    // wrapping the whole thing in an Opacity. Opacity forces an offscreen
    // saveLayer every scroll frame, and a BackdropFilter inside that layer
    // samples the (empty) layer instead of the screen behind it — so the old
    // approach was both costly per-frame and didn't blur the content correctly.
    // Same end state at full scroll; just a cleaner, cheaper ramp in between.
    final double t = opacity.clamp(0.0, 1.0);
    return IgnorePointer(
      child: RepaintBoundary(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: widget.blurSigma * t,
                  sigmaY: widget.blurSigma * t,
                ),
                child: const SizedBox.expand(),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      widget.overlayColor.withValues(
                        alpha: widget.overlayColor.a * t,
                      ),
                      widget.overlayColor.withValues(alpha: 0),
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
}
