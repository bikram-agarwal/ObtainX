import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/layout_breakpoints.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/add_app.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/pages/import_export.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/shared_url_receiver.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/widgets/progressive_top_edge_overlay.dart';
import 'package:provider/provider.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class NavigationPageItem {
  late String title;
  late IconData icon;
  late Widget widget;

  NavigationPageItem(this.title, this.icon, this.widget);
}

class HomePageState extends State<HomePage> {
  List<int> selectedIndexHistory = [];
  int pageSwitchRequestId = 0;
  int prevAppCount = -1;
  bool prevIsLoading = true;
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  final SharedUrlReceiver _sharedUrlReceiver = SharedUrlReceiver();
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
      Icons.backup_outlined,
      const ImportExportPage(),
    ),
    NavigationPageItem(
      tr('settings'),
      Icons.settings,
      SettingsPage(key: GlobalKey<SettingsPageState>()),
    ),
  ];

  @override
  void initState() {
    super.initState();
    initDeepLinks();
  }

  /// Waits for [key.currentState] to become non-null by checking once per
  /// frame instead of busy-looping with microsecond delays.
  Future<T> _waitForState<T extends State>(GlobalKey<T> key) {
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

  Future<void> switchToAppsTabAndOpenApp(String appId) async {
    await switchToPage(0);
    final state = await _waitForState(
      pages[0].widget.key as GlobalKey<AppsPageState>,
    );
    state.openAppById(appId);
  }

  Future<void> initDeepLinks() async {
    _appLinks = AppLinks();

    goToAddApp(String data) async {
      switchToPage(1);
      final state = await _waitForState(
        pages[1].widget.key as GlobalKey<AddAppPageState>,
      );
      state.linkFn(data);
    }

    goToExistingApp(String appId) async {
      // Go to Apps page
      switchToPage(0);
      final state = await _waitForState(
        pages[0].widget.key as GlobalKey<AppsPageState>,
      );
      // Navigate to the app
      state.openAppById(appId);
    }

    handleAddUrl(String data) async {
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
    }

    handleSharedText(String sharedText) async {
      isLinkActivity = true;
      final String? sharedUrl = SharedUrlReceiver.extractFirstUrl(sharedText);
      if (sharedUrl == null) {
        if (!context.mounted) return;
        showError(UnsupportedURLError(), context);
        return;
      }
      try {
        await handleAddUrl(sharedUrl);
      } catch (e) {
        if (!context.mounted) return;
        // ignore: use_build_context_synchronously
        showError(e, context);
      }
    }

    interpretLink(Uri uri) async {
      isLinkActivity = true;
      var action = uri.host;
      var data = uri.path.length > 1 ? uri.path.substring(1) : "";
      try {
        if (action == 'add') {
          await handleAddUrl(data);
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
    _sharedUrlReceiver.listen(handleSharedText);
    final String? initialSharedText = await _sharedUrlReceiver
        .getInitialSharedText();
    if (initialSharedText != null) {
      await handleSharedText(initialSharedText);
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
        hapticSelection();
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

    if (index == 0) {
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
    if (currentKey is GlobalKey<SettingsPageState>) {
      return currentKey.currentState?.confirmDiscardUnsavedChanges() ?? true;
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
          (p) => (p.apps.length, p.loadingApps, p.pendingUpdateCount),
        );
    // Only the blur toggle is read in build now; page-transition settings
    // are unused after switching to IndexedStack.
    context.select<SettingsProvider, bool>((s) => s.progressiveBlurEnabled);
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
        if (currentKey is GlobalKey<SettingsPageState>) {
          final SettingsPageState? settingsPageState = currentKey.currentState;
          if (settingsPageState != null) {
            if (!await settingsPageState.confirmDiscardUnsavedChanges()) {
              return;
            }
          }
        }
        if (currentKey is GlobalKey<AppsPageState>) {
          if (currentKey.currentState?.handleBack() == true) return;
        }
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
          final double screenWidth = MediaQuery.sizeOf(context).width;
          final bool isLargeScreen = screenWidth >= kLargeScreenWidthBreakpoint;

          // Shared icon builder (adds the update-count badge to the first tab),
          // and build only the destination list the current layout actually
          // uses instead of both every frame.
          Widget navIcon(MapEntry<int, NavigationPageItem> entry) =>
              entry.key == 0 && updateCount > 0
              ? Badge(
                  label: Text(updateCount.toString()),
                  child: Icon(entry.value.icon),
                )
              : Icon(entry.value.icon);

          final List<NavigationDestination> homeNavDestinations = isLargeScreen
              ? const <NavigationDestination>[]
              : pages
                    .asMap()
                    .entries
                    .map(
                      (entry) => NavigationDestination(
                        icon: navIcon(entry),
                        label: entry.value.title,
                      ),
                    )
                    .toList();

          // NavigationRailDestination.selectedIcon defaults to [icon] when
          // omitted, so the previous explicit duplicate isn't needed.
          final List<NavigationRailDestination> homeNavRailDestinations =
              isLargeScreen
              ? pages
                    .asMap()
                    .entries
                    .map(
                      (entry) => NavigationRailDestination(
                        icon: navIcon(entry),
                        label: Text(entry.value.title),
                      ),
                    )
                    .toList()
              : const <NavigationRailDestination>[];

          final int homeNavSelectedIndex = selectedIndexHistory.isEmpty
              ? 0
              : selectedIndexHistory.last;

          return Scaffold(
            // Don't resize the shell for the keyboard. A resize relays-out and
            // lifts the bottom nav bar every frame of the keyboard animation,
            // and the nav bar's progressive blur (a BackdropFilter) re-rasterizes
            // on each of those frames — that is the staggered nav-bar slide and
            // the keyboard-slide stutter. With this off the nav bar stays put and
            // the keyboard simply overlays it, so the blur is never re-rastered.
            // Note this also stops the shell consuming the bottom inset, so it
            // reaches the nested Apps/Add-App Scaffolds — they are deliberately
            // resizeToAvoidBottomInset:false too, because extendBody draws their
            // bodies behind this blurred nav bar and a per-frame body relayout
            // would re-raster the blur and bring the stutter back. Trade-off:
            // the keyboard overlays bottom content rather than pushing it up
            // (the search/URL fields are top-anchored, so they stay visible).
            resizeToAvoidBottomInset: false,
            backgroundColor: scheme.surface,
            extendBody: blurBottomNav && !isLargeScreen,
            body: isLargeScreen
                ? Builder(
                    builder: (BuildContext context) {
                      return Row(
                        children: [
                          MediaQuery(
                            data: MediaQuery.of(context).copyWith(
                              padding: MediaQuery.of(context).padding.copyWith(
                                left: MediaQuery.of(context).padding.left > 0
                                    ? 24.0
                                    : 0.0,
                                right: MediaQuery.of(context).padding.right > 0
                                    ? 24.0
                                    : 0.0,
                              ),
                            ),
                            child: NavigationRail(
                              selectedIndex: homeNavSelectedIndex,
                              onDestinationSelected: (int index) async {
                                hapticSelection();
                                switchToPage(index);
                              },
                              labelType: NavigationRailLabelType.all,
                              destinations: homeNavRailDestinations,
                              backgroundColor: scheme.surface,
                            ),
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: scheme.outlineVariant.withAlpha(50),
                          ),
                          Expanded(
                            child: MediaQuery.removePadding(
                              context: context,
                              removeLeft: true,
                              removeRight: true,
                              child: IndexedStack(
                                index: homeNavSelectedIndex,
                                children: pages.map((p) => p.widget).toList(),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      // IndexedStack keeps all four pages mounted so tab switches
                      // are a single paint op — no rebuild, no tear-down.
                      IndexedStack(
                        index: homeNavSelectedIndex,
                        children: pages.map((p) => p.widget).toList(),
                      ),
                    ],
                  ),
            bottomNavigationBar: isLargeScreen
                ? null
                : blurBottomNav
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
    _linkSubscription?.cancel();
    _sharedUrlReceiver.dispose();
    super.dispose();
  }
}
