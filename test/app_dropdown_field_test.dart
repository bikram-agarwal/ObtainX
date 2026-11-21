import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_dropdown_field.dart';

void main() {
  testWidgets(
    'menu width shrinks safely when requested minimum exceeds available width',
    (WidgetTester tester) async {
      final Map<String, double> measuredWidths = <String, double>{};

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(190, 800)),
            child: Builder(
              builder: (BuildContext context) {
                measuredWidths['importExport'] = appDropdownMenuWidth(
                  context,
                  const <String>['Apps'],
                  horizontalPadding: 96,
                  minWidth: 150,
                  maxWidthInset: 120,
                );
                measuredWidths['locale'] = appDropdownMenuWidth(
                  context,
                  const <String>['System'],
                  horizontalPadding: 96,
                  minWidth: 150,
                  maxWidthInset: 48,
                );
                measuredWidths['swipeAction'] = appDropdownMenuWidth(
                  context,
                  const <String>['None'],
                  horizontalPadding: 120,
                  minWidth: 180,
                  maxWidthInset: 80,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(measuredWidths['importExport'], 70);
      expect(measuredWidths['locale'], 142);
      expect(measuredWidths['swipeAction'], 110);
    },
  );

  testWidgets(
    'menu width preserves its requested minimum when space is available',
    (WidgetTester tester) async {
      double? measuredWidth;

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(400, 800)),
            child: Builder(
              builder: (BuildContext context) {
                measuredWidth = appDropdownMenuWidth(
                  context,
                  const <String>['Short'],
                  horizontalPadding: 0,
                  minWidth: 150,
                  maxWidthInset: 48,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(measuredWidth, 150);
    },
  );

  testWidgets(
    'externally controlled dropdown keeps its saved value after rejection',
    (WidgetTester tester) async {
      String? requestedValue;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                return appDropdownField<String>(
                  context: context,
                  value: 'system',
                  updateInternalValueOnChange: false,
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                      value: 'system',
                      child: Text('System'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'shizuku',
                      child: Text('Shizuku'),
                    ),
                  ],
                  onChanged: (String? value) {
                    requestedValue = value;
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shizuku').last);
      await tester.pumpAndSettle();

      final DropdownButton<String> dropdown = tester.widget(
        find.byType(DropdownButton<String>),
      );
      expect(requestedValue, 'shizuku');
      expect(dropdown.value, 'system');
    },
  );

  testWidgets(
    'multi-line dropdown menu items expand beyond 48px without clipping',
    (WidgetTester tester) async {
      const String longOption =
          'Enforce - verify, show result, and block installation of unverified builds.';

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(1.4),
            ),
            child: Scaffold(
              body: Builder(
                builder: (BuildContext context) {
                  return appDropdownField<String>(
                    context: context,
                    value: 'off',
                    menuWidth: appDropdownMenuWidth(
                      context,
                      const <String>['Off', longOption],
                    ),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(value: 'off', child: Text('Off')),
                      DropdownMenuItem<String>(
                        value: 'enforce',
                        child: Text(longOption),
                      ),
                    ],
                    onChanged: (_) {},
                  );
                },
              ),
            ),
          ),
        ),
      );

      final DropdownButton<String> dropdown = tester.widget(
        find.byType(DropdownButton<String>),
      );
      expect(dropdown.itemHeight, isNull);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      final Finder menuTextFinder = find.text(longOption).last;
      final Finder menuItemFinder = find
          .ancestor(
            of: menuTextFinder,
            matching: find.byType(DropdownMenuItem<String>),
          )
          .last;
      final Size textSize = tester.getSize(menuTextFinder);
      final Size itemSize = tester.getSize(menuItemFinder);

      expect(textSize.height, greaterThan(kMinInteractiveDimension));
      expect(itemSize.height, greaterThanOrEqualTo(textSize.height));
    },
  );
}
