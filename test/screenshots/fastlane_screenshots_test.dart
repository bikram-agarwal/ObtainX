// Fastlane screenshot generator for ObtainX.
//
// Renders the 16 store screenshots in `fastlane/metadata/android/en-US/images/
// phoneScreenshots/` with `flutter test` (no emulator, no pubspec changes — the
// F-Droid build stays reproducible). Driven by `capture_screenshots.ps1` in the
// workspace root, which passes:
//   --dart-define=CAPTURE_SCREENSHOTS=true      (otherwise every test is a no-op)
//   --dart-define=SCREENSHOT_FORM_FACTOR=all|phone|tablet
//   --dart-define=SCREENSHOT_SHOTS=01_apps,...   (optional subset)
//   --dart-define=SCREENSHOT_OUT_DIR=<dir>       (PNG output; the script converts to JPEG)
//
// Each shot is an independent [_Scene] reproducing the original screenshot taken
// on the maintainer's phone/tablet: same theme/accent, app list, versions, view
// options and open sheet. Apps that were installed on that phone are emulated by
// seeding [AppInMemory] entries with a fake [PackageInfo] and by mocking the
// device-apps / installer platform channels.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

// ignore: implementation_imports
import 'package:android_package_manager/src/entities/impl/package_info.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_ui_scaling.dart';
import 'package:obtainium/components/generated_form_renderer.dart'
    show CategoryEditorFields;
import 'package:obtainium/components/legacy_material_bridge.dart';
import 'package:obtainium/custom_errors.dart' show setAppLocale;
import 'package:obtainium/date_time_format.dart'
    show DeviceDateOrderScope, setSystemDateOrder;
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/main.dart'
    show
        AppScrollBehavior,
        fallbackLocale,
        globalNavigatorKey,
        homePageKey,
        localeDir,
        scaffoldMessengerKey,
        supportedLocales;
import 'package:obtainium/models/app.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/home.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/external_install_bridge.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/theme/app_dialog_theme.dart';
import 'package:obtainium/theme/app_segmented_button_theme.dart';
import 'package:obtainium/theme/app_switch_theme.dart';
import 'package:obtainium/theme/app_text_button_theme.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/widgets/app_toast.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const bool _captureScreenshotsEnabled = bool.fromEnvironment(
  'CAPTURE_SCREENSHOTS',
);
const String _requestedFormFactor = String.fromEnvironment(
  'SCREENSHOT_FORM_FACTOR',
  defaultValue: 'all',
);
const String _requestedShotsCsv = String.fromEnvironment(
  'SCREENSHOT_SHOTS',
  defaultValue: '',
);
const String _requestedOutDir = String.fromEnvironment(
  'SCREENSHOT_OUT_DIR',
  defaultValue: '',
);

// Geometry measured from the original screenshots (a Material switch track is
// 52 dp wide; label widths give the font scale). Phone: 1008x2244 at 360 dpi with
// Android's "Small" font size. Tablet: 1920x1200 at 240 dpi, default font size.
const Size _phonePhysicalSize = Size(1008, 2244);
const double _phonePixelRatio = 2.25;
const double _phoneTextScale = 0.85;
// The phone's status bar area is tall: content starts ~66 dp down.
const EdgeInsets _phoneSystemBars = EdgeInsets.only(top: 66, bottom: 20);

const Size _tabletPhysicalSize = Size(1920, 1200);
const double _tabletPixelRatio = 1.5;
const double _tabletTextScale = 1.0;
const EdgeInsets _tabletSystemBars = EdgeInsets.only(top: 24, bottom: 20);

// Saved custom accent shown after the presets in the accent picker.
const String _customDeepPurpleHex = '#673AB7';
// Wallpaper colour behind the "Material You" shots (olive green).
const Color _wallpaperOlive = Color(0xFF6B8E4E);

// Dummy (validated) GitHub token: "Verified Build" only shows while a validated
// PAT is configured. Never sent anywhere — every network path is mocked/offline.
const String _demoGithubCreds = 'screenshots:ghp_screenshotDemoToken';

final int _year = DateTime.now().year;
DateTime _on(int month, int day, [int hour = 12, int minute = 0]) =>
    DateTime(_year, month, day, hour, minute);

// Category colours as configured on the maintainer's phone.
const Map<String, Color> _phoneCategoryColors = <String, Color>{
  'App Managers': Color(0xFF00E5FF),
  'Bad Versioning': Color(0xFFE53935),
  'Cleaners': Color(0xFF9E9D24),
  'Entertainment': Color(0xFFEF5350),
  'Fdroid': Color(0xFF3DDC84),
  'Modifiers': Color(0xFF7E57C2),
  'Productivity': Color(0xFF4ADE80),
  'Root': Color(0xFFFFA726),
  'System': Color(0xFF2E7D4F),
  'Theme': Color(0xFF1E88E5),
  'Verified': Color(0xFF78909C),
};

const Map<String, Color> _tabletCategoryColors = <String, Color>{
  ..._phoneCategoryColors,
  'Personal': Color(0xFFEC407A),
};

// ---------------------------------------------------------------------------
// Scene model
// ---------------------------------------------------------------------------

/// One emulated tracked app.
class _DemoApp {
  const _DemoApp({
    required this.id,
    required this.name,
    required this.author,
    required this.url,
    required this.latest,
    this.installed,
    this.categories = const <String>[],
    this.release,
    this.changeLog,
    this.apkCount = 1,
    this.apkSizeMb,
    this.lastCheck,
    this.verifiedBuild = false,
    this.malwareClean = false,
    this.folderIds = const <String>[],
  });

  final String id;
  final String name;
  final String author;
  final String url;
  final String latest;

  /// Installed version name; null = not installed.
  final String? installed;
  final List<String> categories;
  final DateTime? release;
  final String? changeLog;
  final int apkCount;
  final int? apkSizeMb;
  final DateTime? lastCheck;
  final bool verifiedBuild;
  final bool malwareClean;

  /// Folder membership (normally materialised by the real provider).
  final List<String> folderIds;
}

/// One emulated installed device app (bulk add / installer picker).
class _DeviceApp {
  const _DeviceApp(this.packageName, this.label);

  final String packageName;
  final String label;
}

class _Scene {
  const _Scene({
    required this.isTablet,
    required this.theme,
    required this.accent,
    required this.apps,
    this.customSeedHex,
    this.useBlackTheme = false,
    this.use24HourClock = false,
    this.prefs = const <String, Object>{},
    this.folders = const <AppFolder>[],
    this.deviceApps = const <_DeviceApp>[],
    this.categoryColors,
  });

  final bool isTablet;
  final ThemeSettings theme;
  final AppAccentColorSource accent;
  final String? customSeedHex;
  final bool useBlackTheme;
  final bool use24HourClock;
  final List<_DemoApp> apps;
  final Map<String, Object> prefs;
  final List<AppFolder> folders;
  final List<_DeviceApp> deviceApps;

  /// Category set for this shot (defaults to the phone/tablet set).
  final Map<String, Color>? categoryColors;
}

// ---------------------------------------------------------------------------
// Fake providers
// ---------------------------------------------------------------------------

class _DemoNotificationsProvider implements NotificationsProvider {
  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> checkLaunchByNotif() async {}

  @override
  Future<void> notify(
    ObtainiumNotification notif, {
    bool cancelExisting = false,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _DemoAppsProvider extends ChangeNotifier implements AppsProvider {
  _DemoAppsProvider({
    required this.settingsProvider,
    required this.logs,
    required Directory storageRoot,
  }) : apkDir = Directory('${storageRoot.path}/apks')
         ..createSync(recursive: true),
       iconsCacheDir = Directory('${storageRoot.path}/icons')
         ..createSync(recursive: true),
       userAppIconsDir = Directory('${storageRoot.path}/user_icons')
         ..createSync(recursive: true),
       deducedAppIconsDir = Directory('${storageRoot.path}/deduced_icons')
         ..createSync(recursive: true);

  @override
  final AppListings apps = AppListings();

  @override
  SettingsProvider settingsProvider;

  @override
  LogsProvider logs;

  @override
  final Directory apkDir;

  @override
  final Directory iconsCacheDir;

  @override
  final Directory userAppIconsDir;

  @override
  final Directory deducedAppIconsDir;

  @override
  bool get iconsCacheDirReady => true;

  @override
  final ValueNotifier<double?> refreshProgressNotifier = ValueNotifier<double?>(
    null,
  );

  @override
  final Map<String, ({String? title, String message})> appPageErrors =
      <String, ({String? title, String message})>{};

  @override
  final Set<String> detailPageAutoChecksInFlight = <String>{};

  @override
  final Map<String, DateTime> lastDetailPageAutoCheckStartedAt =
      <String, DateTime>{};

  @override
  final Map<String, Timer> deferredObtainiumTimers = <String, Timer>{};

  @override
  final Map<String, AppInMemory> deferredObtainiumSnapshots =
      <String, AppInMemory>{};

  @override
  final Map<String, Timer> thirdPartyInstallIndicatorTimers = <String, Timer>{};

  @override
  bool loadingApps = false;

  @override
  bool isForeground = true;

  @override
  int appsListRevision = 1;

  @override
  int get pendingUpdateCount => findExistingUpdates(
    installedOnly: true,
    excludeOnDemandOnly: true,
    includeVersionOrderUncertain: true,
  ).length;

  @override
  Iterable<AppInMemory> getAppValues() => apps.values;

  @override
  void notify() => notifyListeners();

  @override
  void markAppsChanged() {
    appsListRevision += 1;
  }

  @override
  Future<void> waitForInitialLoad() => Future<void>.value();

  @override
  Future<void> waitForAppsToLoad() => Future<void>.value();

  @override
  void dispose() {
    refreshProgressNotifier.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _InMemoryAssetLoader extends AssetLoader {
  const _InMemoryAssetLoader(this.translations);

  final Map<String, dynamic> translations;

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

// ---------------------------------------------------------------------------
// Fonts and icons
// ---------------------------------------------------------------------------

Directory? _findMaterialFontsDirectory() {
  Directory current = File(Platform.resolvedExecutable).parent;
  for (int depth = 0; depth < 8; depth++) {
    for (final String relativePath in <String>[
      'cache/artifacts/material_fonts',
      'bin/cache/artifacts/material_fonts',
    ]) {
      final Directory candidateDir = Directory('${current.path}/$relativePath');
      if (candidateDir.existsSync()) {
        return candidateDir;
      }
    }
    final Directory parentDir = current.parent;
    if (parentDir.path == current.path) break;
    current = parentDir;
  }
  return null;
}

Future<void> _loadFontFamily(String family, List<File> files) async {
  final FontLoader loader = FontLoader(family);
  bool added = false;
  for (final File fontFile in files) {
    if (fontFile.existsSync()) {
      loader.addFont(
        Future<ByteData>.value(
          ByteData.sublistView(await fontFile.readAsBytes()),
        ),
      );
      added = true;
    }
  }
  if (added) await loader.load();
}

/// Loads real Roboto + Material Icons from the Flutter SDK cache, and a
/// monospace face for the version / certificate rows (Android uses Droid Sans
/// Mono; Consolas is the closest face available on the Windows host).
Future<void> _loadRealFonts() async {
  final Directory? fontsDir = _findMaterialFontsDirectory();
  if (fontsDir == null) {
    throw StateError('Could not locate the Flutter material_fonts cache.');
  }
  final List<File> robotoFiles = <String>[
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-light.ttf',
    'roboto-thin.ttf',
    'roboto-black.ttf',
    'roboto-italic.ttf',
    'roboto-mediumitalic.ttf',
    'roboto-bolditalic.ttf',
    'roboto-lightitalic.ttf',
  ].map((String name) => File('${fontsDir.path}/$name')).toList();
  await _loadFontFamily('Roboto', robotoFiles);
  await _loadFontFamily('sans-serif', robotoFiles);
  final String windowsFonts =
      '${Platform.environment['WINDIR'] ?? r'C:\Windows'}\\Fonts';
  final List<File> monoFiles = <File>[
    File('$windowsFonts\\consola.ttf'),
    File('$windowsFonts\\consolab.ttf'),
  ];
  await _loadFontFamily(
    'monospace',
    monoFiles.any((File file) => file.existsSync())
        ? monoFiles
        : <File>[robotoFiles.first],
  );
  await _loadFontFamily('MaterialIcons', <File>[
    File('${fontsDir.path}/materialicons-regular.otf'),
  ]);
}

Future<Uint8List> _encodePng(ui.Picture picture, int dimension) async {
  final ui.Image image = await picture.toImage(dimension, dimension);
  final ByteData? pngBytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  return pngBytes!.buffer.asUint8List();
}

void _paintCentredText(
  Canvas canvas,
  double dimension,
  String text,
  TextStyle style,
) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: dimension);
  painter.paint(
    canvas,
    Offset((dimension - painter.width) / 2, (dimension - painter.height) / 2),
  );
}

/// A circular launcher-style icon: [background] disc with a Material glyph or
/// short text in [foreground].
Future<Uint8List> _circleIcon(
  Color background, {
  IconData? glyph,
  String? text,
  Color foreground = Colors.white,
  double glyphScale = 0.56,
  FontWeight textWeight = FontWeight.w700,
  double textScale = 0.42,
}) async {
  const double dimension = 192;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawCircle(
    const Offset(dimension / 2, dimension / 2),
    dimension / 2,
    Paint()..color = background,
  );
  if (glyph != null) {
    _paintCentredText(
      canvas,
      dimension,
      String.fromCharCode(glyph.codePoint),
      TextStyle(
        fontFamily: glyph.fontFamily ?? 'MaterialIcons',
        package: glyph.fontPackage,
        fontSize: dimension * glyphScale,
        color: foreground,
      ),
    );
  } else if (text != null) {
    _paintCentredText(
      canvas,
      dimension,
      text,
      TextStyle(
        fontFamily: 'Roboto',
        fontSize: dimension * textScale,
        fontWeight: textWeight,
        height: 1.0,
        color: foreground,
      ),
    );
  }
  return _encodePng(recorder.endRecording(), dimension.toInt());
}

/// VLC's orange cone on a white disc.
Future<Uint8List> _vlcIcon() async {
  const double dimension = 192;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawCircle(
    const Offset(dimension / 2, dimension / 2),
    dimension / 2,
    Paint()..color = const Color(0xFFFF8800),
  );
  final Paint white = Paint()..color = Colors.white;
  final Paint orange = Paint()..color = const Color(0xFFFF8800);
  final Path cone = Path()
    ..moveTo(96, 36)
    ..lineTo(140, 150)
    ..lineTo(52, 150)
    ..close();
  canvas.drawPath(cone, white);
  canvas.drawRect(const Rect.fromLTWH(60, 84, 72, 14), orange);
  canvas.drawRect(const Rect.fromLTWH(48, 120, 96, 14), orange);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(40, 146, 112, 16),
      const Radius.circular(6),
    ),
    white,
  );
  return _encodePng(recorder.endRecording(), dimension.toInt());
}

/// Clips a square asset to a disc, as Android's launcher mask does.
Future<Uint8List> _circleClippedAsset(
  String assetPath, {
  Color? background,
}) async {
  final ByteData data = await rootBundle.load(assetPath);
  final ui.Codec codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
  );
  final ui.Image source = (await codec.getNextFrame()).image;
  const double dimension = 192;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.clipPath(
    Path()..addOval(const Rect.fromLTWH(0, 0, dimension, dimension)),
  );
  if (background != null) {
    canvas.drawPaint(Paint()..color = background);
  }
  canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    const Rect.fromLTWH(0, 0, dimension, dimension),
    Paint()..filterQuality = FilterQuality.high,
  );
  source.dispose();
  return _encodePng(recorder.endRecording(), dimension.toInt());
}

Future<Map<String, Uint8List>> _buildIcons() async {
  final Uint8List remember = await _circleClippedAsset(
    'assets/graphics/logo_remember.png',
  );
  final Uint8List filePipe = await _circleClippedAsset(
    'assets/graphics/logo_filepipe.png',
  );
  final Uint8List obtainx = await _circleClippedAsset(
    'assets/graphics/icon_small.png',
    background: Colors.white,
  );
  return <String, Uint8List>{
    'dev.bikram.remember.gh': remember,
    'dev.bikram.filepipe.gh': filePipe,
    'dev.imranr.obtainium': obtainx,
    'dev.bikram.obtainx.debug': obtainx,
    'org.videolan.vlc': await _vlcIcon(),
    'com.aurora.store': await _circleIcon(
      const Color(0xFF8E7CC3),
      glyph: Icons.shopping_bag_rounded,
    ),
    'io.github.muntashirakon.AppManager': await _circleIcon(
      const Color(0xFF101010),
      text: 'A',
      textWeight: FontWeight.w300,
      textScale: 0.5,
    ),
    'com.rosan.installer.x.revived': await _circleIcon(
      const Color(0xFFD7EFC1),
      text: 'X',
      foreground: const Color(0xFF1B5E20),
      textWeight: FontWeight.w900,
    ),
    'com.mixplorer': await _circleIcon(
      const Color(0xFF1E88E5),
      text: 'M',
      textScale: 0.38,
    ),
    'com.google.android.packageinstaller': await _circleIcon(
      const Color(0xFF3949AB),
      glyph: Icons.download_rounded,
    ),
    'com.onepassword.android': await _circleIcon(
      const Color(0xFF1A73E8),
      glyph: Icons.lock_outline_rounded,
    ),
    'com.tplink.aginet': await _circleIcon(
      const Color(0xFF00BCD4),
      text: 'N',
      textScale: 0.48,
    ),
    'com.maxpatchs.aivy': await _circleIcon(
      const Color(0xFF29B6F6),
      glyph: Icons.local_florist_rounded,
      glyphScale: 0.62,
    ),
    'com.bandot.alexis.minimal.iconpack': await _circleIcon(
      const Color(0xFF263B57),
      glyph: Icons.face_3_rounded,
      foreground: const Color(0xFFB3E5FC),
    ),
    'com.amazon.mp3': await _circleIcon(
      const Color(0xFF25D1DA),
      text: 'music',
      foreground: const Color(0xFF0F1111),
      textScale: 0.24,
    ),
    'com.americanexpress.android.acctsvcs.us': await _circleIcon(
      const Color(0xFF016FD0),
      text: 'AM\nEX',
      textScale: 0.27,
      textWeight: FontWeight.w900,
    ),
    'com.maxpatchs.ango': await _circleIcon(
      const Color(0xFFFFB300),
      glyph: Icons.spa_rounded,
      foreground: const Color(0xFF558B2F),
    ),
    'org.chromium.webapk.a88ef60f112e1dcbf_v2': await _circleIcon(
      const Color(0xFFF47D20),
      text: 'A',
      textScale: 0.55,
    ),
    'com.anod.appwatcher': await _circleIcon(
      const Color(0xFF2196F3),
      glyph: Icons.notifications_rounded,
    ),
    'com.appsales': await _circleIcon(
      const Color(0xFFE53935),
      glyph: Icons.sell_rounded,
    ),
    '_generic': await _circleIcon(
      const Color(0xFF607D8B),
      glyph: Icons.android_rounded,
    ),
  };
}

// ---------------------------------------------------------------------------
// Demo data
// ---------------------------------------------------------------------------

_DemoApp _remember({
  String installed = '1.1.8',
  String latest = 'v1.1.9',
  DateTime? release,
  List<String> categories = const <String>['Fdroid', 'Productivity'],
  DateTime? lastCheck,
}) => _DemoApp(
  id: 'dev.bikram.remember.gh',
  name: 'Remember',
  author: 'bikram-agarwal',
  url: 'https://github.com/bikram-agarwal/Remember',
  installed: installed,
  latest: latest,
  release: release ?? _on(7, 13, 14, 51),
  changeLog: 'Material 3 Expressive editor polish and reminder fixes.',
  categories: categories,
  apkCount: 2,
  apkSizeMb: 8,
  lastCheck: lastCheck,
  verifiedBuild: true,
  malwareClean: true,
);

_DemoApp _filePipe({
  String installed = '3.9.0',
  String latest = 'v3.9.1',
  DateTime? release,
  List<String> categories = const <String>['Fdroid', 'Productivity'],
  DateTime? lastCheck,
}) => _DemoApp(
  id: 'dev.bikram.filepipe.gh',
  name: 'FilePipe',
  author: 'bikram-agarwal',
  url: 'https://github.com/bikram-agarwal/FilePipe',
  installed: installed,
  latest: latest,
  release: release ?? _on(7, 14),
  categories: categories,
  apkCount: 2,
  apkSizeMb: 7,
  lastCheck: lastCheck,
  verifiedBuild: true,
  malwareClean: true,
);

_DemoApp _vlc({String installed = '3.7.2 Beta 1'}) => _DemoApp(
  id: 'org.videolan.vlc',
  name: 'VLC',
  author: 'F-Droid official',
  url: 'https://f-droid.org/packages/org.videolan.vlc',
  installed: installed,
  latest: installed,
  changeLog: 'https://code.videolan.org/videolan/vlc-android/-/tags',
  categories: const <String>['Entertainment'],
);

final _DemoApp _auroraStoreNotInstalled = _DemoApp(
  id: 'com.aurora.store',
  name: 'Aurora Store',
  author: 'AuroraOSS',
  url: 'https://gitlab.com/AuroraOSS/AuroraStore',
  latest: '4.7.4',
  release: _on(5, 13),
  categories: <String>['Modifiers'],
);

const _DemoApp _installerX = _DemoApp(
  id: 'com.rosan.installer.x.revived',
  name: 'InstallerX Revived',
  author: 'wxxsfxyzm',
  url: 'https://github.com/wxxsfxyzm/InstallerX-Revived',
  installed: '26.07.a048293',
  // Clearly newer so the row shows an update, not "order uncertain".
  latest: 'v26.08.0',
  categories: <String>['App Managers', 'Bad Versioning', 'Root', 'Verified'],
);

const _DemoApp _appManager = _DemoApp(
  id: 'io.github.muntashirakon.AppManager',
  name: 'App Manager',
  author: 'MuntashirAkon',
  url: 'https://github.com/MuntashirAkon/AppManager',
  installed: '4.0.5',
  latest: 'v4.0.5',
  categories: <String>['App Managers', 'Verified'],
);

const List<String> _fillerNames = <String>[
  'Aves',
  'Breezy Weather',
  'Catima',
  'Droid-ify',
  'Element',
  'Fossify Gallery',
  'Fossify Clock',
  'Gadgetbridge',
  'Heliboard',
  'Immich',
  'Jellyfin',
  'K-9 Mail',
  'Librera',
  'Mihon',
  'NewPipe',
  'Nextcloud',
  'OsmAnd',
  'Pano Scrobbler',
  'Quillpad',
  'Read You',
  'Seal',
  'Shizuku',
  'Signal',
  'Syncthing',
  'Termux',
  'Tusky',
  'Untracker',
  'VLC Remote',
  'Weechat',
  'Xtra',
  'Yubico Authenticator',
  'Zapp',
];

/// Apps for collapsed groups (only their count is visible).
List<_DemoApp> _fillerApps(
  String source,
  int count, {
  int offset = 0,
  bool installed = true,
  bool hasUpdate = false,
  String author = '',
  List<String> categories = const <String>[],
}) {
  return List<_DemoApp>.generate(count, (int index) {
    final int nameIndex = (offset + index) % _fillerNames.length;
    final String name = _fillerNames[nameIndex];
    final String slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    final String packageId = 'demo.$source.$slug${offset + index}'
        .toLowerCase();
    final String url = switch (source) {
      'APKPure' => 'https://apkpure.com/$slug/$packageId',
      'GitHub' => 'https://github.com/demo-$slug/$slug',
      'GitLab' => 'https://gitlab.com/demo-$slug/$slug',
      'IzzyOnDroid' => 'https://apt.izzysoft.de/fdroid/index/apk/$packageId',
      'APKMirror' => 'https://www.apkmirror.com/apk/google-inc/$slug/',
      _ => 'https://f-droid.org/packages/$packageId',
    };
    return _DemoApp(
      id: packageId,
      name: name,
      author: author.isNotEmpty ? author : 'demo-$slug',
      url: url,
      installed: installed ? '2.${index % 9}.0' : null,
      latest: hasUpdate ? '2.${index % 9}.1' : '2.${index % 9}.0',
      // Recent, so Update health doesn't flag them (stale = 180+ days).
      release: _on(8 + (index % 3), 1 + (index % 27)),
      categories: categories,
    );
  });
}

/// 53 Google apps (the "Google" folder). Exactly 10 are installed and carry a
/// category from the 11_folders rule (App Managers/Entertainment/System/Theme,
/// none of Bad Versioning/Root), so that rule reports "matches 10 app(s)".
List<_DemoApp> _googleApps() {
  const List<String> googleNames = <String>[
    'Android Auto',
    'Android System WebView',
    'Calculator',
    'Calendar',
    'Camera',
    'Chrome',
    'Clock',
    'Contacts',
    'Drive',
    'Files',
    'Gemini',
    'Gmail',
    'Google',
    'Google Home',
    'Google Lens',
    'Google One',
    'Google Pay',
    'Google Photos',
    'Google Play Games',
    'Google TV',
    'Keep Notes',
    'Maps',
    'Meet',
    'Messages',
    'News',
    'Phone',
    'Photos',
    'Pixel Launcher',
    'Pixel Tips',
    'Podcasts',
    'Recorder',
    'Safety',
    'Settings Services',
    'Sheets',
    'Slides',
    'Snapseed',
    'Sound Amplifier',
    'Speech Services',
    'Tasks',
    'Translate',
    'Voice',
    'Wallet',
    'Wallpapers',
    'Wear OS',
    'YouTube',
    'YouTube Music',
    'Docs',
    'Find Hub',
    'Fitbit',
    'Gboard',
    'Assistant',
    'Authenticator',
    'Digital Wellbeing',
  ];
  return List<_DemoApp>.generate(googleNames.length, (int index) {
    final String name = googleNames[index];
    final String slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    final List<String> categories = index < 10
        ? <String>[
            const <String>[
              'System',
              'Entertainment',
              'Theme',
              'App Managers',
            ][index % 4],
          ]
        : index < 14
        ? const <String>['System', 'Root']
        : const <String>[];
    return _DemoApp(
      id: 'com.google.android.demo.$slug',
      name: name,
      author: 'Google LLC',
      folderIds: const <String>['folder_google'],
      url: 'https://www.apkmirror.com/apk/google-inc/$slug/',
      installed: index < 40 ? '1.${index % 7}.0' : null,
      latest: index < 3 ? '1.${index % 7}.1' : '1.${index % 7}.0',
      release: _on(8 + (index % 3), 1 + (index % 27)),
      categories: categories,
    );
  });
}

final AppFolder _googleFolderAuthorOnly = AppFolder(
  id: 'folder_google',
  name: 'Google',
  criteria: FolderCriteria(author: const FolderTextCriterion(query: 'Google')),
);

final AppFolder _googleFolderFullRule = AppFolder(
  id: 'folder_google',
  name: 'Google',
  criteria: FolderCriteria(
    author: const FolderTextCriterion(query: 'Google'),
    includedCategories: const <String>{
      'App Managers',
      'Entertainment',
      'System',
      'Theme',
    },
    excludedCategories: const <String>{'Bad Versioning'},
    installedIntent: FolderConditionIntent.include,
  ),
);

List<_DeviceApp> _phoneDeviceApps() {
  const List<_DeviceApp> visible = <_DeviceApp>[
    _DeviceApp('com.onepassword.android', '1Password'),
    _DeviceApp('com.tplink.aginet', 'Aginet'),
    _DeviceApp('com.maxpatchs.aivy', 'Aivy icons'),
    _DeviceApp('com.bandot.alexis.minimal.iconpack', 'Alexis'),
    _DeviceApp('com.amazon.mp3', 'Amazon Music'),
    _DeviceApp('com.americanexpress.android.acctsvcs.us', 'Amex'),
    _DeviceApp('com.maxpatchs.ango', 'Ango icons'),
    _DeviceApp('org.chromium.webapk.a88ef60f112e1dcbf_v2', 'APKMirror'),
    _DeviceApp('com.anod.appwatcher', 'App Watcher'),
    _DeviceApp('com.appsales', 'AppSales'),
  ];
  // 155 more user apps that sort after "AppSales" (only the count is visible).
  final List<_DeviceApp> rest = List<_DeviceApp>.generate(155, (int index) {
    final String name = _fillerNames[index % _fillerNames.length];
    return _DeviceApp(
      'demo.device.${name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '')}$index',
      '$name ${index ~/ _fillerNames.length + 1}',
    );
  });
  return <_DeviceApp>[...visible, ...rest];
}

const List<_DeviceApp> _tabletDeviceApps = <_DeviceApp>[
  _DeviceApp('io.github.muntashirakon.AppManager', 'App Manager'),
  _DeviceApp('dev.bikram.filepipe.gh', 'FilePipe'),
  _DeviceApp('com.mixplorer', 'MiXplorer'),
  _DeviceApp('dev.imranr.obtainium', 'Obtainium'),
  _DeviceApp('dev.bikram.obtainx.debug', 'ObtainX Debug'),
  _DeviceApp('dev.bikram.remember.gh', 'Remember'),
  _DeviceApp('org.videolan.vlc', 'VLC'),
];

/// View options common to the maintainer's setup (group by tracked source,
/// updates and non-installed apps grouped separately, category stripes).
Map<String, Object> _viewPrefs({
  bool categoriesBadge = false,
  SortColumnSettings sort = SortColumnSettings.releaseDate,
  SortOrderSettings order = SortOrderSettings.descending,
  bool groupNonInstalled = true,
  bool groupTrackOnly = false,
  List<String> collapsed = const <String>[],
}) => <String, Object>{
  'showAppTypeBadge': true,
  'showTrackedStoreBadge': true,
  'showCategoriesBadge': categoriesBadge,
  'showAuthorBadge': true,
  'showVersionBadge': true,
  'sortColumn': sort.index,
  'sortOrder': order.index,
  'groupBy': AppsListGroupBy.source.name,
  'groupUpdatesSeparately': true,
  'groupNonInstalledSeparately': groupNonInstalled,
  'groupTrackOnlySeparately': groupTrackOnly,
  'pinUpdates': true,
  'buryNonInstalled': true,
  'showFolderedAppsOnMainPage': false,
  'collapsedGroups': collapsed,
};

// ---------------------------------------------------------------------------
// Theme (mirrors main.dart's _resolveThemeSchemes + _buildAppThemeData)
// ---------------------------------------------------------------------------

ThemeData _appThemeFor(ColorScheme scheme) {
  final ThemeData base = buildObtainiumTheme(scheme, 'Roboto');
  final double focusAlpha = scheme.brightness == Brightness.dark ? 0.24 : 0.12;
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    cardColor: scheme.surfaceContainer,
    focusColor: scheme.primary.withValues(alpha: focusAlpha),
    segmentedButtonTheme: appSegmentedButtonTheme(scheme),
    switchTheme: appSwitchTheme(scheme),
    dialogTheme: appDialogTheme().copyWith(shape: base.dialogTheme.shape),
    textButtonTheme: TextButtonThemeData(
      style: appTextButtonTheme().style!.merge(base.textButtonTheme.style),
    ),
  );
}

({ThemeData light, ThemeData dark}) _buildThemes(SettingsProvider settings) {
  // "Material You" shots: the OS hands the app a wallpaper-derived scheme.
  final ColorScheme lightDynamic = ColorScheme.fromSeed(
    seedColor: _wallpaperOlive,
  );
  final ColorScheme darkDynamic = ColorScheme.fromSeed(
    seedColor: _wallpaperOlive,
    brightness: Brightness.dark,
  );
  ColorScheme schemeFor(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    ColorScheme scheme = colorSchemeForAccentSettings(
      brightness: brightness,
      accentSource: settings.appAccentColorSource,
      paletteStyle: settings.appThemePaletteStyle,
      lightDynamic: lightDynamic,
      darkDynamic: darkDynamic,
      activeCustomSeedHex: settings.activeCustomSeedHex,
    );
    scheme = scheme.boostSurfaceContainersTowardPrimary(
      darkTheme: dark,
      useGradient: settings.useGradientBackground,
      shadingIntensity: settings.shadingIntensity,
    );
    if (settings.appAccentColorSource != AppAccentColorSource.materialYou) {
      scheme = scheme.boostContainersForSeedThemes(darkTheme: dark);
    }
    if (dark && settings.useBlackTheme) {
      scheme = scheme.withPureBlackBackgrounds();
    }
    return scheme;
  }

  final ColorScheme light = schemeFor(Brightness.light);
  final ColorScheme dark = schemeFor(Brightness.dark);
  // Same slot logic as main.dart: a forced theme fills both MaterialApp slots.
  final ColorScheme themeSlot = settings.theme == ThemeSettings.dark
      ? dark
      : light;
  final ColorScheme darkSlot = settings.theme == ThemeSettings.light
      ? light
      : dark;
  return (light: _appThemeFor(themeSlot), dark: _appThemeFor(darkSlot));
}

PackageInfoImpl _packageInfo(String packageName, String versionName) {
  return PackageInfoImpl(<String, dynamic>{
    'packageName': packageName,
    'versionName': versionName,
    'versionCode': 1000,
    'longRevisionCode': 1000,
    'installLocation': 0,
    'firstInstallTime': DateTime.utc(2025, 11, 10).millisecondsSinceEpoch,
    'lastUpdateTime': DateTime.utc(2026, 3, 18).millisecondsSinceEpoch,
    'applicationInfo': <String, dynamic>{
      'packageName': packageName,
      'compatibleWidthLimitDp': 0,
      'dataDir': '/data/user/0/$packageName',
      'descriptionRes': 0,
      'enabled': true,
      'flags': 0,
      'largestWidthLimitDp': 0,
      'processName': packageName,
      'publicSourceDir': '/data/app/$packageName-1/base.apk',
      'requiresSmallestWidthDp': 0,
      'sourceDir': '/data/app/$packageName-1/base.apk',
      'targetSdkVersion': 36,
      'theme': 0,
      'uiOptions': 0,
      'uid': 10200,
    },
  });
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> englishTranslations;
  late Map<String, Uint8List> icons;
  late Directory tempStorageDir;
  List<_DeviceApp> activeDeviceApps = const <_DeviceApp>[];

  final Set<String> requestedShots = _requestedShotsCsv
      .split(',')
      .map(
        (String rawShot) =>
            rawShot.trim().replaceAll(RegExp(r'\.(png|jpe?g)$'), ''),
      )
      .where((String trimmedShot) => trimmedShot.isNotEmpty)
      .toSet();

  bool shouldRunShot(String shotName, {required bool isTablet}) {
    if (!_captureScreenshotsEnabled) return false;
    if (requestedShots.isNotEmpty) return requestedShots.contains(shotName);
    return switch (_requestedFormFactor) {
      'phone' => !isTablet,
      'tablet' => isTablet,
      'tablet10' => false,
      _ => true,
    };
  }

  Uint8List iconFor(String key) => icons[key] ?? icons['_generic']!;

  setUpAll(() async {
    if (!_captureScreenshotsEnabled) return;
    await binding.runAsync(() async {
      await _loadRealFonts();
      tempStorageDir = await Directory.systemTemp.createTemp(
        'obtainx_screenshots_',
      );
      englishTranslations = (await const RootBundleAssetLoader().load(
        localeDir,
        fallbackLocale,
      ))!;
      icons = await _buildIcons();
    });
    Localization.load(
      fallbackLocale,
      translations: Translations(englishTranslations),
    );
    setAppLocale(fallbackLocale);
    setSystemDateOrder('mdy');
  });

  tearDownAll(() async {
    ExternalInstallerBridge.listTargetsOverrideForTesting = null;
    if (_captureScreenshotsEnabled) {
      await binding.runAsync(() async {
        if (tempStorageDir.existsSync()) {
          await tempStorageDir.delete(recursive: true);
        }
      });
    }
  });

  void installPlatformChannelMocks(_Scene scene) {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    for (final String channel in <String>[
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
      'dev.imranr.obtainium/share',
      'dev.imranr.obtainium/shortcuts',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (MethodCall call) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => tempStorageDir.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.imranr.obtainium/storage'),
      (MethodCall call) async =>
          call.method == 'hasPersistedDocumentTreePermission' ? true : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('io.alexrintt.plugins/sharedstorage/documentfile'),
      (MethodCall call) async =>
          <String>['canRead', 'canWrite', 'exists'].contains(call.method)
          ? true
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/device_info'),
      (MethodCall call) async => <String, dynamic>{
        'version': <String, dynamic>{
          'baseOS': '',
          'codename': 'REL',
          'incremental': '123456',
          'previewSdkInt': 0,
          'release': '16',
          'sdkInt': 36,
          'securityPatch': '2026-07-01',
        },
        'board': 'husky',
        'bootloader': 'ripcurrent',
        'brand': 'google',
        'device': 'husky',
        'display': 'BP2A.250705.008',
        'fingerprint': 'google/husky/husky:16/BP2A/123:user/release-keys',
        'hardware': 'tensor',
        'host': 'abfarm',
        'id': 'BP2A.250705.008',
        'manufacturer': 'Google',
        'model': 'Pixel 8 Pro',
        'product': 'husky',
        'supported32BitAbis': <String>[],
        'supported64BitAbis': <String>['arm64-v8a'],
        'supportedAbis': <String>['arm64-v8a'],
        'tags': 'release-keys',
        'type': 'user',
        'isPhysicalDevice': true,
        'systemFeatures': <String>[],
        'serialNumber': 'unknown',
        'isLowRamDevice': false,
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.imranr.obtainium/device_apps'),
      (MethodCall call) async {
        switch (call.method) {
          case 'uses24HourFormat':
            return scene.use24HourClock;
          case 'dateFormatOrder':
            return 'mdy';
          case 'getSigningCertificates':
            // Any stable bytes: the page shows their SHA-256.
            return <String, dynamic>{
              'hasMultipleSigners': false,
              'signatures': <Uint8List>[
                Uint8List.fromList(utf8.encode('bikram-agarwal release key')),
              ],
            };
          case 'getInstalledAppsLight':
            return activeDeviceApps
                .map(
                  (_DeviceApp app) => <String, dynamic>{
                    'packageName': app.packageName,
                    'label': app.label,
                    'isSystem': false,
                    'sourceDir': '/data/app/${app.packageName}/base.apk',
                  },
                )
                .toList();
          case 'getAppIcon':
            final Map<dynamic, dynamic> iconArgs =
                call.arguments as Map<dynamic, dynamic>;
            return iconFor(iconArgs['packageName']?.toString() ?? '');
          case 'getApplicationLabels':
            return <String, String>{};
          default:
            return null;
        }
      },
    );

    InstallerTarget target(String package, String activity, String label) =>
        InstallerTarget(
          package: package,
          activity: activity,
          activityLabel: label,
          label: switch (package) {
            'io.github.muntashirakon.AppManager' => 'App Manager',
            'com.rosan.installer.x.revived' => 'InstallerX Revived',
            'com.mixplorer' => 'MiXplorer',
            _ => 'Package installer',
          },
          icon: iconFor(package),
        );
    const String appManager = 'io.github.muntashirakon.AppManager';
    ExternalInstallerBridge.listTargetsOverrideForTesting = () async =>
        <InstallerTarget>[
          target(
            appManager,
            '$appManager.apk.installer.PackageInstallerActivity',
            'Install',
          ),
          target(
            appManager,
            '$appManager.details.AppDetailsActivity',
            'App info',
          ),
          target(appManager, '$appManager.fm.FmActivity', 'Explore'),
          target(
            appManager,
            '$appManager.intercept.ActivityInterceptor',
            'Interceptor',
          ),
          target(
            appManager,
            '$appManager.details.manifest.ManifestViewerActivity',
            'Manifest viewer',
          ),
          target(appManager, '$appManager.scanner.ScannerActivity', 'Scanner'),
          target(
            'com.rosan.installer.x.revived',
            'com.rosan.installer.ui.activity.InstallerActivity',
            'Install',
          ),
          target(
            'com.mixplorer',
            'com.mixplorer.activities.InstallActivity',
            'Package Installer',
          ),
          target(
            'com.google.android.packageinstaller',
            'com.android.packageinstaller.InstallStart',
            'Package installer',
          ),
        ];
  }

  AppInMemory toAppInMemory(_DemoApp demo) {
    final App model = App(
      id: demo.id,
      url: demo.url,
      author: demo.author,
      name: demo.name,
      installedVersion: demo.installed,
      latestVersion: demo.latest,
      apkUrls: List<MapEntry<String, String>>.generate(
        demo.apkCount,
        (int index) => MapEntry<String, String>(
          '${demo.name}-${demo.latest}-${<String>['arm64-v8a', 'armeabi-v7a', 'x86_64'][index % 3]}.apk',
          '${demo.url}/releases/download/${demo.latest}/${demo.name}-$index.apk',
        ),
      ),
      preferredApkIndex: 0,
      additionalSettings: <String, dynamic>{
        'versionDetection': 'standard',
        if (demo.verifiedBuild)
          GitHub.buildVerificationModeKey: GitHub.buildVerificationAudit,
        if (demo.folderIds.isNotEmpty) 'folderIds': demo.folderIds,
      },
      lastUpdateCheck: demo.lastCheck ?? _on(7, 18, 15, 47),
      releaseDate: demo.release,
      changeLog: demo.changeLog,
      categories: demo.categories,
      apkSizeBytes: demo.apkSizeMb == null ? null : demo.apkSizeMb! << 20,
      latestAttestationStatus: demo.verifiedBuild
          ? githubAttestationStatusVerified
          : null,
      latestMalwareScanStatus: demo.malwareClean
          ? malwareScanStatusClean
          : null,
    );
    return AppInMemory(
      model,
      null,
      demo.installed == null
          ? null
          : _packageInfo(demo.id, demo.installed!.replaceFirst('v', '')),
      iconFor(demo.id),
    );
  }

  Future<({SettingsProvider settings, GlobalKey repaintKey})> mountScene(
    WidgetTester tester,
    _Scene scene, {
    Widget? home,
  }) async {
    installPlatformChannelMocks(scene);
    activeDeviceApps = scene.deviceApps;

    final double pixelRatio = scene.isTablet
        ? _tabletPixelRatio
        : _phonePixelRatio;
    final EdgeInsets systemBars = scene.isTablet
        ? _tabletSystemBars
        : _phoneSystemBars;
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.physicalSize = scene.isTablet
        ? _tabletPhysicalSize
        : _phonePhysicalSize;
    tester.view.padding = FakeViewPadding(
      top: systemBars.top * pixelRatio,
      bottom: systemBars.bottom * pixelRatio,
    );
    tester.view.viewPadding = FakeViewPadding(
      top: systemBars.top * pixelRatio,
      bottom: systemBars.bottom * pixelRatio,
    );
    tester.platformDispatcher.textScaleFactorTestValue = scene.isTablet
        ? _tabletTextScale
        : _phoneTextScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    SharedPreferences.setMockInitialValues(<String, Object>{
      'firstRun': false,
      'welcomeShown': true,
      'checkOnStart': false,
      'theme': scene.theme.index,
      'appAccentColorSource': scene.accent.name,
      'useMaterialYou': scene.accent == AppAccentColorSource.materialYou,
      'activeCustomSeedHex': scene.customSeedHex ?? _customDeepPurpleHex,
      'savedCustomSeedHexList': jsonEncode(<String>[_customDeepPurpleHex]),
      'appThemePaletteStyle': AppThemePaletteStyle.tonalSpot.name,
      'useBlackTheme': scene.useBlackTheme,
      'useGradientBackground': true,
      'shadingIntensity': 1.0,
      'progressiveBlurEnabled': true,
      'reduceVisualEffects': false,
      // Update health is newer than the originals: with its stale-release /
      // stale-version checks off (0), no app is flagged and the list has no
      // "Update health (n)" footer (Aurora's real 05-13 release is >180 days).
      'showUpdateHealthIndicator': false,
      'updateHealthStaleReleaseDays': 0,
      'updateHealthStaleVersionDays': 0,
      GitHub.githubCredsKey: _demoGithubCreds,
      GitHub.validatedPATFingerprintKey: GitHub.patFingerprint(
        _demoGithubCreds,
      )!,
      ..._viewPrefs(),
      ...scene.prefs,
    });

    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    final LogsProvider logs = LogsProvider(runDefaultClear: false);
    final _DemoAppsProvider apps = _DemoAppsProvider(
      settingsProvider: settings,
      logs: logs,
      storageRoot: tempStorageDir,
    );
    settings.setCategories(<String, int>{
      for (final MapEntry<String, Color> entry
          in (scene.categoryColors ??
                  (scene.isTablet
                      ? _tabletCategoryColors
                      : _phoneCategoryColors))
              .entries)
        entry.key: entry.value.toARGB32(),
    }, appsProvider: apps);
    settings.appFolders = scene.folders;
    for (final _DemoApp demo in scene.apps) {
      final AppInMemory entry = toAppInMemory(demo);
      apps.apps[entry.listingKey] = entry;
    }
    BulkScanCache.setCacheForTesting(<String, Map<String, String>>{
      'dev.bikram.remember.gh': <String, String>{
        'PlayStore':
            'https://play.google.com/store/apps/details?id=dev.bikram.remember',
        'F-Droid': 'https://f-droid.org/packages/dev.bikram.remember',
      },
      'dev.bikram.filepipe.gh': <String, String>{
        'PlayStore':
            'https://play.google.com/store/apps/details?id=dev.bikram.filepipe',
        'F-Droid': 'https://f-droid.org/packages/dev.bikram.filepipe',
      },
    });
    addTearDown(apps.dispose);
    addTearDown(settings.dispose);

    final ({ThemeData light, ThemeData dark}) themes = _buildThemes(settings);
    final GlobalKey repaintKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: repaintKey,
        child: EasyLocalization(
          supportedLocales: supportedLocales
              .map((MapEntry<Locale, String> item) => item.key)
              .toList(),
          path: localeDir,
          fallbackLocale: fallbackLocale,
          startLocale: fallbackLocale,
          assetLoader: _InMemoryAssetLoader(englishTranslations),
          useOnlyLangCode: true,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppsProvider>.value(value: apps),
              ChangeNotifierProvider<SettingsProvider>.value(value: settings),
              Provider<NotificationsProvider>.value(
                value: _DemoNotificationsProvider(),
              ),
              Provider<LogsProvider>.value(value: logs),
            ],
            child: Builder(
              builder: (BuildContext context) => MaterialApp(
                title: 'ObtainX',
                scrollBehavior: const AppScrollBehavior(),
                localizationsDelegates: <LocalizationsDelegate<dynamic>>[
                  ...context.localizationDelegates,
                  ...GlobalMaterialLocalizations.delegates,
                ],
                supportedLocales: context.supportedLocales,
                locale: fallbackLocale,
                navigatorKey: globalNavigatorKey,
                scaffoldMessengerKey: scaffoldMessengerKey,
                debugShowCheckedModeBanner: false,
                themeAnimationDuration: Duration.zero,
                theme: themes.light,
                darkTheme: themes.dark,
                builder: (BuildContext innerContext, Widget? child) =>
                    DeviceDateOrderScope(
                      child: LegacyMaterialBridge(
                        child: AppUiScaler(
                          scale: settings.appUiScale,
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ),
                    ),
                home: AppToastHost(child: home ?? HomePage(key: homePageKey)),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.runAsync(() async {
      final BuildContext? navContext = globalNavigatorKey.currentContext;
      if (navContext != null) {
        for (final Uint8List iconBytes in icons.values) {
          await precacheImage(MemoryImage(iconBytes), navContext);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
    return (settings: settings, repaintKey: repaintKey);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  Future<void> tapText(
    WidgetTester tester,
    String text, {
    bool last = false,
  }) async {
    final Finder finder = find.text(text);
    expect(finder, findsWidgets, reason: 'No widget with text "$text"');
    await tester.tap(last ? finder.last : finder.first);
    await settle(tester);
  }

  /// Scrolls the accent swatch row to its end (as in the originals) and opens
  /// the colour panel from the trailing add/expand swatch.
  Future<void> openAccentColorPanel(WidgetTester tester) async {
    final Finder swatchRow = find.ancestor(
      of: find
          .byWidgetPredicate(
            (Widget widget) =>
                widget.runtimeType.toString() == '_AccentSourceSwatch',
          )
          .first,
      matching: find.byType(ListView),
    );
    await tester.drag(swatchRow.first, const Offset(-3000, 0));
    await settle(tester);
    await tester.tap(
      find.descendant(of: swatchRow.first, matching: find.byIcon(Icons.add)),
    );
    await settle(tester);
  }

  Future<void> capture(
    WidgetTester tester,
    GlobalKey repaintKey,
    String shotName, {
    required bool isTablet,
    bool keepFocus = false,
    String subDirectory = '',
  }) async {
    if (!keepFocus) FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
    final RenderRepaintBoundary boundary =
        repaintKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(
        pixelRatio: isTablet ? _tabletPixelRatio : _phonePixelRatio,
      );
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      final String outDirPath = _requestedOutDir.isNotEmpty
          ? _requestedOutDir
          : '${Directory.current.path}/build/screenshots_png';
      final Directory outDir = Directory(
        subDirectory.isEmpty ? outDirPath : '$outDirPath/$subDirectory',
      );
      if (!outDir.existsSync()) await outDir.create(recursive: true);
      await File('${outDir.path}/$shotName.png')
          .writeAsBytes(byteData!.buffer.asUint8List(), flush: true);
    });
  }

  /// Registers one screenshot test.
  void shot(
    String name,
    _Scene Function() sceneBuilder,
    Future<void> Function(WidgetTester tester) interact, {
    Widget Function()? home,
    bool keepFocus = false,
  }) {
    testWidgets(name, (WidgetTester tester) async {
      final _Scene scene = sceneBuilder();
      if (!shouldRunShot(name, isTablet: scene.isTablet)) return;
      // flutter_test replaces every shadow with a hard black outline unless
      // this is off; it must be back on before the test ends (the framework
      // verifies painting debug flags are reset).
      debugDisableShadows = false;
      try {
        final mounted = await mountScene(tester, scene, home: home?.call());
        try {
          await interact(tester);
        } catch (_) {
          // Save what was on screen when a step failed (failed/<name>.png;
          // the capture script only converts top-level PNGs), then fail.
          await capture(
            tester,
            mounted.repaintKey,
            name,
            isTablet: scene.isTablet,
            keepFocus: true,
            subDirectory: 'failed',
          );
          rethrow;
        }
        await capture(
          tester,
          mounted.repaintKey,
          name,
          isTablet: scene.isTablet,
          keepFocus: keepFocus,
        );
      } finally {
        debugDisableShadows = true;
      }
    });
  }

  // -------------------------------------------------------------------------
  // Phone shots
  // -------------------------------------------------------------------------

  group('ObtainX Fastlane phone screenshots', () {
    shot(
      '01_apps',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.presetLime,
        apps: <_DemoApp>[
          _remember(release: _on(7, 24, 18)),
          _filePipe(
            installed: '3.8.8',
            latest: 'v3.8.9',
            release: _on(7, 24, 9),
          ),
          _vlc(),
          ..._fillerApps('APKPure', 12),
          ..._fillerApps('GitHub', 13, offset: 3),
          ..._fillerApps('GitLab', 1, offset: 9),
          ..._fillerApps('IzzyOnDroid', 2, offset: 11),
          ..._fillerApps('GitHub', 10, offset: 40, installed: false),
          ..._googleApps(),
        ],
        folders: <AppFolder>[_googleFolderAuthorOnly],
        prefs: _viewPrefs(
          collapsed: <String>[
            'src:APKPure',
            'src:GitHub',
            'src:GitLab',
            'src:IzzyOnDroid',
            '__nonInstalled__',
          ],
        ),
      ),
      (WidgetTester tester) async {},
    );

    shot(
      '02_view_opts',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.presetEmerald,
        apps: <_DemoApp>[
          _remember(installed: '1.2.2', latest: 'v1.2.3', release: _on(8, 1)),
          _filePipe(installed: '3.9.6', latest: 'v3.9.7', release: _on(7, 28)),
          _vlc(),
          ..._fillerApps('APKPure', 12),
          ..._fillerApps('GitHub', 13, offset: 3),
        ],
        prefs: _viewPrefs(collapsed: <String>['src:APKPure', 'src:GitHub']),
      ),
      (WidgetTester tester) async {
        await tester.tap(find.byIcon(Icons.tune).first);
        await settle(tester);
      },
    );

    shot(
      '03_filters',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.presetTeal,
        apps: <_DemoApp>[
          _filePipe(installed: '3.9.0', latest: 'v3.9.1', release: _on(7, 14)),
          _remember(installed: '1.1.8', release: _on(7, 13)),
          _vlc(),
          ..._fillerApps(
            'GitHub',
            13,
            offset: 3,
            categories: <String>['Productivity'],
          ),
        ],
      ),
      (WidgetTester tester) async {
        // The filter sheet first opens from the search bar's "App name" pill.
        await tester.tap(find.byIcon(Icons.search).first);
        await settle(tester);
        await tapText(tester, tr('appName'));
        // The sheet is the topmost route, so its chips are the last matches.
        // Status chips: tap once = must be (+), twice = exclude (x).
        await tapText(tester, tr('visibilityFilterUpToDate'), last: true);
        await tapText(tester, tr('visibilityFilterUpToDate'), last: true);
        await tapText(tester, tr('visibilityFilterInstalled'), last: true);
        await tapText(tester, 'Productivity', last: true);
        // App source dropdown ("Any" is the first "Any" in the sheet; the
        // categories Any/All toggle comes later), then GitHub in its menu.
        await tapText(tester, 'Any');
        await tapText(tester, 'GitHub', last: true);
        // Close it and let the empty search bar collapse, so the page shows the
        // title + active-filter chips as in the original, then reopen the
        // sheet from the filter row's funnel button.
        await tester.tapAt(const Offset(200, 120));
        await settle(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(tester);
        await tester.tap(find.byTooltip(tr('filterApps')).first);
        await settle(tester);
        await tester.enterText(find.byType(TextField).last, 'My App Updates');
        await settle(tester);
      },
      keepFocus: true,
    );

    shot(
      '04_app',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.materialYou,
        apps: <_DemoApp>[
          _remember(installed: '1.1.6', release: _on(7, 13, 14, 51)),
        ],
      ),
      (WidgetTester tester) async {},
      home: () => const AppPage(appId: 'dev.bikram.remember.gh'),
    );

    shot(
      '05_edit',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.custom,
        customSeedHex: _customDeepPurpleHex,
        apps: <_DemoApp>[
          _filePipe(categories: const <String>['Productivity']),
        ],
      ),
      (WidgetTester tester) async {},
      home: () =>
          const AppPage(appId: 'dev.bikram.filepipe.gh', openInEditMode: true),
    );

    shot(
      '06_import_export',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.light,
        accent: AppAccentColorSource.appDefault,
        apps: <_DemoApp>[_remember(), _filePipe()],
        prefs: const <String, Object>{
          'exportDir': 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FBackups%2FObtainX',
          'apkSaveDir': 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FBackups%2FObtainX',
          'iconsDir': 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FBackups%2FObtainX',
          'saveDownloadedApkCopies': false,
          'autoExportOnChanges': true,
        },
      ),
      (WidgetTester tester) async {
        await homePageKey.currentState!.switchToPage(2);
        await settle(tester);
      },
    );

    shot(
      '07_add_apps',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.presetEmerald,
        apps: <_DemoApp>[_remember(), _filePipe()],
      ),
      (WidgetTester tester) async {
        await homePageKey.currentState!.switchToPage(1);
        await settle(tester);
        await tester.tap(find.byType(TextField).first);
        await settle(tester);
      },
      keepFocus: true,
    );

    shot(
      '08_bulk_add',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.presetAmber,
        apps: <_DemoApp>[_remember(), _filePipe()],
        deviceApps: _phoneDeviceApps(),
      ),
      (WidgetTester tester) async {
        await homePageKey.currentState!.switchToPage(1);
        await settle(tester);
        await tapText(tester, tr('bulkSearchDeviceApps'));
        await tester.pump(const Duration(milliseconds: 500));
        await settle(tester);
        await tapText(tester, tr('selectAll'));
      },
    );

    shot(
      '09_settings',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.presetTeal,
        apps: <_DemoApp>[_remember(), _filePipe()],
      ),
      (WidgetTester tester) async {
        await homePageKey.currentState!.switchToPage(3);
        await settle(tester);
        await tapText(tester, tr('settingsThemesSection'));
        // Today's settings list has an extra card ("Update health"); scroll so
        // the Themes header sits where it does in the original.
        await Scrollable.ensureVisible(
          tester.element(find.text(tr('settingsThemesSection')).first),
          alignment: 0.37,
        );
        await settle(tester);
        await openAccentColorPanel(tester);
      },
    );

    shot(
      '10_BulkEdit',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.materialYou,
        apps: <_DemoApp>[
          _DemoApp(
            id: _installerX.id,
            name: _installerX.name,
            author: _installerX.author,
            url: _installerX.url,
            installed: _installerX.installed,
            latest: _installerX.latest,
            categories: _installerX.categories,
            release: _on(7, 16),
          ),
          _filePipe(
            installed: '3.8.8',
            latest: 'v3.8.9',
            release: _on(7, 14),
            categories: const <String>['Productivity'],
          ),
          _remember(
            installed: '1.1.6',
            release: _on(7, 13),
            categories: const <String>['Productivity'],
          ),
          ..._fillerApps('APKPure', 7),
          _appManager,
        ],
        // This shot predates the "Fdroid" category.
        categoryColors: <String, Color>{
          for (final MapEntry<String, Color> entry
              in _phoneCategoryColors.entries)
            if (entry.key != 'Fdroid') entry.key: entry.value,
        },
        prefs: _viewPrefs(collapsed: <String>['src:APKPure']),
      ),
      (WidgetTester tester) async {
        await tester.longPress(find.text('InstallerX Revived').first);
        await settle(tester);
        await tester.tap(find.text('App Manager').first);
        await settle(tester);
        await tester.tap(find.byIcon(Icons.checklist).first);
        await settle(tester);
        await tapText(tester, tr('categorize'));
        // Both selected apps are Verified, so one tap = remove from all (x).
        await tapText(tester, 'Verified', last: true);
        await tapText(tester, tr('addCategory'), last: true);
        await tester.enterText(find.byType(TextField).last, 'Installer');
        await settle(tester);
        // The suggested colour is random; pin the original's.
        tester
            .widget<CategoryEditorFields>(find.byType(CategoryEditorFields))
            .onColorHexChanged('#6B8D4E');
        await settle(tester);
      },
      keepFocus: true,
    );

    shot(
      '11_folders',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.light,
        accent: AppAccentColorSource.presetEmerald,
        apps: <_DemoApp>[_remember(), _filePipe(), _vlc(), ..._googleApps()],
        folders: <AppFolder>[_googleFolderFullRule],
      ),
      (WidgetTester tester) async {
        final Finder manageFolders = find.text(tr('manageFolders'));
        await tester.scrollUntilVisible(
          manageFolders,
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await settle(tester);
        await tester.tap(manageFolders.first);
        await settle(tester);
        final Finder editFolder = find.byTooltip(tr('editFolder'));
        if (editFolder.evaluate().isNotEmpty) {
          await tester.tap(editFolder.first);
          await settle(tester);
        }
        // The original was mid-edit: Root exclusion not saved yet (so the
        // summary reads "+4" and Save is enabled). Tap twice = exclude (x).
        await tapText(tester, 'Root', last: true);
        await tapText(tester, 'Root', last: true);
      },
    );

    shot(
      '12_installer_choice',
      () => _Scene(
        isTablet: false,
        theme: ThemeSettings.light,
        accent: AppAccentColorSource.presetAmber,
        use24HourClock: true,
        apps: <_DemoApp>[_remember(), _filePipe()],
        prefs: const <String, Object>{
          'installMethod': 'external',
          'externalInstallerPackage': 'io.github.muntashirakon.AppManager',
          'externalInstallerComponent': 'io.github.muntashirakon.AppManager.apk.installer.PackageInstallerActivity',
        },
      ),
      (WidgetTester tester) async {
        await homePageKey.currentState!.switchToPage(3);
        await settle(tester);
        await tapText(tester, tr('integrations'));
        final Finder chooseInstaller = find.text(tr('chooseExternalInstaller'));
        await Scrollable.ensureVisible(
          tester.element(chooseInstaller.first),
          alignment: 0.1,
        );
        await settle(tester);
        await tester.tap(chooseInstaller.first);
        await settle(tester);
        // Expand App Manager's activities in the picker sheet (topmost).
        await tapText(tester, 'App Manager', last: true);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Tablet shots
  // -------------------------------------------------------------------------

  List<_DemoApp> tabletApps() => <_DemoApp>[
    _filePipe(
      installed: '3.9.0',
      latest: 'v3.9.1',
      release: _on(7, 14),
      categories: const <String>['Productivity'],
      lastCheck: _on(7, 18, 12, 40),
    ),
    _remember(
      installed: '1.1.8',
      release: _on(7, 13, 14, 51),
      categories: const <String>['Productivity', 'Personal'],
      lastCheck: _on(7, 18, 13, 2),
    ),
    _vlc(installed: '3.7.1'),
    _auroraStoreNotInstalled,
    ..._fillerApps('APKPure', 9),
    ..._fillerApps('GitHub', 21, offset: 4),
  ];

  group('ObtainX Fastlane tablet screenshots', () {
    shot(
      'tablet_01_apps',
      () => _Scene(
        isTablet: true,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.materialYou,
        use24HourClock: true,
        apps: tabletApps(),
        prefs: _viewPrefs(
          groupNonInstalled: false,
          collapsed: <String>['src:APKPure', 'src:GitHub'],
        ),
      ),
      (WidgetTester tester) async {
        await tapText(tester, 'Remember');
      },
    );

    shot(
      'tablet_02_view_opts',
      () => _Scene(
        isTablet: true,
        theme: ThemeSettings.light,
        accent: AppAccentColorSource.materialYou,
        use24HourClock: true,
        apps: tabletApps(),
        prefs: _viewPrefs(
          categoriesBadge: true,
          sort: SortColumnSettings.lastUpdateCheck,
          order: SortOrderSettings.ascending,
          groupNonInstalled: false,
          groupTrackOnly: true,
          collapsed: <String>['src:APKPure', 'src:GitHub'],
        ),
      ),
      (WidgetTester tester) async {
        await tapText(tester, 'Remember');
        await tester.tap(find.byIcon(Icons.tune).first);
        await settle(tester);
      },
    );

    shot(
      'tablet_03_add',
      () => _Scene(
        isTablet: true,
        theme: ThemeSettings.dark,
        accent: AppAccentColorSource.appDefault,
        apps: <_DemoApp>[_remember(), _filePipe(), _vlc(), _appManager],
        deviceApps: _tabletDeviceApps,
      ),
      (WidgetTester tester) async {
        await homePageKey.currentState!.switchToPage(1);
        await settle(tester);
        await tapText(tester, tr('bulkSearchDeviceApps'));
        await tester.pump(const Duration(milliseconds: 500));
        await settle(tester);
        await tapText(tester, tr('excludeAlreadyTrackedApps'));
        await tapText(tester, 'MiXplorer');
        await tapText(tester, 'Obtainium');
      },
    );

    shot(
      'tablet_04_settings',
      () => _Scene(
        isTablet: true,
        theme: ThemeSettings.system,
        accent: AppAccentColorSource.presetAmber,
        useBlackTheme: true,
        apps: <_DemoApp>[_remember(), _filePipe()],
        prefs: const <String, Object>{'matchAppPageToIconColors': false},
      ),
      (WidgetTester tester) async {
        await homePageKey.currentState!.switchToPage(3);
        await settle(tester);
        await tapText(tester, tr('settingsThemesSection'));
        await openAccentColorPanel(tester);
      },
    );
  });
}
