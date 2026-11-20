// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/update_health.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/utils/update_health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The fork's Update health page (v1.7.4 sync D8) and the options page it
// opens at the Update-health card (DET-2 scrollToSection).

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  @override
  int appsListRevision = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

App _app(
  String name, {
  int failedChecks = 6,
  bool healthEnabled = true,
  String? dismissedVersion,
  String? listingId,
}) => App(
  id: 'org.example.${name.toLowerCase()}',
  listingId: listingId,
  url: 'https://github.com/example/${name.toLowerCase()}',
  author: 'Example',
  name: name,
  installedVersion: '1.0',
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: const {},
  consecutiveFailedChecks: failedChecks,
  updateHealthEnabled: healthEnabled,
  updateHealthDismissedVersion: dismissedVersion,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsProvider settings;
  late _Apps provider;
  late Uint8List icon;

  setUpAll(() async {
    final translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    icon = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'useGradientBackground': false,
      'matchAppPageToIconColors': false,
    });
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _Apps();
  });

  tearDown(() {
    provider.dispose();
    settings.dispose();
  });

  void add(App app) {
    provider.apps[app.listingKey] = AppInMemory(app, null, null, icon);
  }

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(theme: ThemeData(useMaterial3: true), home: page),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('lists flagged apps with their reasons, and ignored apps', (
    tester,
  ) async {
    add(_app('Flagged'));
    // The same package from a second store: its own listing, its own row.
    add(_app('Flagged', listingId: 'org.example.flagged#2'));
    add(_app('Healthy', failedChecks: 0));
    add(_app('Paused', dismissedVersion: '1.0'));
    add(_app('Muted', healthEnabled: false));
    await pump(tester, const UpdateHealthPage());

    expect(find.text(tr('updateHealthDetectedApps')), findsOneWidget);
    expect(find.text(tr('updateHealthIgnoredApps')), findsOneWidget);
    expect(find.text('Flagged'), findsNWidgets(2));
    expect(find.text('Healthy'), findsNothing);
    expect(
      find.text(plural('updateHealthReasonFailedChecks', 6)),
      findsNWidgets(2),
    );
    expect(find.text(tr('updateHealthIgnoredForVersion')), findsOneWidget);
    expect(find.text(tr('updateHealthIgnoredPermanently')), findsOneWidget);
    expect(find.byTooltip(tr('restore')), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('says so when there is nothing to show', (tester) async {
    add(_app('Healthy', failedChecks: 0));
    await pump(tester, const UpdateHealthPage());

    expect(find.text(tr('updateHealthNoApps')), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('the actions change only update health, from the live listing', () {
    // A check finished after the page was built: the live listing has a new
    // release and a new installed version.
    final App live = _app(
      'Flagged',
    ).copyWith(latestVersion: '2.0', installedVersion: '1.5');

    final App forVersion = ignoreUpdateHealthForCurrentVersion(live);
    expect(forVersion.updateHealthDismissedVersion, '2.0');
    expect(forVersion.updateHealthEnabled, isTrue);
    expect(forVersion.installedVersion, '1.5');
    expect(isUpdateHealthIgnored(forVersion), isTrue);
    // A newer release brings the check back.
    expect(
      isUpdateHealthIgnored(forVersion.copyWith(latestVersion: '2.1')),
      isFalse,
    );

    final App permanently = ignoreUpdateHealthPermanently(forVersion);
    expect(permanently.updateHealthEnabled, isFalse);
    expect(permanently.updateHealthDismissedVersion, isNull);
    expect(isUpdateHealthIgnored(permanently), isTrue);

    final App restored = restoreUpdateHealth(permanently);
    expect(restored.updateHealthEnabled, isTrue);
    expect(restored.updateHealthDismissedVersion, isNull);
    expect(isUpdateHealthIgnored(restored), isFalse);
    expect(restored.installedVersion, '1.5');
  });

  testWidgets('the options page opens at the Update-health card', (
    tester,
  ) async {
    final App app = _app('Flagged');
    add(app);
    final String header = tr('sectionUpdateHealthDetection').toUpperCase();

    await pump(tester, AdditionalOptionsPage(appId: app.listingKey));
    final double topWithout = tester.getTopLeft(find.text(header)).dy;
    // Far down the form: its last card.
    expect(topWithout, greaterThan(1000));

    await tester.pumpWidget(const SizedBox.shrink());
    await pump(
      tester,
      AdditionalOptionsPage(
        appId: app.listingKey,
        scrollToSection: updateHealthSectionKey,
      ),
    );
    final double topWith = tester.getTopLeft(find.text(header)).dy;
    expect(topWith, greaterThan(kToolbarHeight));
    expect(topWith, lessThan(1000 / 2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
