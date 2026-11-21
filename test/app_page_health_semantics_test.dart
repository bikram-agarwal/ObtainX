import 'package:android_package_manager/android_package_manager.dart';
import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/utils/update_health.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The app page (v1.7.4 sync):
// - DET-7 (upstream #3398): the icon of an installed app is one TalkBack
//   button, "Open <app>";
// - DET-6 (D8): a flagged app has an Update health line under Changes that
//   opens its options at the Update-health card;
// - D10: an app added without a check can't be installed until one succeeds.

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  @override
  final Map<String, ({String? title, String message})> appPageErrors = {};
  @override
  late SettingsProvider settingsProvider;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _SigningInfo extends SigningInfo {
  const _SigningInfo({super.signingCertificateHistory});
}

class _InstalledPackage extends PackageInfo {
  const _InstalledPackage({super.signingInfo})
    : super(
        installLocation: AndroidInstallLocation.unspecified,
        packageName: 'org.example.app',
        versionName: '1.0',
        versionCode: 1,
      );
}

App _app({
  int failedChecks = 0,
  String? installedVersion = '1.0',
  List<MapEntry<String, String>> apkUrls = const [
    MapEntry('app.apk', 'https://example.com/app.apk'),
  ],
}) => App(
  id: 'org.example.app',
  url: 'https://github.com/example/app',
  author: 'Example',
  name: 'Example',
  installedVersion: installedVersion,
  latestVersion: '1.0',
  apkUrls: apkUrls,
  preferredApkIndex: 0,
  additionalSettings: const {'versionDetection': 'auto'},
  consecutiveFailedChecks: failedChecks,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List icon;
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
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _Apps()..settingsProvider = settings;
  });

  tearDown(() {
    provider.dispose();
    settings.dispose();
  });

  Future<void> openPage(
    WidgetTester tester,
    App app, {
    bool installed = true,
    SigningInfo? signingInfo,
  }) {
    provider.apps[app.id] = AppInMemory(
      app,
      null,
      installed ? _InstalledPackage(signingInfo: signingInfo) : null,
      icon,
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1600);
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        // The app theme, so the page's snackbars float as they do in the app.
        child: MaterialApp(
          theme: buildObtainiumTheme(const ColorScheme.light(), null),
          home: AppPage(appId: app.id),
        ),
      ),
    );
  }

  // With an installed package the page never settles under test.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('the icon of an installed app is one "Open <app>" button', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await openPage(tester, _app());
    await settle(tester);

    final Finder iconNode = find.bySemanticsLabel(
      tr('openApp', args: ['Example']),
    );
    expect(iconNode, findsOneWidget);
    final SemanticsData data = tester.getSemantics(iconNode).getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a flagged app has an Update health line that opens its options '
      'at the Update-health card', (tester) async {
    await openPage(tester, _app(), installed: false);
    await settle(tester);
    expect(
      find.text(plural('updateHealthReasonFailedChecks', 6)),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await openPage(tester, _app(failedChecks: 6), installed: false);
    await settle(tester);
    final Finder line = find.text(plural('updateHealthReasonFailedChecks', 6));
    expect(line, findsOneWidget);
    // Not a Needs attention notice: that's for what blocks an update.
    expect(find.text(tr('needsAttention')), findsNothing);

    await tester.ensureVisible(line);
    await tester.tap(line);
    await settle(tester);
    final AdditionalOptionsPage options = tester.widget(
      find.byType(AdditionalOptionsPage),
    );
    expect(options.scrollToSection, updateHealthSectionKey);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an app added without a check has no Install to offer yet', (
    tester,
  ) async {
    await openPage(
      tester,
      _app(
        installedVersion: null,
        apkUrls: const [MapEntry('placeholder', 'placeholder')],
      ),
      installed: false,
    );
    await settle(tester);
    final Finder install = find.widgetWithText(FilledButton, tr('install'));
    expect(tester.widget<FilledButton>(install).onPressed, isNull);
    // A tap says why: the app needs a check first, as the install paths say.
    await tester.tap(install);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(tr('appNotCheckedYet')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('copy certificate hash button has an accessible label and copies', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final List<String> copiedTexts = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          final Map<dynamic, dynamic> args =
              call.arguments as Map<dynamic, dynamic>;
          copiedTexts.add(args['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final Uint8List signatureBytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final String expectedHash = certificateHashesFromSignatures([
      signatureBytes,
    ]).single;

    await openPage(
      tester,
      _app(),
      signingInfo: _SigningInfo(signingCertificateHistory: [signatureBytes]),
    );
    await settle(tester);

    final Finder copyNode = find.bySemanticsLabel(tr('copyToClipboard'));
    expect(copyNode, findsOneWidget);
    final SemanticsData data = tester.getSemantics(copyNode).getSemanticsData();
    expect(data.label, tr('copyToClipboard'));
    expect(data.tooltip, isEmpty);
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    tester.semantics.tap(find.semantics.byLabel(tr('copyToClipboard')));
    await tester.pump();

    expect(copiedTexts, <String>[expectedHash]);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
