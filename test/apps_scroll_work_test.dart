import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
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
    settings.rightSwipeAction = SwipeAction.pin;
    settings.leftSwipeAction = SwipeAction.pin;
    provider = _Apps();
    final icon = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
    for (int appIndex = 0; appIndex < 20; appIndex++) {
      final app = App(
        id: 'org.example.app$appIndex',
        url: 'https://github.com/example/app$appIndex',
        name: 'App ${appIndex.toString().padLeft(2, '0')}',
        author: 'Example',
        installedVersion: '1.0',
        latestVersion: '1.0',
        preferredApkIndex: 0,
        additionalSettings: {},
      );
      provider.apps[app.id] = AppInMemory(app, null, null, icon);
    }
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

  testWidgets('idle list does not lay out hidden swipe action panels', (
    tester,
  ) async {
    await openApps(tester);
    final rows = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_SwipeableListItem',
    );
    expect(rows, findsWidgets);
    expect(find.descendant(of: rows, matching: find.text('')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('repeated cancelled swipes settle and preserve row state', (
    tester,
  ) async {
    await openApps(tester);
    final row = find.ancestor(
      of: find.text('App 00'),
      matching: find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_SwipeableListItem',
      ),
    );
    final initialState = tester.state(row);
    final initialPosition = tester.getTopLeft(find.text('App 00'));
    for (int swipeIndex = 0; swipeIndex < 12; swipeIndex++) {
      final gesture = await tester.startGesture(tester.getCenter(row));
      await gesture.moveBy(Offset(swipeIndex.isEven ? 25 : -25, 0));
      await tester.pump();
      await gesture.moveBy(Offset(swipeIndex.isEven ? 40 : -40, 0));
      await tester.pump();
      expect(find.text(tr('pin')), findsOneWidget);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('App 00')), initialPosition);
      expect(tester.state(row), same(initialState));
      expect(tester.takeException(), isNull);
    }
    await tester.longPress(find.text('App 00'));
    await tester.pumpAndSettle();
    expect(
      tester.state<AppsPageState>(find.byType(AppsPage)).isSelectionActive,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final reduceEffects in [false, true]) {
    testWidgets(
      'row appearance is preserved with reduced effects $reduceEffects',
      (tester) async {
        settings.reduceVisualEffects = reduceEffects;
        await openApps(tester);
        final row = find.ancestor(
          of: find.text('App 00'),
          matching: find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_SwipeableListItem',
          ),
        );
        await expectLater(
          row,
          matchesGoldenFile('goldens/app-row-$reduceEffects.png'),
        );
        await tester.longPress(find.text('App 00'));
        await tester.pumpAndSettle();
        await expectLater(
          row,
          matchesGoldenFile('goldens/app-row-selected-$reduceEffects.png'),
        );
        final gesture = await tester.startGesture(tester.getCenter(row));
        await gesture.moveBy(const Offset(25, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
        await expectLater(
          row,
          matchesGoldenFile('goldens/app-row-swiping-$reduceEffects.png'),
        );
        await gesture.cancel();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
