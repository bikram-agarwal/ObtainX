import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/widgets/app_toast.dart';

/// [AppToastHost] belongs inside the route, not around the whole app.
///
/// It briefly lived in `MaterialApp.builder` wrapped in `FToastBuilder()`, whose
/// `Overlay` consumes [Overlay.initialEntries] only once — so the overlay kept
/// serving the child instance it was first handed and the app's [MediaQuery]
/// froze at the launch size. Layout still reflowed (the render view's own
/// constraints do change), so the only symptom was that the phone/tablet layout
/// never switched on rotation.
///
/// Two things have to hold for the placement under `home:`:
///  * a view-size change reaches widgets below the host, and
///  * the host's context can still find an [Overlay], which is what FToast
///    looks up for the context-less toasts fired from providers.
void main() {
  testWidgets('host passes view size changes through to its child', (
    WidgetTester tester,
  ) async {
    const double dpr = 2.625;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.reset);

    final List<Size> observedSizes = <Size>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) {
          final MediaQueryData mq = MediaQuery.of(context);
          return MediaQuery(
            data: mq.copyWith(textScaler: const TextScaler.linear(1.1)),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: AppToastHost(
          child: Builder(
            builder: (BuildContext context) {
              observedSizes.add(MediaQuery.sizeOf(context));
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(observedSizes.last.width, closeTo(1080 / dpr, 0.5));

    tester.view.physicalSize = const Size(2400, 1080);
    await tester.pumpAndSettle();

    expect(observedSizes.last.width, closeTo(2400 / dpr, 0.5));
    expect(observedSizes.last.height, closeTo(1080 / dpr, 0.5));
  });

  testWidgets('host context can resolve an Overlay for context-less toasts', (
    WidgetTester tester,
  ) async {
    final GlobalKey hostKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: AppToastHost(key: hostKey, child: const SizedBox.shrink()),
      ),
    );

    // This is the context AppToastHost hands to FToast for toasts fired without
    // one of their own.
    expect(Overlay.maybeOf(hostKey.currentContext!), isNotNull);
  });
}
