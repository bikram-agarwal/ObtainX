import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_bottom_sheet.dart';

/// Geometry regressions for [showAppModalSheet] / [AppSheetScaffold].
///
/// The RegEx assist sheet used to overflow its flex by ~40dp on a landscape
/// phone with the keyboard open: the sheet was lifted above the keyboard (as it
/// should be), leaving ~105dp of content height, while the pinned header and
/// action row alone wanted ~145dp.
void main() {
  const double dpr = 2.625;
  const double statusBarPhysical = 63;
  const double navBarPhysical = 63;

  /// Physical keyboard heights measured on a 1080p phone.
  const double landscapeKeyboardPhysical = 678;
  const double portraitKeyboardPhysical = 780;

  /// Slack for logical-pixel rounding when comparing laid-out edges.
  const double epsilon = 0.5;

  double toLogical(double physical) => physical / dpr;

  void useViewport(
    WidgetTester tester, {
    required Size physicalSize,
    required double keyboardPhysical,
  }) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = dpr;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardPhysical);
    tester.view.viewPadding = const FakeViewPadding(
      top: statusBarPhysical,
      bottom: navBarPhysical,
    );
    // The engine drops the parts of the padding the keyboard covers.
    tester.view.padding = FakeViewPadding(
      top: statusBarPhysical,
      bottom: keyboardPhysical > 0 ? 0 : navBarPhysical,
    );
    addTearDown(tester.view.reset);
  }

  late FocusNode rawFieldFocus;
  setUp(() => rawFieldFocus = FocusNode());
  tearDown(() => rawFieldFocus.dispose());

  /// The RegEx assist sheet's shape: a title + close header, a column of hints,
  /// fields and radio tiles, and a Cancel / Apply action row.
  List<Widget> buildBodyWidgets() {
    return <Widget>[
      const Text('Pick the part of the raw string to keep'),
      const SizedBox(height: 12),
      TextField(
        key: const Key('raw'),
        focusNode: rawFieldFocus,
        minLines: 1,
        maxLines: 4,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      const SizedBox(height: 16),
      for (int i = 0; i < 4; i++)
        RadioListTile<int>(
          value: i,
          // ignore: deprecated_member_use
          groupValue: 0,
          // ignore: deprecated_member_use
          onChanged: (_) {},
          title: Text('candidate $i'),
          dense: true,
          contentPadding: EdgeInsets.zero,
        ),
      const SizedBox(height: 12),
      const TextField(
        key: Key('custom'),
        decoration: InputDecoration(border: OutlineInputBorder()),
      ),
      const SizedBox(height: 16),
    ];
  }

  Widget buildSheet({required bool ownScrollView, bool expand = false}) {
    final List<Widget> bodyWidgets = buildBodyWidgets();
    return AppSheetScaffold(
      expand: expand,
      header: Row(
        children: <Widget>[
          const Expanded(child: Text('Trim latest version (RegEx helper)')),
          IconButton(icon: const Icon(Icons.close), onPressed: () {}),
        ],
      ),
      bodyPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      body: ownScrollView
          ? SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: bodyWidgets,
              ),
            )
          : null,
      bodyChildren: ownScrollView ? null : bodyWidgets,
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          TextButton(onPressed: () {}, child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: () {}, child: const Text('Apply RegEx')),
        ],
      ),
    );
  }

  Future<void> openSheet(
    WidgetTester tester, {
    required bool ownScrollView,
    bool expand = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              return Center(
                child: TextButton(
                  onPressed: () => showAppModalSheet<void>(
                    context: context,
                    builder: (_) => buildSheet(
                      ownScrollView: ownScrollView,
                      expand: expand,
                    ),
                  ),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('landscape phone with the keyboard open', () {
    const Size landscapePhone = Size(2400, 1080);
    final double keyboardTop =
        toLogical(landscapePhone.height) - toLogical(landscapeKeyboardPhysical);

    for (final bool ownScrollView in <bool>[false, true]) {
      final String bodyKind = ownScrollView ? 'body' : 'bodyChildren';

      testWidgets('$bodyKind sheet does not overflow', (
        WidgetTester tester,
      ) async {
        useViewport(
          tester,
          physicalSize: landscapePhone,
          keyboardPhysical: landscapeKeyboardPhysical,
        );
        await openSheet(tester, ownScrollView: ownScrollView);

        expect(tester.takeException(), isNull);
      });

      testWidgets('$bodyKind sheet keeps the action row above the keyboard', (
        WidgetTester tester,
      ) async {
        useViewport(
          tester,
          physicalSize: landscapePhone,
          keyboardPhysical: landscapeKeyboardPhysical,
        );
        await openSheet(tester, ownScrollView: ownScrollView);

        expect(
          tester.getRect(find.byType(AppSheetScaffold)).bottom,
          lessThanOrEqualTo(keyboardTop + epsilon),
        );
        expect(
          tester.getRect(find.text('Apply RegEx')).bottom,
          lessThanOrEqualTo(keyboardTop + epsilon),
        );
        expect(
          tester.getRect(find.text('Cancel')).bottom,
          lessThanOrEqualTo(keyboardTop + epsilon),
        );
      });
    }

    testWidgets('expanded sheets do not overflow either', (
      WidgetTester tester,
    ) async {
      useViewport(
        tester,
        physicalSize: landscapePhone,
        keyboardPhysical: landscapeKeyboardPhysical,
      );
      await openSheet(tester, ownScrollView: true, expand: true);

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byType(AppSheetScaffold)).bottom,
        lessThanOrEqualTo(keyboardTop + epsilon),
      );
    });

    testWidgets('focusing a field scrolls it above the keyboard', (
      WidgetTester tester,
    ) async {
      useViewport(
        tester,
        physicalSize: landscapePhone,
        keyboardPhysical: landscapeKeyboardPhysical,
      );
      await openSheet(tester, ownScrollView: false);

      rawFieldFocus.requestFocus();
      await tester.pumpAndSettle();

      final Rect sheet = tester.getRect(find.byType(AppSheetScaffold));
      final Rect field = tester.getRect(find.byKey(const Key('raw')));
      // The field cannot be taller than the surviving viewport, but the part of
      // it holding the caret has to be on screen and clear of the keyboard.
      final double visible =
          field.bottom.clamp(sheet.top, sheet.bottom) -
          field.top.clamp(sheet.top, sheet.bottom);
      expect(visible, greaterThan(40));
      expect(tester.takeException(), isNull);
    });
  });

  group('portrait phone with the keyboard open', () {
    const Size portraitPhone = Size(1080, 2400);

    testWidgets('header stays pinned and the action row clears the keyboard', (
      WidgetTester tester,
    ) async {
      useViewport(
        tester,
        physicalSize: portraitPhone,
        keyboardPhysical: portraitKeyboardPhysical,
      );
      await openSheet(tester, ownScrollView: false);

      final double keyboardTop =
          toLogical(portraitPhone.height) - toLogical(portraitKeyboardPhysical);
      final Rect header = tester.getRect(
        find.text('Trim latest version (RegEx helper)'),
      );
      final Rect sheet = tester.getRect(find.byType(AppSheetScaffold));

      expect(tester.takeException(), isNull);
      expect(sheet.bottom, lessThanOrEqualTo(keyboardTop + epsilon));
      expect(header.top, greaterThanOrEqualTo(sheet.top));
      expect(
        tester.getRect(find.text('Apply RegEx')).bottom,
        lessThanOrEqualTo(keyboardTop + epsilon),
      );
      // Roomy viewports keep the body between the pinned header and footer, so
      // the first field is visible without scrolling.
      expect(
        tester.getRect(find.byKey(const Key('raw'))).bottom,
        lessThan(keyboardTop),
      );
    });
  });

  group('no keyboard', () {
    testWidgets('footer still clears the system nav bar', (
      WidgetTester tester,
    ) async {
      useViewport(
        tester,
        physicalSize: const Size(1080, 2400),
        keyboardPhysical: 0,
      );
      await openSheet(tester, ownScrollView: false);

      final Rect sheet = tester.getRect(find.byType(AppSheetScaffold));
      final Rect apply = tester.getRect(find.text('Apply RegEx'));

      expect(tester.takeException(), isNull);
      expect(
        sheet.bottom - apply.bottom,
        greaterThanOrEqualTo(toLogical(navBarPhysical)),
      );
    });
  });
}
