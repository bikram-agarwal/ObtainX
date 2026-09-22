import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/settings.dart';

const TextStyle _headlineStyle = TextStyle(
  fontSize: 36,
  fontWeight: FontWeight.w700,
);

/// Lays out [text] exactly as the About headline does, so a returned size can be
/// checked for the ellipsis the shrinking is meant to avoid.
bool _rendersInFull({
  required BuildContext context,
  required String text,
  required double fontSize,
  required double maxWidth,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: _headlineStyle.copyWith(fontSize: fontSize)),
    maxLines: aboutHeadlineMaxLines,
    textAlign: TextAlign.center,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: maxWidth);
  return !painter.didExceedMaxLines &&
      !painter.computeLineMetrics().any((line) => line.width > maxWidth + 0.5);
}

Future<BuildContext> _contextWithTextScale(
  WidgetTester tester,
  double textScaleFactor,
) async {
  late BuildContext capturedContext;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScaleFactor)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (BuildContext context) {
            capturedContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return capturedContext;
}

void main() {
  testWidgets('a long version name shrinks until it fits in full', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await _contextWithTextScale(tester, 1);
    const String headline = 'ObtainX v2.20.0-Preview-277';
    const double maxWidth = 500;

    final double fontSize = aboutHeadlineFontSize(
      context: context,
      text: headline,
      style: _headlineStyle,
      maxWidth: maxWidth,
    );

    expect(fontSize, lessThan(36));
    expect(
      _rendersInFull(
        context: context,
        text: headline,
        fontSize: fontSize,
        maxWidth: maxWidth,
      ),
      isTrue,
    );
    // Regression guard for the ellipsis this replaces: the headline's own size
    // could not render that version in full at this width.
    expect(
      _rendersInFull(
        context: context,
        text: headline,
        fontSize: 36,
        maxWidth: maxWidth,
      ),
      isFalse,
    );
  });

  testWidgets('a headline that already fits keeps its full size', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await _contextWithTextScale(tester, 1);

    expect(
      aboutHeadlineFontSize(
        context: context,
        text: 'ObtainX v2.20.0',
        style: _headlineStyle,
        maxWidth: 600,
      ),
      36,
    );
  });

  testWidgets('a large system font scale is accounted for', (
    WidgetTester tester,
  ) async {
    const String headline = 'ObtainX v2.20.0-Preview-277';
    const double maxWidth = 500;
    final double atNormalScale = aboutHeadlineFontSize(
      context: await _contextWithTextScale(tester, 1),
      text: headline,
      style: _headlineStyle,
      maxWidth: maxWidth,
    );
    final double atLargeScale = aboutHeadlineFontSize(
      context: await _contextWithTextScale(tester, 2),
      text: headline,
      style: _headlineStyle,
      maxWidth: maxWidth,
    );

    expect(atLargeScale, lessThan(atNormalScale));
  });

  testWidgets('shrinking stops at a floor instead of vanishing', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await _contextWithTextScale(tester, 1);

    expect(
      aboutHeadlineFontSize(
        context: context,
        text: 'ObtainX v2.20.0-Preview-277',
        style: _headlineStyle,
        maxWidth: 24,
      ),
      20,
    );
  });

  testWidgets('an unbounded width keeps the full size', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await _contextWithTextScale(tester, 1);

    expect(
      aboutHeadlineFontSize(
        context: context,
        text: 'ObtainX v2.20.0-Preview-277',
        style: _headlineStyle,
        maxWidth: double.infinity,
      ),
      36,
    );
  });
}
