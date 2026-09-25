import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/backup_import_sheet.dart';
import 'package:obtainium/custom_errors.dart';
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

App _app(String id, String url, String name) => App(
  id: id,
  url: url,
  author: 'author',
  name: name,
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: {},
);

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

  test('a URL list is sorted into tracked apps and ones to fetch', () {
    final AppListings listings = AppListings();
    final App adAway = _app(
      'org.adaway',
      'https://github.com/AdAway/AdAway',
      'AdAway',
    );
    const String rememberUrl = 'https://github.com/bikram-agarwal/Remember';
    final App rememberGh = _app('dev.bikram.remember.gh', rememberUrl, 'R');
    for (final App app in [adAway, rememberGh]) {
      listings[app.listingKey] = AppInMemory(app, null, null, null);
    }

    final UrlImportPlan plan = planUrlImport(listings, [
      // Stored under the source's standard form of the URL.
      const UrlImportEntry('https://github.com/AdAway/AdAway/releases'),
      const UrlImportEntry('https://github.com/a/new'),
      const UrlImportEntry('https://github.com/a/new'),
      // A link that names its package matches on that package, not the URL:
      // the repo's .gh build is tracked, its .offline build isn't.
      UrlImportEntry(rememberUrl, seed: rememberGh),
      UrlImportEntry(
        rememberUrl,
        seed: _app('dev.bikram.remember.offline', rememberUrl, 'R'),
      ),
      const UrlImportEntry('https://gitlab.com/AuroraOSS/AuroraStore'),
    ], SourceProvider());

    expect(plan.alreadyTracked.map((AppInMemory l) => l.app.id), [
      'org.adaway',
      'dev.bikram.remember.gh',
    ]);
    // Fetched once each, in the order typed.
    expect(plan.toFetch.map((UrlImportEntry entry) => entry.url), [
      'https://github.com/a/new',
      rememberUrl,
      'https://gitlab.com/AuroraOSS/AuroraStore',
    ]);
    expect(plan.toFetch[1].seed?.id, 'dev.bikram.remember.offline');
  });

  test("a link's app is fetched with its own settings, as Add app's fields "
      'would be filled in', () {
    final App seed =
        _app(
          'dev.bikram.remember.gh',
          'https://github.com/bikram-agarwal/Remember',
          'Remember',
        ).copyWith(
          additionalSettings: {
            'apkFilterRegEx': r'-github\.apk$',
            // Folders on the phone it came from.
            'folderIds': ['f1'],
            'folderNames': {'f1': 'Notes'},
            'excludedFolderIds': ['f2'],
          },
        );

    // Its package ID goes in as the custom App ID.
    expect(urlImportSettingsFor(seed), {
      'apkFilterRegEx': r'-github\.apk$',
      'appId': 'dev.bikram.remember.gh',
    });
    // A temporary one is looked up instead, as for a URL.
    expect(urlImportSettingsFor(seed.copyWith(id: '0123456789ab')), {
      'apkFilterRegEx': r'-github\.apk$',
    });
    expect(seed.additionalSettings['folderIds'], ['f1']);
  });

  // The URL list saves through Add app's own steps (AppsProvider
  // .addNewListing), so a track-only app's installed version comes from the
  // phone as it does there.
  test('a fetched app is prepared for adding as Add app prepares it', () async {
    const MethodChannel deviceApps = MethodChannel(
      'dev.imranr.obtainium/device_apps',
    );
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(deviceApps, (MethodCall call) async {
      if (call.method != 'getInstalledPackageInfo' ||
          call.arguments['packageName'] != 'com.android.vending') {
        return null;
      }
      return {
        'packageName': 'com.android.vending',
        'versionName': '45.1.2',
        'versionCode': 84512,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(deviceApps, null));
    App trackOnly(String id) => _app(
      id,
      'https://www.apkmirror.com/apk/google-inc/google-play-store',
      'google-play-store',
    ).copyWith(additionalSettings: {'trackOnly': true});

    final App store = await appPreparedForAdding(
      trackOnly('com.android.vending'),
    );
    expect(store.installedVersion, '45.1.2');
    expect(store.additionalSettings['trackOnlyTemporaryPackageId'], false);
    expect(
      store.additionalSettings['trackOnlyUndeterminedInstalledVersion'],
      false,
    );
    // With a temporary ID, there's nothing to ask the phone about.
    final App unknown = await appPreparedForAdding(trackOnly('0123456789ab'));
    expect(unknown.installedVersion, isNull);
    expect(unknown.additionalSettings['trackOnlyTemporaryPackageId'], true);
  });

  testWidgets('the URL list sheet shows tracked apps at once and fetches the '
      'rest while open', (tester) async {
    final SettingsProvider settings = SettingsProvider()..prefs = preferences;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    final _Apps provider = _Apps();
    AppInMemory track(App app) {
      final AppInMemory listing = AppInMemory(app, null, null, icon);
      provider.apps[app.listingKey] = listing;
      return listing;
    }

    final AppInMemory filePipe = track(
      _app('dev.bikram.filepipe', 'https://github.com/b/FilePipe', 'FilePipe'),
    );
    // Tracked under a URL the list doesn't use: only its fetch finds it.
    final AppInMemory charlie = track(
      _app('org.charlie', 'https://github.com/c/Charlie', 'Charlie'),
    );
    addTearDown(provider.dispose);
    addTearDown(settings.dispose);

    const List<String> urls = [
      'https://github.com/a/Alpha',
      'https://github.com/a/Broken',
      'https://gitlab.com/c/Charlie',
      'https://github.com/a/Slow',
    ];
    final Map<String, Completer<App>> fetches = {
      for (final String url in urls) url: Completer<App>(),
    };
    final App alpha = _app('org.alpha', urls[0], 'Alpha');

    BackupImportSelection? chosen;
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
                chosen = await showUrlListImportPickerSheet(
                  context: context,
                  urls: urls,
                  alreadyTracked: [filePipe.app],
                  existingApps: provider.apps,
                  fetchApp: (String url) => fetches[url]!.future,
                  trackedListingFor: (App app) =>
                      app.id == 'org.charlie' ? charlie : null,
                  // As saving will name and draw it, with its icon downloaded.
                  lookFor: (App app) async => NewAppLook(
                    name: '${app.name} as saved',
                    icon: icon,
                    downloadedIcon: icon,
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
    // The spinners never settle, so the clock is stepped instead.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Tracked from the start, and every other URL fetching.
    expect(find.text(tr('alreadyTrackedApps')), findsOneWidget);
    expect(find.text('FilePipe'), findsOneWidget);
    expect(find.text('github.com/a/Alpha'), findsOneWidget);
    expect(find.byType(ExpressiveLoadingIndicator), findsNWidgets(4));
    expect(find.text('${tr('selectAppsToImport')} (0/4)'), findsOneWidget);

    fetches[urls[0]]!.complete(alpha);
    fetches[urls[1]]!.completeError(ObtainiumError('No releases found'));
    fetches[urls[2]]!.complete(
      _app('org.charlie', urls[2], 'Charlie from GitLab'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Alpha arrived selected, looking as it will once saved; Broken says why;
    // Charlie joined the tracked group as the listing it duplicates.
    expect(find.text('Alpha as saved'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    // Two lines only, name and author: no URL once it has arrived, and no
    // version, on any row.
    expect(find.text(urls[0]), findsNothing);
    expect(find.text('github.com/a/Alpha'), findsNothing);
    expect(find.text('1.0'), findsNothing);
    expect(find.text('No releases found'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('github.com/c/Charlie'), findsNothing);
    expect(find.text('gitlab.com/c/Charlie'), findsNothing);
    expect(find.byType(ExpressiveLoadingIndicator), findsOneWidget);
    // Only the new group's header and Alpha can be ticked.
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('${tr('selectAppsToImport')} (1/2)'), findsOneWidget);

    // Imported with Slow still fetching: it is dropped when it arrives.
    await tester.tap(find.text(tr('import')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(chosen?.fetchedApps, [alpha]);
    // The icon shown is handed over for the add to keep, not downloaded again.
    expect(chosen?.downloadedIcons, {'org.alpha': icon});

    fetches[urls[3]]!.complete(_app('org.slow', urls[3], 'Slow'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
