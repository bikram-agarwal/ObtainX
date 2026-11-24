// v1.7.5 sync U1: ObtainX's take on upstream #698's refresh button. A tap on
// the apps page title checks the visible apps exactly as pull-to-refresh does
// (which stays); there is no setting, and TV keeps its app-bar Refresh.
// (Upstream's own refresh_button_test covered an opt-in app-bar button that
// replaced the pull; ObtainX doesn't port that.)

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the keys read in the synchronous turn in which a check starts.
/// `_checkUpdatesInSession` sets `refreshProgress` to 0 and then resolves the
/// IDs it was asked to check before its first await, so that record is
/// exactly the IDs refresh() passed, with nothing from list rebuilds.
class _RecordingListings extends AppListings {
  Set<String>? _recording;
  final List<Set<String>> checkedIds = [];

  void recordThisTurn() {
    final Set<String> ids = _recording = <String>{};
    checkedIds.add(ids);
    scheduleMicrotask(() => _recording = null);
  }

  @override
  AppInMemory? operator [](Object? key) {
    if (key is String) _recording?.add(key);
    return super[key];
  }
}

class _Apps extends ChangeNotifier implements AppsProvider {
  _Apps(this.settingsProvider);

  @override
  final SettingsProvider settingsProvider;
  @override
  final _RecordingListings apps = _RecordingListings();
  @override
  bool get loadingApps => false;
  @override
  bool get isForeground => false;
  @override
  int appsListRevision = 0;
  @override
  int get pendingUpdateCount => 0;
  @override
  Completer<List<App>>? updateCheckCompleter;
  @override
  CancellationToken? updateCheckCancellation;
  @override
  final ValueNotifier<double?> refreshProgressNotifier = ValueNotifier(null);
  @override
  double? get refreshProgress => refreshProgressNotifier.value;
  @override
  set refreshProgress(double? value) {
    if (value == 0.0 && refreshProgressNotifier.value == null) {
      apps.recordThisTurn();
    }
    refreshProgressNotifier.value = value;
  }

  @override
  void finishPendingAutoExport() {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

const MethodChannel _deviceInfoChannel = MethodChannel(
  'dev.fluttercommunity.plus/device_info',
);

class _Notifications extends Fake implements NotificationsProvider {
  @override
  Future<void> cancel(int id) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsProvider settings;
  late _Apps provider;
  late List<String> nativeCalls;
  late List<String> haptics;

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

  App app(String id, {bool onDemandOnly = false}) {
    return App(
      id: id,
      url: 'https://github.com/example/$id',
      name: id,
      author: 'Example',
      installedVersion: '1.0',
      latestVersion: '1.0',
      preferredApkIndex: 0,
      additionalSettings: {'onDemandOnly': onDemandOnly},
      // A paused listing: the check skips it before any request, so nothing
      // here reaches the network.
      pendingRepoRenameUrl: 'https://github.com/example/$id-renamed',
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'checkOnStart': false,
      'progressiveBlurEnabled': false,
      'useGradientBackground': false,
      'reduceVisualEffects': true,
    });
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _Apps(settings);
    final icon = (await rootBundle.load('assets/graphics/logo_remember.png'))
        .buffer
        .asUint8List();
    for (final App listed in [
      app('org.example.one'),
      app('org.example.two'),
      app('org.example.later', onDemandOnly: true),
    ]) {
      provider.apps[listed.listingKey] = AppInMemory(listed, null, null, icon);
    }
    nativeCalls = [];
    haptics = [];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.imranr.obtainium/notifications'),
      (MethodCall call) async {
        nativeCalls.add(call.method);
        // Android refused the keep-alive service: the check runs bare.
        return call.method == 'startUpdateCheckForegroundService'
            ? false
            : null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
    // No device info: the check falls back to its default worker count.
    // Unanswered, the lookup would never complete under fake time.
    messenger.setMockMethodCallHandler(_deviceInfoChannel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
  });

  tearDown(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.imranr.obtainium/notifications'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_deviceInfoChannel, null);
    provider.dispose();
    settings.dispose();
  });

  Future<void> openApps(
    WidgetTester tester, {
    bool onDemandOnlyList = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          Provider<NotificationsProvider>.value(value: _Notifications()),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: AppsPage(onDemandOnlyList: onDemandOnlyList),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  /// Lets a started refresh run to its end: the check, the progress bar's
  /// last frame and the deferred store scan (which then does nothing).
  Future<void> finishRefresh(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('tapping the title checks exactly the listed apps', (
    tester,
  ) async {
    await openApps(tester);
    await tester.tap(find.text(tr('appsString')));
    await finishRefresh(tester);

    expect(provider.apps.checkedIds, [
      {'org.example.one', 'org.example.two'},
    ], reason: 'the on-demand app is not on the main list');
    expect(nativeCalls, ['startUpdateCheckForegroundService']);
    expect(provider.refreshProgress, isNull);
    expect(provider.updateCheckCancellation, isNull);
    expect(haptics, isEmpty, reason: 'a tap gets no haptic');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the on-demand page title checks its own apps', (tester) async {
    await openApps(tester, onDemandOnlyList: true);
    await tester.tap(find.text(tr('onDemandOnlyAppsTitle')));
    await finishRefresh(tester);

    expect(provider.apps.checkedIds, [
      {'org.example.later'},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pulling down still refreshes, with its haptic', (tester) async {
    await openApps(tester);
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 400),
      1000,
    );
    await finishRefresh(tester);

    expect(provider.apps.checkedIds, [
      {'org.example.one', 'org.example.two'},
    ]);
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap while a check runs starts no second one', (tester) async {
    await openApps(tester);
    // Another check is running (a pull on another page, check on start, a
    // link): the title can't stop it and mustn't queue one behind it.
    provider.refreshProgressNotifier.value = 0.4;
    await tester.tap(find.text(tr('appsString')));
    await finishRefresh(tester);
    expect(provider.apps.checkedIds, isEmpty);
    expect(nativeCalls, isEmpty);

    // Two quick taps start one check.
    provider.refreshProgressNotifier.value = null;
    await tester.tap(find.text(tr('appsString')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text(tr('appsString')));
    await finishRefresh(tester);
    expect(provider.apps.checkedIds, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TalkBack reads the title as a refresh button', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await openApps(tester);
    final SemanticsNode title = tester.getSemantics(
      find.text(tr('appsString')),
    );
    final SemanticsData data = title.getSemanticsData();
    expect(title.label, tr('appsString'));
    expect(title.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(title.hintOverrides?.onTapHint, tr('refresh'));
    semantics.dispose();
  });

  testWidgets('on TV the title is plain text', (tester) async {
    settings.isTV = true;
    await openApps(tester);
    final Finder title = find.text(tr('appsString'));
    expect(
      find.ancestor(of: title, matching: find.byType(InkWell)),
      findsNothing,
    );
    await tester.tap(title);
    await finishRefresh(tester);
    expect(provider.apps.checkedIds, isEmpty);
    // TV's own Refresh stays in the app bar (D23).
    expect(find.byTooltip(tr('refresh')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
