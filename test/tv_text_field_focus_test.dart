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
  Future<FocusNode> pumpField(WidgetTester tester, {required bool isTV}) async {
    final FocusNode textFocus = FocusNode();
    addTearDown(textFocus.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>(
        create: (_) => SettingsProvider()..isTV = isTV,
        child: MaterialApp(
          home: Scaffold(
            body: TvTextFieldFocus(
              textFocusNode: textFocus,
              child: TextField(focusNode: textFocus),
            ),
          ),
        ),
      ),
    );
    return textFocus;
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
    final Focus frame = tester.widget<Focus>(
      find
          .descendant(
            of: find.byType(TvTextFieldFocus),
            matching: find.byWidgetPredicate(
              (Widget w) => w is Focus && w.onKeyEvent != null,
            ),
          )
          .first,
    );
    frame.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump();
    expect(textFocus.hasFocus, isTrue);
  });
}
