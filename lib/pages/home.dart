import 'dart:async';

import 'package:animations/animations.dart';
import 'package:app_links/app_links.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/add_app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/pages/import_export.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/widgets/progressive_top_edge_overlay.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class NavigationPageItem {
  late String title;
  late IconData icon;
  late Widget widget;

  NavigationPageItem(this.title, this.icon, this.widget);
}

class _HomePageState extends State<HomePage> {
  List<int> selectedIndexHistory = [];
  bool isReversing = false;
  int pageSwitchRequestId = 0;
  int prevAppCount = -1;
  bool prevIsLoading = true;
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  bool isLinkActivity = false;

  List<NavigationPageItem> pages = [
    NavigationPageItem(
      tr('appsString'),
      Icons.apps,
      AppsPage(key: GlobalKey<AppsPageState>()),
    ),
    NavigationPageItem(
      tr('addApp'),
      Icons.add,
      AddAppPage(key: GlobalKey<AddAppPageState>()),
    ),
    NavigationPageItem(
      tr('importExport'),
      Icons.import_export,
      const ImportExportPage(),
    ),
    NavigationPageItem(tr('settings'), Icons.settings, const SettingsPage()),
  ];

  @override
  void initState() {
    super.initState();
    initDeepLinks();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      var sp = context.read<SettingsProvider>();
      if (!sp.welcomeShown) {
        if (!context.mounted) return;
        await showDialog(
          context: context,
          builder: (BuildContext ctx) {
            return AlertDialog(
              title: Text(tr('welcome')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 20,
                children: [
                  Text(tr('documentationLinksNote')),
                  InkWell(
                    onTap: () {
                      launchUrlString(
                        'https://github.com/bikram-agarwal/ObtainX/blob/main/README.md',
                        mode: LaunchMode.externalApplication,
                      );
                    },
                    child: const Text(
                      'https://github.com/bikram-agarwal/ObtainX/blob/main/README.md',
                      style: TextStyle(
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  autofocus: sp.isTV,
                  onPressed: () {
                    sp.welcomeShown = true;
                    Navigator.of(context).pop(null);
                  },
                  child: Text(tr('ok')),
                ),
              ],
            );
          },
        );
      }
      if (!sp.googleVerificationWarningShown && DateTime.now().year == 2026) {
        if (!context.mounted) return;
        await showDialog(
          // ignore: use_build_context_synchronously
          context: context,
          builder: (BuildContext ctx) {
            return AlertDialog(
              title: Text(tr('note')),
              scrollable: true,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 20,
                children: [
                  Text(tr('googleVerificationWarningP1')),
                  InkWell(
                    onTap: () {
                      launchUrlString(
                        'https://keepandroidopen.org/',
                        mode: LaunchMode.externalApplication,
                      );
                    },
                    child: Text(
                      tr('googleVerificationWarningP2'),
                      style: const TextStyle(
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(tr('googleVerificationWarningP3')),
                ],
              ),
              actions: [
                TextButton(
                  autofocus: sp.isTV,
                  onPressed: () {
                    sp.googleVerificationWarningShown = true;
                    Navigator.of(context).pop(null);
                  },
                  child: Text(tr('ok')),
                ),
              ],
            );
          },
        );
      }
    });
  }

  Future<void> initDeepLinks() async {
    _appLinks = AppLinks();

    /// Waits for [key.currentState] to become non-null by checking once per
    /// frame instead of busy-looping with microsecond delays.
    Future<T> waitForState<T extends State>(GlobalKey<T> key) {
      if (key.currentState != null) return Future.value(key.currentState!);
      final completer = Completer<T>();
      void check(Duration _) {
        if (key.currentState != null) {
          completer.complete(key.currentState!);
        } else {
          WidgetsBinding.instance.addPostFrameCallback(check);
        }
      }

      WidgetsBinding.instance.addPostFrameCallback(check);
      return completer.future;
    }

    goToAddApp(String data) async {
      switchToPage(1);
      final state = await waitForState(
        pages[1].widget.key as GlobalKey<AddAppPageState>,
      );
      state.linkFn(data);
    }

    goToExistingApp(String appId) async {
      // Go to Apps page
      switchToPage(0);
      final state = await waitForState(
        pages[0].widget.key as GlobalKey<AppsPageState>,
      );
      // Navigate to the app
      state.openAppById(appId);
    }

    interpretLink(Uri uri) async {
      isLinkActivity = true;
      var action = uri.host;
      var data = uri.path.length > 1 ? uri.path.substring(1) : "";
      try {
        if (action == 'add') {
          // Ensure apps are loaded
          AppsProvider appsProvider = context.read<AppsProvider>();
          while (appsProvider.loadingApps) {
            await Future.delayed(const Duration(milliseconds: 10));
          }

          // See if we already have this app
          String standardizedUrl = SourceProvider()
              .getSource(data)
              .standardizeUrl(data);

          AppInMemory? existingApp = appsProvider.apps.values
              .where((AppInMemory a) => a.app.url == standardizedUrl)
              .firstOrNull;

          if (existingApp != null) {
            await goToExistingApp(existingApp.app.id);
          } else {
            await goToAddApp(data);
          }
        } else if (action == 'app' || action == 'apps') {
          var dataStr = Uri.decodeComponent(data);
          if (!context.mounted) return;
          if (await showDialog(
                context: context,
                builder: (BuildContext ctx) {
                  return GeneratedFormModal(
                    title: tr(
                      'importX',
                      args: [
                        (action == 'app' ? tr('app') : tr('appsString'))
                            .toLowerCase(),
                      ],
                    ),
                    items: const [],
                    additionalWidgets: [
                      ExpansionTile(
                        title: Text(tr('rawJson')),
                        children: [
                          Text(
                            dataStr,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ) !=
              null) {
            // ignore: use_build_context_synchronously
            var appsProvider = context.read<AppsProvider>();
            var result = await appsProvider.import(
              action == 'app'
                  ? '{ "apps": [$dataStr] }'
                  : '{ "apps": $dataStr }',
            );
            if (!context.mounted) return;
            showMessage(
              tr(
                'importedX',
                args: [plural('apps', result.key.length).toLowerCase()],
              ),
              context, // ignore: use_build_context_synchronously
            );
          }
        } else {
          throw ObtainiumError(tr('unknown'));
        }
      } catch (e) {
        if (!context.mounted) return;
        // ignore: use_build_context_synchronously
        showError(e, context);
      }
    }

    // Check initial link if app was in cold state (terminated)
    final appLink = await _appLinks.getInitialLink();
    var initLinked = false;
    if (appLink != null) {
      await interpretLink(appLink);
      initLinked = true;
    }
    // Handle link when app is in warm state (front or background)
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) async {
      if (!initLinked) {
        await interpretLink(uri);
      } else {
        initLinked = false;
      }
    });
  }

  void setIsReversing(int targetIndex) {
    bool reversing =
        selectedIndexHistory.isNotEmpty &&
        selectedIndexHistory.last > targetIndex;
    setState(() {
      isReversing = reversing;
    });
  }

  NavigationBar _materialHomeNavigationBar({
    required List<NavigationDestination> destinations,
    required int selectedIndex,
    required bool transparent,
  }) {
    return NavigationBar(
      backgroundColor: transparent ? Colors.transparent : null,
      surfaceTintColor: transparent ? Colors.transparent : null,
      elevation: transparent ? 0 : null,
      shadowColor: transparent ? Colors.transparent : null,
      destinations: destinations,
      onDestinationSelected: (int index) async {
        HapticFeedback.selectionClick();
        switchToPage(index);
      },
      selectedIndex: selectedIndex,
    );
  }

  Future<void> switchToPage(int index) async {
    final int activeIndex = selectedIndexHistory.isEmpty
        ? 0
        : selectedIndexHistory.last;
    if (activeIndex == index) {
      return;
    }

    if (!await _confirmActivePageCanNavigateAway(activeIndex)) {
      return;
    }
    if (!mounted) {
      return;
    }

    pageSwitchRequestId += 1;
    final int currentRequestId = pageSwitchRequestId;

    setIsReversing(index);
    if (index == 0) {
      while ((pages[0].widget.key as GlobalKey<AppsPageState>).currentState !=
          null) {
        // Avoid duplicate GlobalKey error
        await Future.delayed(const Duration(microseconds: 1));
      }
      if (!mounted || currentRequestId != pageSwitchRequestId) {
        return;
      }
      setState(() {
        selectedIndexHistory.clear();
      });
    } else if (selectedIndexHistory.isEmpty ||
        (selectedIndexHistory.isNotEmpty &&
            selectedIndexHistory.last != index)) {
      if (!mounted || currentRequestId != pageSwitchRequestId) {
        return;
      }
      setState(() {
        int existingIndex = selectedIndexHistory.indexOf(index);
        if (existingIndex >= 0) {
          selectedIndexHistory.removeAt(existingIndex);
        }
        selectedIndexHistory.add(index);
      });
    }
  }

  Future<bool> _confirmActivePageCanNavigateAway(int activeIndex) async {
    final currentKey = pages[activeIndex].widget.key;
    if (currentKey is GlobalKey<AddAppPageState>) {
      return currentKey.currentState?.confirmCancelBulkScanForNavigation() ??
          true;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // Only the app-count, loading flag, and update count are needed here;
    // using select() avoids rebuilding the home scaffold on every
    // download-progress notification.
    final (int appsCount, bool isLoading, int updateCount) = context
        .select<AppsProvider, (int, bool, int)>(
          (p) => (
            p.apps.length,
            p.loadingApps,
            p
                .findExistingUpdates(
                  installedOnly: true,
                  excludeOnDemandOnly: true,
                  includeVersionOrderUncertain: true,
                )
                .length,
          ),
        );
    // Subscribe only to the three settings home.dart actually reads in
    // build (blur toggle, page-transition disable, reverse direction).
    // Without this, every notify on SettingsProvider rebuilt the entire
    // navigation shell — including the apps page IndexedStack child.
    context.select<SettingsProvider, int>(
      (s) => Object.hash(
        s.progressiveBlurEnabled,
        s.disablePageTransitions,
        s.reversePageTransitions,
      ),
    );
    SettingsProvider settingsProvider = context.read<SettingsProvider>();

    final AddAppPageState? addPageState =
        (pages[1].widget.key as GlobalKey<AddAppPageState>).currentState;
    if (!prevIsLoading &&
        prevAppCount >= 0 &&
        appsCount > prevAppCount &&
        selectedIndexHistory.isNotEmpty &&
        selectedIndexHistory.last == 1 &&
        !isLinkActivity &&
        !(addPageState?.isBulkAdding ?? false)) {
      switchToPage(0);
    }
    prevAppCount = appsCount;
    prevIsLoading = isLoading;

    return PopScope(
      canPop:
          isLinkActivity &&
          selectedIndexHistory.length == 1 &&
          selectedIndexHistory.last == 1,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        final int activeIndex = selectedIndexHistory.isEmpty
            ? 0
            : selectedIndexHistory.last;
        final currentKey = pages[activeIndex].widget.key;
        if (currentKey is GlobalKey<AddAppPageState>) {
          final AddAppPageState? addAppPageState = currentKey.currentState;
          if (addAppPageState != null) {
            if (!await addAppPageState.confirmCancelBulkScanForNavigation()) {
              return;
            }
            if (!mounted || !addAppPageState.mounted) {
              return;
            }
            if (addAppPageState.handleBack()) return;
          }
        }
        if (currentKey is GlobalKey<AppsPageState>) {
          if (currentKey.currentState?.handleBack() == true) return;
        }
        setIsReversing(
          selectedIndexHistory.length >= 2
              ? selectedIndexHistory.reversed.toList()[1]
              : 0,
        );
        if (selectedIndexHistory.isNotEmpty) {
          setState(() {
            selectedIndexHistory.removeLast();
          });
          return;
        }
        final AppsPageState? appsPageState =
            (pages[0].widget.key as GlobalKey<AppsPageState>).currentState;
        if (appsPageState == null || !appsPageState.handleBack()) {
          // Root route: Navigator.pop would remove [HomePage] and leave an empty
          // [MaterialApp] (black screen). Minimize/finish the activity instead.
          SystemNavigator.pop();
        }
      },
      child: Builder(
        builder: (BuildContext context) {
          final ColorScheme scheme = Theme.of(context).colorScheme;
          final bool blurBottomNav = settingsProvider.progressiveBlurEnabled;
          final List<NavigationDestination> homeNavDestinations = pages
              .asMap()
              .entries
              .map(
                (MapEntry<int, NavigationPageItem> entry) =>
                    NavigationDestination(
                      icon: entry.key == 0 && updateCount > 0
                          ? Badge(
                              label: Text(updateCount.toString()),
                              child: Icon(entry.value.icon),
                            )
                          : Icon(entry.value.icon),
                      label: entry.value.title,
                    ),
              )
              .toList();
          final int homeNavSelectedIndex = selectedIndexHistory.isEmpty
              ? 0
              : selectedIndexHistory.last;

          return Scaffold(
            backgroundColor: scheme.surface,
            extendBody: blurBottomNav,
            body: Stack(
              fit: StackFit.expand,
              children: [
                SizedBox.expand(
                  child: PageTransitionSwitcher(
                    duration: Duration(
                      milliseconds: settingsProvider.disablePageTransitions
                          ? 0
                          : 300,
                    ),
                    reverse: settingsProvider.reversePageTransitions
                        ? !isReversing
                        : isReversing,
                    transitionBuilder:
                        (
                          Widget child,
                          Animation<double> animation,
                          Animation<double> secondaryAnimation,
                        ) {
                          return SharedAxisTransition(
                            animation: animation,
                            secondaryAnimation: secondaryAnimation,
                            transitionType: SharedAxisTransitionType.horizontal,
                            child: child,
                          );
                        },
                    child: pages
                        .elementAt(
                          selectedIndexHistory.isEmpty
                              ? 0
                              : selectedIndexHistory.last,
                        )
                        .widget,
                  ),
                ),
              ],
            ),
            bottomNavigationBar: blurBottomNav
                ? ClipRect(
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      fit: StackFit.loose,
                      children: [
                        Positioned.fill(
                          child: ProgressiveBottomEdgeBlur(
                            overlayColor:
                                scheme.schemeProgressiveBlurOverlayTint,
                          ),
                        ),
                        _materialHomeNavigationBar(
                          destinations: homeNavDestinations,
                          selectedIndex: homeNavSelectedIndex,
                          transparent: true,
                        ),
                      ],
                    ),
                  )
                : _materialHomeNavigationBar(
                    destinations: homeNavDestinations,
                    selectedIndex: homeNavSelectedIndex,
                    transparent: false,
                  ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    _linkSubscription?.cancel();
  }
}
