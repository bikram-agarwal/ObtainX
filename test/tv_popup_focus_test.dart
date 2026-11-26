import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/ui_widgets.dart' show TvPopupFocusObserver;

/// D23: on TV a dialog that opens with nothing focused gets its first control
/// focused, which for a confirmation is the safe option (Cancel comes first).
void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    required bool isTV,
    bool autofocusConfirm = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TvPopupFocusObserver(() => isTV)],
        home: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (BuildContext dialogContext) => AlertDialog(
                  title: const Text('Remove?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      autofocus: autofocusConfirm,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool isFocused(WidgetTester tester, String label) {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    // A focused scope (the dialog itself) means no control has focus.
    if (primary == null || primary is FocusScopeNode) return false;
    final BuildContext? context = primary.context;
    if (context == null) return false;
    return find
        .descendant(
          of: find.byWidget(context.widget),
          matching: find.text(label),
        )
        .evaluate()
        .isNotEmpty;
  }

  testWidgets('on TV a confirmation opens with Cancel focused', (tester) async {
    await openDialog(tester, isTV: true);
    expect(isFocused(tester, 'Cancel'), isTrue);
  });

  testWidgets('a dialog that autofocuses its own control keeps it', (
    tester,
  ) async {
    await openDialog(tester, isTV: true, autofocusConfirm: true);
    expect(isFocused(tester, 'Remove'), isTrue);
  });

  testWidgets('phones leave dialog focus alone', (tester) async {
    await openDialog(tester, isTV: false);
    expect(isFocused(tester, 'Cancel'), isFalse);
  });
}
