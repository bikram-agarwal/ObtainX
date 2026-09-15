import 'dart:ui' show DisplayFeature;

import 'package:flutter/widgets.dart';

const double maxSystemTextScaleFactor = 1.2;

/// Scales the app's complete widget tree while keeping it inside the physical
/// viewport.
///
/// The child receives inverse-scaled layout constraints and MediaQuery
/// dimensions, then is painted and hit-tested at [scale]. This makes fixed
/// dimensions, icons, spacing, controls, and text scale together instead of
/// changing only the text scaler.
class AppUiScaler extends StatelessWidget {
  const AppUiScaler({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final double effectiveScale = scale.isFinite && scale > 0 ? scale : 1.0;
    final MediaQueryData scaledMediaQuery = mediaQuery.copyWith(
      size: mediaQuery.size / effectiveScale,
      padding: _scaleInsets(mediaQuery.padding, effectiveScale),
      viewPadding: _scaleInsets(mediaQuery.viewPadding, effectiveScale),
      viewInsets: _scaleInsets(mediaQuery.viewInsets, effectiveScale),
      systemGestureInsets: _scaleInsets(
        mediaQuery.systemGestureInsets,
        effectiveScale,
      ),
      displayFeatures: mediaQuery.displayFeatures
          .map(
            (DisplayFeature feature) => DisplayFeature(
              bounds: Rect.fromLTRB(
                feature.bounds.left / effectiveScale,
                feature.bounds.top / effectiveScale,
                feature.bounds.right / effectiveScale,
                feature.bounds.bottom / effectiveScale,
              ),
              type: feature.type,
              state: feature.state,
            ),
          )
          .toList(growable: false),
      textScaler: mediaQuery.textScaler.clamp(
        maxScaleFactor: maxSystemTextScaleFactor,
      ),
    );

    return CustomSingleChildLayout(
      delegate: _ScaledViewportLayoutDelegate(effectiveScale),
      child: Transform.scale(
        scale: effectiveScale,
        alignment: Alignment.topLeft,
        child: MediaQuery(data: scaledMediaQuery, child: child),
      ),
    );
  }
}

EdgeInsets _scaleInsets(EdgeInsets insets, double scale) {
  return EdgeInsets.fromLTRB(
    insets.left / scale,
    insets.top / scale,
    insets.right / scale,
    insets.bottom / scale,
  );
}

class _ScaledViewportLayoutDelegate extends SingleChildLayoutDelegate {
  const _ScaledViewportLayoutDelegate(this.scale);

  final double scale;

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.tight(constraints.biggest / scale);
  }

  @override
  bool shouldRelayout(_ScaledViewportLayoutDelegate oldDelegate) {
    return scale != oldDelegate.scale;
  }
}
