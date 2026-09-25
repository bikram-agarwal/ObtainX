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
const String _fdroidUrl = 'https://f-droid.org/packages/dev.bikram.remember.gh';

App _app({
  String id = _packageId,
  String? listingId,
  required String url,
  String name = 'Remember',
  String? iconUrl,
}) {
  return App(
    id: id,
    listingId: listingId,
    url: url,
    author: 'bikram-agarwal',
    name: name,
    iconUrl: iconUrl,
    latestVersion: 'Unknown',
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

  testWidgets('the link picker keys rows by listing and never re-imports a '
      'tracked app', (tester) async {
    final SettingsProvider settings = SettingsProvider()..prefs = preferences;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    final _Apps provider = _Apps();
    final App tracked = _app(
      id: 'dev.bikram.filepipe',
      url: 'https://github.com/bikram-agarwal/FilePipe',
      name: 'FilePipe',
    );
    provider.apps[tracked.listingKey] = AppInMemory(tracked, null, null, icon);
    addTearDown(provider.dispose);
    addTearDown(settings.dispose);

    // One package from two stores: two listings, which must stay separate.
    final App github = _app(
      url: _githubUrl,
      iconUrl: 'https://tracker.example/pixel.png',
    );
    final App fdroid = _app(
      listingId: appListingKey(_packageId, 'FDroid'),
      url: _fdroidUrl,
    );
    Set<String>? chosen;
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
                chosen = await showLinkImportPickerSheet(
                  context: context,
                  newApps: [github, fdroid],
                  alreadyTracked: [tracked],
                  existingApps: provider.apps,
                  rawJson: '{"raw": "payload"}',
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

    expect(find.text('${tr('selectAppsToImport')} (2/2)'), findsOneWidget);
    // Each listing shows the source it will be tracked from.
    expect(find.text(_githubUrl), findsOneWidget);
    expect(find.text(_fdroidUrl), findsOneWidget);
    // The tracked app is listed, but has no checkbox: only the new section's
    // header and its two rows do.
    expect(find.text('FilePipe'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));
    // A link's iconUrl is never fetched: opening the sheet must not contact
    // a server the link chose.
    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is Image && widget.image is NetworkImage,
      ),
      findsNothing,
    );
    // Raw JSON starts collapsed.
    expect(find.text('{"raw": "payload"}'), findsNothing);

    await tester.tap(find.text(_fdroidUrl));
    await tester.pumpAndSettle();
    expect(find.text('${tr('selectAppsToImport')} (1/2)'), findsOneWidget);

    await tester.tap(find.text(tr('rawJson')));
    await tester.pumpAndSettle();
    expect(find.text('{"raw": "payload"}'), findsOneWidget);

    await tester.tap(find.text(tr('import')));
    await tester.pumpAndSettle();
    expect(chosen, {github.listingKey});
    expect(tester.takeException(), isNull);
  });
}
