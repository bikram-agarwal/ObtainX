import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/import_export.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final Map<String, dynamic> translations;
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
  });

  /// Opens the page with [preferences] saved.
  Future<void> openPage(
    WidgetTester tester, [
    Map<String, Object> preferences = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(preferences);
    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    final _Apps apps = _Apps();
    addTearDown(settings.dispose);
    addTearDown(apps.dispose);
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: const MaterialApp(home: ImportExportPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  SwitchListTile autoExport(WidgetTester tester) =>
      tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, tr('autoExportOnChanges')),
      );

  testWidgets('with no backup folder, auto-export is off and looks it, even '
      'when it was turned on', (tester) async {
    await openPage(tester, {'autoExportOnChanges': true});

    expect(autoExport(tester).value, isFalse);
    expect(autoExport(tester).onChanged, isNull);

    // Tapped, it says why.
    await tester.ensureVisible(find.text(tr('autoExportOnChanges')));
    await tester.tap(find.text(tr('autoExportOnChanges')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(tr('pickExportDirFirst')),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('with a backup folder, auto-export can be turned on', (
    tester,
  ) async {
    await openPage(tester, {
      'exportDir':
          'content://com.android.externalstorage.documents/tree/primary%3AObtainX',
    });

    expect(autoExport(tester).value, isFalse);
    expect(autoExport(tester).onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no folders picked, the buttons that would do nothing '
      'look off', (tester) async {
    await openPage(tester);

    // App icons' Import and Export come first, then the backup's.
    final Finder imports = find.widgetWithText(
      TextButton,
      tr('obtainiumImport'),
    );
    final Finder exports = find.widgetWithText(
      TextButton,
      tr('obtainiumExport'),
    );
    expect(imports, findsNWidgets(2));
    expect(exports, findsNWidgets(2));
    bool enabled(Finder button) =>
        tester.widget<TextButton>(button).onPressed != null;
    Color? labelColor(Finder button) => tester
        .renderObject<RenderParagraph>(
          find.descendant(of: button, matching: find.byType(RichText)),
        )
        .text
        .style
        ?.color;
    final Color onSurface = Theme.of(
      tester.element(imports.first),
    ).colorScheme.onSurface;

    // No icons folder: both do nothing, and look it.
    for (final Finder button in [imports.first, exports.first]) {
      expect(enabled(button), isFalse);
      expect(labelColor(button), onSurface.withValues(alpha: 0.38));
    }
    // A backup can be imported from anywhere, and Export asks for a folder
    // first, so both work.
    for (final Finder button in [imports.last, exports.last]) {
      expect(enabled(button), isTrue);
      expect(labelColor(button), onSurface);
    }

    // Tapped, the icons ones say why, and nothing else happens.
    for (final Finder button in [imports.first, exports.first]) {
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(tr('pickIconsDirFirst')),
        ),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('taps on controls that are on go to them, not to a warning', (
    tester,
  ) async {
    await openPage(tester, {
      'exportDir':
          'content://com.android.externalstorage.documents/tree/primary%3AObtainX',
    });

    await tester.ensureVisible(find.text(tr('autoExportOnChanges')));
    await tester.tap(find.text(tr('autoExportOnChanges')));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    expect(autoExport(tester).value, isTrue);
    expect(tester.takeException(), isNull);
  });
}
