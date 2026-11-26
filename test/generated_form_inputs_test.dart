import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/components/m3e_slider_theme.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';

/// Samples every generated-form input type (switch, text field, dropdown,
/// slider) and confirms each writes through to the form's value map. Controls
/// of the same type share their plumbing, so one representative each is enough.
///
/// Upstream's test, adapted to the fork (v1.7.4 sync): flutter/material
/// instead of material_ui, the fork's `turnsOffKeys` instead of upstream's
/// `mutuallyExclusiveWith`, and the fork's dropdown (a FormField around a
/// DropdownButton, not a DropdownButtonFormField).
void main() {
  Future<Map<String, dynamic> Function()> pumpForm(
    WidgetTester tester,
    List<List<GeneratedFormItem>> items,
  ) async {
    Map<String, dynamic> values = {};
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: GeneratedForm(
              items: items,
              onValueChanges: (v, _, _) => values = v,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return () => values;
  }

  testWidgets('switch writes through', (tester) async {
    final values = await pumpForm(tester, [
      [GeneratedFormSwitch('flag', label: 'Flag', value: false)],
    ]);
    expect(values()['flag'], isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(values()['flag'], isTrue);
  });

  testWidgets('switch is announced with its label (#3398)', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpForm(tester, [
      [GeneratedFormSwitch('flag', label: 'Flag', value: false)],
    ]);
    final data = tester.getSemantics(find.byType(Switch)).getSemanticsData();
    expect(data.label, 'Flag');
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });

  testWidgets('exclusive switches turn each other off and survive cloning', (
    tester,
  ) async {
    final values = await pumpForm(
      tester,
      cloneFormItems([
        [
          GeneratedFormSwitch(
            'play',
            label: 'Google Play',
            value: true,
            turnsOffKeys: ['galaxy'],
          ),
        ],
        [
          GeneratedFormSwitch(
            'galaxy',
            label: 'Samsung Galaxy Store',
            turnsOffKeys: ['play'],
          ),
        ],
        [GeneratedFormSwitch('unrelated', label: 'Unrelated', value: true)],
      ]),
    );
    await tester.tap(find.byType(Switch).at(1));
    await tester.pump();
    expect(values(), {'play': false, 'galaxy': true, 'unrelated': true});
    await tester.tap(find.byType(Switch).at(0));
    await tester.pump();
    expect(values(), {'play': true, 'galaxy': false, 'unrelated': true});
    await tester.tap(find.byType(Switch).at(0));
    await tester.pump();
    expect(values(), {'play': false, 'galaxy': false, 'unrelated': true});
  });

  testWidgets('text field writes through', (tester) async {
    final values = await pumpForm(tester, [
      [GeneratedFormTextField('text', label: 'Text', value: '')],
    ]);
    await tester.enterText(find.byType(TextFormField), 'typed-value');
    await tester.pump();
    expect(values()['text'], 'typed-value');
  });

  testWidgets('dropdown writes through', (tester) async {
    final values = await pumpForm(tester, [
      [
        GeneratedFormDropdown(
          'choice',
          [const MapEntry('a', 'Option A'), const MapEntry('b', 'Option B')],
          label: 'Pick',
          value: 'a',
        ),
      ],
    ]);
    expect(values()['choice'], 'a');
    await tester.tap(find.byType(DropdownButton<dynamic>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option B').last);
    await tester.pumpAndSettle();
    expect(values()['choice'], 'b');
  });

  testWidgets('slider writes through', (tester) async {
    final values = await pumpForm(tester, [
      [
        GeneratedFormSlider(
          'days',
          [
            const MapEntry('', 'Use global default'),
            const MapEntry('optA', 'Option A'),
            const MapEntry('optB', 'Option B'),
            const MapEntry('optC', 'Option C'),
          ],
          label: 'Days',
          value: '',
        ),
      ],
    ]);
    expect(values()['days'], '');
    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pump();
    expect(values()['days'], isNotEmpty);
  });

  // A per-app override of a global value: '' is labelled with the global
  // value, and every value is listed besides it, so picking the value the
  // global has now pins it instead of following the global.
  testWidgets('dropdown with a global default lists it and every value', (
    tester,
  ) async {
    final values = await pumpForm(tester, [
      [
        GeneratedFormDropdown(
          'choice',
          [
            const MapEntry('', 'Use global default'),
            const MapEntry('a', 'Option A'),
            const MapEntry('b', 'Option B'),
          ],
          label: 'Pick',
          value: '',
          globalValue: (_) => 'b',
        ),
      ],
    ]);
    List<String> listed() => tester
        .widget<DropdownButton<dynamic>>(find.byType(DropdownButton<dynamic>))
        .items!
        .map((item) => ((item.child as Opacity).child as Text).data!)
        .toList();

    expect(values()['choice'], '');
    expect(find.text('Global (Option B)'), findsOneWidget);
    expect(listed(), ['Global (Option B)', 'Option A', 'Option B']);

    await tester.tap(find.byType(DropdownButton<dynamic>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option A').last);
    await tester.pumpAndSettle();
    expect(values()['choice'], 'a');

    await tester.tap(find.byType(DropdownButton<dynamic>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Global (Option B)').last);
    await tester.pumpAndSettle();
    expect(values()['choice'], '');

    await tester.tap(find.byType(DropdownButton<dynamic>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option B').last);
    await tester.pumpAndSettle();
    expect(values()['choice'], 'b');
  });

  testWidgets('dropdown pinned to the global value shows the pin', (
    tester,
  ) async {
    await pumpForm(tester, [
      [
        GeneratedFormDropdown(
          'choice',
          [
            const MapEntry('', 'Use global default'),
            const MapEntry('a', 'Option A'),
            const MapEntry('b', 'Option B'),
          ],
          label: 'Pick',
          value: 'b',
          globalValue: (_) => 'b',
        ),
      ],
    ]);
    final List<dynamic> keys = tester
        .widget<DropdownButton<dynamic>>(find.byType(DropdownButton<dynamic>))
        .items!
        .map((item) => item.value)
        .toList();
    expect(keys, ['', 'a', 'b']);
    expect(find.text('Use global default'), findsNothing);
    expect(find.text('Option B'), findsOneWidget);
  });

  // A per-app override of a global value: '' is a first stop of its own,
  // labelled "Global (<value>)", ahead of every value, so landing on the
  // global value's own stop pins it instead of following the global.
  testWidgets('slider with a global default shows and keeps it', (
    tester,
  ) async {
    final values = await pumpForm(tester, [
      [
        GeneratedFormSlider(
          'days',
          [
            const MapEntry('a', 'Option A'),
            const MapEntry('b', 'Option B'),
            const MapEntry('c', 'Option C'),
          ],
          label: 'Days',
          value: '',
          globalValue: (_) => 'b',
        ),
      ],
    ]);
    Slider slider() => tester.widget<Slider>(find.byType(Slider));
    Future<void> moveTo(double stop) async {
      slider().onChanged!(stop);
      slider().onChangeEnd!(stop);
      await tester.pump();
    }

    expect(values()['days'], '');
    expect(slider().value, 0);
    expect(slider().max, 3);
    expect(find.text('Global (Option B)'), findsOneWidget);

    await moveTo(3);
    expect(values()['days'], 'c');
    expect(find.text('Option C'), findsOneWidget);

    await moveTo(2);
    expect(values()['days'], 'b');
    expect(find.text('Option B'), findsOneWidget);
    expect(find.text('Global (Option B)'), findsNothing);

    await moveTo(0);
    expect(values()['days'], '');
    expect(find.text('Global (Option B)'), findsOneWidget);
  });

  testWidgets('slider pinned to the global value stays pinned', (tester) async {
    await pumpForm(tester, [
      [
        GeneratedFormSlider(
          'days',
          [const MapEntry('a', 'Option A'), const MapEntry('b', 'Option B')],
          label: 'Days',
          value: 'b',
          globalValue: (_) => 'b',
        ),
      ],
    ]);
    expect(find.text('Option B'), findsOneWidget);
    expect(find.text('Global (Option B)'), findsNothing);
  });

  // Add app stays alive beside Settings, so a global value changed there
  // must reach a form that is already open.
  testWidgets('a global value changed while the form is open is shown', (
    tester,
  ) async {
    final SettingsProvider settings = SettingsProvider();
    String global = 'b';
    Map<String, dynamic> values = {};
    const List<MapEntry<String, String>> opts = [
      MapEntry('a', 'Option A'),
      MapEntry('b', 'Option B'),
      MapEntry('c', 'Option C'),
    ];
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: GeneratedForm(
              items: [
                [
                  GeneratedFormSlider(
                    'days',
                    opts,
                    label: 'Days',
                    value: '',
                    globalValue: (_) => global,
                  ),
                ],
                [
                  GeneratedFormDropdown(
                    'choice',
                    [const MapEntry('', 'Use global default'), ...opts],
                    label: 'Pick',
                    value: '',
                    globalValue: (_) => global,
                  ),
                ],
              ],
              onValueChanges: (v, _, _) => values = v,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Global (Option B)'), findsNWidgets(2));

    global = 'c';
    // Any setting change notifies; this one needs no saved preferences.
    settings.checkOnStart = true;
    await tester.pump();

    expect(find.text('Global (Option B)'), findsNothing);
    expect(find.text('Global (Option C)'), findsNWidgets(2));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    expect(values['days'], '');
    expect(values['choice'], '');
  });

  // The options page's sliders must look like the settings page's: the M3E
  // vertical-bar thumb on the gapped track, title left and value right.
  testWidgets('slider uses the settings page slider look', (tester) async {
    await pumpForm(tester, [
      [
        GeneratedFormSlider(
          'days',
          [const MapEntry('a', 'Option A'), const MapEntry('b', 'Option B')],
          label: 'Days',
          value: 'a',
        ),
      ],
    ]);
    final SliderThemeData theme = SliderTheme.of(
      tester.element(find.byType(Slider)),
    );
    expect(theme.thumbShape, isA<M3eVerticalBarThumbShape>());
    expect(theme.trackShape, isA<M3eGappedTrackShape>());
    expect(find.text('Days'), findsOneWidget);
    expect(find.text('Option A'), findsOneWidget);
    // Same text size as the switch rows (bodyLarge), not the body default.
    final double? bodyLarge = Theme.of(tester.element(find.text('Days')))
        .textTheme
        .bodyLarge
        ?.fontSize;
    expect(
      DefaultTextStyle.of(tester.element(find.text('Days'))).style.fontSize,
      bodyLarge,
    );
    expect(
      DefaultTextStyle.of(tester.element(find.text('Option A'))).style.fontSize,
      bodyLarge,
    );
  });
}
