// The M3E slider look shared by every settings-style slider: a 16 dp track
// split around a 4x28 dp vertical-bar thumb, tick dots, no overlay. One home
// so the Settings sliders and the generated-form sliders on the additional
// options page look the same (they had drifted: the form used Material's
// default thumb). The shapes also paint disabled colours.

import 'package:material_ui/material_ui.dart';

/// Text style for a slider row's title and value: the list-tile title style
/// (bodyLarge), so slider rows read at the same size as the switch and link
/// rows they sit between. Plain `Text` would get the smaller body default.
TextStyle? m3eSliderTitleStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return theme.listTileTheme.titleTextStyle ?? theme.textTheme.bodyLarge;
}

/// [SliderTheme] data for an M3E slider. Callers may `copyWith` more fields
/// (e.g. disabled colours).
SliderThemeData m3eSliderTheme(BuildContext context) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  return SliderTheme.of(context).copyWith(
    trackHeight: 16,
    trackShape: const M3eGappedTrackShape(),
    thumbShape: const M3eVerticalBarThumbShape(),
    activeTickMarkColor: cs.onPrimary,
    inactiveTickMarkColor: cs.primary,
    overlayShape: SliderComponentShape.noOverlay,
  );
}

class M3eVerticalBarThumbShape extends SliderComponentShape {
  const M3eVerticalBarThumbShape();

  static const double _width = 4;
  static const double _height = 28;
  static const double _radius = 2;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size(_width, _height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Rect trackRect = sliderTheme.trackShape!.getPreferredRect(
      parentBox: parentBox,
      offset: Offset.zero,
      sliderTheme: sliderTheme,
      isEnabled: enableAnimation.value > 0,
      isDiscrete: isDiscrete,
    );
    final double trackHeight = trackRect.height;
    final double trackWidth = trackRect.width;
    Offset alignedCenter = center;
    if (trackWidth > trackHeight) {
      final double valueRatio = textDirection == TextDirection.rtl
          ? 1.0 - value
          : value;
      final double alignedX =
          trackRect.left +
          valueRatio * (trackWidth - trackHeight) +
          trackHeight / 2;
      alignedCenter = Offset(alignedX, center.dy);
    }
    final Canvas canvas = context.canvas;
    final Color thumbColor =
        ColorTween(
          begin: sliderTheme.disabledThumbColor,
          end: sliderTheme.thumbColor,
        ).evaluate(enableAnimation) ??
        sliderTheme.thumbColor ??
        Colors.white;
    final Paint paint = Paint()
      ..color = thumbColor
      ..style = PaintingStyle.fill;
    final RRect thumb = RRect.fromRectAndRadius(
      Rect.fromCenter(center: alignedCenter, width: _width, height: _height),
      const Radius.circular(_radius),
    );
    canvas.drawRRect(thumb, paint);
  }
}

class M3eGappedTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const M3eGappedTrackShape();

  static const double _gap = 4;
  static const double _radius = 8;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final Canvas canvas = context.canvas;
    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    double thumbX = thumbCenter.dx;
    final double trackHeight = trackRect.height;
    final double trackWidth = trackRect.width;
    if (trackWidth > trackHeight) {
      final double valueRatio = ((thumbCenter.dx - trackRect.left) / trackWidth)
          .clamp(0.0, 1.0);
      thumbX =
          trackRect.left +
          valueRatio * (trackWidth - trackHeight) +
          trackHeight / 2;
    }

    final Color activeTrackColor =
        ColorTween(
          begin: sliderTheme.disabledActiveTrackColor,
          end: sliderTheme.activeTrackColor,
        ).evaluate(enableAnimation) ??
        sliderTheme.activeTrackColor ??
        Colors.blue;
    final Color inactiveTrackColor =
        ColorTween(
          begin: sliderTheme.disabledInactiveTrackColor,
          end: sliderTheme.inactiveTrackColor,
        ).evaluate(enableAnimation) ??
        sliderTheme.inactiveTrackColor ??
        Colors.grey;
    final Paint activePaint = Paint()..color = activeTrackColor;
    final Paint inactivePaint = Paint()..color = inactiveTrackColor;

    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
          trackRect.left,
          trackRect.top,
          thumbX - _gap,
          trackRect.bottom,
        ),
        topLeft: const Radius.circular(_radius),
        bottomLeft: const Radius.circular(_radius),
      ),
      activePaint,
    );

    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
          thumbX + _gap,
          trackRect.top,
          trackRect.right,
          trackRect.bottom,
        ),
        topRight: const Radius.circular(_radius),
        bottomRight: const Radius.circular(_radius),
      ),
      inactivePaint,
    );
  }
}
