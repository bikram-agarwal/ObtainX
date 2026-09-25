import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/ui_widgets.dart';

void main() {
  /// A Settings-style row: a switch that's on or off, and a link button
  /// beside it that always works.
  Future<List<String>> openRow(WidgetTester tester, {String? reason}) async {
    final List<String> taps = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExplainedWhenOff(
            reason: reason,
            child: ListTile(
              title: const Text('Row'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () => taps.add('link'),
                    icon: const Icon(Icons.open_in_new),
                  ),
                  Switch(
                    value: false,
                    onChanged: reason == null
                        ? (bool value) => taps.add('switch')
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return taps;
  }

  testWidgets('off, a tap anywhere on it says why', (tester) async {
    final List<String> taps = await openRow(tester, reason: 'Install it first');

    for (final Finder target in [find.text('Row'), find.byType(Switch)]) {
      await tester.tap(target);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Install it first'),
        ),
        findsOneWidget,
      );
    }
    expect(taps, isEmpty);
  });

  testWidgets('off, a button inside that works still works', (tester) async {
    final List<String> taps = await openRow(tester, reason: 'Install it first');

    await tester.tap(find.byType(IconButton));
    await tester.pump();

    expect(taps, ['link']);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('on, taps go to it and nothing is said', (tester) async {
    final List<String> taps = await openRow(tester);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(taps, ['switch']);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('tapped again, the warning replaces itself', (tester) async {
    await openRow(tester, reason: 'Install it first');

    for (int tap = 0; tap < 3; tap++) {
      await tester.tap(find.text('Row'));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
  });
}
