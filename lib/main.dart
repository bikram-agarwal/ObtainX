import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/pages/home.dart';
import 'package:obtainium/theme/app_segmented_button_theme.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/theme/app_switch_theme.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/native_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_system_colors/dynamic_system_colors.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:background_fetch/background_fetch.dart';
import 'package:easy_localization/easy_localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/easy_localization_controller.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

List<MapEntry<Locale, String>> supportedLocales = const [
  MapEntry(Locale('en'), 'English'),
  MapEntry(Locale('zh'), '简体中文'),
  MapEntry(Locale('zh', 'Hant_TW'), '臺灣話'),
  MapEntry(Locale('it'), 'Italiano'),
  MapEntry(Locale('ja'), '日本語'),
  MapEntry(Locale('hu'), 'Magyar'),
  MapEntry(Locale('de'), 'Deutsch'),
  MapEntry(Locale('fa'), 'فارسی'),
  MapEntry(Locale('fr'), 'Français'),
  MapEntry(Locale('es'), 'Español'),
  MapEntry(Locale('pl'), 'Polski'),
  MapEntry(Locale('ru'), 'Русский'),
  MapEntry(Locale('bs'), 'Bosanski'),
  MapEntry(Locale('pt'), 'Português'),
  MapEntry(Locale('pt', 'BR'), 'Brasileiro'),
  MapEntry(Locale('cs'), 'Česky'),
  MapEntry(Locale('sv'), 'Svenska'),
  MapEntry(Locale('nl'), 'Nederlands'),
  MapEntry(Locale('vi'), 'Tiếng Việt'),
  MapEntry(Locale('tr'), 'Türkçe'),
  MapEntry(Locale('uk'), 'Українська'),
  MapEntry(Locale('da'), 'Dansk'),
  MapEntry(
    Locale('en', 'EO'),
    'Esperanto',
  ), // https://github.com/aissat/easy_localization/issues/220#issuecomment-846035493
  MapEntry(Locale('in'), 'Bahasa Indonesia'),
  MapEntry(Locale('ko'), '한국어'),
  MapEntry(Locale('ca'), 'Català'),
  MapEntry(Locale('ar'), 'العربية'),
  MapEntry(Locale('ml'), 'മലയാളം'),
  MapEntry(Locale('gl'), 'Galego'),
];
const fallbackLocale = Locale('en');
const localeDir = 'assets/translations';
var fdroid = false;

final globalNavigatorKey = GlobalKey<NavigatorState>();
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> loadTranslations() async {
  // See easy_localization/issues/210
  await EasyLocalizationController.initEasyLocation();
  var s = SettingsProvider();
  await s.initializeSettings();
  var forceLocale = s.forcedLocale;
  final controller = EasyLocalizationController(
    saveLocale: true,
    forceLocale: forceLocale,
    fallbackLocale: fallbackLocale,
    supportedLocales: supportedLocales.map((e) => e.key).toList(),
    assetLoader: const RootBundleAssetLoader(),
    useOnlyLangCode: false,
    useFallbackTranslations: true,
    path: localeDir,
    onLoadError: (FlutterError e) {
      throw e;
    },
  );
  await controller.loadTranslations();
  Localization.load(
    controller.locale,
    translations: controller.translations,
    fallbackTranslations: controller.fallbackTranslations,
  );
}

@pragma('vm:entry-point')
void backgroundFetchHeadlessTask(HeadlessEvent headlessEvent) async {
  String taskId = headlessEvent.taskId;
  bool isTimeout = headlessEvent.timeout;
  if (isTimeout) {
    debugPrint('BG update task timed out.');
    BackgroundFetch.finish(taskId);
    return;
  }
  await bgUpdateCheck(taskId, null);
  BackgroundFetch.finish(taskId);
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  static const String incrementCountCommand = 'incrementCount';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('onStart(starter: ${starter.name})');
    bgUpdateCheck('bg_check', null);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    bgUpdateCheck('bg_check', null);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('Foreground service onDestroy(isTimeout: $isTimeout)');
  }

  @override
  void onReceiveData(Object data) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    ByteData data = await PlatformAssetBundle().load(
      'assets/ca/lets-encrypt-r3.pem',
    );
    SecurityContext.defaultContext.setTrustedCertificatesBytes(
      data.buffer.asUint8List(),
    );
  } catch (e) {
    // Already added, do nothing (see #375)
  }
  await EasyLocalization.ensureInitialized();
  if ((await DeviceInfoPlugin().androidInfo).version.sdkInt >= 29) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  final SettingsProvider settingsProvider = SettingsProvider();
  await settingsProvider.initializeSettings();
  final np = NotificationsProvider();
  await np.initialize();
  FlutterForegroundTask.initCommunicationPort();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (context) => AppsProvider(sharedSettings: settingsProvider),
        ),
        ChangeNotifierProvider.value(value: settingsProvider),
        Provider(create: (context) => np),
        Provider(create: (context) => LogsProvider()),
      ],
      child: EasyLocalization(
        supportedLocales: supportedLocales.map((e) => e.key).toList(),
        path: localeDir,
        fallbackLocale: fallbackLocale,
        useOnlyLangCode: false,
        child: const Obtainium(),
      ),
    ),
  );
  BackgroundFetch.registerHeadlessTask(backgroundFetchHeadlessTask);
}

class Obtainium extends StatefulWidget {
  const Obtainium({super.key});

  @override
  State<Obtainium> createState() => _ObtainiumState();
}

class _ObtainiumState extends State<Obtainium> {
  var existingUpdateInterval = -1;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestNonOptionalPermissions();
    });
  }

  Future<void> requestNonOptionalPermissions() async {
    final NotificationPermission notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  void initForegroundService() {
    // ignore: invalid_use_of_visible_for_testing_member
    if (!FlutterForegroundTask.isInitialized) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'bg_update',
          channelName: tr('foregroundService'),
          channelDescription: tr('foregroundService'),
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(900000),
          autoRunOnBoot: true,
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
    }
  }

  Future<ServiceRequestResult?> startForegroundService(bool restart) async {
    initForegroundService();
    if (await FlutterForegroundTask.isRunningService) {
      if (restart) {
        return FlutterForegroundTask.restartService();
      }
    } else {
      return FlutterForegroundTask.startService(
        serviceTypes: [ForegroundServiceTypes.specialUse],
        serviceId: 666,
        notificationTitle: tr('foregroundService'),
        notificationText: tr('fgServiceNotice'),
        notificationIcon: NotificationIcon(
          metaDataName: 'dev.imranr.obtainium.service.NOTIFICATION_ICON',
        ),
        callback: startCallback,
      );
    }
    return null;
  }

  Future<dynamic> stopForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.stopService();
    }
  }

  // void onReceiveForegroundServiceData(Object data) {
  //   print('onReceiveTaskData: $data');
  // }

  @override
  void dispose() {
    // Remove a callback to receive data sent from the TaskHandler.
    // FlutterForegroundTask.removeTaskDataCallback(onReceiveForegroundServiceData);
    super.dispose();
  }

  Future<void> initPlatformState() async {
    await BackgroundFetch.configure(
      BackgroundFetchConfig(
        minimumFetchInterval: 15,
        stopOnTerminate: false,
        startOnBoot: true,
        enableHeadless: true,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresStorageNotLow: false,
        requiresDeviceIdle: false,
        requiredNetworkType: NetworkType.ANY,
      ),
      (String taskId) async {
        await bgUpdateCheck(taskId, null);
        BackgroundFetch.finish(taskId);
      },
      (String taskId) async {
        context.read<LogsProvider>().add('BG update task timed out.');
        BackgroundFetch.finish(taskId);
      },
    );
    if (!mounted) return;
  }

  @override
  Widget build(BuildContext context) {
    SettingsProvider settingsProvider = context.watch<SettingsProvider>();
    AppsProvider appsProvider = context.read<AppsProvider>();
    LogsProvider logs = context.read<LogsProvider>();
    NotificationsProvider notifs = context.read<NotificationsProvider>();
    if (settingsProvider.updateInterval == 0) {
      stopForegroundService();
      BackgroundFetch.stop();
    } else {
      if (settingsProvider.useFGService) {
        BackgroundFetch.stop();
        startForegroundService(false);
      } else {
        stopForegroundService();
        BackgroundFetch.start();
      }
    }
    if (settingsProvider.prefs == null) {
      settingsProvider.initializeSettings();
    } else {
      bool isFirstRun = settingsProvider.checkAndFlipFirstRun();
      if (isFirstRun) {
        logs.add('This is the first ever run of ObtainX.');
        // If this is the first run, add ObtainX to the Apps list
        if (!fdroid) {
          getInstalledInfo(obtainiumId)
              .then((value) {
                if (value?.versionName != null) {
                  appsProvider.saveApps([
                    App(
                      obtainiumId,
                      obtainiumUrl,
                      'Bikram-Agarwal',
                      'ObtainX',
                      value!.versionName,
                      value.versionName!,
                      [],
                      0,
                      {
                        'versionDetection': true,
                        'apkFilterRegEx': 'fdroid',
                        'invertAPKFilter': true,
                      },
                      null,
                      false,
                    ),
                  ], onlyIfExists: false);
                }
              })
              .catchError((err) {
                debugPrint(err.toString());
              });
        }
      }
      if (!supportedLocales.map((e) => e.key).contains(context.locale) ||
          (settingsProvider.forcedLocale == null &&
              context.deviceLocale != context.locale)) {
        settingsProvider.resetLocaleSafe(context);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifs.checkLaunchByNotif();
    });

    return WithForegroundTask(
      child: DynamicColorBuilder(
        builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
          // Decide on a colour/brightness scheme based on OS and user settings
          ColorScheme lightColorScheme = colorSchemeForAccentSettings(
            brightness: Brightness.light,
            accentSource: settingsProvider.appAccentColorSource,
            paletteStyle: settingsProvider.appThemePaletteStyle,
            lightDynamic: lightDynamic,
            darkDynamic: darkDynamic,
            activeCustomSeedHex: settingsProvider.activeCustomSeedHex,
          );
          ColorScheme darkColorScheme = colorSchemeForAccentSettings(
            brightness: Brightness.dark,
            accentSource: settingsProvider.appAccentColorSource,
            paletteStyle: settingsProvider.appThemePaletteStyle,
            lightDynamic: lightDynamic,
            darkDynamic: darkDynamic,
            activeCustomSeedHex: settingsProvider.activeCustomSeedHex,
          );

          // set the background and surface colors to pure black in the amoled theme
          if (settingsProvider.useBlackTheme) {
            darkColorScheme = darkColorScheme
                .copyWith(surface: Colors.black)
                .harmonized();
          }

          // Boost surface containers toward primary — ports FilePipe's
          // boostSurfaceContainersTowardPrimary* logic that makes surfaces vivid.
          final bool useGradient = settingsProvider.useGradientBackground;
          lightColorScheme = lightColorScheme
              .boostSurfaceContainersTowardPrimary(
                darkTheme: false,
                useGradient: useGradient,
              );
          darkColorScheme = darkColorScheme.boostSurfaceContainersTowardPrimary(
            darkTheme: true,
            useGradient: useGradient,
          );

          if (settingsProvider.useSystemFont) NativeFeatures.loadSystemFont();

          final ColorScheme themeColorScheme =
              settingsProvider.theme == ThemeSettings.dark
              ? darkColorScheme
              : lightColorScheme;
          final ColorScheme darkThemeColorScheme =
              settingsProvider.theme == ThemeSettings.light
              ? lightColorScheme
              : darkColorScheme;

          NavigationBarThemeData navigationBarThemeFor(ColorScheme scheme) {
            // Use labelMedium as base so nav labels keep M3 size (bare color-only TextStyle inherits body scale and can wrap).
            final TextStyle navLabelBase = Theme.of(
              context,
            ).textTheme.labelMedium!;
            return NavigationBarThemeData(
              backgroundColor: scheme.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              shadowColor: Colors.transparent,
              indicatorColor: scheme.primary.withValues(alpha: 0.14),
              iconTheme: WidgetStateProperty.resolveWith((
                Set<WidgetState> states,
              ) {
                if (states.contains(WidgetState.selected)) {
                  return IconThemeData(color: scheme.primary);
                }
                return IconThemeData(color: scheme.onSurfaceVariant);
              }),
              labelTextStyle: WidgetStateProperty.resolveWith((
                Set<WidgetState> states,
              ) {
                if (states.contains(WidgetState.disabled)) {
                  return navLabelBase.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.38),
                  );
                }
                if (states.contains(WidgetState.selected)) {
                  return navLabelBase.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  );
                }
                return navLabelBase.copyWith(color: scheme.onSurfaceVariant);
              }),
            );
          }

          return MaterialApp(
            title: 'ObtainX',
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            navigatorKey: globalNavigatorKey,
            scaffoldMessengerKey: scaffoldMessengerKey,
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: themeColorScheme,
              fontFamily: settingsProvider.useSystemFont
                  ? 'SystemFont'
                  : 'Montserrat',
              navigationBarTheme: navigationBarThemeFor(themeColorScheme),
              segmentedButtonTheme: appSegmentedButtonTheme(themeColorScheme),
              switchTheme: appSwitchTheme(themeColorScheme),
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              colorScheme: darkThemeColorScheme,
              fontFamily: settingsProvider.useSystemFont
                  ? 'SystemFont'
                  : 'Montserrat',
              navigationBarTheme: navigationBarThemeFor(darkThemeColorScheme),
              segmentedButtonTheme: appSegmentedButtonTheme(
                darkThemeColorScheme,
              ),
              switchTheme: appSwitchTheme(darkThemeColorScheme),
            ),
            home: Shortcuts(
              shortcuts: <LogicalKeySet, Intent>{
                LogicalKeySet(LogicalKeyboardKey.select):
                    const ActivateIntent(),
              },
              child: const HomePage(),
            ),
          );
        },
      ),
    );
  }
}
