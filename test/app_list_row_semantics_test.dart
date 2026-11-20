import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The apps list row (apps.dart _AppListItem), in the apps_scroll_work_test
// harness:
// - LIST-4 (upstream #3398, b7e32b00): the version/changelog column is its own
//   TalkBack button, apart from the row;
// - LIST-11 (v1.7.4 D8): the update-health marker after a flagged app's name,
//   following "Show update health indicator".

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  @override
  bool get loadingApps => false;
  @override
  bool get isForeground => false;
  @override
  int appsListRevision = 0;
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
    final icon = (await rootBundle.load('assets/graphics/logo_remember.png'))
        .buffer
        .asUint8List();
    for (int appIndex = 0; appIndex < 3; appIndex++) {
      final app = App(
        id: 'org.example.app$appIndex',
        url: 'https://github.com/example/app$appIndex',
        name: 'App $appIndex',
        author: 'Example',
        installedVersion: '1.0',
        latestVersion: '1.0',
        preferredApkIndex: 0,
        additionalSettings: {},
        // App 1 has failed its last checks past the default threshold (5).
        consecutiveFailedChecks: appIndex == 1 ? 6 : 0,
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

  testWidgets('the version column is a TalkBack button of its own', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await openApps(tester);

    final String versionLabel = '1.0 ${tr('changes')}';
    final Finder versionNode = find.bySemanticsLabel(versionLabel);
    expect(versionNode, findsNWidgets(3));
    final SemanticsNode node = tester.getSemantics(versionNode.first);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(node.flagsCollection.isButton, isTrue);

    // The row reads the app, without the version merged into it.
    final SemanticsNode row = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^App 0\b')),
    );
    expect(row.label, isNot(contains(tr('changes'))));
    expect(row.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a flagged app shows the update-health marker', (tester) async {
    await openApps(tester);

    final Finder marker = find.byIcon(Icons.warning_amber_rounded);
    final Finder flaggedRow = find.ancestor(
      of: find.text('App 1'),
      matching: find.byType(ListTile),
    );
    expect(find.descendant(of: flaggedRow, matching: marker), findsOneWidget);
    final Tooltip tooltip = tester.widget<Tooltip>(
      find.ancestor(of: marker.first, matching: find.byType(Tooltip)).first,
    );
    expect(tooltip.message, plural('updateHealthReasonFailedChecks', 6));
    for (final String name in ['App 0', 'App 2']) {
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text(name),
            matching: find.byType(ListTile),
          ),
          matching: marker,
        ),
        findsNothing,
        reason: name,
      );
    }

    // "Show update health indicator" off hides it at once (rebuild token).
    settings.showUpdateHealthIndicator = false;
    await tester.pumpAndSettle();
    expect(find.descendant(of: flaggedRow, matching: marker), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
