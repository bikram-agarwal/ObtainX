import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/add_app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Add App by URL (v1.7.4 sync):
// - DET-14 (upstream #3377/#3346): what the options form shows on its own is
//   what an untouched add saves, and a kept On-demand choice survives a
//   source change;
// - D10 (upstream #3345): "Add anyway" after an unexpected failure, opt-in.

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  final List<App> added = [];

  @override
  Future<App> addNewListing(App app) async {
    added.add(app);
    apps[app.listingKey] = AppInMemory(app, null, null, null);
    return app;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _Notifications extends Fake implements NotificationsProvider {}

/// The real provider, except every check fails the way [error] says.
/// (SourceProvider is a singleton, so this wraps it.)
class _FailingSourceProvider implements SourceProvider {
  _FailingSourceProvider(this.error);

  final Object error;
  final SourceProvider _real = SourceProvider();
  int checks = 0;

  @override
  List<AppSource> get sourceTemplates => _real.sourceTemplates;

  @override
  List<AppSource> get sources => _real.sources;

  @override
  AppSource getSource(String url, {String? overrideSource}) =>
      _real.getSource(url, overrideSource: overrideSource);

  @override
  bool ifRequiredAppSpecificSettingsExist(AppSource source) =>
      _real.ifRequiredAppSpecificSettingsExist(source);

  @override
  App buildPlaceholderApp(
    AppSource source,
    String url,
    Map<String, dynamic> additionalSettings, {
    bool trackOnlyOverride = false,
    bool sourceIsOverriden = false,
  }) => _real.buildPlaceholderApp(
    source,
    url,
    additionalSettings,
    trackOnlyOverride: trackOnlyOverride,
    sourceIsOverriden: sourceIsOverriden,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<App> getApp(
    AppSource source,
    String url,
    Map<String, dynamic> additionalSettings, {
    App? currentApp,
    bool trackOnlyOverride = false,
    bool sourceIsOverriden = false,
    bool inferAppIdIfOptional = false,
  }) async {
    checks++;
    throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsProvider settings;
  late _Apps provider;

  setUpAll(() async {
    final translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'useGradientBackground': false});
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _Apps();
  });

  tearDown(() {
    provider.dispose();
    settings.dispose();
  });

  Future<AddAppPageState> openAddApp(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1600);
    addTearDown(tester.view.reset);
    // The category picker reads translations from the context.
    await tester.runAsync(EasyLocalization.ensureInitialized);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          Provider<NotificationsProvider>.value(value: _Notifications()),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          useOnlyLangCode: true,
          child: Builder(
            builder: (BuildContext context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: buildObtainiumTheme(const ColorScheme.light(), null),
              home: const AddAppPage(),
            ),
          ),
        ),
      ),
    );
    // EasyLocalization loads its asset outside the fake clock.
    for (int frame = 0; frame < 5; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    return tester.state<AddAppPageState>(find.byType(AddAppPage));
  }

  Future<void> enterUrl(
    WidgetTester tester,
    AddAppPageState page,
    String url,
  ) async {
    page.linkFn(url);
    await tester.pumpAndSettle();
  }

  testWidgets('an untouched add keeps the global pre-release default', (
    tester,
  ) async {
    settings.includePrereleasesByDefault = true;
    final AddAppPageState page = await openAddApp(tester);
    await enterUrl(tester, page, 'https://github.com/example/app');

    expect(page.additionalSettings['includePrereleases'], isTrue);
    // Never stored: it's an add-time choice.
    expect(
      page.additionalSettings.containsKey('inferAppIdIfOptional'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('On-demand stays on, and shown, across a source change', (
    tester,
  ) async {
    final AddAppPageState page = await openAddApp(tester);
    await enterUrl(tester, page, 'https://github.com/example/app');
    final Finder onDemandSwitch = find.descendant(
      of: find
          .ancestor(
            of: find.text(tr('onDemandOnly')),
            matching: find.byType(Row),
          )
          .first,
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(onDemandSwitch);
    await tester.tap(onDemandSwitch);
    await tester.pumpAndSettle();
    expect(page.additionalSettings['onDemandOnly'], isTrue);

    await enterUrl(tester, page, 'https://gitlab.com/example/app');
    expect(page.additionalSettings['onDemandOnly'], isTrue);
    expect(tester.widget<Switch>(onDemandSwitch).value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Not pumpAndSettle: the save button spins while the dialog is open.
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text(tr('save')));
    for (int frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('an unexpected failure offers Add anyway, when allowed', (
    tester,
  ) async {
    settings.allowAddingAppsWithoutCheck = true;
    final AddAppPageState page = await openAddApp(tester);
    page.sourceProvider = _FailingSourceProvider(
      const SocketException('offline'),
    );
    await enterUrl(tester, page, 'https://github.com/example/app');
    await save(tester);

    expect(find.text(tr('addWithoutCheckQuestion')), findsOneWidget);
    await tester.tap(find.text(tr('addAnyway')));
    for (int frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final App app = provider.added.single;
    expect(hasOnlyPlaceholderApks(app), isTrue);
    expect(app.url, 'https://github.com/example/app');
    expect(isTempId(app), isTrue);
    // Nothing was checked, so nothing is marked installed.
    expect(app.installedVersion, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (String label, Object error, bool allowed) in [
    ('setting off', const SocketException('offline'), false),
    ('source answered', ObtainiumError('No releases'), true),
    ('too new', MinUpdateAgeError(DateTime(2026, 11, 19), 3), true),
  ]) {
    testWidgets('no Add anyway: $label', (tester) async {
      settings.allowAddingAppsWithoutCheck = allowed;
      final AddAppPageState page = await openAddApp(tester);
      final _FailingSourceProvider failing = _FailingSourceProvider(error);
      page.sourceProvider = failing;
      await enterUrl(tester, page, 'https://github.com/example/app');
      await save(tester);

      expect(failing.checks, 1);
      expect(find.text(tr('addWithoutCheckQuestion')), findsNothing);
      expect(provider.added, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
