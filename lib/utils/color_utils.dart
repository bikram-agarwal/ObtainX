import 'dart:math';

import 'package:flutter/material.dart';
import 'package:hsluv/hsluv.dart';

// Generates a color in the HSLuv (Pastel) color space
// https://pub.dev/documentation/hsluv/latest/hsluv/Hsluv/hpluvToRgb.html
//
// ObtainX keeps its lightness 55 with the 0-255 clamp (c6f783da); upstream
// uses 70 without the clamp. Keep the fork's values here.
Color generateRandomLightColor() {
  final randomSeed = Random().nextInt(120);
  // https://en.wikipedia.org/wiki/Golden_angle
  final goldenAngle = 180 * (3 - sqrt(5));
  // Generate next golden angle hue
  final double hue = randomSeed * goldenAngle;
  // Map from HPLuv color space to RGB, use constant saturation=100, lightness=55
  final List<double> rgbValuesDbl = Hsluv.hpluvToRgb([hue, 100, 55]);
  // Map RBG values from 0-1 to 0-255:
  final List<int> rgbValues = rgbValuesDbl
      .map((rgb) => (rgb * 255).clamp(0, 255).toInt())
      .toList();
  return Color.fromARGB(255, rgbValues[0], rgbValues[1], rgbValues[2]);
}
