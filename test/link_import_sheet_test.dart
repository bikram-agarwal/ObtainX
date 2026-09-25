import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/backup_import_sheet.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
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

const String _packageId = 'dev.bikram.remember.gh';
const String _githubUrl = 'https://github.com/bikram-agarwal/Remember';

App _app({
  String id = _packageId,
  String? listingId,
  required String url,
  String name = 'Remember',
  String? iconUrl,
  // What a link's app reads before its first check.
  String latestVersion = 'Unknown',
}) {
  return App(
    id: id,
    listingId: listingId,
    url: url,
    author: 'bikram-agarwal',
    name: name,
    iconUrl: iconUrl,
    latestVersion: latestVersion,
    preferredApkIndex: 0,
    additionalSettings: {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Loaded here, outside the widget test's fake clock, which real file and
  // asset reads never finish under.
  late final Map<String, dynamic> translations;
  late final Uint8List icon;
  late SharedPreferences preferences;
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    icon = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test('a link payload reads with its settings expanded', () {
    const String payload =
        '{"id":"a","additionalSettings":"{\\"apkFilterRegEx\\":\\"-github\\\\\\\\.apk\$\\"}"}';

    final String readable = readableLinkPayload(payload);

    expect(readable, contains('\n  "additionalSettings": {'));
    expect(jsonDecode(readable)['additionalSettings'], {
      'apkFilterRegEx': r'-github\.apk$',
    });
    expect(readableLinkPayload('not json'), 'not json');
  });

  /// Opens the add sheet (Import from URL list's, which links use too) for a
  /// link whose apps are all [tracked]: nothing to fetch. [onClosed] gets
  /// what was chosen.
  Future<void> openLinkSheet(
    WidgetTester tester, {
    required List<App> tracked,
    String? rawJson,
    required void Function(BackupImportSelection? chosen) onClosed,
  }) async {
    final SettingsProvider settings = SettingsProvider()..prefs = preferences;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    final _Apps provider = _Apps();
    for (final App app in tracked) {
      provider.apps[app.listingKey] = AppInMemory(app, null, null, icon);
    }
    addTearDown(provider.dispose);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                onClosed(
                  await showUrlListImportPickerSheet(
                    context: context,
                    urls: const [],
                    alreadyTracked: tracked,
                    existingApps: provider.apps,
                    fetchApp: (String url) async =>
                        throw StateError('Nothing to fetch'),
                    trackedListingFor: (App app) => null,
                    rawJson: rawJson,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets("a link's JSON shows collapsed under its apps", (tester) async {
    final App tracked = _app(
      id: 'dev.bikram.filepipe',
      url: 'https://github.com/bikram-agarwal/FilePipe',
      name: 'FilePipe',
      latestVersion: '2.4.0',
    );
    BackupImportSelection? chosen;
    await openLinkSheet(
      tester,
      tracked: [tracked],
      rawJson: '{"raw": "payload"}',
      onClosed: (BackupImportSelection? selection) => chosen = selection,
    );

    // Listed with no checkbox, in two lines: name and author.
    expect(find.text('FilePipe'), findsOneWidget);
    expect(find.text('2.4.0'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    // Raw JSON starts collapsed.
    expect(find.text('{"raw": "payload"}'), findsNothing);

    await tester.tap(find.text(tr('rawJson')));
    await tester.pumpAndSettle();
    expect(find.text('{"raw": "payload"}'), findsOneWidget);

    await tester.tap(find.text(tr('cancel')));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a backup row shows name and author only', (tester) async {
    final SettingsProvider settings = SettingsProvider()..prefs = preferences;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    final _Apps provider = _Apps();
    addTearDown(provider.dispose);
    addTearDown(settings.dispose);
    // The version a backup recorded is neither the installed nor the latest.
    final App backedUp = _app(url: _githubUrl, latestVersion: '3.1.4');
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showBackupImportPickerSheet(
                context: context,
                backupApps: [backedUp],
                hasSettings: false,
                hasSecrets: false,
                existingApps: provider.apps,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Remember'), findsOneWidget);
    expect(find.text(tr('byX', args: ['bikram-agarwal'])), findsOneWidget);
    expect(find.text('3.1.4'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a link whose apps are all tracked lists them with nothing to '
      'import', (tester) async {
    final List<App> tracked = [
      for (final String name in ['Alpha', 'Bravo', 'Charlie'])
        _app(
          id: 'org.${name.toLowerCase()}',
          url: 'https://github.com/x/$name',
          name: name,
        ),
    ];
    bool closed = false;
    BackupImportSelection? chosen;
    await openLinkSheet(
      tester,
      tracked: tracked,
      onClosed: (BackupImportSelection? selection) {
        closed = true;
        chosen = selection;
      },
    );

    expect(find.text(tr('alreadyTrackedApps')), findsOneWidget);
    for (final App app in tracked) {
      expect(find.text(app.name), findsOneWidget);
    }
    expect(find.text(tr('newApps')), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, tr('import')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text(tr('cancel')));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(chosen, isNull);
    expect(tester.takeException(), isNull);
  });
}
