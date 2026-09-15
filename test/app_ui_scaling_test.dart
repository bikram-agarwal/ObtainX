import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_ui_scaling.dart';

void main() {
  testWidgets('scales layout, MediaQuery, text, and hit testing together', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    MediaQueryData? scaledMediaQuery;
    bool wasTapped = false;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(400, 800),
          padding: EdgeInsets.only(top: 20),
          viewPadding: EdgeInsets.only(top: 20),
          textScaler: TextScaler.linear(3.0),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppUiScaler(
            scale: 1.25,
            child: Builder(
              builder: (BuildContext context) {
                scaledMediaQuery = MediaQuery.of(context);
                return Align(
                  alignment: Alignment.topLeft,
                  child: GestureDetector(
                    key: const ValueKey<String>('scaled-target'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => wasTapped = true,
                    child: const SizedBox(width: 40, height: 20),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(scaledMediaQuery?.size, const Size(320, 640));
    expect(scaledMediaQuery?.padding.top, 16);
    expect(scaledMediaQuery?.textScaler.scale(20), 24);

    final Finder target = find.byKey(const ValueKey<String>('scaled-target'));
    expect(tester.getTopLeft(target), Offset.zero);
    expect(tester.getBottomRight(target), const Offset(50, 25));

    await tester.tapAt(const Offset(45, 20));
    expect(wasTapped, isTrue);
  });
}
