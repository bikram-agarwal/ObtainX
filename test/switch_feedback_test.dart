import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/ui_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall methodCall,
        ) async {
          platformCalls.add(methodCall);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  int clickSoundCount() {
    return platformCalls
        .where(
          (MethodCall methodCall) =>
              methodCall.method == 'SystemSound.play' &&
              methodCall.arguments == 'SystemSoundType.click',
        )
        .length;
  }

  testWidgets('AppSwitch plays platform tap feedback', (
    WidgetTester tester,
  ) async {
    bool? changedValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSwitch(
            value: false,
            onChanged: (bool value) {
              changedValue = value;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(changedValue, isTrue);
    expect(clickSoundCount(), 1);
  });

  testWidgets('AppSwitchListTile plays one click from switch or row', (
    WidgetTester tester,
  ) async {
    int changeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSwitchListTile(
            title: const Text('Toggle setting'),
            value: false,
            onChanged: (bool value) {
              changeCount++;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(changeCount, 1);
    expect(clickSoundCount(), 1);

    platformCalls.clear();
    await tester.tap(find.text('Toggle setting'));
    await tester.pump();
    expect(changeCount, 2);
    expect(clickSoundCount(), 1);
  });
}
