import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/generated_form_renderer.dart'
    show TvTextFieldFocus;
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';

/// D23: on TV a text field must not trap the remote (it takes the arrow keys
/// for its caret), so it is entered with SELECT. Elsewhere it's untouched.
void main() {
  Future<FocusNode> pumpField(
    WidgetTester tester, {
    required bool isTV,
    double? borderRadius,
  }) async {
    final FocusNode textFocus = FocusNode();
    addTearDown(textFocus.dispose);
    final Widget field = TextField(focusNode: textFocus);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>(
        create: (_) => SettingsProvider()..isTV = isTV,
        child: MaterialApp(
          home: Scaffold(
            body: borderRadius == null
                ? TvTextFieldFocus(textFocusNode: textFocus, child: field)
                : TvTextFieldFocus(
                    textFocusNode: textFocus,
                    borderRadius: borderRadius,
                    child: field,
                  ),
          ),
        ),
      ),
    );
    return textFocus;
  }

  Focus frameOf(WidgetTester tester) {
    return tester.widget<Focus>(
      find
          .descendant(
            of: find.byType(TvTextFieldFocus),
            matching: find.byWidgetPredicate(
              (Widget w) => w is Focus && w.onKeyEvent != null,
            ),
          )
          .first,
    );
  }

  Container ringBox(WidgetTester tester) {
    return tester.widget<Container>(
      find
          .descendant(
            of: find.byType(TvTextFieldFocus),
            matching: find.byType(Container),
          )
          .first,
    );
  }

  testWidgets('phones type straight into the field', (tester) async {
    final FocusNode textFocus = await pumpField(tester, isTV: false);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(textFocus.hasFocus, isTrue);
  });

  testWidgets('on TV the field is entered with SELECT', (tester) async {
    final FocusNode textFocus = await pumpField(tester, isTV: true);
    // Arrows reach the frame, not the field: the field can't take focus yet.
    textFocus.requestFocus();
    await tester.pump();
    expect(textFocus.hasFocus, isFalse);

    // Focus the frame (as the D-pad would), then SELECT enters the field.
    frameOf(tester).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump();
    expect(textFocus.hasFocus, isTrue);
  });

  // v1.7.5 sync U2 (upstream #3491): the ring follows the field's corners and
  // is painted over it, since ObtainX's filled fields would hide a ring drawn
  // behind them.
  testWidgets('the TV ring follows the field radius, in front of the field', (
    tester,
  ) async {
    await pumpField(tester, isTV: true, borderRadius: 30);
    expect(ringBox(tester).foregroundDecoration, isNull);

    frameOf(tester).focusNode!.requestFocus();
    await tester.pump();
    final Container ring = ringBox(tester);
    expect(ring.decoration, isNull);
    final BoxDecoration decoration =
        ring.foregroundDecoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(30));
    expect(decoration.border, isNotNull);

    // Typing in the field: the ring goes away.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump();
    expect(ringBox(tester).foregroundDecoration, isNull);
  });

  testWidgets('without a radius the ring keeps its small default corners', (
    tester,
  ) async {
    await pumpField(tester, isTV: true);
    frameOf(tester).focusNode!.requestFocus();
    await tester.pump();
    final BoxDecoration decoration =
        ringBox(tester).foregroundDecoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(4));
  });
}
