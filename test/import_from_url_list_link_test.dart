import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/import_from_url_list.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _link(String id) =>
    'obtainium://app/'
    '${Uri.encodeComponent(jsonEncode({'id': id, 'url': 'https://github.com/a/$id'}))}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Loaded here, outside the widget test's fake clock, which real file and
  // asset reads never finish under.
  late final Map<String, dynamic> translations;
  late SharedPreferences preferences;
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  /// Opens the page as the phone layout does: pushed above the home page.
  Future<void> openPage(
    WidgetTester tester,
    Future<void> Function(Uri link, {VoidCallback? onLeave}) openLink,
  ) async {
    final SettingsProvider settings = SettingsProvider()..prefs = preferences;
    addTearDown(settings.dispose);
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ImportFromUrlListPage(openLink: openLink),
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

  testWidgets('pasted links open as one link import, and the page closes '
      'once it goes ahead', (tester) async {
    final List<Uri> opened = [];
    await openPage(tester, (Uri link, {VoidCallback? onLeave}) async {
      opened.add(link);
      onLeave?.call();
    });
    expect(find.text(tr('appURLListTakesLinks')), findsOneWidget);

    await tester.enterText(
      find.byType(TextFormField),
      '${_link('a.b')}\n\n${_link('c.d')}',
    );
    await tester.pump();
    // Not checked as a URL list, which would reject both lines.
    expect(find.textContaining('${tr('line')} 1'), findsNothing);

    await tester.tap(find.text(tr('import')));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.host, 'apps');
    expect(find.byType(ImportFromUrlListPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the import sheet keeps the page and its text', (
    tester,
  ) async {
    await openPage(tester, (Uri link, {VoidCallback? onLeave}) async {});
    final String link = _link('a.b');
    await tester.enterText(find.byType(TextFormField), link);
    await tester.pump();

    await tester.tap(find.text(tr('import')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportFromUrlListPage), findsOneWidget);
    expect(find.text(link), findsOneWidget);
    // The Import button is usable again.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, tr('import')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
