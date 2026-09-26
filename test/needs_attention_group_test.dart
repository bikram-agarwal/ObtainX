import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  @override
  bool get loadingApps => false;
  @override
  bool get isForeground => false;
  @override
  int get appsListRevision => 0;
  @override
  int get pendingUpdateCount => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
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
    SharedPreferences.setMockInitialValues({
      'checkOnStart': false,
      'progressiveBlurEnabled': false,
      'useGradientBackground': false,
      'reduceVisualEffects': true,
    });
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _Apps();
    final icon = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
    provider.apps['moved'] = AppInMemory(
      const App(
        id: 'org.example.moved',
        url: 'https://github.com/example/moved',
        name: 'Moved',
        author: 'Example',
        installedVersion: '1.0',
        latestVersion: '1.0',
        preferredApkIndex: 0,
        additionalSettings: {},
        categories: ['Tools'],
        pendingRepoRenameUrl: 'https://github.com/example/moved-new',
      ),
      null,
      null,
      icon,
    );
    provider.apps['steady'] = AppInMemory(
      const App(
        id: 'org.example.steady',
        url: 'https://github.com/example/steady',
        name: 'Steady',
        author: 'Example',
        installedVersion: '1.0',
        latestVersion: '1.0',
        preferredApkIndex: 0,
        additionalSettings: {},
        categories: ['Media'],
      ),
      null,
      null,
      icon,
    );
    const App blockedBase = App(
      id: 'org.example.blocked',
      url: 'https://github.com/example/blocked',
      name: 'Blocked',
      author: 'Example',
      installedVersion: '1.0',
      latestVersion: '1.0',
      preferredApkIndex: 0,
      additionalSettings: {'apkFilterRegEx': r'-arm64\.apk$'},
      categories: ['Tools'],
    );
    final Map<String, dynamic> blockedSettings = Map<String, dynamic>.from(
      blockedBase.additionalSettings,
    );
    setNeedsAttention(
      blockedSettings,
      needsAttentionVersionFilter,
      detail: releaseFilterFingerprint(blockedBase),
    );
    provider.apps['blocked'] = AppInMemory(
      blockedBase.copyWith(additionalSettings: blockedSettings),
      null,
      null,
      icon,
    );
  });

  tearDown(() {
    provider.dispose();
    settings.dispose();
  });

  Future<void> openApps(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const AppsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('pending repo moves stay in Needs attention above categories', (
    tester,
  ) async {
    settings.appsListGroupBy = AppsListGroupBy.category;
    await openApps(tester);

    final groupHeaders = tester
        .widgetList<M3eCollapsibleGroupHeader>(
          find.byType(M3eCollapsibleGroupHeader),
        )
        .toList();
    expect(groupHeaders.first.title, tr('needsAttention'));
    expect(groupHeaders.first.count, 2);
    expect(
      groupHeaders.map((header) => header.title),
      isNot(contains('Tools')),
    );
    expect(find.text('Media'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('needsAttentionListDivider')),
      findsNothing,
    );
    expect(find.text('Moved'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Steady'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Moved')).dy,
      lessThan(tester.getTopLeft(find.text('Steady')).dy),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pending repo moves stay grouped when Group by is None', (
    tester,
  ) async {
    settings.appsListGroupBy = AppsListGroupBy.none;
    await openApps(tester);

    final groupHeaders = tester
        .widgetList<M3eCollapsibleGroupHeader>(
          find.byType(M3eCollapsibleGroupHeader),
        )
        .toList();
    expect(groupHeaders, hasLength(1));
    expect(groupHeaders.single.title, tr('needsAttention'));
    expect(groupHeaders.single.count, 2);
    expect(find.text('Moved'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Steady'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Needs attention')).dy,
      lessThan(tester.getTopLeft(find.text('Moved')).dy),
    );
    final divider = find.byKey(const ValueKey('needsAttentionListDivider'));
    expect(divider, findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Moved')).dy,
      lessThan(tester.getTopLeft(divider).dy),
    );
    expect(
      tester.getTopLeft(divider).dy,
      lessThan(tester.getTopLeft(find.text('Steady')).dy),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('a stored filter miss explains itself', () {
    final App blocked = provider.apps['org.example.blocked']!.app;
    final notice = needsAttentionPageNotice(blocked);
    expect(notice?.title, tr('needsAttention'));
    expect(notice?.message, tr('needsAttentionVersionFilter'));
    expect(
      needsAttentionPageNotice(
        blocked.copyWith(
          additionalSettings: {
            ...blocked.additionalSettings,
            'apkFilterRegEx': r'-other\.apk$',
          },
        ),
      ),
      isNull,
    );
  });
}
