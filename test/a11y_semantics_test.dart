import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/ui_widgets.dart';

// Upstream #3398, adapted to the fork (v1.7.4 sync): the labelled switch is
// AppSwitch(semanticLabel:) instead of upstream's ToggleTile, and upstream's
// AppIconAction case is dropped (the fork labels its own icon sites).
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('a labelled AppSwitch names its switch and toggles it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var value = false;

    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) => AppSwitch(
            semanticLabel: 'Flag',
            value: value,
            onChanged: (next) => setState(() => value = next),
          ),
        ),
      ),
    );

    final data = tester.getSemantics(find.byType(Switch)).getSemanticsData();
    expect(data.label, 'Flag');
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(find.bySemanticsLabel('Flag'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(value, isTrue);

    handle.dispose();
  });

  testWidgets(
    'the semantics tap of a labelled AppSwitch toggles it with one click',
    (tester) async {
      final handle = tester.ensureSemantics();
      final List<MethodCall> platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final List<bool> changes = <bool>[];

      await tester.pumpWidget(
        wrap(
          AppSwitch(semanticLabel: 'Flag', value: true, onChanged: changes.add),
        ),
      );

      tester.semantics.tap(find.semantics.byLabel('Flag'));
      await tester.pump();

      expect(changes, <bool>[false]);
      expect(
        platformCalls
            .where(
              (MethodCall call) =>
                  call.method == 'SystemSound.play' &&
                  call.arguments == 'SystemSoundType.click',
            )
            .length,
        1,
      );

      handle.dispose();
    },
  );

  testWidgets('a disabled labelled AppSwitch has no tap action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      wrap(
        const AppSwitch(semanticLabel: 'Flag', value: false, onChanged: null),
      ),
    );

    final data = tester.getSemantics(find.byType(Switch)).getSemanticsData();
    expect(data.label, 'Flag');
    expect(data.hasAction(SemanticsAction.tap), isFalse);

    handle.dispose();
  });
}
