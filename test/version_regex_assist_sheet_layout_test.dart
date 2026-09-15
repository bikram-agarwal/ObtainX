import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_bottom_sheet.dart';
import 'package:obtainium/components/version_regex_assist_dialog.dart';

/// The RegEx assist sheet is the sheet that surfaced the landscape overflow:
/// it pins a title row and a Cancel / Apply row around a body full of fields
/// and radio tiles. These assertions drive the real sheet widget, so they also
/// cover its own header/footer contents — not just [AppSheetScaffold].
///
/// Labels resolve to raw translation keys here (easy_localization is not
/// initialised in tests), which does not change the chrome's height.
void main() {
  const double dpr = 2.625;
  const double epsilon = 0.5;
  const Size landscapePhone = Size(2400, 1080);
  const double keyboardPhysical = 678;

  double toLogical(double physical) => physical / dpr;

  final double keyboardTop =
      toLogical(landscapePhone.height) - toLogical(keyboardPhysical);

  /// Raises the software keyboard the way the engine does: view insets grow and
  /// the padding the keyboard now covers is dropped.
  Future<void> raiseKeyboard(WidgetTester tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardPhysical);
    tester.view.padding = const FakeViewPadding(top: 63);
    await tester.pumpAndSettle();
  }

  Future<void> openAssistSheet(
    WidgetTester tester, {
    bool withKeyboard = true,
  }) async {
    tester.view.physicalSize = landscapePhone;
    tester.view.devicePixelRatio = dpr;
    tester.view.viewInsets = withKeyboard
        ? const FakeViewPadding(bottom: keyboardPhysical)
        : FakeViewPadding.zero;
    tester.view.viewPadding = const FakeViewPadding(top: 63, bottom: 63);
    tester.view.padding = withKeyboard
        ? const FakeViewPadding(top: 63)
        : const FakeViewPadding(top: 63, bottom: 63);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              return Center(
                child: TextButton(
                  onPressed: () => showRegexAssistDialog(
                    context: context,
                    kind: RegexAssistKind.versionExtraction,
                    initialRaw: 'MyApp-v19.35.34-arm64-v8a-release.apk',
                    rawLineSuggestions: const <String>[],
                    filterFieldKey: null,
                    patch: (Map<String, String> patches) {},
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

  testWidgets('lays out without overflowing on a landscape phone', (
    WidgetTester tester,
  ) async {
    await openAssistSheet(tester);

    expect(find.byType(AppSheetScaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps its action row reachable above the keyboard', (
    WidgetTester tester,
  ) async {
    await openAssistSheet(tester);

    final Rect sheet = tester.getRect(find.byType(AppSheetScaffold));
    expect(sheet.bottom, lessThanOrEqualTo(keyboardTop + epsilon));

    for (final Finder action in <Finder>[
      find.text('cancel'),
      find.text('versionRegexAssistApply'),
    ]) {
      final Rect actionRect = tester.getRect(action);
      expect(actionRect.bottom, lessThanOrEqualTo(keyboardTop + epsilon));
      expect(actionRect.top, greaterThanOrEqualTo(sheet.top - epsilon));
      // Reachable, not just painted: a tap has to land on the button.
      expect(action.hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolls a body field into the surviving viewport', (
    WidgetTester tester,
  ) async {
    await openAssistSheet(tester);

    final Rect sheet = tester.getRect(find.byType(AppSheetScaffold));
    final Finder rawField = find.byType(TextField).first;
    tester
        .state<EditableTextState>(
          find.descendant(of: rawField, matching: find.byType(EditableText)),
        )
        .widget
        .focusNode
        .requestFocus();
    await tester.pumpAndSettle();

    final Rect field = tester.getRect(rawField);
    final double visible =
        field.bottom.clamp(sheet.top, sheet.bottom) -
        field.top.clamp(sheet.top, sheet.bottom);
    expect(visible, greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  // The real sequence: the sheet opens with no keyboard, the user taps a field,
  // and only then does the keyboard shrink the sheet.
  testWidgets('lifts a tapped field above a keyboard that opens after it', (
    WidgetTester tester,
  ) async {
    await openAssistSheet(tester, withKeyboard: false);

    final Finder rawField = find.byType(TextField).first;
    await tester.tap(rawField);
    await tester.pumpAndSettle();
    await raiseKeyboard(tester);

    final Rect sheet = tester.getRect(find.byType(AppSheetScaffold));
    final Rect viewport = tester.getRect(
      find.descendant(
        of: find.byType(AppSheetScaffold),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    final Rect field = tester.getRect(rawField);
    expect(tester.takeException(), isNull);
    expect(sheet.bottom, lessThanOrEqualTo(keyboardTop + epsilon));
    // Squeezed sheets reach the top of the screen, so they owe the status bar
    // its clearance.
    expect(sheet.top, greaterThanOrEqualTo(toLogical(63) - epsilon));
    // The field's caret end sits inside the visible viewport, above both the
    // pinned action row and the keyboard. A field with several wrapped lines can
    // be taller than everything the sheet has left, so what has to hold is that
    // the end the user is typing at is on screen, with most of the field too.
    expect(field.bottom, lessThanOrEqualTo(viewport.bottom + epsilon));
    expect(
      field.bottom.clamp(viewport.top, viewport.bottom) -
          field.top.clamp(viewport.top, viewport.bottom),
      greaterThanOrEqualTo(48),
    );
    // The field must survive the relayout: a rebuilt field would lose focus and
    // bounce the keyboard back down.
    expect(
      tester
          .state<EditableTextState>(
            find.descendant(of: rawField, matching: find.byType(EditableText)),
          )
          .widget
          .focusNode
          .hasFocus,
      isTrue,
    );
  });

  testWidgets('drops the drag handle only where there is no room for it', (
    WidgetTester tester,
  ) async {
    await openAssistSheet(tester, withKeyboard: false);
    final Finder handle = find.byWidgetPredicate(
      (Widget widget) => widget.runtimeType.toString() == '_AppSheetDragHandle',
    );
    expect(handle, findsOneWidget);

    await raiseKeyboard(tester);
    expect(handle, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
