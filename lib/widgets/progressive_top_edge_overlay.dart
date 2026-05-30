import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';

/// Full height of the collapsed app bar: status-bar inset + toolbar.
double progressiveBlurHeaderHeight(BuildContext context) {
  return MediaQuery.paddingOf(context).top + kToolbarHeight;
}

/// Progressive blur overlay anchored at y=0.
///
/// Single-layer [BackdropFilter] over the band height, with a colour-tint
/// gradient overlay that fades from opaque at the top to transparent at
/// the bottom. The gradient creates the "progressive" feel without paying
/// for multiple BackdropFilter passes - the previous two-layer
/// implementation cost ~2x as much GPU per frame and was the dominant
/// cause of 30 fps drops on mid-range devices reported by users.
///
/// Wrapped in [RepaintBoundary] so the blur layer is its own composition
/// island - dirty rects from neighbouring widgets don't force the blur
/// to recomposite.
class ProgressiveTopEdgeOverlay extends StatelessWidget {
  const ProgressiveTopEdgeOverlay({
    super.key,
    required this.height,
    required this.overlayColor,
    this.blurSigma = 4.0,
  });

  final double height;
  final Color overlayColor;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    if (height <= 0) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                  ),
                  child: const SizedBox.expand(),
                ),
                // Colour tint: opaque at top, fades to transparent. Provides
                // the visual "progressive" gradient that the second blur
                // layer used to provide.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [overlayColor, overlayColor.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget? buildTopProgressiveOverlay(
  BuildContext context,
  SettingsProvider settings, {
  double? bandHeight,
  double blurSigma = 4.0,
}) {
  if (!settings.progressiveBlurEnabled) return null;
  final double resolvedBand =
      bandHeight ?? progressiveBlurHeaderHeight(context);
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return ProgressiveTopEdgeOverlay(
    height: resolvedBand,
    overlayColor: scheme.schemeProgressiveBlurOverlayTint,
    blurSigma: blurSigma,
  );
}

/// Fills its parent (e.g. [Positioned.fill] behind a transparent [NavigationBar]).
/// Mirrors [ProgressiveTopEdgeOverlay] but anchors blur and tint at the bottom edge,
/// matching the home navigation bar band.
///
/// Single-layer BackdropFilter + colour-tint gradient + RepaintBoundary -
/// same trade-off as [ProgressiveTopEdgeOverlay]. See its comments for the
/// rationale.
class ProgressiveBottomEdgeBlur extends StatelessWidget {
  const ProgressiveBottomEdgeBlur({
    super.key,
    required this.overlayColor,
    this.blurSigma = 4.0,
  });

  final Color overlayColor;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: const SizedBox.expand(),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [overlayColor, overlayColor.withValues(alpha: 0)],
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
