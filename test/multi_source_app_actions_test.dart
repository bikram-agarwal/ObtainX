// Platform test doubles use the interfaces supplied by the existing plugins.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:expressive_refresh/expressive_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_detail_widgets.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/app_check_store.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _packageId = 'com.google.android.apps.tachyon';
const _installed = '376.0.977329897.public_beta.duo.android_20260907.02_p0';
const _latest = '376.0.977329897.duo.android_20260907.02_p0';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getExternalStoragePath() async {
    return root;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    return root;
  }
}

class _Device extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    return BaseDeviceInfo({
      'version': {
        'sdkInt': 35,
        'release': '15',
        'codename': 'REL',
        'incremental': '1',
        'previewSdkInt': 0,
        'securityPatch': '',
        'baseOS': '',
      },
      for (final key in [
        'board',
        'bootloader',
        'brand',
        'device',
        'display',
        'fingerprint',
        'hardware',
        'host',
        'id',
        'manufacturer',
        'model',
        'product',
        'tags',
      ])
        key: '',
      'type': 'user',
      'supported32BitAbis': ['armeabi-v7a'],
      'supported64BitAbis': ['arm64-v8a'],
      'supportedAbis': ['arm64-v8a', 'armeabi-v7a'],
      'isPhysicalDevice': true,
      'freeDiskSize': 1,
      'totalDiskSize': 1,
      'physicalRamSize': 4096,
      'availableRamSize': 2048,
      'isLowRamDevice': false,
      'systemFeatures': <String>[],
    });
  }
}

class _Logs extends Fake implements LogsProvider {
  @override
  Future<Log> add(String message, {LogLevel level = LogLevel.info}) async {
    return Log(message, level);
  }
}

class _Notifications extends Fake implements NotificationsProvider {}

class _InstalledMeet extends Fake implements PackageInfo {
  @override
  String get packageName => _packageId;
  @override
  String get versionName => _installed;
}

class _LocalSources extends HttpOverrides {
  _LocalSources(this.port);
  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _LocalClient(super.createHttpClient(context), port);
  }
}

class _LocalClient extends Fake implements HttpClient {
  _LocalClient(this.client, this.port);
  final HttpClient client;
  final int port;

  @override
  set connectionTimeout(Duration? value) {
    client.connectionTimeout = value;
  }

  @override
  set maxConnectionsPerHost(int? value) {
    client.maxConnectionsPerHost = value;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    expect(url.host, 'api.github.com');
    return client.openUrl(
      method,
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) {
    client.close(force: force);
  }
}

class _Apps extends ChangeNotifier implements AppsProvider {
  _Apps(this.settingsProvider, Directory directory)
    : cachedAppsDir = directory,
      appCheckStore = AppCheckStore('${directory.path}/checks.db');

  @override
  final AppListings apps = AppListings();
  @override
  final SettingsProvider settingsProvider;
  @override
  Directory? cachedAppsDir;
  @override
  AppCheckStore? appCheckStore;
  @override
  DateTime? appDirectoryModifiedAt;
  @override
  DateTime? appCheckStoreModifiedAt;
  @override
  final LogsProvider logs = _Logs();
  @override
  final Map<String, ({String? title, String message})> appPageErrors = {};
  @override
  final Set<String> detailPageAutoChecksInFlight = {};
  @override
  final Map<String, DateTime> lastDetailPageAutoCheckStartedAt = {};
  final clearedErrors = <String>[];
  @override
  Completer<List<App>>? updateCheckCompleter;
  @override
  double? refreshProgress;

  @override
  void clearAppPageError(String appId) {
    clearedErrors.add(appId);
    appPageErrors.remove(appId);
  }

  @override
  void setAppPageError(String appId, Object error, {String? title}) {
    appPageErrors[appId] = (title: title, message: error.toString());
    notifyListeners();
  }

  @override
  void markAppsChanged() {
    notifyListeners();
  }

  @override
  void notify() {
    notifyListeners();
  }

  @override
  void scheduleAutoExport() {}

  @override
  void finishPendingAutoExport() {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

App _listing({required bool trackOnly, bool pendingRename = false}) {
  return App(
    id: _packageId,
    listingId: trackOnly ? null : appListingKey(_packageId, 'APKPure'),
    url: trackOnly
        ? 'https://www.apkmirror.com/apk/google-inc/meet/'
        : 'https://apkpure.com/meet/$_packageId',
    author: 'Google LLC',
    name: 'Meet',
    installedVersion: _installed,
    latestVersion: _latest,
    apkSizeBytes: 145 * 1024 * 1024,
    preferredApkIndex: 0,
    apkUrls: trackOnly
        ? []
        : const [
            MapEntry('meet-arm64.apk', 'https://apkpure.com/meet-arm64.apk'),
            MapEntry('meet-arm.apk', 'https://apkpure.com/meet-arm.apk'),
          ],
    additionalSettings: {'trackOnly': trackOnly, 'versionDetection': 'auto'},
    pendingRepoRenameUrl: pendingRename
        ? 'https://github.com/example/renamed'
        : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SettingsProvider settings;
  late _Apps provider;
  late Uint8List icon;
  late PathProviderPlatform previousPaths;
  late DeviceInfoPlatform previousDevice;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    directory = await Directory.systemTemp.createTemp(
      'obtainx-listing-actions-',
    );
    previousPaths = PathProviderPlatform.instance;
    previousDevice = DeviceInfoPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    DeviceInfoPlatform.instance = _Device();
    SharedPreferences.setMockInitialValues({
      'matchAppPageToIconColors': false,
      'checkUpdateOnDetailPage': false,
      'showAppWebpage': false,
      'updateButtonsAtTopOfAppPage': true,
    });
    settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    provider = _Apps(settings, directory);
    await BulkScanCache.save({
      _packageId: {
        'APKMirror': 'https://www.apkmirror.com/apk/google-inc/meet/',
        'APKPure': 'https://apkpure.com/meet/$_packageId',
        'F-Droid': 'https://f-droid.org/packages/$_packageId/',
        'PlayStore':
            'https://play.google.com/store/apps/details?id=$_packageId',
      },
    });
  });

  tearDown(() async {
    await provider.appCheckStore?.close();
    provider.dispose();
    settings.dispose();
    PathProviderPlatform.instance = previousPaths;
    DeviceInfoPlatform.instance = previousDevice;
    await directory.delete(recursive: true);
  });

  Future<void> openListing(
    WidgetTester tester,
    App displayed,
    App sibling,
  ) async {
    provider.apps[sibling.listingKey] = AppInMemory(sibling, null, null, icon);
    provider.apps[displayed.listingKey] = AppInMemory(
      displayed,
      null,
      null,
      icon,
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppsProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          Provider<NotificationsProvider>.value(value: _Notifications()),
        ],
        child: MaterialApp(
          navigatorKey: globalNavigatorKey,
          home: AppPage(appId: displayed.listingKey),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('manual list refresh includes both store listing keys', () {
    final primary = _listing(trackOnly: true);
    final secondary = _listing(trackOnly: false);
    expect(
      appIdsForManualRefresh(
        apps: [primary, secondary],
        onDemandOnlyList: false,
        folderId: null,
        showFolderedAppsOnMainPage: true,
        existingFolderIds: {},
      ),
      [primary.listingKey, secondary.listingKey],
    );
  });

  test('bulk refresh persists the result for each requested listing', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestedPaths = <String>[];
    server.listen((request) async {
      requestedPaths.add(request.uri.path);
      final repo = request.uri.path.split('/')[3];
      final release = {
        'tag_name': repo == 'first' ? '2.0' : '3.0',
        'name': repo == 'first' ? '2.0' : '3.0',
        'prerelease': false,
        'draft': false,
        'body': '',
        'published_at': '2026-09-13T00:00:00Z',
        'assets': [
          {
            'name': '$repo.apk',
            'size': 1024,
            'browser_download_url':
                'https://github.com/example/$repo/releases/download/latest/$repo.apk',
          },
        ],
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path.contains('/releases')
              ? (request.uri.path.endsWith('/latest') ? release : [release])
              : {'full_name': 'example/$repo', 'name': repo},
        ),
      );
      await request.response.close();
    });
    final first = _listing(trackOnly: true).copyWith(
      url: 'https://github.com/example/first',
      installedVersion: '1.0',
      latestVersion: '1.0',
    );
    final second = first.copyWith(
      listingId: appListingKey(_packageId, 'second'),
      url: 'https://github.com/example/second',
    );
    provider.apps[first.listingKey] = AppInMemory(first, null, null, icon);
    provider.apps[second.listingKey] = AppInMemory(second, null, null, icon);
    final updates = await HttpOverrides.runWithHttpOverrides(
      () => provider.checkUpdates(
        specificIds: [first.listingKey, second.listingKey],
      ),
      _LocalSources(server.port),
    );
    expect(requestedPaths, contains('/repos/example/first/releases'));
    expect(requestedPaths, contains('/repos/example/second/releases'));
    expect(updates.map((app) => app.listingKey).toSet(), {
      first.listingKey,
      second.listingKey,
    });
    expect(provider.apps[first.listingKey]!.app.latestVersion, '2.0');
    expect(provider.apps[second.listingKey]!.app.latestVersion, '3.0');
    expect(provider.refreshProgress, isNull);
    expect(provider.updateCheckCompleter, isNull);
  });

  test('reset install status clears an accidental source acknowledgement', () {
    final original = _listing(trackOnly: true);
    final marked = acknowledgeSourceRelease(original);
    expect(appHasActionableUpdate(marked), isFalse);
    final restored = resetInstallStatusToDeviceVersion(
      marked,
      _InstalledMeet(),
    );
    expect(restored.installedVersion, _installed);
    expect(appHasActionableUpdate(restored), isTrue);
    expect(
      restored.additionalSettings.containsKey(acknowledgedSourceReleaseKey),
      isFalse,
    );
  });

  testWidgets('refresh on a second listing finishes and clears its own error', (
    tester,
  ) async {
    // A paused source is a valid no-result check. Even then the page must leave
    // its busy state and must never clear a sibling's error instead.
    final displayed = _listing(trackOnly: false, pendingRename: true);
    final sibling = _listing(trackOnly: true, pendingRename: true);
    await openListing(tester, displayed, sibling);
    final update = find.widgetWithText(FilledButton, 'Update · 145 MB');
    expect(tester.widget<FilledButton>(update).onPressed, isNotNull);
    await tester
        .widget<ExpressiveRefreshIndicator>(
          find.byType(ExpressiveRefreshIndicator),
        )
        .onRefresh();
    await tester.pumpAndSettle();
    expect(provider.clearedErrors, [displayed.listingKey]);
    expect(tester.widget<FilledButton>(update).onPressed, isNotNull);
    expect(provider.findExistingUpdates(installedOnly: true).toSet(), {
      displayed.listingKey,
      sibling.listingKey,
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'secondary store Update opens its APK picker and leaves track-only sibling pending',
    (tester) async {
      final displayed = _listing(trackOnly: false);
      final sibling = _listing(trackOnly: true);
      await openListing(tester, displayed, sibling);
      await tester.tap(find.widgetWithText(FilledButton, 'Update · 145 MB'));
      await tester.pumpAndSettle();
      expect(find.byType(AppFilePicker), findsOneWidget);
      expect(find.text('meet-arm64.apk'), findsWidgets);
      expect(
        provider.apps[sibling.listingKey]!.app.installedVersion,
        _installed,
      );
      expect(provider.findExistingUpdates(installedOnly: true).toSet(), {
        displayed.listingKey,
        sibling.listingKey,
      });
      globalNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('secondary listing download progress stays visible', (
    tester,
  ) async {
    final displayed = _listing(trackOnly: false);
    await openListing(tester, displayed, _listing(trackOnly: true));
    provider.apps[displayed.listingKey]!.downloadProgress = 30;
    provider.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text(tr('downloadingX', args: ['30%'])), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed refresh restores actions on the displayed listing', (
    tester,
  ) async {
    final displayed = _listing(trackOnly: false);
    final sibling = _listing(trackOnly: true, pendingRename: true);
    await openListing(tester, displayed, sibling);
    // The widget-test HTTP client rejects the source request. Exercise the
    // actual failure path without reaching a live store.
    await tester.runAsync(() async {
      await tester
          .widget<ExpressiveRefreshIndicator>(
            find.byType(ExpressiveRefreshIndicator),
          )
          .onRefresh();
    });
    await tester.pumpAndSettle();
    expect(provider.appPageErrors.keys, [displayed.listingKey]);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Update · 145 MB'),
          )
          .onPressed,
      isNotNull,
    );
    expect(provider.findExistingUpdates(installedOnly: true).toSet(), {
      displayed.listingKey,
      sibling.listingKey,
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'track-only second listing keeps Update and Mark updated after refresh',
    (tester) async {
      final displayed = _listing(
        trackOnly: true,
        pendingRename: true,
      ).copyWith(listingId: appListingKey(_packageId, 'APKMirror'));
      final sibling = _listing(
        trackOnly: false,
        pendingRename: true,
      ).copyWith(listingId: null);
      await openListing(tester, displayed, sibling);
      await tester
          .widget<ExpressiveRefreshIndicator>(
            find.byType(ExpressiveRefreshIndicator),
          )
          .onRefresh();
      await tester.pumpAndSettle();
      expect(provider.clearedErrors, [displayed.listingKey]);
      for (final label in ['Update · 145 MB', tr('markUpdated')]) {
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, label))
              .onPressed,
          isNotNull,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('detail auto-checks are scheduled for each store independently', (
    tester,
  ) async {
    settings.checkUpdateOnDetailPage = true;
    final displayed = _listing(trackOnly: false, pendingRename: true);
    final sibling = _listing(trackOnly: true, pendingRename: true);
    await openListing(tester, displayed, sibling);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(provider.lastDetailPageAutoCheckStartedAt.keys, [
      displayed.listingKey,
    ]);
    expect(provider.clearedErrors, [displayed.listingKey]);
    expect(provider.detailPageAutoChecksInFlight, isEmpty);
    await openListing(tester, sibling, displayed);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(provider.lastDetailPageAutoCheckStartedAt.keys.toSet(), {
      displayed.listingKey,
      sibling.listingKey,
    });
    expect(provider.clearedErrors, [displayed.listingKey, sibling.listingKey]);
    expect(provider.detailPageAutoChecksInFlight, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
