import 'dart:math' show sqrt;
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
/// N [BackdropFilter] layers of increasing height are stacked. Layer i covers
/// the top (i/N * height) pixels and adds sigma/sqrt(N) blur. Because Gaussian
/// blurs accumulate quadratically, the effective sigma at position y is:
///   sigma_eff(y) = (sigma / sqrt(N)) * sqrt(floor(y / (height/N)) + 1)
///
/// This gives maximum blur at the top edge, smoothly decreasing to near-zero
/// at the bottom — no sharp step where content enters the blur zone.
class ProgressiveTopEdgeOverlay extends StatelessWidget {
  const ProgressiveTopEdgeOverlay({
    super.key,
    required this.height,
    required this.overlayColor,
    this.blurSigma = 8,
  });

  final double height;
  final Color overlayColor;
  final double blurSigma;
  static const int _layers = 2;

  @override
  Widget build(BuildContext context) {
    if (height <= 0) return const SizedBox.shrink();
    final double sigmaPerLayer = blurSigma / sqrt(_layers.toDouble());
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Blur layers: each successive layer covers more of the band.
              // The top of the band accumulates all layers (max blur); the
              // bottom accumulates only the first layer (min blur ~sigma/sqrt(N)).
              for (int i = 1; i <= _layers; i++)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: height * i / _layers,
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: sigmaPerLayer,
                        sigmaY: sigmaPerLayer,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              // Colour tint: opaque at top, fades to transparent.
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
}

Widget? buildTopProgressiveOverlay(
  BuildContext context,
  SettingsProvider settings, {
  double? bandHeight,
  double blurSigma = 8,
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
class ProgressiveBottomEdgeBlur extends StatelessWidget {
  const ProgressiveBottomEdgeBlur({
    super.key,
    required this.overlayColor,
    this.blurSigma = 8,
  });

  final Color overlayColor;
  final double blurSigma;
  static const int _layers = 2;

  @override
  Widget build(BuildContext context) {
    final double sigmaPerLayer = blurSigma / sqrt(_layers.toDouble());
    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (int i = 1; i <= _layers; i++)
              Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  widthFactor: 1.0,
                  heightFactor: i / _layers,
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: sigmaPerLayer,
                        sigmaY: sigmaPerLayer,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
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
}
