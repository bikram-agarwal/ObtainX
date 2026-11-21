import 'package:android_package_manager/android_package_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/widgets/app_toast.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  @override
  final Map<String, ({String? title, String message})> appPageErrors = {};
  // The app page's Downgrade gate asks the app's installer (v1.7.4 D13,
  // getInstaller(app)), which reads the global install method from here.
  @override
  late SettingsProvider settingsProvider;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _InstalledPackage extends PackageInfo {
  const _InstalledPackage(String versionName, int versionCode)
    : super(
        installLocation: AndroidInstallLocation.unspecified,
        packageName: 'com.google.android.aicore',
        versionName: versionName,
        versionCode: versionCode,
      );
}

App _app(String installed, String latest, {bool trackOnly = true}) {
  return App(
    id: 'com.google.android.aicore',
    url: trackOnly
        ? 'https://www.apkmirror.com/apk/google-inc/aicore/'
        : 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    apkSizeBytes: 40 * 1024 * 1024,
    additionalSettings: {'trackOnly': trackOnly, 'versionDetection': 'auto'},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final Map<String, dynamic> translations;
  late final Uint8List icon;
  late SharedPreferences preferences;
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    icon = (await rootBundle.load('assets/graphics/logo_remember.png')).buffer
        .asUint8List();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'matchAppPageToIconColors': false,
      'checkUpdateOnDetailPage': false,
      'showAppWebpage': false,
      'updateButtonsAtTopOfAppPage': true,
    });
    preferences = await SharedPreferences.getInstance();
  });

  for (final (installed, latest, verdict) in [
    ('1.2.3', 'v1.2.3', AppVersionDisplayVerdict.sameVersion),
    ('v1.2.3', '1.2.3', AppVersionDisplayVerdict.sameVersion),
    ('V1.2.3', '1.2.3', AppVersionDisplayVerdict.sameVersion),
    ('v1.2.3-rc1', '1.2.3-rc1', AppVersionDisplayVerdict.sameVersion),
    ('v1.2.3-rc1', '1.2.3', AppVersionDisplayVerdict.updateAvailable),
    ('1.2.3-foss', '1.2.3', AppVersionDisplayVerdict.effectivelyEqual),
  ]) {
    test('details verdict for $installed / $latest', () {
      expect(appVersionVerdictForDisplay(_app(installed, latest)), verdict);
    });
  }

  test(
    'Downgrade is offered only for a newer build with a release to go to',
    () {
      expect(
        appOffersDowngrade(_app('2.21.0', '2.20.0', trackOnly: false)),
        isTrue,
      );
      expect(
        appOffersDowngrade(_app('2.20.0', '2.21.0', trackOnly: false)),
        isFalse,
      );
      expect(
        appOffersDowngrade(_app('2.20.0', '2.20.0', trackOnly: false)),
        isFalse,
      );
      // Track-only too: its Downgrade opens the release page, as Update does.
      expect(appOffersDowngrade(_app('2.21.0', '2.20.0')), isTrue);
      final App noMatch = _app('2.21.0', '2.20.0', trackOnly: false);
      expect(
        appOffersDowngrade(
          noMatch.copyWith(
            additionalSettings: {
              ...noMatch.additionalSettings,
              noMatchingReleaseKey: true,
            },
          ),
        ),
        isFalse,
      );
    },
  );

  test('marking a by-hand track-only downgrade moves the mark down', () {
    final App app = _app('2.21.0', '2.20.0');
    // A plain acknowledgement keeps the newer mark, so it stays newer.
    expect(
      versionDecisionForApp(acknowledgeSourceRelease(app)).relation,
      VersionRelation.newer,
    );
    final App marked = markTrackOnlyDowngraded(app);
    expect(marked.installedVersion, '2.20.0');
    expect(marked.additionalSettings[trackOnlyUserMarkedInstalledKey], isTrue);
    expect(versionDecisionForApp(marked).relation, VersionRelation.same);
    expect(appOffersDowngrade(marked), isFalse);
  });

  test('only an installer that can downgrade runs one', () {
    expect(
      installerCanDowngrade(
        installerModeKey: 'external',
        downgradeModuleUsable: false,
      ),
      isTrue,
    );
    for (final String mode in ['system', 'shizuku', 'dhizuku']) {
      expect(
        installerCanDowngrade(
          installerModeKey: mode,
          downgradeModuleUsable: false,
        ),
        isFalse,
        reason: mode,
      );
      expect(
        installerCanDowngrade(
          installerModeKey: mode,
          downgradeModuleUsable: true,
        ),
        isTrue,
        reason: mode,
      );
    }
  });

  for (final (installerMode, corePatchInstalled, canDowngrade) in [
    ('external', false, true),
    ('system', false, false),
    ('system', true, true),
  ]) {
    testWidgets('newer on device shows Downgrade '
        '(installer: $installerMode, CorePatch: $corePatchInstalled)', (
      tester,
    ) async {
      if (corePatchInstalled) {
        final messenger = tester.binding.defaultBinaryMessenger;
        const channel = MethodChannel('dev.imranr.obtainium/device_apps');
        messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
          final Object? packageName = call.arguments is Map
              ? (call.arguments as Map)['packageName']
              : null;
          return call.method == 'getInstalledPackageInfo' &&
                  packageName == 'org.lsposed.corepatch'
              ? <String, Object?>{'packageName': packageName}
              : null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      final settings = SettingsProvider()..prefs = preferences;
      settings.installerMode = installerMode;
      Localization.load(
        const Locale('en'),
        translations: Translations(translations),
      );
      final provider = _Apps()..settingsProvider = settings;
      final model = _app('2.21.0', '2.20.0', trackOnly: false);
      provider.apps[model.id] = AppInMemory(model, null, null, icon);
      addTearDown(provider.dispose);
      addTearDown(settings.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 1600);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppsProvider>.value(value: provider),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          // The app theme, so snackbars float with the app's insets.
          child: MaterialApp(
            theme: buildObtainiumTheme(const ColorScheme.light(), null),
            home: AppPage(appId: model.id),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Update · 40 MB'), findsNothing);
      final downgradeButton = find.widgetWithText(
        FilledButton,
        'Downgrade · 40 MB',
      );
      expect(
        tester.widget<FilledButton>(downgradeButton).onPressed,
        canDowngrade ? isNotNull : isNull,
      );
      if (canDowngrade) {
        final String question = tr(
          'downgradeToVersionQuestion',
          args: ['2.20.0'],
        );
        await tester.tap(downgradeButton);
        await tester.pumpAndSettle();
        expect(find.text(question), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, tr('cancel')));
        await tester.pumpAndSettle();
        expect(find.text(question), findsNothing);
        expect(find.text(tr('downgradeNeedsCapableInstaller')), findsNothing);
      } else {
        // A tap on the disabled button explains it, not just a long-press.
        await tester.tap(downgradeButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text(tr('downgradeNeedsCapableInstaller')), findsOneWidget);
        // Sits just above the page's bottom bar, like its other snackbars.
        expect(
          tester.widget<SnackBar>(find.byType(SnackBar)).margin,
          buildAppSnackBar(
            tester.element(find.byType(AppPage)),
            '',
            scaffoldHasBottomBar: true,
          ).margin,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final packageReadable in [false, true]) {
    testWidgets('track-only newer on device shows Downgrade '
        '(package readable: $packageReadable)', (tester) async {
      final settings = SettingsProvider()..prefs = preferences;
      Localization.load(
        const Locale('en'),
        translations: Translations(translations),
      );
      final provider = _Apps();
      final model = _app('2.21.0', '2.20.0');
      provider.apps[model.id] = AppInMemory(
        model,
        null,
        packageReadable ? const _InstalledPackage('2.21.0', 2210) : null,
        icon,
      );
      addTearDown(provider.dispose);
      addTearDown(settings.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 1600);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppsProvider>.value(value: provider),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          child: MaterialApp(home: AppPage(appId: model.id)),
        ),
      );
      // With an installed package the page never settles under test; a fixed
      // pump is enough for the action bar.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // The stock installer can't downgrade, but a track-only app installs
      // nothing itself, so the release page is always open to it.
      final downgradeButton = find.widgetWithText(
        FilledButton,
        'Downgrade · 40 MB',
      );
      expect(tester.widget<FilledButton>(downgradeButton).onPressed, isNotNull);
      final markButton = find.widgetWithText(
        FilledButton,
        tr('markDowngraded'),
      );
      if (packageReadable) {
        expect(markButton, findsNothing);
      } else {
        expect(tester.widget<FilledButton>(markButton).onPressed, isNotNull);
      }
      expect(find.text(tr('markUpdated')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final (installed, latest, trackOnly, reducedEffects) in [
    for (final reducedEffects in [false, true]) ...[
      (
        '0.release.prod_aicore_20260723.00_RC11.964081323',
        '20260723.00_RC11.964081323',
        true,
        reducedEffects,
      ),
      (
        'C.6.playstore.pixel9.961955194',
        'B.28.playstore.oemfull.969713662',
        true,
        reducedEffects,
      ),
      ('1.5.5 (4D91B33C)', '1.5.5-ced5040c', false, reducedEffects),
    ],
  ]) {
    testWidgets(
      'manual actions during another download: $installed (reduced effects: $reducedEffects)',
      (tester) async {
        await preferences.setBool('reduceVisualEffects', reducedEffects);
        final settings = SettingsProvider()..prefs = preferences;
        Localization.load(
          const Locale('en'),
          translations: Translations(translations),
        );
        final provider = _Apps();
        final model = _app(installed, latest, trackOnly: trackOnly);
        provider.apps[model.id] = AppInMemory(model, null, null, icon);
        final other = AppInMemory(
          model.copyWith(id: 'org.example.other'),
          null,
          null,
          icon,
        );
        provider.apps[other.app.id] = other;
        addTearDown(provider.dispose);
        addTearDown(settings.dispose);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(480, 1600);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AppsProvider>.value(value: provider),
              ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ],
            child: MaterialApp(home: AppPage(appId: model.id)),
          ),
        );
        await tester.pumpAndSettle();

        final updateButton = find.widgetWithText(
          FilledButton,
          'Update · 40 MB',
        );
        final markButton = find.widgetWithText(FilledButton, tr('markUpdated'));
        final skipButton = find.widgetWithText(TextButton, tr('skipVersion'));
        expect(tester.widget<FilledButton>(updateButton).onPressed, isNotNull);

        other.downloadProgress = 0.3;
        provider.notifyListeners();
        await tester.pumpAndSettle();
        expect(
          tester.widget<FilledButton>(updateButton).onPressed,
          trackOnly ? isNotNull : isNull,
        );
        expect(tester.widget<TextButton>(skipButton).onPressed, isNotNull);
        if (trackOnly) {
          expect(tester.widget<FilledButton>(markButton).onPressed, isNotNull);
        }

        other.downloadProgress = null;
        provider.notifyListeners();
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(updateButton).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  group('with the package confirmed on F-Droid', () {
    // A store chip only shows once a scan has confirmed the store, so seed
    // the scan cache the way a finished scan leaves it.
    setUp(() {
      BulkScanCache.setCacheForTesting({
        'com.google.android.aicore': {
          'F-Droid': 'https://f-droid.org/packages/com.google.android.aicore/',
        },
      });
    });
    tearDown(() => BulkScanCache.setCacheForTesting({}));

    testWidgets('alternate F-Droid icon long-press offers swap menu', (
      tester,
    ) async {
      final settings = SettingsProvider()..prefs = preferences;
      Localization.load(
        const Locale('en'),
        translations: Translations(translations),
      );
      final provider = _Apps();
      final model = _app('1.0.0', '1.0.0', trackOnly: false);
      provider.apps[model.id] = AppInMemory(model, null, null, icon);
      addTearDown(provider.dispose);
      addTearDown(settings.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 1600);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppsProvider>.value(value: provider),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          child: MaterialApp(home: AppPage(appId: model.id)),
        ),
      );
      await tester.pumpAndSettle();

      final Finder fdroidIcon = find.byWidgetPredicate(
        (Widget widget) =>
            widget is StoreSourceIconImage &&
            widget.assetPath == StoreSourceIconPaths.fdroid,
      );
      expect(fdroidIcon, findsOneWidget);
      await tester.longPress(fdroidIcon);
      await tester.pumpAndSettle();
      expect(find.text(tr('swapToThisSource')), findsOneWidget);
      expect(find.text(tr('trackHereToo')), findsOneWidget);
      expect(find.text(tr('copyLink')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('an unconfirmed store shows no chip', (tester) async {
    // Nothing has scanned this package, so F-Droid and APKMirror are not
    // listed on a guess - the tracked source is the only chip.
    final settings = SettingsProvider()..prefs = preferences;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    final provider = _Apps();
    final model = _app('1.0.0', '1.0.0', trackOnly: false);
    provider.apps[model.id] = AppInMemory(model, null, null, icon);
    addTearDown(provider.dispose);
    addTearDown(settings.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(home: AppPage(appId: model.id)),
      ),
    );
    await tester.pumpAndSettle();

    for (final String assetPath in [
      StoreSourceIconPaths.fdroid,
      StoreSourceIconPaths.apkmirror,
    ]) {
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is StoreSourceIconImage && widget.assetPath == assetPath,
        ),
        findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('alternate store already tracked offers its listing instead', (
    tester,
  ) async {
    final settings = SettingsProvider()..prefs = preferences;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    final provider = _Apps();
    final model = _app('1.0.0', '1.0.0', trackOnly: false);
    provider.apps[model.listingKey] = AppInMemory(model, null, null, icon);
    // The same package already tracked from F-Droid, so swapping this GitHub
    // listing onto F-Droid would leave it tracked twice from one store.
    final App fdroidListing = model.copyWith(
      listingId: appListingKey(model.id, 'FDroid'),
      url: 'https://f-droid.org/packages/${model.id}/',
    );
    provider.apps[fdroidListing.listingKey] = AppInMemory(
      fdroidListing,
      null,
      null,
      icon,
    );
    addTearDown(provider.dispose);
    addTearDown(settings.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(home: AppPage(appId: model.listingKey)),
      ),
    );
    await tester.pumpAndSettle();

    final Finder fdroidIcon = find.byWidgetPredicate(
      (Widget widget) =>
          widget is StoreSourceIconImage &&
          widget.assetPath == StoreSourceIconPaths.fdroid,
    );
    expect(fdroidIcon, findsOneWidget);
    await tester.longPress(fdroidIcon);
    await tester.pumpAndSettle();
    expect(find.text(tr('swapToThisSource')), findsNothing);
    expect(find.text(tr('trackHereToo')), findsNothing);
    expect(find.text(tr('showTrackedItem')), findsOneWidget);
    expect(find.text(tr('copyLink')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a sibling listing surfaces its store as an alternate source', (
    tester,
  ) async {
    final settings = SettingsProvider()..prefs = preferences;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    final provider = _Apps();
    // GitHub repo URLs cannot be derived from a package ID, so a store scan
    // never finds one. The sibling listing is the only thing that knows it.
    final App githubListing = _app('1.0.0', '1.0.0', trackOnly: false);
    provider.apps[githubListing.listingKey] = AppInMemory(
      githubListing,
      null,
      null,
      icon,
    );
    final App fdroidListing = githubListing.copyWith(
      listingId: appListingKey(githubListing.id, 'FDroid'),
      url: 'https://f-droid.org/packages/${githubListing.id}/',
    );
    provider.apps[fdroidListing.listingKey] = AppInMemory(
      fdroidListing,
      null,
      null,
      icon,
    );
    addTearDown(provider.dispose);
    addTearDown(settings.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(home: AppPage(appId: fdroidListing.listingKey)),
      ),
    );
    await tester.pumpAndSettle();

    final Finder githubIcon = find.byWidgetPredicate(
      (Widget widget) =>
          widget is StoreSourceIconImage &&
          widget.assetPath == StoreSourceIconPaths.github,
    );
    expect(githubIcon, findsOneWidget);
    await tester.longPress(githubIcon);
    await tester.pumpAndSettle();
    expect(find.text(tr('swapToThisSource')), findsNothing);
    expect(find.text(tr('showTrackedItem')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('Play Store is not a swappable tracked source', () {
    expect(swappableAlternateStoreNames.contains('PlayStore'), isFalse);
  });

  test('GitHub is a swappable alternate source', () {
    expect(swappableAlternateStoreNames.contains('GitHub'), isTrue);
  });
}
