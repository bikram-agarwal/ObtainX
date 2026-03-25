import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/page_route_slide_up.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:markdown/markdown.dart' as md;

const double _appsListGroupCardRadius = 20;

/// Fingerprint so [AppsPage] rebuilds only when app-list data changes,
/// not on every [AppsProvider.notifyListeners] (e.g. download-progress ticks
/// or icon-load completions — icons are watched per-row by [_AppIconWidget]).
int _appsPageAppsRebuildToken(AppsProvider provider) {
  return Object.hashAll([
    provider.loadingApps,
    provider.areDownloadsRunning(),
    ...provider.apps.values.map(
      (a) => Object.hashAll([
        a.app.id,
        a.app.name,
        a.app.author,
        a.app.latestVersion,
        a.app.installedVersion,
        a.app.lastUpdateCheck,
        a.app.pinned,
        a.app.categories.length,
        Object.hashAll(a.app.categories),
        a.app.additionalSettings['onDemandOnly'] == true,
        a.app.additionalSettings['skippedLatestVersion'],
        // Icon fields deliberately excluded: each row watches its own icon
        // via _AppIconWidget.context.select, so icon loads only rebuild that
        // one row widget instead of the entire apps list.
      ]),
    ),
  ]);
}

/// An isolated icon widget that subscribes only to its own app's icon bytes.
/// When an icon finishes loading, only this widget rebuilds — not [AppsPage].
class _AppIconWidget extends StatelessWidget {
  const _AppIconWidget({required this.appId});

  final String appId;

  @override
  Widget build(BuildContext context) {
    final (Uint8List? icon, bool notInstalled) =
        context.select<AppsProvider, (Uint8List?, bool)>(
      (p) {
        final a = p.apps[appId];
        return (a?.icon, a?.installedInfo == null);
      },
    );
    if (icon != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          icon,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          opacity: AlwaysStoppedAnimation(notInstalled ? 0.6 : 1.0),
        ),
      );
    }
    // Placeholder shown while the icon is still loading.
    return SizedBox(
      width: 40,
      height: 40,
      child: Center(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.rotationZ(0.31),
          child: Image(
            image: const AssetImage('assets/graphics/icon_small.png'),
            width: 28,
            height: 28,
            fit: BoxFit.contain,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.3),
            colorBlendMode: BlendMode.modulate,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

/// A single row in the apps list.
///
/// Pushes [AppPage] with a bottom sheet style slide-up so it reads as opening
/// from the bottom bar / actions.

/// Subscribes directly to [AppsProvider] for [AppInMemory.downloadProgress]
/// so download-progress ticks only rebuild the one row that is downloading,
/// not the entire page.  All other per-row data is received from the parent
/// (already gated behind the page-level list-build token).
class _AppListItem extends StatelessWidget {
  const _AppListItem({
    required this.appId,
    required this.isSelected,
    required this.areDownloadsRunning,
    required this.iconWidget,
    required this.onTap,
    required this.onLongPress,
    required this.highlightTouchTargets,
    required this.categoryColors,
  });

  final String appId;
  final bool isSelected;
  final bool areDownloadsRunning;
  final Widget iconWidget;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool highlightTouchTargets;
  final Map<String?, int> categoryColors;

  @override
  Widget build(BuildContext context) {
    // Full app data — rebuilds when any field changes (gated by page token).
    final AppInMemory? app =
        context.select<AppsProvider, AppInMemory?>((p) => p.apps[appId]);
    if (app == null) return const SizedBox.shrink();

    // Download progress watched independently so only this row rebuilds on ticks.
    final double? downloadProgress = context
        .select<AppsProvider, double?>((p) => p.apps[appId]?.downloadProgress);

    final showChangesFn = getChangeLogFn(context, app.app);
    final installed = app.app.installedVersion;
    final hasUpdate =
        installed != null && appHasActionableUpdate(app.app);
    final hasUncertainUpdate =
        installed != null && versionOrderUncertainUpdate(app.app);

    void onUpdateOrOpenReleasePressed() {
      final trackOnly = app.app.additionalSettings['trackOnly'] == true;
      if (trackOnly) {
        launchUrlString(
          trackOnlyDownloadPageUrl(app.app),
          mode: LaunchMode.externalApplication,
        );
      } else {
        context
            .read<AppsProvider>()
            .downloadAndInstallLatestApps(
                [app.app.id], globalNavigatorKey.currentContext)
            .catchError((e) {
          if (!context.mounted) return <String>[];
          showError(e, context);
          return <String>[];
        });
      }
    }

    Widget buildUpdateButton() {
      final trackOnly = app.app.additionalSettings['trackOnly'] == true;
      return IconButton(
        visualDensity: VisualDensity.compact,
        color: Theme.of(context).colorScheme.primary,
        tooltip: trackOnly ? tr('openDownloadPage') : tr('update'),
        onPressed:
            areDownloadsRunning ? null : onUpdateOrOpenReleasePressed,
        icon: const Icon(Icons.install_mobile),
      );
    }

    Widget buildUncertainUpdateButton() {
      return IconButton(
        visualDensity: VisualDensity.compact,
        color: Theme.of(context).colorScheme.primary,
        tooltip: tr('uncertainUpdateTooltip'),
        onPressed:
            areDownloadsRunning ? null : onUpdateOrOpenReleasePressed,
        icon: const Icon(Icons.help_outline),
      );
    }

    final String versionText =
        app.app.installedVersion ?? tr('notInstalled');
    final String changesButtonString = app.app.releaseDate == null
        ? (showChangesFn != null ? tr('changes') : '')
        : DateFormat('yyyy-MM-dd').format(app.app.releaseDate!.toLocal());

    final Widget trailingRow = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasUpdate) ...[buildUpdateButton(), const SizedBox(width: 5)],
        if (!hasUpdate && hasUncertainUpdate) ...[
          buildUncertainUpdateButton(),
          const SizedBox(width: 5),
        ],
        GestureDetector(
          onTap: showChangesFn,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: highlightTouchTargets && showChangesFn != null
                  ? (Theme.of(context).brightness == Brightness.light
                            ? Theme.of(context).primaryColor
                            : Theme.of(context).primaryColorLight)
                        .withAlpha(
                          Theme.of(context).brightness == Brightness.light
                              ? 20
                              : 40,
                        )
                  : null,
            ),
            padding: highlightTouchTargets
                ? const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 0)
                : const EdgeInsetsDirectional.fromSTEB(24, 0, 0, 0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width / 4,
                      ),
                      child: Text(
                        versionText,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: isVersionPseudo(app.app)
                            ? const TextStyle(fontStyle: FontStyle.italic)
                            : null,
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      changesButtonString,
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        decoration: showChangesFn != null
                            ? TextDecoration.underline
                            : TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );

    final int transparent =
        Theme.of(context).colorScheme.surface.withValues(alpha: 0).toARGB32();
    List<double> stops = [
      ...app.app.categories.asMap().entries.map(
        (e) =>
            ((e.key / (app.app.categories.length - 1)) - 0.0001),
      ),
      1,
    ];
    if (stops.length == 2) stops[0] = 0.9999;

    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            stops: stops,
            begin: const Alignment(-1, 0),
            end: const Alignment(-0.97, 0),
            colors: [
              ...app.app.categories.map(
                (e) =>
                    Color(categoryColors[e] ?? transparent).withAlpha(255),
              ),
              Color(transparent),
            ],
          ),
        ),
        child: ListTile(
          tileColor: app.app.pinned
              ? Colors.grey.withValues(alpha: 0.1)
              : Colors.transparent,
          selectedTileColor:
              Theme.of(context).colorScheme.primary.withValues(
            alpha: app.app.pinned ? 0.2 : 0.1,
          ),
          selected: isSelected,
          onLongPress: onLongPress,
          leading: iconWidget,
          title: Text(
            app.name,
            maxLines: 1,
            style: TextStyle(
              overflow: TextOverflow.ellipsis,
              fontWeight:
                  app.app.pinned ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            tr('byX', args: [app.author]),
            maxLines: 1,
            style: TextStyle(
              overflow: TextOverflow.ellipsis,
              fontWeight:
                  app.app.pinned ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          trailing: downloadProgress != null
              ? SizedBox(
                  child: Text(
                    downloadProgress >= 0
                        ? tr('percentProgress',
                            args: [downloadProgress.toInt().toString()])
                        : tr('installing'),
                    textAlign: downloadProgress >= 0
                        ? TextAlign.start
                        : TextAlign.end,
                  ),
                )
              : trailingRow,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// Opens the full-screen Additional Options page (same transition as [AppPage]).
Future<void> _openAdditionalOptionsModal(
  String appId,
  BuildContext context,
) async {
  final appsProvider = context.read<AppsProvider>();
  if (appsProvider.apps[appId] == null) return;
  if (!context.mounted) return;
  await Navigator.push<void>(
    context,
    slideUpPageRoute(
      (_) => AdditionalOptionsPage(appId: appId),
    ),
  );
}

/// Wraps a list row with horizontal-swipe action hints.
/// The left/right actions are configurable via [SettingsProvider].
class _SwipeableListItem extends StatefulWidget {
  const _SwipeableListItem({
    super.key,
    required this.appId,
    required this.hasUpdate,
    required this.isPinned,
    required this.isInstalled,
    required this.areDownloadsRunning,
    required this.keepAlive,
    required this.rightAction,
    required this.leftAction,
    required this.child,
  });

  final String appId;
  final bool hasUpdate;
  final bool isPinned;
  final bool isInstalled;
  final bool areDownloadsRunning;
  final bool keepAlive;
  final SwipeAction rightAction;
  final SwipeAction leftAction;
  final Widget child;

  @override
  State<_SwipeableListItem> createState() => _SwipeableListItemState();
}

class _SwipeableListItemState extends State<_SwipeableListItem>
    with AutomaticKeepAliveClientMixin {
  double _dragOffset = 0;

  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(_SwipeableListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) updateKeepAlive();
  }

  bool _canExecute(SwipeAction action) {
    switch (action) {
      case SwipeAction.update:
        return (widget.hasUpdate || !widget.isInstalled) &&
            !widget.areDownloadsRunning;
      case SwipeAction.open:
        return widget.isInstalled;
      case SwipeAction.none:
        return false;
      default:
        return true;
    }
  }

  (IconData, Color) _actionVisuals(SwipeAction action, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (action) {
      case SwipeAction.update:
        return (Icons.install_mobile, Colors.green);
      case SwipeAction.pin:
        return (
          widget.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
          cs.primary,
        );
      case SwipeAction.appOptions:
        return (Icons.tune, cs.primary);
      case SwipeAction.edit:
        return (Icons.edit_outlined, Colors.blue);
      case SwipeAction.delete:
        return (Icons.delete_outline, Colors.red);
      case SwipeAction.open:
        return (Icons.open_in_new, Colors.orange);
      case SwipeAction.appInfo:
        return (Icons.info_outline, Colors.teal);
      case SwipeAction.none:
        return (Icons.circle, Colors.transparent);
    }
  }

  Future<void> _executeAction(SwipeAction action, BuildContext context) async {
    final provider = context.read<AppsProvider>();
    final app = provider.apps[widget.appId]?.app;
    switch (action) {
      case SwipeAction.update:
        final isTrackOnly = app?.additionalSettings['trackOnly'] == true;
        if (isTrackOnly && app != null) {
          launchUrlString(
            trackOnlyDownloadPageUrl(app),
            mode: LaunchMode.externalApplication,
          );
        } else {
          provider
              .downloadAndInstallLatestApps(
                  [widget.appId], globalNavigatorKey.currentContext)
              .catchError((e) {
            showError(e, globalNavigatorKey.currentContext!);
            return <String>[];
          });
        }
      case SwipeAction.pin:
        if (app != null) {
          provider.saveApps([app..pinned = !widget.isPinned]);
        }
      case SwipeAction.appOptions:
        await _openAdditionalOptionsModal(widget.appId, context);
      case SwipeAction.edit:
        if (context.mounted) {
          await Navigator.push(
            context,
            heroFriendlyAppPageRoute(
              (_) => AppPage(
                appId: widget.appId,
                openInEditMode: true,
              ),
            ),
          );
        }
      case SwipeAction.delete:
        if (app != null) {
          // Capture messenger before the await – the widget may be disposed after removal
          final messenger = scaffoldMessengerKey.currentState;
          final RemoveAppsWithModalResult removeResult =
              await provider.removeAppsWithModal(context, [app]);
          if (removeResult.shouldShowSnackBar) {
            final Set<String> undoAppIds = removeResult.deferredUndoAppIds;
            messenger
              ?..clearSnackBars()
              ..showSnackBar(
                SnackBar(
                  content: Text(tr('xAppsRemoved', args: ['1'])),
                  persist: false,
                  duration: const Duration(seconds: 5),
                  behavior: SnackBarBehavior.floating,
                  action: undoAppIds.isNotEmpty
                      ? SnackBarAction(
                          label: tr('undo'),
                          onPressed: () => provider
                              .undoDeferredObtainiumRemovals(undoAppIds),
                        )
                      : null,
                ),
              );
          }
        }
      case SwipeAction.open:
        pm.openApp(widget.appId);
      case SwipeAction.appInfo:
        provider.openAppSettings(widget.appId);
      case SwipeAction.none:
        break;
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    const swipeThreshold = 80.0;
    const maxDrag = 120.0;

    final canSwipeRight = _canExecute(widget.rightAction);
    final canSwipeLeft = _canExecute(widget.leftAction);

    Color bgColor;
    IconData bgIcon;
    Alignment bgAlign;
    Color iconColor;

    if (_dragOffset > 0 && canSwipeRight) {
      final (icon, color) = _actionVisuals(widget.rightAction, context);
      bgColor = color.withValues(alpha: 0.25);
      bgIcon = icon;
      bgAlign = Alignment.centerLeft;
      iconColor = color;
    } else if (_dragOffset < 0 && canSwipeLeft) {
      final (icon, color) = _actionVisuals(widget.leftAction, context);
      bgColor = color.withValues(alpha: 0.20);
      bgIcon = icon;
      bgAlign = Alignment.centerRight;
      iconColor = color;
    } else {
      bgColor = Colors.transparent;
      bgIcon = Icons.circle;
      bgAlign = Alignment.center;
      iconColor = Colors.transparent;
    }

    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        setState(() {
          _dragOffset += details.delta.dx;
          _dragOffset = _dragOffset.clamp(
            canSwipeLeft ? -maxDrag : 0.0,
            canSwipeRight ? maxDrag : 0.0,
          );
        });
      },
      onHorizontalDragEnd: (_) {
        if (_dragOffset > swipeThreshold && canSwipeRight) {
          _executeAction(widget.rightAction, context);
        } else if (_dragOffset < -swipeThreshold && canSwipeLeft) {
          _executeAction(widget.leftAction, context);
        }
        setState(() => _dragOffset = 0);
      },
      onHorizontalDragCancel: () => setState(() => _dragOffset = 0),
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                color: bgColor,
                alignment: bgAlign,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Icon(bgIcon, color: iconColor),
              ),
            ),
            Transform.translate(
              offset: Offset(_dragOffset, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}

class AppsPage extends StatefulWidget {
  const AppsPage({super.key, this.onDemandOnlyList = false});

  /// When true, only apps with [App.additionalSettings] `onDemandOnly` are listed
  /// and pull-to-refresh checks only those IDs.
  final bool onDemandOnlyList;

  @override
  State<AppsPage> createState() => AppsPageState();
}

void showChangeLogDialog(
  BuildContext context,
  App app,
  String? changesUrl,
  AppSource appSource,
  String changeLog,
) {
  showDialog(
    context: context,
    builder: (BuildContext context) {
      return GeneratedFormModal(
        title: tr('changes'),
        items: const [],
        message: app.latestVersion,
        additionalWidgets: [
          changesUrl != null
              ? GestureDetector(
                  child: Text(
                    changesUrl,
                    style: const TextStyle(
                      decoration: TextDecoration.underline,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  onTap: () {
                    launchUrlString(
                      changesUrl,
                      mode: LaunchMode.externalApplication,
                    );
                  },
                )
              : const SizedBox.shrink(),
          changesUrl != null
              ? const SizedBox(height: 16)
              : const SizedBox.shrink(),
          appSource.changeLogIfAnyIsMarkDown
              ? SizedBox(
                  width: MediaQuery.of(context).size.width,
                  height: MediaQuery.of(context).size.height - 350,
                  child: Markdown(
                    styleSheet: MarkdownStyleSheet(
                      blockquoteDecoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                      ),
                    ),
                    data: changeLog,
                    onTapLink: (text, href, title) {
                      if (href != null) {
                        launchUrlString(
                          href.startsWith('http://') ||
                                  href.startsWith('https://')
                              ? href
                              : '${Uri.parse(app.url).origin}/$href',
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                    extensionSet: md.ExtensionSet(
                      md.ExtensionSet.gitHubFlavored.blockSyntaxes,
                      [
                        md.EmojiSyntax(),
                        ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
                      ],
                    ),
                  ),
                )
              : Text(changeLog),
        ],
        singleNullReturnButton: tr('ok'),
      );
    },
  );
}

Null Function()? getChangeLogFn(BuildContext context, App app) {
  AppSource appSource = SourceProvider().getSource(
    app.url,
    overrideSource: app.overrideSource,
  );
  String? changesUrl = appSource.changeLogPageFromStandardUrl(app.url);
  String? changeLog = app.changeLog;
  if (changeLog?.split('\n').length == 1) {
    if (RegExp(
      '(http|ftp|https)://([\\w_-]+(?:(?:\\.[\\w_-]+)+))([\\w.,@?^=%&:/~+#-]*[\\w@?^=%&/~+#-])?',
    ).hasMatch(changeLog!)) {
      if (changesUrl == null) {
        changesUrl = changeLog;
        changeLog = null;
      }
    }
  }
  return (changeLog == null && changesUrl == null)
      ? null
      : () {
          if (changeLog != null) {
            showChangeLogDialog(context, app, changesUrl, appSource, changeLog);
          } else {
            launchUrlString(changesUrl!, mode: LaunchMode.externalApplication);
          }
        };
}

void showAppsViewOptionsSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      final bottomInset = MediaQuery.viewPaddingOf(sheetContext).bottom;
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final settingsProvider = ctx.watch<SettingsProvider>();
          final colorScheme = Theme.of(ctx).colorScheme;
          final textTheme = Theme.of(ctx).textTheme;

          Widget sectionLabel(String text) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 4),
              child: Text(
                text,
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            );
          }

          Widget sortChip({
            required String label,
            required bool selected,
            required VoidCallback onTap,
          }) {
            return FilterChip(
              label: Text(label),
              selected: selected,
              onSelected: (_) => onTap(),
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
            );
          }

          Widget themeIconButton({
            required IconData icon,
            required String tooltip,
            required bool selected,
            required VoidCallback? onPressed,
          }) {
            return IconButton(
              tooltip: tooltip,
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                backgroundColor: selected
                    ? colorScheme.primaryContainer
                    : null,
                foregroundColor: selected
                    ? colorScheme.onPrimaryContainer
                    : null,
              ),
              onPressed: onPressed,
              icon: Icon(icon),
            );
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottomInset),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant.withAlpha(80),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Text(
                      tr('appsViewOptions'),
                      style: textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    sectionLabel(tr('theme')),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: FutureBuilder(
                        future: DeviceInfoPlugin().androidInfo,
                        builder: (context, snapshot) {
                          final sdkInt = snapshot.data?.version.sdkInt ?? 0;
                          final showMaterialYou = sdkInt >= 31;
                          final themeModeBlack =
                              settingsProvider.useBlackTheme;
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              if (showMaterialYou) ...[
                                themeIconButton(
                                  icon: Icons.palette_outlined,
                                  tooltip: tr('useMaterialYou'),
                                  selected: settingsProvider.useMaterialYou,
                                  onPressed: () {
                                    settingsProvider.useMaterialYou =
                                        !settingsProvider.useMaterialYou;
                                    setSheetState(() {});
                                  },
                                ),
                                const SizedBox(width: 16),
                              ],
                              themeIconButton(
                                icon: Icons.brightness_auto,
                                tooltip: tr('followSystem'),
                                selected: settingsProvider.theme ==
                                        ThemeSettings.system &&
                                    !themeModeBlack,
                                onPressed: () {
                                  settingsProvider.useBlackTheme = false;
                                  settingsProvider.theme =
                                      ThemeSettings.system;
                                  setSheetState(() {});
                                },
                              ),
                              const SizedBox(width: 10),
                              themeIconButton(
                                icon: Icons.light_mode_outlined,
                                tooltip: tr('light'),
                                selected: settingsProvider.theme ==
                                        ThemeSettings.light &&
                                    !themeModeBlack,
                                onPressed: () {
                                  settingsProvider.useBlackTheme = false;
                                  settingsProvider.theme =
                                      ThemeSettings.light;
                                  setSheetState(() {});
                                },
                              ),
                              const SizedBox(width: 10),
                              themeIconButton(
                                icon: Icons.dark_mode_outlined,
                                tooltip: tr('dark'),
                                selected: settingsProvider.theme ==
                                        ThemeSettings.dark &&
                                    !themeModeBlack,
                                onPressed: () {
                                  settingsProvider.useBlackTheme = false;
                                  settingsProvider.theme =
                                      ThemeSettings.dark;
                                  setSheetState(() {});
                                },
                              ),
                              const SizedBox(width: 10),
                              themeIconButton(
                                icon: Icons.square,
                                tooltip: tr('useBlackTheme'),
                                selected: themeModeBlack,
                                onPressed: () {
                                  if (themeModeBlack) {
                                    settingsProvider.useBlackTheme = false;
                                    settingsProvider.theme =
                                        ThemeSettings.dark;
                                  } else {
                                    settingsProvider.theme =
                                        ThemeSettings.dark;
                                    settingsProvider.useBlackTheme = true;
                                  }
                                  setSheetState(() {});
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('matchAppPageToIconColors')),
                      value: settingsProvider.matchAppPageToIconColors,
                      onChanged: (value) {
                        settingsProvider.matchAppPageToIconColors = value;
                        setSheetState(() {});
                      },
                    ),
                    const SizedBox(height: 16),
                    Divider(color: colorScheme.outlineVariant),
                    const SizedBox(height: 8),
                    sectionLabel(tr('sortBy')),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        sortChip(
                          label: tr('authorName'),
                          selected: settingsProvider.sortColumn ==
                              SortColumnSettings.authorName,
                          onTap: () {
                            settingsProvider.sortColumn =
                                SortColumnSettings.authorName;
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('nameAuthor'),
                          selected: settingsProvider.sortColumn ==
                              SortColumnSettings.nameAuthor,
                          onTap: () {
                            settingsProvider.sortColumn =
                                SortColumnSettings.nameAuthor;
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('asAdded'),
                          selected: settingsProvider.sortColumn ==
                              SortColumnSettings.added,
                          onTap: () {
                            settingsProvider.sortColumn =
                                SortColumnSettings.added;
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('releaseDate'),
                          selected: settingsProvider.sortColumn ==
                              SortColumnSettings.releaseDate,
                          onTap: () {
                            settingsProvider.sortColumn =
                                SortColumnSettings.releaseDate;
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('sortByLastUpdateCheck'),
                          selected: settingsProvider.sortColumn ==
                              SortColumnSettings.lastUpdateCheck,
                          onTap: () {
                            settingsProvider.sortColumn =
                                SortColumnSettings.lastUpdateCheck;
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    sectionLabel(tr('sortOrder')),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        sortChip(
                          label: tr('ascending'),
                          selected: settingsProvider.sortOrder ==
                              SortOrderSettings.ascending,
                          onTap: () {
                            settingsProvider.sortOrder =
                                SortOrderSettings.ascending;
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('descending'),
                          selected: settingsProvider.sortOrder ==
                              SortOrderSettings.descending,
                          onTap: () {
                            settingsProvider.sortOrder =
                                SortOrderSettings.descending;
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Divider(color: colorScheme.outlineVariant),
                    const SizedBox(height: 8),
                    sectionLabel(tr('groupBy')),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        sortChip(
                          label: tr('groupByNone'),
                          selected: settingsProvider.appsListGroupBy ==
                              AppsListGroupBy.none,
                          onTap: () {
                            settingsProvider.appsListGroupBy =
                                AppsListGroupBy.none;
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('category'),
                          selected: settingsProvider.appsListGroupBy ==
                              AppsListGroupBy.category,
                          onTap: () {
                            settingsProvider.appsListGroupBy =
                                AppsListGroupBy.category;
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('groupByTrackedSource'),
                          selected: settingsProvider.appsListGroupBy ==
                              AppsListGroupBy.source,
                          onTap: () {
                            settingsProvider.appsListGroupBy =
                                AppsListGroupBy.source;
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    if (settingsProvider.appsListGroupBy !=
                        AppsListGroupBy.none) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(tr('groupNonInstalledSeparately')),
                                ),
                                Tooltip(
                                  message: tr(
                                    'groupNonInstalledSeparatelyDescription',
                                  ),
                                  triggerMode: TooltipTriggerMode.tap,
                                  waitDuration: Duration.zero,
                                  showDuration: const Duration(seconds: 5),
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Icon(
                                      Icons.help_outline,
                                      size: 20,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value:
                                settingsProvider.groupNonInstalledSeparately,
                            onChanged: (value) {
                              settingsProvider.groupNonInstalledSeparately =
                                  value;
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Divider(color: colorScheme.outlineVariant),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('pinUpdates')),
                      value: settingsProvider.pinUpdates,
                      onChanged: (value) {
                        settingsProvider.pinUpdates = value;
                        setSheetState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('moveNonInstalledAppsToBottom')),
                      value: settingsProvider.buryNonInstalled,
                      onChanged: (value) {
                        settingsProvider.buryNonInstalled = value;
                        setSheetState(() {});
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Keeps auto-hide/show of the apps footer local to this state so scrolling
/// does not call [setState] on [AppsPageState] and rebuild the whole list.
class _ScrollLinkedAppFooter extends StatefulWidget {
  const _ScrollLinkedAppFooter({
    required this.scrollController,
    required this.selectionActive,
    required this.footer,
  });

  final ScrollController scrollController;
  final bool selectionActive;
  final Widget footer;

  @override
  State<_ScrollLinkedAppFooter> createState() => _ScrollLinkedAppFooterState();
}

class _ScrollLinkedAppFooterState extends State<_ScrollLinkedAppFooter> {
  bool _footerExpanded = true;
  double _previousOffset = 0;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _ScrollLinkedAppFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
    if (oldWidget.selectionActive != widget.selectionActive) {
      if (widget.scrollController.hasClients) {
        _previousOffset = widget.scrollController.offset;
      }
      if (!_footerExpanded) {
        setState(() {
          _footerExpanded = true;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final ScrollController controller = widget.scrollController;
    if (!controller.hasClients) {
      return;
    }
    if (widget.selectionActive) {
      _previousOffset = controller.offset;
      if (!_footerExpanded) {
        setState(() {
          _footerExpanded = true;
        });
      }
      return;
    }
    final double currentOffset = controller.offset;
    final double delta = currentOffset - _previousOffset;
    _previousOffset = currentOffset;
    if (currentOffset <= 24) {
      if (!_footerExpanded) {
        setState(() {
          _footerExpanded = true;
        });
      }
      return;
    }
    const double scrollSensitivity = 10;
    if (delta > scrollSensitivity) {
      if (_footerExpanded) {
        setState(() {
          _footerExpanded = false;
        });
      }
    } else if (delta < -scrollSensitivity) {
      if (!_footerExpanded) {
        setState(() {
          _footerExpanded = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.fastOutSlowIn,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: _footerExpanded || widget.selectionActive
          ? widget.footer
          : const SizedBox(width: double.infinity),
    );
  }
}

class AppsPageState extends State<AppsPage> {
  AppsFilter filter = AppsFilter();
  final AppsFilter neutralFilter = AppsFilter();
  var updatesOnlyFilter = AppsFilter(
    includeUptodate: false,
    includeNonInstalled: false,
  );
  Set<String> selectedAppIds = {};
  DateTime? refreshingSince;

  bool clearSelected() {
    if (selectedAppIds.isNotEmpty) {
      setState(() {
        selectedAppIds.clear();
      });
      return true;
    }
    return false;
  }

  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<RefreshIndicatorState>();

  late final ScrollController scrollController;

  /// One [Future] per app id so icon loading is not restarted on every rebuild.
  final Map<String, Future<void>> _appListIconWarmFutures = {};

  var sourceProvider = SourceProvider();

  // ── List-computation cache ────────────────────────────────────────────────
  // The filter → sort → pin/bury pass is O(n log n) and runs inside build().
  // We skip it entirely when the inputs haven't changed (e.g. a setState() for
  // row selection or the refresh-indicator doesn't need a new sort).
  int? _lastListBuildToken;
  List<AppInMemory> _listedAppsCache = const [];
  List<String> _existingUpdatesCache = const [];
  List<String> _newInstallsCache = const [];

  /// Maps category key (`__null__` for uncategorized) → indices into [_listedAppsCache].
  Map<String, List<int>> _categoryGroupListedIndices = const {};
  /// Maps source runtime type string → indices into [_listedAppsCache].
  Map<String, List<int>> _sourceGroupListedIndices = const {};
  List<int> _nonInstalledListedIndices = const [];
  int? _lastGroupIndexCacheToken;

  // ── Group expansion state ─────────────────────────────────────────────────
  // Groups start expanded. When the user collapses one its key goes here and
  // its child tiles are no longer built, saving widget-tree work on rebuilds.
  final Set<String> _collapsedGroups = {};

  // ── Hero keep-alive ───────────────────────────────────────────────────────
  // While AppPage is open for a given app, its list row must stay built so
  // the Hero destination exists when the user swipes back. This id is set
  // when Navigator.push fires and cleared when the route pops.
  String? _heroKeepaliveAppId;

  // ── Inline search ─────────────────────────────────────────────────────────
  late final TextEditingController _searchController;

  /// Which field the search bar is currently filtering on.
  /// One of: 'appName' | 'author' | 'appId'.
  String _searchField = 'appName';

  /// Guards against the listener re-firing when we programmatically change
  /// the controller text during a field switch.
  bool _changingSearchField = false;

  /// Whether the search bar is currently expanded.
  bool _searchExpanded = false;
  final FocusNode _searchFocusNode = FocusNode();

  String _searchFieldValue(String field) => switch (field) {
        'author' => filter.authorFilter,
        'appId' => filter.idFilter,
        _ => filter.nameFilter,
      };

  void _applySearchText(String field, String text) {
    switch (field) {
      case 'author':
        filter.authorFilter = text;
        break;
      case 'appId':
        filter.idFilter = text;
        break;
      default:
        filter.nameFilter = text;
    }
  }

  /// Switches the active search field, preserving any text in the old field
  /// and loading the new field's current value into the controller.
  void _changeSearchField(String newField) {
    if (newField == _searchField) return;
    _changingSearchField = true;
    setState(() {
      // Commit whatever is in the controller to the current field.
      _applySearchText(_searchField, _searchController.text);
      _searchField = newField;
      _searchController.text = _searchFieldValue(newField);
    });
    _changingSearchField = false;
  }

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController();
    _searchController = TextEditingController();
    _searchController.addListener(() {
      if (_changingSearchField) return;
      final text = _searchController.text;
      if (text != _searchFieldValue(_searchField)) {
        setState(() => _applySearchText(_searchField, text));
      }
    });
  }

  @override
  void dispose() {
    scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Builds the compact search bar that lives inline with the "Apps" title.
  ///
  /// The right-hand chip shows the currently-active search field. Tapping it
  /// opens the full filter sheet. When any filter is active (or the field is
  /// not the default) the chip uses a primary-container colour as a visual cue.
  Widget _buildSearchBar({
    required ColorScheme colorScheme,
    required VoidCallback showFilterSheet,
    required AppsFilter neutralFilter,
    required SettingsProvider settingsProvider,
    required FocusNode focusNode,
  }) {
    final bool anyFilterActive =
        !filter.isIdenticalTo(neutralFilter, settingsProvider) ||
        _searchField != 'appName';

    final String fieldLabel = switch (_searchField) {
      'author' => tr('author'),
      'appId' => tr('appId'),
      _ => tr('appName'),
    };

    return TextField(
      controller: _searchController,
      focusNode: focusNode,
      autofocus: true,
      decoration: InputDecoration(
        hintText: tr('search'),
        prefixIcon: const Icon(Icons.search, size: 18),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        suffix: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_searchController.text.isNotEmpty)
              GestureDetector(
                onTap: _searchController.clear,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            GestureDetector(
              onTap: showFilterSheet,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: anyFilterActive
                      ? colorScheme.primaryContainer
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      fieldLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: anyFilterActive
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 14,
                      color: anyFilterActive
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Returns the human-readable display name for a source given its
  /// runtimeType string (the value stored in [AppsFilter.sourceFilter]).
  String _getSourceName(String sourceKey) {
    for (final s in sourceProvider.sources) {
      if (s.runtimeType.toString() == sourceKey) return s.name;
    }
    return sourceKey;
  }

  /// Builds a single dismissible [InputChip] for the filter chips row.
  Widget _filterChip(String label, VoidCallback onDelete) {
    return InputChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onDeleted: onDelete,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 2),
    );
  }

  /// Builds a pinned row of dismissible filter chips for every active
  /// non-text filter. Returns [null] when no non-text filters are active
  /// (which causes [CustomAppBar] to omit the bottom bar entirely).
  PreferredSizeWidget? _buildFilterChipsRow() {
    final chips = <Widget>[];

    if (!filter.includeUptodate) {
      chips.add(_filterChip(
        tr('updatesOnly'),
        () => setState(() => filter.includeUptodate = true),
      ));
    }

    if (!filter.includeNonInstalled) {
      chips.add(_filterChip(
        tr('installedOnly'),
        () => setState(() => filter.includeNonInstalled = true),
      ));
    }

    if (filter.sourceFilter.isNotEmpty) {
      chips.add(_filterChip(
        '${tr('source')}: ${_getSourceName(filter.sourceFilter)}',
        () => setState(() => filter.sourceFilter = ''),
      ));
    }

    for (final cat in filter.categoryFilter) {
      chips.add(_filterChip(
        cat,
        () => setState(
          () => filter.categoryFilter = Set.from(filter.categoryFilter)
            ..remove(cat),
        ),
      ));
    }

    if (chips.isEmpty) return null;

    return PreferredSize(
      preferredSize: const Size.fromHeight(44),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          children: chips
              .expand((c) => [c, const SizedBox(width: 6)])
              .toList()
            ..removeLast(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // select() prevents rebuilds for notifications that don't affect list data
    // (download-progress ticks, icon-load completions). The returned token is
    // also used as part of the list-computation cache key below.
    final int appsToken =
        context.select<AppsProvider, int>(_appsPageAppsRebuildToken);
    var appsProvider = context.read<AppsProvider>();
    var settingsProvider = context.watch<SettingsProvider>();

    refresh() {
      HapticFeedback.lightImpact();
      setState(() {
        refreshingSince = DateTime.now();
        _appListIconWarmFutures.clear();
      });
      final Future<List<App>> refreshFuture = widget.onDemandOnlyList
          ? appsProvider.checkUpdates(
              specificIds: appsProvider.apps.values
                  .where(
                    (a) => a.app.additionalSettings['onDemandOnly'] == true,
                  )
                  .map((a) => a.app.id)
                  .toList(),
            )
          : appsProvider.checkUpdates();
      return refreshFuture
          .catchError((e) {
            if (!context.mounted) return <App>[];
            showError(e is Map ? e['errors'] : e, context);
            return <App>[];
          })
          .whenComplete(() {
            setState(() {
              refreshingSince = null;
            });
          });
    }

    if (!widget.onDemandOnlyList &&
        !appsProvider.loadingApps &&
        appsProvider.apps.isNotEmpty &&
        settingsProvider.checkJustStarted() &&
        settingsProvider.checkOnStart) {
      _refreshIndicatorKey.currentState?.show();
    }

    // Keep only IDs that still exist in the provider (e.g. after a delete).
    selectedAppIds = selectedAppIds
        .where((element) => appsProvider.apps.containsKey(element))
        .toSet();

    toggleAppSelected(App app) {
      setState(() {
        if (selectedAppIds.contains(app.id)) {
          selectedAppIds.removeWhere((a) => a == app.id);
        } else {
          selectedAppIds.add(app.id);
        }
      });
    }

    // ── Cached filter / sort / reorder ─────────────────────────────────────
    // filter+sort is O(n log n). We skip the entire pass when nothing that
    // affects list ordering has changed — e.g. tapping to select a row or
    // toggling the refresh indicator doesn't need a new sort.
    final int listBuildToken = Object.hashAll([
      appsToken,
      widget.onDemandOnlyList,
      filter.nameFilter,
      filter.authorFilter,
      filter.idFilter,
      filter.includeUptodate,
      filter.includeNonInstalled,
      Object.hashAll(filter.categoryFilter.toList()..sort()),
      filter.sourceFilter,
      settingsProvider.sortColumn.index,
      settingsProvider.sortOrder.index,
      settingsProvider.pinUpdates,
      settingsProvider.buryNonInstalled,
      settingsProvider.groupNonInstalledSeparately,
    ]);
    if (listBuildToken != _lastListBuildToken) {
      _lastListBuildToken = listBuildToken;
      var workingList = appsProvider.apps.values.toList();

      if (widget.onDemandOnlyList) {
        workingList = workingList
            .where(
              (appInMem) =>
                  appInMem.app.additionalSettings['onDemandOnly'] == true,
            )
            .toList();
      } else {
        workingList = workingList
            .where(
              (appInMem) =>
                  appInMem.app.additionalSettings['onDemandOnly'] != true,
            )
            .toList();
      }

      workingList = workingList.where((app) {
        final installed = app.app.installedVersion;
        final latest = app.app.latestVersion;
        final upToDate = installed == null
            ? false
            : isSkipActiveForCurrentLatest(app.app) ||
                installed == latest ||
                versionsEffectivelyEqual(installed, latest) ||
                (installedVersionIsNewerOrEqual(installed, latest) &&
                    !versionOrderIsUnclear(installed, latest));
        if (upToDate && !(filter.includeUptodate)) {
          return false;
        }
        if (app.app.installedVersion == null && !(filter.includeNonInstalled)) {
          return false;
        }
        if (filter.nameFilter.isNotEmpty || filter.authorFilter.isNotEmpty) {
          final nameTokens = filter.nameFilter
              .split(' ')
              .where((element) => element.trim().isNotEmpty)
              .toList();
          final authorTokens = filter.authorFilter
              .split(' ')
              .where((element) => element.trim().isNotEmpty)
              .toList();
          for (final t in nameTokens) {
            if (!app.name.toLowerCase().contains(t.toLowerCase())) {
              return false;
            }
          }
          for (final t in authorTokens) {
            if (!app.author.toLowerCase().contains(t.toLowerCase())) {
              return false;
            }
          }
        }
        if (filter.idFilter.isNotEmpty) {
          if (!app.app.id.contains(filter.idFilter)) {
            return false;
          }
        }
        if (filter.categoryFilter.isNotEmpty &&
            filter.categoryFilter
                .intersection(app.app.categories.toSet())
                .isEmpty) {
          return false;
        }
        if (filter.sourceFilter.isNotEmpty &&
            sourceProvider
                    .getSource(
                      app.app.url,
                      overrideSource: app.app.overrideSource,
                    )
                    .runtimeType
                    .toString() !=
                filter.sourceFilter) {
          return false;
        }
        return true;
      }).toList();

      workingList.sort((a, b) {
        int result = 0;
        if (settingsProvider.sortColumn == SortColumnSettings.authorName) {
          result = ((a.author + a.name).toLowerCase()).compareTo(
            (b.author + b.name).toLowerCase(),
          );
        } else if (settingsProvider.sortColumn ==
            SortColumnSettings.nameAuthor) {
          result = ((a.name + a.author).toLowerCase()).compareTo(
            (b.name + b.author).toLowerCase(),
          );
        } else if (settingsProvider.sortColumn ==
            SortColumnSettings.releaseDate) {
          // Handle null dates: apps with unknown release dates go to end.
          final aDate = a.app.releaseDate;
          final bDate = b.app.releaseDate;
          final isDescending =
              settingsProvider.sortOrder == SortOrderSettings.descending;
          if (aDate == null && bDate == null) {
            result = ((a.name + a.author).toLowerCase()).compareTo(
              (b.name + b.author).toLowerCase(),
            );
          } else if (aDate == null) {
            result = isDescending ? -1 : 1;
          } else if (bDate == null) {
            result = isDescending ? 1 : -1;
          } else {
            result = aDate.compareTo(bDate);
          }
        } else if (settingsProvider.sortColumn ==
            SortColumnSettings.lastUpdateCheck) {
          final aDate = a.app.lastUpdateCheck;
          final bDate = b.app.lastUpdateCheck;
          final isDescending =
              settingsProvider.sortOrder == SortOrderSettings.descending;
          if (aDate == null && bDate == null) {
            result = ((a.name + a.author).toLowerCase()).compareTo(
              (b.name + b.author).toLowerCase(),
            );
          } else if (aDate == null) {
            result = isDescending ? -1 : 1;
          } else if (bDate == null) {
            result = isDescending ? 1 : -1;
          } else {
            result = aDate.compareTo(bDate);
          }
        } else if (settingsProvider.sortColumn == SortColumnSettings.added) {
          result = 0;
        }
        return result;
      });

      if (settingsProvider.sortOrder == SortOrderSettings.descending) {
        workingList = workingList.reversed.toList();
      }

      // Cache existingUpdates together with the list: pinUpdates ordering
      // depends on it and it's a pure function of app state (in the token).
      _existingUpdatesCache = appsProvider
          .findExistingUpdates(
            installedOnly: true,
            includeVersionOrderUncertain: true,
          )
          .toList();
      _newInstallsCache =
          appsProvider.findExistingUpdates(nonInstalledOnly: true).toList();

      if (settingsProvider.pinUpdates) {
        final temp = <AppInMemory>[];
        workingList = workingList.where((sa) {
          if (_existingUpdatesCache.contains(sa.app.id)) {
            temp.add(sa);
            return false;
          }
          return true;
        }).toList();
        workingList = [...temp, ...workingList];
      }

      if (settingsProvider.buryNonInstalled) {
        final temp = <AppInMemory>[];
        workingList = workingList.where((sa) {
          if (sa.app.installedVersion == null) {
            temp.add(sa);
            return false;
          }
          return true;
        }).toList();
        workingList = [...workingList, ...temp];
      }

      final tempPinned = <AppInMemory>[];
      final tempNotPinned = <AppInMemory>[];
      for (final a in workingList) {
        if (a.app.pinned) {
          tempPinned.add(a);
        } else {
          tempNotPinned.add(a);
        }
      }
      _listedAppsCache = [...tempPinned, ...tempNotPinned];
    }
    // ── Use cached results ──────────────────────────────────────────────────
    final listedApps = _listedAppsCache;
    final existingUpdates = _existingUpdatesCache;
    final newInstalls = _newInstallsCache;
    final int onDemandOnlyAppCount = appsProvider.apps.values
        .where((a) => a.app.additionalSettings['onDemandOnly'] == true)
        .length;

    var existingUpdateIdsAllOrSelected = existingUpdates
        .where(
          (element) => selectedAppIds.isEmpty
              ? listedApps.any((a) => a.app.id == element)
              : selectedAppIds.contains(element),
        )
        .toList();
    var newInstallIdsAllOrSelected = newInstalls
        .where(
          (element) => selectedAppIds.isEmpty
              ? listedApps.any((a) => a.app.id == element)
              : selectedAppIds.contains(element),
        )
        .toList();

    List<String> trackOnlyUpdateIdsAllOrSelected = [];
    existingUpdateIdsAllOrSelected = existingUpdateIdsAllOrSelected.where((id) {
      if (appsProvider.apps[id]!.app.additionalSettings['trackOnly'] == true) {
        trackOnlyUpdateIdsAllOrSelected.add(id);
        return false;
      }
      return true;
    }).toList();
    newInstallIdsAllOrSelected = newInstallIdsAllOrSelected.where((id) {
      if (appsProvider.apps[id]!.app.additionalSettings['trackOnly'] == true) {
        trackOnlyUpdateIdsAllOrSelected.add(id);
        return false;
      }
      return true;
    }).toList();

    final segregateNonInstalled =
        settingsProvider.groupNonInstalledSeparately &&
            (settingsProvider.appsListGroupBy == AppsListGroupBy.category ||
                settingsProvider.appsListGroupBy == AppsListGroupBy.source);
    final appsListedForCategoryKeys = segregateNonInstalled
        ? listedApps.where((e) => e.app.installedVersion != null).toList()
        : listedApps;
    final appsListedForSourceKeys = segregateNonInstalled
        ? listedApps.where((e) => e.app.installedVersion != null).toList()
        : listedApps;
    final showNonInstalledGroupSection = segregateNonInstalled &&
        listedApps.any((e) => e.app.installedVersion == null);

    List<String?> getListedCategories(List<AppInMemory> appsSource) {
      var temp = appsSource.map(
        (e) => e.app.categories.isNotEmpty ? e.app.categories : [null],
      );
      return temp.isNotEmpty
          ? {
              ...temp.reduce((v, e) => [...v, ...e]),
            }.toList()
          : [];
    }

    var listedCategories = getListedCategories(appsListedForCategoryKeys);
    listedCategories.sort((a, b) {
      return a != null && b != null
          ? a.toLowerCase().compareTo(b.toLowerCase())
          : a == null
          ? 1
          : -1;
    });

    List<String> getListedSourceKeys(List<AppInMemory> appsSource) {
      if (appsSource.isEmpty) return [];
      final keys = appsSource
          .map(
            (e) => sourceProvider
                .getSource(e.app.url, overrideSource: e.app.overrideSource)
                .runtimeType
                .toString(),
          )
          .toSet()
          .toList();
      keys.sort(
        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
      );
      return keys;
    }

    var listedSources = getListedSourceKeys(appsListedForSourceKeys);

    if (listBuildToken != _lastGroupIndexCacheToken) {
      _lastGroupIndexCacheToken = listBuildToken;
      final nextCategoryMap = <String, List<int>>{};
      for (int categoryIndex = 0;
          categoryIndex < listedCategories.length;
          categoryIndex++) {
        final String? categoryNullable = listedCategories[categoryIndex];
        final String mapKey = categoryNullable ?? '__null__';
        final indices = <int>[];
        for (int listingIndex = 0;
            listingIndex < listedApps.length;
            listingIndex++) {
          final AppInMemory row = listedApps[listingIndex];
          if (segregateNonInstalled && row.app.installedVersion == null) {
            continue;
          }
          if (row.app.categories.contains(categoryNullable) ||
              (row.app.categories.isEmpty && categoryNullable == null)) {
            indices.add(listingIndex);
          }
        }
        nextCategoryMap[mapKey] = indices;
      }
      _categoryGroupListedIndices = nextCategoryMap;

      final nextSourceMap = <String, List<int>>{};
      for (int sourceIndex = 0;
          sourceIndex < listedSources.length;
          sourceIndex++) {
        final String sourceKey = listedSources[sourceIndex];
        final indices = <int>[];
        for (int listingIndex = 0;
            listingIndex < listedApps.length;
            listingIndex++) {
          final AppInMemory row = listedApps[listingIndex];
          if (segregateNonInstalled && row.app.installedVersion == null) {
            continue;
          }
          if (sourceProvider
                  .getSource(row.app.url, overrideSource: row.app.overrideSource)
                  .runtimeType
                  .toString() ==
              sourceKey) {
            indices.add(listingIndex);
          }
        }
        nextSourceMap[sourceKey] = indices;
      }
      _sourceGroupListedIndices = nextSourceMap;

      final nonInstalled = <int>[];
      for (int listingIndex = 0;
          listingIndex < listedApps.length;
          listingIndex++) {
        if (listedApps[listingIndex].app.installedVersion == null) {
          nonInstalled.add(listingIndex);
        }
      }
      _nonInstalledListedIndices = nonInstalled;
    }

    Set<App> selectedApps = listedApps
        .map((e) => e.app)
        .where((a) => selectedAppIds.contains(a.id))
        .toSet();

    getLoadingWidgets() {
      final int progressDenominator = widget.onDemandOnlyList
          ? (onDemandOnlyAppCount > 0 ? onDemandOnlyAppCount : 1)
          : (appsProvider.apps.isNotEmpty ? appsProvider.apps.length : 1);
      return [
        if (listedApps.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Text(
                appsProvider.apps.isEmpty
                    ? appsProvider.loadingApps
                          ? tr('pleaseWait')
                          : tr('noApps')
                    : widget.onDemandOnlyList && onDemandOnlyAppCount == 0
                    ? tr('onDemandOnlyEmpty')
                    : tr('noAppsForFilter'),
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (refreshingSince != null || appsProvider.loadingApps)
          SliverToBoxAdapter(
            child: LinearProgressIndicator(
              value: appsProvider.loadingApps
                  ? null
                  : appsProvider.apps.values
                            .where(
                              (element) =>
                                  !(element.app.lastUpdateCheck?.isBefore(
                                        refreshingSince!,
                                      ) ??
                                      true),
                            )
                            .where(
                              (element) =>
                                  !widget.onDemandOnlyList ||
                                  element.app.additionalSettings['onDemandOnly'] ==
                                      true,
                            )
                            .length /
                        progressDenominator,
            ),
          ),
      ];
    }

    getAppIcon(int appIndex) {
      final String rowAppId = listedApps[appIndex].app.id;
      // Kick off icon loading once; putIfAbsent prevents duplicate loads.
      // _AppIconWidget independently watches the icon bytes via context.select,
      // so only that widget rebuilds when the icon arrives — not the full page.
      if (appsProvider.apps[rowAppId]?.icon == null) {
        _appListIconWarmFutures.putIfAbsent(
          rowAppId,
          () => appsProvider.updateAppIcon(rowAppId),
        );
      }
      return GestureDetector(
        child: Hero(
          tag: 'app-icon-$rowAppId',
          // Preserve the ClipRRect/shape during the flight.
          flightShuttleBuilder: (_, animation, _, _, _) =>
              _AppIconWidget(appId: rowAppId),
          child: _AppIconWidget(appId: rowAppId),
        ),
        onDoubleTap: () => pm.openApp(rowAppId),
        onLongPress: () {
          Navigator.push(
            context,
            heroFriendlyAppPageRoute(
              (_) => AppPage(
                appId: rowAppId,
                showOppositeOfPreferredView: true,
              ),
            ),
          );
        },
      );
    }

    getSingleAppHorizTile(int index) {
      final app = listedApps[index];
      final appId = app.app.id;
      final installed = app.app.installedVersion;
      final hasUpdate =
          installed != null && appHasActionableUpdate(app.app);
      final hasUncertainUpdate =
          installed != null && versionOrderUncertainUpdate(app.app);
      final downloadsRunning = appsProvider.areDownloadsRunning();
      final sourceHost = sourceProvider
          .getSource(app.app.url, overrideSource: app.app.overrideSource)
          .hosts
          .firstOrNull;
      final iconWithBadge = sourceHost != null
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                getAppIcon(index),
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: StoreSourceListBadge(host: sourceHost),
                ),
              ],
            )
          : getAppIcon(index);
      return _SwipeableListItem(
        key: ValueKey(appId),
        appId: appId,
        hasUpdate: hasUpdate || hasUncertainUpdate,
        isPinned: app.app.pinned,
        isInstalled: installed != null,
        areDownloadsRunning: downloadsRunning,
        keepAlive: _heroKeepaliveAppId == appId,
        rightAction: settingsProvider.rightSwipeAction,
        leftAction: settingsProvider.leftSwipeAction,
        child: _AppListItem(
          appId: appId,
          isSelected: selectedAppIds.contains(appId),
          areDownloadsRunning: downloadsRunning,
          iconWidget: iconWithBadge,
          onTap: selectedAppIds.isNotEmpty
              ? () => toggleAppSelected(app.app)
              : () {
                  setState(() => _heroKeepaliveAppId = appId);
                  Navigator.push(
                    context,
                    heroFriendlyAppPageRoute((_) => AppPage(appId: appId)),
                  ).then((_) {
                    if (mounted) setState(() => _heroKeepaliveAppId = null);
                  });
                },
          onLongPress: () => toggleAppSelected(app.app),
          highlightTouchTargets: settingsProvider.highlightTouchTargets,
          categoryColors: settingsProvider.categories,
        ),
      );
    }

    getCategoryCollapsibleTile(int index) {
      final catKey = 'cat:${listedCategories[index] ?? '__null__'}';
      final isExpanded = !_collapsedGroups.contains(catKey);

      final String categoryMapKey = listedCategories[index] ?? '__null__';
      final matchingIndices =
          _categoryGroupListedIndices[categoryMapKey] ?? const <int>[];
      final tiles = isExpanded
          ? matchingIndices
              .map((listingIndex) => getSingleAppHorizTile(listingIndex))
              .toList()
          : const <Widget>[];

      capFirstChar(String str) => str[0].toUpperCase() + str.substring(1);
      final theme = Theme.of(context);
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Material(
            elevation: 3,
            shadowColor: theme.colorScheme.shadow.withAlpha(100),
            surfaceTintColor: theme.colorScheme.surfaceTint,
            borderRadius: BorderRadius.circular(_appsListGroupCardRadius),
            color: theme.colorScheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey(catKey),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(_appsListGroupCardRadius),
                  ),
                ),
                collapsedShape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(_appsListGroupCardRadius),
                  ),
                ),
                initiallyExpanded: isExpanded,
                onExpansionChanged: (expanded) => setState(() {
                  if (expanded) {
                    _collapsedGroups.remove(catKey);
                  } else {
                    _collapsedGroups.add(catKey);
                  }
                }),
                title: Text(
                  capFirstChar(listedCategories[index] ?? tr('noCategory')),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                trailing: Text(matchingIndices.length.toString()),
                children: tiles,
              ),
            ),
          ),
        ),
      );
    }

    getNonInstalledCollapsibleTile() {
      const nonInstalledKey = '__nonInstalled__';
      final isExpanded = !_collapsedGroups.contains(nonInstalledKey);

      final matchingIndices = _nonInstalledListedIndices;
      final tiles = isExpanded
          ? matchingIndices
              .map((listingIndex) => getSingleAppHorizTile(listingIndex))
              .toList()
          : const <Widget>[];

      final theme = Theme.of(context);
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Material(
            elevation: 3,
            shadowColor: theme.colorScheme.shadow.withAlpha(100),
            surfaceTintColor: theme.colorScheme.surfaceTint,
            borderRadius: BorderRadius.circular(_appsListGroupCardRadius),
            color: theme.colorScheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const PageStorageKey(nonInstalledKey),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(_appsListGroupCardRadius),
                  ),
                ),
                collapsedShape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(_appsListGroupCardRadius),
                  ),
                ),
                initiallyExpanded: isExpanded,
                onExpansionChanged: (expanded) => setState(() {
                  if (expanded) {
                    _collapsedGroups.remove(nonInstalledKey);
                  } else {
                    _collapsedGroups.add(nonInstalledKey);
                  }
                }),
                title: Text(
                  tr('notInstalled'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                trailing: Text(matchingIndices.length.toString()),
                children: tiles,
              ),
            ),
          ),
        ),
      );
    }

    getSourceCollapsibleTile(int index) {
      final sourceKey = listedSources[index];
      final groupKey = 'src:$sourceKey';
      final isExpanded = !_collapsedGroups.contains(groupKey);

      final matchingIndices =
          _sourceGroupListedIndices[sourceKey] ?? const <int>[];
      final tiles = isExpanded
          ? matchingIndices
              .map((listingIndex) => getSingleAppHorizTile(listingIndex))
              .toList()
          : const <Widget>[];

      final AppInMemory firstForTitle = matchingIndices.isEmpty
          ? listedApps.firstWhere(
              (appInMem) =>
                  sourceProvider
                      .getSource(
                        appInMem.app.url,
                        overrideSource: appInMem.app.overrideSource,
                      )
                      .runtimeType
                      .toString() ==
                  sourceKey,
            )
          : listedApps[matchingIndices.first];
      final sourceTitle = sourceProvider
          .getSource(
            firstForTitle.app.url,
            overrideSource: firstForTitle.app.overrideSource,
          )
          .name;

      final theme = Theme.of(context);
      return RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Material(
            elevation: 3,
            shadowColor: theme.colorScheme.shadow.withAlpha(100),
            surfaceTintColor: theme.colorScheme.surfaceTint,
            borderRadius: BorderRadius.circular(_appsListGroupCardRadius),
            color: theme.colorScheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey(groupKey),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(_appsListGroupCardRadius),
                  ),
                ),
                collapsedShape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(_appsListGroupCardRadius),
                  ),
                ),
                initiallyExpanded: isExpanded,
                onExpansionChanged: (expanded) => setState(() {
                  if (expanded) {
                    _collapsedGroups.remove(groupKey);
                  } else {
                    _collapsedGroups.add(groupKey);
                  }
                }),
                title: Text(
                  sourceTitle,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                trailing: Text(matchingIndices.length.toString()),
                children: tiles,
              ),
            ),
          ),
        ),
      );
    }

    getMassObtainFunction() {
      return appsProvider.areDownloadsRunning() ||
              (existingUpdateIdsAllOrSelected.isEmpty &&
                  newInstallIdsAllOrSelected.isEmpty &&
                  trackOnlyUpdateIdsAllOrSelected.isEmpty)
          ? null
          : () {
              HapticFeedback.heavyImpact();
              List<GeneratedFormItem> formItems = [];
              if (existingUpdateIdsAllOrSelected.isNotEmpty) {
                formItems.add(
                  GeneratedFormSwitch(
                    'updates',
                    label: tr(
                      'updateX',
                      args: [
                        plural(
                          'apps',
                          existingUpdateIdsAllOrSelected.length,
                        ).toLowerCase(),
                      ],
                    ),
                    defaultValue: true,
                  ),
                );
              }
              if (newInstallIdsAllOrSelected.isNotEmpty) {
                formItems.add(
                  GeneratedFormSwitch(
                    'installs',
                    label: tr(
                      'installX',
                      args: [
                        plural(
                          'apps',
                          newInstallIdsAllOrSelected.length,
                        ).toLowerCase(),
                      ],
                    ),
                    defaultValue: existingUpdateIdsAllOrSelected.isEmpty,
                  ),
                );
              }
              if (trackOnlyUpdateIdsAllOrSelected.isNotEmpty) {
                formItems.add(
                  GeneratedFormSwitch(
                    'trackonlies',
                    label: tr(
                      'markXTrackOnlyAsUpdated',
                      args: [
                        plural('apps', trackOnlyUpdateIdsAllOrSelected.length),
                      ],
                    ),
                    defaultValue:
                        existingUpdateIdsAllOrSelected.isEmpty &&
                        newInstallIdsAllOrSelected.isEmpty,
                  ),
                );
              }
              showDialog<Map<String, dynamic>?>(
                context: context,
                builder: (BuildContext ctx) {
                  var totalApps =
                      existingUpdateIdsAllOrSelected.length +
                      newInstallIdsAllOrSelected.length +
                      trackOnlyUpdateIdsAllOrSelected.length;
                  return GeneratedFormModal(
                    title: tr(
                      'changeX',
                      args: [plural('apps', totalApps).toLowerCase()],
                    ),
                    items: formItems.map((e) => [e]).toList(),
                    initValid: true,
                  );
                },
              ).then((values) async {
                if (values != null) {
                  if (values.isEmpty) {
                    values = getDefaultValuesFromFormItems([formItems]);
                  }
                  bool shouldInstallUpdates = values['updates'] == true;
                  bool shouldInstallNew = values['installs'] == true;
                  bool shouldMarkTrackOnlies = values['trackonlies'] == true;
                  List<String> toInstall = [];
                  if (shouldInstallUpdates) {
                    toInstall.addAll(existingUpdateIdsAllOrSelected);
                  }
                  if (shouldInstallNew) {
                    toInstall.addAll(newInstallIdsAllOrSelected);
                  }
                  if (shouldMarkTrackOnlies) {
                    toInstall.addAll(trackOnlyUpdateIdsAllOrSelected);
                  }
                  appsProvider
                      .downloadAndInstallLatestApps(
                        toInstall,
                        globalNavigatorKey.currentContext,
                      )
                      .catchError((e) {
                        if (!context.mounted) return <String>[];
                        showError(e, context);
                        return <String>[];
                      })
                      .then((value) {
                        if (value.isNotEmpty && shouldInstallUpdates) {
                          if (!context.mounted) return;
                          showMessage(tr('appsUpdated'), context);
                        }
                      });
                }
              });
            };
    }

    launchCategorizeDialog() {
      return () async {
        try {
          Set<String>? preselected;
          var showPrompt = false;
          for (var element in selectedApps) {
            var currentCats = element.categories.toSet();
            if (preselected == null) {
              preselected = currentCats;
            } else {
              if (!settingsProvider.setEqual(currentCats, preselected)) {
                showPrompt = true;
                break;
              }
            }
          }
          var cont = true;
          if (showPrompt) {
            cont =
                await showDialog<Map<String, dynamic>?>(
                  context: context,
                  builder: (BuildContext ctx) {
                    return GeneratedFormModal(
                      title: tr('categorize'),
                      items: const [],
                      initValid: true,
                      message: tr('selectedCategorizeWarning'),
                    );
                  },
                ) !=
                null;
          }
          if (cont) {
            if (!context.mounted) return;
            await showDialog<Map<String, dynamic>?>(
              context: context,
              builder: (BuildContext ctx) {
                return GeneratedFormModal(
                  title: tr('categorize'),
                  items: const [],
                  initValid: true,
                  singleNullReturnButton: tr('continue'),
                  additionalWidgets: [
                    CategoryEditorSelector(
                      preselected: !showPrompt ? preselected ?? {} : {},
                      showLabelWhenNotEmpty: false,
                      onSelected: (categories) {
                        appsProvider.saveApps(
                          selectedApps.map((e) {
                            e.categories = categories;
                            return e;
                          }).toList(),
                        );
                      },
                    ),
                  ],
                );
              },
            );
          }
        } catch (err) {
          if (!context.mounted) return;
          showError(err, context);
        }
      };
    }

    showMassMarkDialog() {
      return showDialog(
        context: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            title: Text(
              tr(
                'markXSelectedAppsAsUpdated',
                args: [selectedAppIds.length.toString()],
              ),
            ),
            content: Text(
              tr('onlyWorksWithNonVersionDetectApps'),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontStyle: FontStyle.italic,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: Text(tr('no')),
              ),
              TextButton(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  appsProvider.saveApps(
                    selectedApps.map((a) {
                      if (a.installedVersion != null &&
                          !appsProvider.isVersionDetectionPossible(
                            appsProvider.apps[a.id],
                          )) {
                        a.installedVersion = a.latestVersion;
                      }
                      return a;
                    }).toList(),
                  );

                  Navigator.of(context).pop();
                },
                child: Text(tr('yes')),
              ),
            ],
          );
        },
      ).whenComplete(() {
        if (!context.mounted) return;
        Navigator.of(context).pop();
      });
    }

    pinSelectedApps() {
      var pinStatus = selectedApps.where((element) => element.pinned).isEmpty;
      appsProvider.saveApps(
        selectedApps.map((e) {
          e.pinned = pinStatus;
          return e;
        }).toList(),
      );
      Navigator.of(context).pop();
    }

    showMoreOptionsDialog() {
      return showDialog(
        context: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            scrollable: true,
            content: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  TextButton(
                    onPressed: pinSelectedApps,
                    child: Text(
                      selectedApps.where((element) => element.pinned).isEmpty
                          ? tr('pinToTop')
                          : tr('unpinFromTop'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Divider(),
                  TextButton(
                    onPressed: () {
                      String urls = '';
                      for (var a in selectedApps) {
                        urls += '${a.url}\n';
                      }
                      urls = urls.substring(0, urls.length - 1);
                      SharePlus.instance.share(ShareParams(
                        text: urls,
                        subject: 'ObtainX - ${tr('appsString')}',
                      ));
                      Navigator.of(context).pop();
                    },
                    child: Text(
                      tr('shareSelectedAppURLs'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Divider(),
                  TextButton(
                    onPressed: selectedAppIds.isEmpty
                        ? null
                        : () {
                            String urls = '';
                            for (var a in selectedApps) {
                              urls +=
                                  'https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/${Uri.encodeComponent(jsonEncode({'id': a.id, 'url': a.url, 'author': a.author, 'name': a.name, 'preferredApkIndex': a.preferredApkIndex, 'additionalSettings': jsonEncode(a.additionalSettings), 'overrideSource': a.overrideSource}))}\n\n';
                            }
                            SharePlus.instance.share(ShareParams(
                              text: urls,
                              subject: 'ObtainX - ${tr('appsString')}',
                            ));
                          },
                    child: Text(
                      tr('shareAppConfigLinks'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Divider(),
                  TextButton(
                    onPressed: selectedAppIds.isEmpty
                        ? null
                        : () {
                            var encoder = const JsonEncoder.withIndent("    ");
                            var exportJSON = encoder.convert(
                              appsProvider.generateExportJSON(
                                appIds: selectedApps.map((e) => e.id).toList(),
                                overrideExportSettings: 0,
                              ),
                            );
                            String fn =
                                '${tr('obtainiumExportHyphenatedLowercase')}-${DateTime.now().toIso8601String().replaceAll(':', '-')}-count-${selectedApps.length}';
                            XFile f = XFile.fromData(
                              Uint8List.fromList(utf8.encode(exportJSON)),
                              mimeType: 'application/json',
                              name: fn,
                            );
                            SharePlus.instance.share(ShareParams(
                              files: [f],
                              fileNameOverrides: ['$fn.json'],
                            ));
                          },
                    child: Text(
                      '${tr('share')} - ${tr('obtainiumExport')}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Divider(),
                  TextButton(
                    onPressed: () {
                      appsProvider
                          .downloadAppAssets(
                            selectedApps.map((e) => e.id).toList(),
                            globalNavigatorKey.currentContext ?? context,
                          )
                          .catchError(
                            // ignore: invalid_return_type_for_catch_error
                            (e) => showError(
                              e,
                              globalNavigatorKey.currentContext ?? context,
                            ),
                          );
                      Navigator.of(context).pop();
                    },
                    child: Text(
                      tr(
                        'downloadX',
                        args: [lowerCaseIfEnglish(tr('releaseAsset'))],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Divider(),
                  TextButton(
                    onPressed: appsProvider.areDownloadsRunning()
                        ? null
                        : showMassMarkDialog,
                    child: Text(
                      tr('markSelectedAppsUpdated'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    // ── Filter bottom sheet ──────────────────────────────────────────────────
    // Shows all filter/search options in a modal bottom sheet.
    // Changes to toggles and dropdown are applied live; the sheet is dismissed
    // by dragging down or tapping outside.
    showFilterSheet() {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (sheetCtx) {
          return StatefulBuilder(
            builder: (sheetCtx, setSheetState) {
              final colorScheme = Theme.of(context).colorScheme;

              // Call both parent and sheet setState when the filter changes.
              void update(VoidCallback fn) {
                fn();
                setState(() {});
                setSheetState(() {});
              }

              // ── Search field selector ─────────────────────────────────────
              Widget fieldChip(String field, String label) {
                final selected = _searchField == field;
                return ChoiceChip(
                  label: Text(label),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (v) {
                    if (v) {
                      update(() => _changeSearchField(field));
                    }
                  },
                );
              }

              // ── Source items ──────────────────────────────────────────────
              final sourceItems = [
                MapEntry('', tr('none')),
                ...sourceProvider.sources.map(
                  (e) => MapEntry(e.runtimeType.toString(), e.name),
                ),
              ];

              return Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Drag handle
                      Center(
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 12),
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      // Title row
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 8, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                tr('filterApps'),
                                style: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                update(() {
                                  filter = AppsFilter();
                                  _searchField = 'appName';
                                  _searchController.clear();
                                });
                                Navigator.of(sheetCtx).pop();
                              },
                              child: Text(tr('remove')),
                            ),
                          ],
                        ),
                      ),

                      // ── Search field selector ─────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                        child: Text(
                          tr('search'),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            fieldChip('appName', tr('appName')),
                            fieldChip('author', tr('author')),
                            fieldChip('appId', tr('appId')),
                          ],
                        ),
                      ),

                      const Divider(height: 1),
                      const SizedBox(height: 8),

                      // ── Visibility toggles ────────────────────────────────
                      SwitchListTile(
                        dense: true,
                        title: Text(tr('upToDateApps')),
                        value: filter.includeUptodate,
                        onChanged: (v) => update(() => filter.includeUptodate = v),
                      ),
                      SwitchListTile(
                        dense: true,
                        title: Text(tr('nonInstalledApps')),
                        value: filter.includeNonInstalled,
                        onChanged: (v) =>
                            update(() => filter.includeNonInstalled = v),
                      ),

                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      const SizedBox(height: 8),

                      // ── Source dropdown ───────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(filter.sourceFilter),
                          decoration: InputDecoration(
                            labelText: tr('appSource'),
                            isDense: true,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                          initialValue: filter.sourceFilter,
                          items: sourceItems
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value),
                                ),
                              )
                              .toList(),
                          onChanged: (v) =>
                              update(() => filter.sourceFilter = v ?? ''),
                        ),
                      ),

                      // ── Category selector ─────────────────────────────────
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          20,
                          16,
                          20,
                          20 + MediaQuery.of(context).viewPadding.bottom,
                        ),
                        child: CategoryEditorSelector(
                          preselected: filter.categoryFilter,
                          onSelected: (categories) {
                            update(() {
                              filter.categoryFilter = categories.toSet();
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    }

    getFilterButtonsRow() {
      final colorScheme = Theme.of(context).colorScheme;
      final selectAllFooterStyle = TextButton.styleFrom(
        foregroundColor: colorScheme.primary,
        visualDensity: VisualDensity.compact,
        iconSize: 24,
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      );
      if (selectedAppIds.isNotEmpty) {
        return Row(
          children: [
            Expanded(
              child: Center(
                child: Tooltip(
                  message: tr('selectAll'),
                  child: TextButton.icon(
                    style: selectAllFooterStyle,
                    onPressed: listedApps.isEmpty
                        ? null
                        : () {
                            setState(() {
                              for (final appInMem in listedApps) {
                                selectedAppIds.add(appInMem.app.id);
                              }
                            });
                          },
                    icon: const Icon(Icons.select_all_outlined, size: 24),
                    label: Text(selectedAppIds.length.toString()),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  onPressed: () {
                    setState(() {
                      selectedAppIds.clear();
                    });
                  },
                  tooltip: tr('deselectAll'),
                  icon: const Icon(Icons.deselect),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  onPressed: () async {
                    final appsProviderRef = appsProvider;
                    // Capture messenger before the await
                    final messenger = scaffoldMessengerKey.currentState;
                    final RemoveAppsWithModalResult removeResult =
                        await appsProviderRef.removeAppsWithModal(
                      context,
                      selectedApps.toList(),
                    );
                    if (removeResult.shouldShowSnackBar) {
                      final Set<String> undoAppIds =
                          removeResult.deferredUndoAppIds;
                      final int removedCount = removeResult
                              .deferredUndoAppIds.isNotEmpty
                          ? removeResult.deferredUndoAppIds.length
                          : selectedApps.length;
                      messenger
                        ?..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(
                              tr('xAppsRemoved', args: ['$removedCount']),
                            ),
                            persist: false,
                            duration: const Duration(seconds: 5),
                            behavior: SnackBarBehavior.floating,
                            action: undoAppIds.isNotEmpty
                                ? SnackBarAction(
                                    label: tr('undo'),
                                    onPressed: () => appsProviderRef
                                        .undoDeferredObtainiumRemovals(
                                      undoAppIds,
                                    ),
                                  )
                                : null,
                          ),
                        );
                    }
                  },
                  tooltip: tr('removeSelectedApps'),
                  icon: const Icon(Icons.delete_outline_outlined),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  onPressed: launchCategorizeDialog(),
                  tooltip: tr('categorize'),
                  icon: const Icon(Icons.category_outlined),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  onPressed: showMoreOptionsDialog,
                  tooltip: tr('more'),
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
            ),
          ],
        );
      }
      return Row(
        children: [
          Expanded(
            child: Center(
              child: Tooltip(
                message: tr('selectAll'),
                child: TextButton.icon(
                  style: selectAllFooterStyle,
                  onPressed: listedApps.isEmpty
                      ? null
                      : () {
                          setState(() {
                            for (final appInMem in listedApps) {
                              selectedAppIds.add(appInMem.app.id);
                            }
                          });
                        },
                  icon: const Icon(Icons.select_all_outlined, size: 24),
                  label: Text(selectedAppIds.length.toString()),
                ),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 24,
                color: colorScheme.primary,
                onPressed: getMassObtainFunction(),
                tooltip: tr('installUpdateApps'),
                icon: const Icon(Icons.file_download_outlined),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 24,
                color: colorScheme.primary,
                tooltip: tr('appsViewOptions'),
                onPressed: () => showAppsViewOptionsSheet(context),
                icon: const Icon(Icons.tune),
              ),
            ),
          ),
        ],
      );
    }

    getDisplayedList() {
      final groupBy = settingsProvider.appsListGroupBy;
      final useCategoryGroups = groupBy == AppsListGroupBy.category &&
          (segregateNonInstalled
              ? (listedCategories.isNotEmpty || showNonInstalledGroupSection)
              : !(listedCategories.isEmpty ||
                  (listedCategories.length == 1 &&
                      listedCategories[0] == null)));
      if (useCategoryGroups) {
        final categoryChildCount = listedCategories.length +
            (showNonInstalledGroupSection ? 1 : 0);
        return SliverList(
          delegate: SliverChildBuilderDelegate((
            BuildContext context,
            int index,
          ) {
            if (showNonInstalledGroupSection &&
                index == listedCategories.length) {
              return getNonInstalledCollapsibleTile();
            }
            return getCategoryCollapsibleTile(index);
          }, childCount: categoryChildCount),
        );
      }
      final useSourceGroups = groupBy == AppsListGroupBy.source &&
          (listedSources.isNotEmpty || showNonInstalledGroupSection);
      if (useSourceGroups) {
        final sourceChildCount =
            listedSources.length + (showNonInstalledGroupSection ? 1 : 0);
        return SliverList(
          delegate: SliverChildBuilderDelegate((
            BuildContext context,
            int index,
          ) {
            if (showNonInstalledGroupSection &&
                index == listedSources.length) {
              return getNonInstalledCollapsibleTile();
            }
            return getSourceCollapsibleTile(index);
          }, childCount: sourceChildCount),
        );
      }
      return SliverList(
        delegate: SliverChildBuilderDelegate((
          BuildContext context,
          int index,
        ) {
          return getSingleAppHorizTile(index);
        }, childCount: listedApps.length),
      );
    }

    return PopScope(
      canPop: selectedAppIds.isEmpty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && selectedAppIds.isNotEmpty) {
          clearSelected();
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: RefreshIndicator(
                key: _refreshIndicatorKey,
                onRefresh: refresh,
                child: Scrollbar(
                  interactive: true,
                  controller: scrollController,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    controller: scrollController,
                    cacheExtent: 900,
                    slivers: <Widget>[
                      CustomAppBar(
                        leading: widget.onDemandOnlyList
                            ? IconButton(
                                icon: const Icon(Icons.arrow_back),
                                onPressed: () =>
                                    Navigator.of(context).maybePop(),
                                tooltip: MaterialLocalizations.of(context)
                                    .backButtonTooltip,
                              )
                            : null,
                        title: widget.onDemandOnlyList
                            ? tr('onDemandOnlyAppsTitle')
                            : tr('appsString'),
                        titleStyle: _searchExpanded
                            ? Theme.of(context).textTheme.titleSmall
                            : null,
                        actions: [
                          if (!_searchExpanded)
                            IconButton(
                              icon: const Icon(Icons.search),
                              onPressed: () {
                                setState(() => _searchExpanded = true);
                                _searchFocusNode.requestFocus();
                              },
                            )
                          else
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _searchExpanded = false;
                                _searchController.clear();
                                _searchFocusNode.unfocus();
                              }),
                            ),
                        ],
                        // Always use the compact layout so the action icon
                        // and "Apps" title are always on the same toolbar row.
                        searchWidget: _searchExpanded
                            ? _buildSearchBar(
                                colorScheme: Theme.of(context).colorScheme,
                                showFilterSheet: showFilterSheet,
                                neutralFilter: neutralFilter,
                                settingsProvider: settingsProvider,
                                focusNode: _searchFocusNode,
                              )
                            : const SizedBox.shrink(),
                        bottom: _buildFilterChipsRow(),
                      ),
                      ...getLoadingWidgets(),
                      getDisplayedList(),
                      if (!widget.onDemandOnlyList && onDemandOnlyAppCount > 0)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
                            child: SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    slideUpPageRoute(
                                      (_) => const AppsPage(
                                        onDemandOnlyList: true,
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(
                                  Icons.folder_special_outlined,
                                ),
                                label: Text(
                                  '${tr('onDemandOnly')} '
                                  '($onDemandOnlyAppCount)',
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (appsProvider.apps.isNotEmpty)
              _ScrollLinkedAppFooter(
                scrollController: scrollController,
                selectionActive: selectedAppIds.isNotEmpty,
                footer: Material(
                  elevation: 3,
                  surfaceTintColor:
                      Theme.of(context).colorScheme.surfaceTint,
                  color:
                      Theme.of(context).colorScheme.surfaceContainerLow,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: getFilterButtonsRow(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void openAppById(String appId) {
    AppsProvider appsProvider = context.read<AppsProvider>();

    AppInMemory? app = appsProvider.apps[appId];

    // Should exist, since we just looked it up, but just in case...
    if (app == null) {
      return;
    }

    Navigator.push(
      context,
      heroFriendlyAppPageRoute((_) => AppPage(appId: app.app.id)),
    );
  }
}

class AppsFilter {
  late String nameFilter;
  late String authorFilter;
  late String idFilter;
  late bool includeUptodate;
  late bool includeNonInstalled;
  late Set<String> categoryFilter;
  late String sourceFilter;

  AppsFilter({
    this.nameFilter = '',
    this.authorFilter = '',
    this.idFilter = '',
    this.includeUptodate = true,
    this.includeNonInstalled = true,
    this.categoryFilter = const {},
    this.sourceFilter = '',
  });

  Map<String, dynamic> toFormValuesMap() {
    return {
      'appName': nameFilter,
      'author': authorFilter,
      'appId': idFilter,
      'upToDateApps': includeUptodate,
      'nonInstalledApps': includeNonInstalled,
      'sourceFilter': sourceFilter,
    };
  }

  void setFormValuesFromMap(Map<String, dynamic> values) {
    nameFilter = values['appName']!;
    authorFilter = values['author']!;
    idFilter = values['appId']!;
    includeUptodate = values['upToDateApps'];
    includeNonInstalled = values['nonInstalledApps'];
    sourceFilter = values['sourceFilter'];
  }

  bool isIdenticalTo(AppsFilter other, SettingsProvider settingsProvider) =>
      authorFilter.trim() == other.authorFilter.trim() &&
      nameFilter.trim() == other.nameFilter.trim() &&
      idFilter.trim() == other.idFilter.trim() &&
      includeUptodate == other.includeUptodate &&
      includeNonInstalled == other.includeNonInstalled &&
      settingsProvider.setEqual(categoryFilter, other.categoryFilter) &&
      sourceFilter.trim() == other.sourceFilter.trim();
}
