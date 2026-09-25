import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/import_from_url_list.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

Map<String, Object> _json(String id) => {
  'id': id,
  'url': 'https://github.com/a/$id',
  'author': 'a',
  'name': id,
  'additionalSettings': jsonEncode({'apkFilterRegEx': '-$id'}),
};

String _link(String id) =>
    'obtainium://app/${Uri.encodeComponent(jsonEncode(_json(id)))}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Reading JSON that isn't apps logs why, and logs go to a sqflite database.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
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

  group('whatever the box holds becomes the same kind of entry', () {
    final _Apps apps = _Apps();
    List<String?> ids(List<UrlImportEntry> entries) =>
        entries.map((UrlImportEntry entry) => entry.seed?.id).toList();

    test('URLs, one per line', () {
      final List<UrlImportEntry> entries = urlImportEntriesIn(
        'https://github.com/a/one\n\n  https://f-droid.org/packages/b.c  \n',
        apps,
      );
      expect(entries.map((UrlImportEntry entry) => entry.url), [
        'https://github.com/a/one',
        'https://f-droid.org/packages/b.c',
      ]);
      expect(ids(entries), [null, null]);
    });

    test('app links, with what each says about its app', () {
      final List<UrlImportEntry> entries = urlImportEntriesIn(
        '${_link('a.b')}\n\n${_link('c.d')}',
        apps,
      );
      expect(entries.map((UrlImportEntry entry) => entry.url), [
        'https://github.com/a/a.b',
        'https://github.com/a/c.d',
      ]);
      expect(ids(entries), ['a.b', 'c.d']);
      expect(entries.first.seed!.additionalSettings['apkFilterRegEx'], '-a.b');
    });

    test('raw JSON and an export', () {
      expect(
        ids(urlImportEntriesIn(jsonEncode([_json('a.b'), _json('c.d')]), apps)),
        ['a.b', 'c.d'],
      );
      expect(
        ids(
          urlImportEntriesIn(
            jsonEncode({
              'apps': [_json('e.f')],
              'settings': {'theme': 1},
            }),
            apps,
          ),
        ),
        ['e.f'],
      );
    });

    test('links and URLs mixed, line by line', () {
      final List<UrlImportEntry> entries = urlImportEntriesIn(
        '${_link('a.b')}\nhttps://github.com/a/plain',
        apps,
      );
      expect(entries.map((UrlImportEntry entry) => entry.url), [
        'https://github.com/a/a.b',
        'https://github.com/a/plain',
      ]);
      expect(ids(entries), ['a.b', null]);
    });
  });

  group('what a picked file adds to the box', () {
    final _Apps apps = _Apps();
    final SourceProvider sources = SourceProvider();
    String fromFile(String contents) =>
        urlListTextInFile(contents, apps, sources);

    test('a file that could have been typed in is taken as it is', () {
      final String export = jsonEncode({
        'apps': [_json('a.b')],
        'settings': {'theme': 1},
      });
      expect(fromFile('\n$export\n'), export);
      final String links = '${_link('a.b')}\n\n${_link('c.d')}';
      expect(fromFile(links), links);
      // A site only the HTML source takes stays: the list is the user's own.
      expect(
        fromFile('https://github.com/a/one\r\n\r\nhttps://example.com/app\r\n'),
        'https://github.com/a/one\nhttps://example.com/app',
      );
    });

    test('from any other file, only app links and sites with their own '
        'source', () {
      const String opml = '''
<?xml version="1.0"?>
<opml version="2.0"><head><title>Feeds</title></head><body>
<outline text="App" xmlUrl="https://github.com/a/app/releases.atom" htmlUrl="https://github.com/a/app/releases"/>
<outline text="News" xmlUrl="https://news.example.com/feed.xml" htmlUrl="https://news.example.com/"/>
</body></opml>''';
      expect(fromFile(opml), 'https://github.com/a/app');

      final String notes =
          'Get it from F-Droid (https://f-droid.org/packages/b.c). '
          'Or [its link](${_link('a.b')}), or https://example.com/download.';
      expect(
        fromFile(notes),
        'https://f-droid.org/packages/b.c\n${_link('a.b')}',
      );

      // JSON that isn't apps is searched like the rest.
      expect(
        fromFile(
          jsonEncode({
            'repos': ['https://github.com/a/x'],
          }),
        ),
        'https://github.com/a/x',
      );
      expect(fromFile('Nothing here.'), '');
    });

    test('reads as the same apps the box would give', () {
      final List<UrlImportEntry> fromExport = urlImportEntriesIn(
        fromFile(
          jsonEncode({
            'apps': [_json('a.b')],
          }),
        ),
        apps,
      );
      expect(fromExport.single.seed!.id, 'a.b');
      expect(
        fromExport.single.seed!.additionalSettings['apkFilterRegEx'],
        '-a.b',
      );
      final List<UrlImportEntry> fromNotes = urlImportEntriesIn(
        fromFile('See https://f-droid.org/packages/b.c and ${_link('c.d')}.'),
        apps,
      );
      expect(fromNotes.map((UrlImportEntry entry) => entry.url), [
        'https://f-droid.org/packages/b.c',
        'https://github.com/a/c.d',
      ]);
      expect(fromNotes.map((UrlImportEntry entry) => entry.seed?.id), [
        null,
        'c.d',
      ]);
    });
  });

  testWidgets('a pasted link opens the URL list sheet, and cancelling it '
      'keeps the page and its text', (tester) async {
    final SettingsProvider settings = SettingsProvider()..prefs = preferences;
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
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ImportFromUrlListPage(),
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
    for (final String key in [
      'appURLListAcceptsUrls',
      'appURLListAcceptsLinks',
      'appURLListAcceptsJson',
    ]) {
      expect(find.text(tr(key)), findsOneWidget);
    }
    // Top to bottom: the card (what it takes, then the not-installed note),
    // the box, Import, then Import from file.
    final List<Finder> order = [
      find.text(tr('appURLListAccepts')),
      find.text(tr('importedAppsIdDisclaimer')),
      find.byType(TextFormField),
      find.widgetWithText(FilledButton, tr('import')),
      find.widgetWithText(OutlinedButton, tr('importFromURLsInFile')),
    ];
    for (int index = 1; index < order.length; index++) {
      expect(
        tester.getTopLeft(order[index]).dy,
        greaterThan(tester.getBottomLeft(order[index - 1]).dy),
      );
    }

    // Import is off while it has nothing to do; Import from file never is.
    bool importEnabled() =>
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, tr('import')),
            )
            .onPressed !=
        null;
    expect(importEnabled(), isFalse);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, tr('importFromURLsInFile')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.enterText(find.byType(TextFormField), '  \n ');
    await tester.pump();
    expect(importEnabled(), isFalse);
    await tester.enterText(find.byType(TextFormField), 'not a url');
    await tester.pump();
    expect(importEnabled(), isFalse);

    final String link = _link('a.b');
    await tester.enterText(find.byType(TextFormField), link);
    await tester.pump();
    // Not checked as a URL, which would reject it.
    expect(find.textContaining('${tr('line')} 1'), findsNothing);
    expect(importEnabled(), isTrue);

    await tester.ensureVisible(find.text(tr('import')));
    await tester.pump();
    await tester.tap(find.text(tr('import')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The same sheet as for URLs: the link's app is fetched like one.
    expect(find.text(tr('newApps')), findsOneWidget);
    expect(find.text('github.com/a/a.b'), findsOneWidget);

    await tester.tap(find.text(tr('cancel')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ImportFromUrlListPage), findsOneWidget);
    expect(find.text(link), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, tr('import')))
          .onPressed,
      isNotNull,
    );

    // Off, a tap on Import says why: nothing entered, or the line it can't
    // read.
    Finder warning(Finder text) =>
        find.descendant(of: find.byType(SnackBar), matching: text);
    await tester.enterText(find.byType(TextFormField), '');
    await tester.pump();
    await tester.tap(find.text(tr('import')));
    await tester.pump();
    expect(warning(find.text(tr('enterAppsToImportFirst'))), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'not a url');
    await tester.pump();
    await tester.tap(find.text(tr('import')));
    await tester.pump();
    expect(warning(find.textContaining('${tr('line')} 1')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
