import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestAppsProvider extends ChangeNotifier implements AppsProvider {
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

  const MethodChannel legacyUrlLauncherChannel = MethodChannel(
    'plugins.flutter.io/url_launcher',
  );
  const List<String> pigeonLaunchChannels = <String>[
    'dev.flutter.pigeon.url_launcher_windows.UrlLauncherApi.launchUrl',
    'dev.flutter.pigeon.url_launcher_linux.UrlLauncherApi.launchUrl',
    'dev.flutter.pigeon.url_launcher_macos.UrlLauncherApi.launchUrl',
    'dev.flutter.pigeon.url_launcher_android.UrlLauncherApi.launchUrl',
  ];

  late SettingsProvider settings;
  late _TestAppsProvider provider;
  late Uint8List iconBytes;
  late List<String> launchedUrls;

  void installUrlLauncherMocks() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(legacyUrlLauncherChannel, (
      MethodCall call,
    ) async {
      if (call.method == 'launch' || call.method == 'launchUrl') {
        final Object? arguments = call.arguments;
        if (arguments is Map) {
          expect(arguments['useWebView'], isNot(true));
          expect(arguments['useSafariVC'], isNot(true));
          final Object? urlValue = arguments['url'];
          if (urlValue is String) {
            launchedUrls.add(urlValue);
          }
        } else if (arguments is String) {
          launchedUrls.add(arguments);
        }
        return true;
      }
      if (call.method == 'canLaunch' || call.method == 'canLaunchUrl') {
        return true;
      }
      return null;
    });
    for (final String channelName in pigeonLaunchChannels) {
      messenger.setMockMessageHandler(channelName, (ByteData? message) async {
        final Object? decoded = const StandardMessageCodec().decodeMessage(
          message,
        );
        if (decoded is List && decoded.isNotEmpty) {
          final Object? urlValue = decoded.first;
          if (urlValue is String) {
            launchedUrls.add(urlValue);
          }
        }
        return const StandardMessageCodec().encodeMessage(<Object?>[true]);
      });
    }
  }

  void clearUrlLauncherMocks() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(legacyUrlLauncherChannel, null);
    for (final String channelName in pigeonLaunchChannels) {
      messenger.setMockMessageHandler(channelName, null);
    }
  }

  setUp(() async {
    launchedUrls = <String>[];
    installUrlLauncherMocks();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'checkOnStart': false,
      'progressiveBlurEnabled': false,
      'useGradientBackground': false,
      'reduceVisualEffects': true,
    });
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _TestAppsProvider();
    iconBytes = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
  });

  tearDown(() {
    clearUrlLauncherMocks();
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

  test('persists SwipeAction.openAppSource and preserves legacy int prefs', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SettingsProvider writer = SettingsProvider()..prefs = prefs;
    addTearDown(writer.dispose);

    writer.rightSwipeAction = SwipeAction.openAppSource;
    writer.leftSwipeAction = SwipeAction.openAppSource;

    expect(
      prefs.getInt('rightSwipeAction'),
      SwipeAction.openAppSource.index,
    );
    expect(prefs.getString('rightSwipeActionName'), 'openAppSource');
    expect(
      prefs.getInt('leftSwipeAction'),
      SwipeAction.openAppSource.index,
    );
    expect(prefs.getString('leftSwipeActionName'), 'openAppSource');

    final SettingsProvider restored = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    addTearDown(restored.dispose);
    expect(restored.rightSwipeAction, SwipeAction.openAppSource);
    expect(restored.leftSwipeAction, SwipeAction.openAppSource);

    for (int legacyIndex = 0; legacyIndex <= 7; legacyIndex++) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'rightSwipeAction': legacyIndex,
        'leftSwipeAction': legacyIndex,
      });
      final SettingsProvider legacyReader = SettingsProvider()
        ..prefs = await SharedPreferences.getInstance();
      addTearDown(legacyReader.dispose);
      expect(legacyReader.rightSwipeAction, SwipeAction.values[legacyIndex]);
      expect(legacyReader.leftSwipeAction, SwipeAction.values[legacyIndex]);
    }
  });

  test('swipeActionsSortedByLocalizedLabel places Open App Source alphabetically and keeps None last', () {
    final List<SwipeAction> sorted = swipeActionsSortedByLocalizedLabel();

    expect(tr('swipeAction_${SwipeAction.openAppSource.name}'), 'Open App Source');
    expect(sorted, contains(SwipeAction.openAppSource));
    expect(sorted.last, SwipeAction.none);
    expect(
      sorted.indexOf(SwipeAction.openAppSource),
      sorted.indexOf(SwipeAction.open) + 1,
    );

    final List<SwipeAction> withoutNone = sorted
        .where((SwipeAction action) => action != SwipeAction.none)
        .toList();
    for (int itemIndex = 1; itemIndex < withoutNone.length; itemIndex++) {
      final String previousLabel = tr(
        'swipeAction_${withoutNone[itemIndex - 1].name}',
      ).toLowerCase();
      final String currentLabel = tr(
        'swipeAction_${withoutNone[itemIndex].name}',
      ).toLowerCase();
      expect(previousLabel.compareTo(currentLabel) <= 0, isTrue);
    }
  });

  testWidgets('swiping openAppSource opens app.url for installed, uninstalled, and track-only apps', (
    WidgetTester tester,
  ) async {
    settings.rightSwipeAction = SwipeAction.openAppSource;
    settings.leftSwipeAction = SwipeAction.openAppSource;

    const String installedUrl = 'https://github.com/example/installed-app';
    const String notInstalledUrl = 'https://codeberg.org/example/uninstalled-app';
    const String trackOnlyUrl = 'https://github.com/example/track-only-app';

    provider.apps['org.example.installed'] = AppInMemory(
      const App(
        id: 'org.example.installed',
        url: installedUrl,
        name: 'Installed App',
        author: 'Example',
        installedVersion: '1.0.0',
        latestVersion: '1.0.0',
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{},
      ),
      null,
      null,
      iconBytes,
    );
    provider.apps['org.example.notinstalled'] = AppInMemory(
      const App(
        id: 'org.example.notinstalled',
        url: notInstalledUrl,
        name: 'Uninstalled App',
        author: 'Example',
        installedVersion: null,
        latestVersion: '2.0.0',
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{},
      ),
      null,
      null,
      iconBytes,
    );
    provider.apps['org.example.trackonly'] = AppInMemory(
      const App(
        id: 'org.example.trackonly',
        url: trackOnlyUrl,
        name: 'Track Only App',
        author: 'Example',
        installedVersion: '1.2.0',
        latestVersion: '1.3.0',
        changeLog: 'https://github.com/example/track-only-app/releases/tag/v1.3.0',
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{'trackOnly': true},
      ),
      null,
      null,
      iconBytes,
    );

    await openApps(tester);

    final Finder installedRow = find.ancestor(
      of: find.text('Installed App'),
      matching: find.byWidgetPredicate(
        (Widget widget) => widget.runtimeType.toString() == '_SwipeableListItem',
      ),
    );
    final TestGesture rightSwipe = await tester.startGesture(
      tester.getCenter(installedRow),
    );
    await rightSwipe.moveBy(const Offset(25, 0));
    await tester.pump();
    await rightSwipe.moveBy(const Offset(95, 0));
    await tester.pump();
    expect(find.text(tr('source')), findsOneWidget);
    expect(find.text('Open App Source'), findsNothing);
    await rightSwipe.up();
    await tester.pumpAndSettle();

    final Finder notInstalledRow = find.ancestor(
      of: find.text('Uninstalled App'),
      matching: find.byWidgetPredicate(
        (Widget widget) => widget.runtimeType.toString() == '_SwipeableListItem',
      ),
    );
    final TestGesture leftSwipe = await tester.startGesture(
      tester.getCenter(notInstalledRow),
    );
    await leftSwipe.moveBy(const Offset(-25, 0));
    await tester.pump();
    await leftSwipe.moveBy(const Offset(-95, 0));
    await tester.pump();
    expect(find.text(tr('source')), findsOneWidget);
    expect(find.text('Open App Source'), findsNothing);
    await leftSwipe.up();
    await tester.pumpAndSettle();

    final Finder trackOnlyRow = find.ancestor(
      of: find.text('Track Only App'),
      matching: find.byWidgetPredicate(
        (Widget widget) => widget.runtimeType.toString() == '_SwipeableListItem',
      ),
    );
    final TestGesture trackOnlySwipe = await tester.startGesture(
      tester.getCenter(trackOnlyRow),
    );
    await trackOnlySwipe.moveBy(const Offset(25, 0));
    await tester.pump();
    await trackOnlySwipe.moveBy(const Offset(95, 0));
    await tester.pump();
    await trackOnlySwipe.up();
    await tester.pumpAndSettle();

    expect(
      launchedUrls,
      <String>[installedUrl, notInstalledUrl, trackOnlyUrl],
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TalkBack offers openAppSource for installed and uninstalled apps when configured', (
    WidgetTester tester,
  ) async {
    settings.rightSwipeAction = SwipeAction.openAppSource;
    settings.leftSwipeAction = SwipeAction.open;

    provider.apps['org.example.uninstalled'] = AppInMemory(
      const App(
        id: 'org.example.uninstalled',
        url: 'https://gitlab.com/example/uninstalled',
        name: 'Uninstalled App',
        author: 'Example',
        installedVersion: null,
        latestVersion: '1.0.0',
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{},
      ),
      null,
      null,
      iconBytes,
    );
    provider.apps['org.example.installed'] = AppInMemory(
      const App(
        id: 'org.example.installed',
        url: 'https://github.com/example/installed',
        name: 'Installed App',
        author: 'Example',
        installedVersion: '1.0.0',
        latestVersion: '1.0.0',
        preferredApkIndex: 0,
        additionalSettings: <String, dynamic>{},
      ),
      null,
      null,
      iconBytes,
    );

    final SemanticsHandle semantics = tester.ensureSemantics();
    await openApps(tester);

    final int openSourceActionId = CustomSemanticsAction.getIdentifier(
      CustomSemanticsAction(label: tr('swipeAction_openAppSource')),
    );
    final int openAppActionId = CustomSemanticsAction.getIdentifier(
      CustomSemanticsAction(label: tr('swipeAction_open')),
    );

    final SemanticsNode uninstalledNode = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^Uninstalled App\b')),
    );
    final List<int> uninstalledActions =
        uninstalledNode.getSemanticsData().customSemanticsActionIds ??
        const <int>[];
    expect(uninstalledActions, contains(openSourceActionId));
    expect(uninstalledActions, isNot(contains(openAppActionId)));

    final SemanticsNode installedNode = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^Installed App\b')),
    );
    final List<int> installedActions =
        installedNode.getSemanticsData().customSemanticsActionIds ??
        const <int>[];
    expect(installedActions, contains(openSourceActionId));
    expect(installedActions, contains(openAppActionId));

    settings.rightSwipeAction = SwipeAction.none;
    settings.leftSwipeAction = SwipeAction.none;
    await tester.pumpAndSettle();

    final SemanticsNode uninstalledAfterNone = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^Uninstalled App\b')),
    );
    expect(
      uninstalledAfterNone.getSemanticsData().customSemanticsActionIds ??
          const <int>[],
      isNot(contains(openSourceActionId)),
    );
    final SemanticsNode installedAfterNone = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^Installed App\b')),
    );
    expect(
      installedAfterNone.getSemanticsData().customSemanticsActionIds ??
          const <int>[],
      isNot(contains(openSourceActionId)),
    );

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
