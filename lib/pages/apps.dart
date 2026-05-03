import 'dart:async' show Timer, unawaited;
import 'dart:convert';

import 'package:animations/animations.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:expressive_refresh/expressive_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:progress_indicator_m3e/progress_indicator_m3e.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/page_route_slide_up.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:obtainium/widgets/help_hint_icon.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:markdown/markdown.dart' as md;

const double _appsListGroupCardRadius = kM3eGroupCardRadius;

/// Group header strip: stronger primary tint than rows; when luminance matches
/// row fill (common with Material You), nudge toward [surfaceBright] so the
/// header still reads as its own band.
Color _appsListGroupHeaderColor(ColorScheme scheme) {
  final Color rowFill = m3eGroupedListRowFill(scheme);
  Color header = Color.lerp(
    scheme.surfaceContainerHighest,
    scheme.primary,
    0.11,
  )!;
  if ((header.computeLuminance() - rowFill.computeLuminance()).abs() < 0.032) {
    header = Color.lerp(
      header,
      scheme.surfaceBright,
      scheme.brightness == Brightness.light ? 0.22 : 0.14,
    )!;
  }
  return header;
}

/// Collapsed group card; expanded header row uses inner radius on bottom edge.
const RoundedRectangleBorder _appsExpansionTileCollapsedShape =
    RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(_appsListGroupCardRadius)),
    );

const RoundedRectangleBorder _appsExpansionTileExpandedShape =
    RoundedRectangleBorder(
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(_appsListGroupCardRadius),
        topRight: Radius.circular(_appsListGroupCardRadius),
        bottomLeft: Radius.circular(kM3eInnerRadius),
        bottomRight: Radius.circular(kM3eInnerRadius),
      ),
    );

Widget _appsGroupedExpansionListBody({
  required ColorScheme scheme,
  required List<Widget> tiles,
}) {
  return ClipRRect(
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(kM3eInnerRadius),
    ),
    child: ColoredBox(
      color: m3eGroupedListBackdropFill(scheme),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: kM3eHeaderToFirstCardGap),
          ...tiles,
        ],
      ),
    ),
  );
}

// Android ApplicationInfo flag constants used for app type classification.
const int _androidFlagSystem = 1; // ApplicationInfo.FLAG_SYSTEM
const int _androidFlagUpdatedSystemApp =
    128; // ApplicationInfo.FLAG_UPDATED_SYSTEM_APP

/// App type groups for the "Group by App Type" feature.
enum AppTypeGroup { user, system, privileged }

/// Returns the [AppTypeGroup] for a given [AppInMemory] based on Android package flags.
/// Non-installed apps (no [AppInMemory.installedInfo]) are treated as user apps.
AppTypeGroup classifyAppType(AppInMemory app) {
  final info = app.installedInfo;
  if (info == null) return AppTypeGroup.user;
  final flags = info.applicationInfo?.flags ?? 0;
  final isSystem =
      (flags & _androidFlagSystem) != 0 ||
      (flags & _androidFlagUpdatedSystemApp) != 0;
  if (!isSystem) return AppTypeGroup.user;
  // Privileged: system app NOT updated by the user that lives in a privileged partition.
  final isUpdatedByUser = (flags & _androidFlagUpdatedSystemApp) != 0;
  if (!isUpdatedByUser) {
    final sourceDir = info.applicationInfo?.sourceDir ?? '';
    if (sourceDir.contains('/priv-app/') ||
        sourceDir.contains('/framework/') ||
        sourceDir.startsWith('/vendor/') ||
        sourceDir.startsWith('/odm/') ||
        sourceDir.startsWith('/oem/')) {
      return AppTypeGroup.privileged;
    }
  }
  return AppTypeGroup.system;
}

/// A labeled row with an info tooltip and a [Switch], used in the view-options sheet.
// `_GroupToggleRow` was here. Removed in favour of [SwitchListTile] at
// the call sites for consistency with the other rows in
// [showAppsViewOptionsSheet] (whole-row tap target, built-in InkWell,
// matching font and padding).

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
        a.app.pinned,
        a.app.categories.length,
        Object.hashAll(a.app.categories),
        a.app.additionalSettings['onDemandOnly'] == true,
        a.app.additionalSettings['skippedLatestVersion'],
        // Folder membership - needed so the main-page filter (hide foldered
        // apps) and folder-view filter both re-run when membership changes.
        Object.hashAll((a.app.additionalSettings['folderIds'] as List? ?? [])),
        // Icon fields deliberately excluded: each row watches its own icon
        // via _AppIconWidget.context.select, so icon loads only rebuild that
        // one row widget instead of the entire apps list.
        // [App.lastUpdateCheck] is also deliberately excluded. It changes for
        // every app on every pull-to-refresh and would otherwise force the
        // entire AppsPage (filter / sort / group / sliver list) to rebuild
        // on every notifyListeners() tick (~4 Hz) during checkUpdates, which
        // is the dominant cause of refresh-time scroll stutter on large lists.
        // The list will still re-sort once at the end of refresh because the
        // final notifyListeners() flips other fields (e.g. latestVersion) on
        // any apps that actually got an update. Users sorting by
        // [SortColumnSettings.lastUpdateCheck] see their order update once
        // the refresh finishes rather than continuously during it - this is
        // intentional, since reordering rows under the user's finger while
        // they try to scroll is itself a usability problem.
      ]),
    ),
  ]);
}

/// Progress bar shown during pull-to-refresh and initial app-load.
///
/// Subscribes to [AppsProvider] via a narrow [context.select] that returns
/// only `(loadingApps, checkedCount)`. As [AppsProvider.checkUpdates] saves
/// each app and calls [AppsProvider.notifyListeners] (~ every 250 ms),
/// `checkedCount` ticks up and only THIS widget rebuilds - the surrounding
/// [AppsPage] (filter / sort / sliver list) does not.
///
/// Counterpart to the deliberate exclusion of [App.lastUpdateCheck] from
/// [_appsPageAppsRebuildToken]. That exclusion is what fixed the scroll
/// stutter; this widget restores the live progress feedback that the
/// exclusion would otherwise have stripped out.
class _RefreshProgressBar extends StatelessWidget {
  const _RefreshProgressBar({
    required this.refreshingSince,
    required this.progressDenominator,
    required this.onDemandOnlyList,
    required this.folderId,
  });

  final DateTime? refreshingSince;
  final int progressDenominator;
  final bool onDemandOnlyList;
  final String? folderId;

  @override
  Widget build(BuildContext context) {
    final (bool loadingApps, int checkedCount) = context
        .select<AppsProvider, (bool, int)>((p) {
          if (p.loadingApps) {
            return (true, 0);
          }
          final DateTime? since = refreshingSince;
          if (since == null) {
            return (false, 0);
          }
          int count = 0;
          for (final a in p.apps.values) {
            final last = a.app.lastUpdateCheck;
            if (last == null || last.isBefore(since)) continue;
            if (onDemandOnlyList &&
                a.app.additionalSettings['onDemandOnly'] != true) {
              continue;
            }
            final String? folder = folderId;
            if (folder != null && !folderIdsForApp(a.app).contains(folder)) {
              continue;
            }
            count++;
          }
          return (false, count);
        });
    // M3 Expressive linear progress indicator. Wavy active track with a
    // stop-dot at the end (per the M3E spec). The widget draws two
    // separate lanes (active above, track below) with a fixed gap so the
    // active and inactive segments never overlap.
    return LinearProgressIndicatorM3E(
      value: loadingApps
          ? null
          : (progressDenominator > 0
                ? checkedCount / progressDenominator
                : 0.0),
    );
  }
}

/// An isolated icon widget that subscribes only to its own app's icon bytes.
/// When an icon finishes loading, only this widget rebuilds — not [AppsPage].
class _AppIconWidget extends StatelessWidget {
  const _AppIconWidget({required this.appId});

  final String appId;

  @override
  Widget build(BuildContext context) {
    final (Uint8List? icon, bool notInstalled) = context
        .select<AppsProvider, (Uint8List?, bool)>((p) {
          final a = p.apps[appId];
          return (a?.icon, a?.installedInfo == null);
        });
    if (icon != null) {
      final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final int iconCachePx = (40 * devicePixelRatio).round();
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          icon,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: iconCachePx,
          cacheHeight: iconCachePx,
          filterQuality: FilterQuality.low,
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
    required this.showAppTypeBadge,
    required this.showTrackedStoreBadge,
    this.sourceHost,
    this.itemBorderRadius,
  });

  final String appId;
  final bool isSelected;
  final bool areDownloadsRunning;
  final Widget iconWidget;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool highlightTouchTargets;
  final Map<String?, int> categoryColors;
  final bool showAppTypeBadge;
  final bool showTrackedStoreBadge;
  final String? sourceHost;
  final BorderRadius? itemBorderRadius;

  @override
  Widget build(BuildContext context) {
    // Full app data — rebuilds when any field changes (gated by page token).
    final AppInMemory? app = context.select<AppsProvider, AppInMemory?>(
      (p) => p.apps[appId],
    );
    if (app == null) return const SizedBox.shrink();

    // Download progress watched independently so only this row rebuilds on ticks.
    final double? downloadProgress = context.select<AppsProvider, double?>(
      (p) => p.apps[appId]?.downloadProgress,
    );

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final showChangesFn = getChangeLogFn(context, app.app);
    final installed = app.app.installedVersion;
    final hasUpdate = installed != null && appHasActionableUpdate(app.app);
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
            .downloadAndInstallLatestApps([
              app.app.id,
            ], globalNavigatorKey.currentContext)
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
        color: colorScheme.primary,
        tooltip: trackOnly ? tr('openDownloadPage') : tr('update'),
        onPressed: areDownloadsRunning ? null : onUpdateOrOpenReleasePressed,
        icon: const Icon(Icons.install_mobile),
      );
    }

    Widget buildUncertainUpdateButton() {
      return IconButton(
        visualDensity: VisualDensity.compact,
        color: colorScheme.primary,
        tooltip: tr('uncertainUpdateTooltip'),
        onPressed: areDownloadsRunning ? null : onUpdateOrOpenReleasePressed,
        icon: const Icon(Icons.help_outline),
      );
    }

    final String versionText = app.app.installedVersion ?? tr('notInstalled');
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
                  ? (theme.brightness == Brightness.light
                            ? theme.primaryColor
                            : theme.primaryColorLight)
                        .withAlpha(
                          theme.brightness == Brightness.light ? 20 : 40,
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

    final int transparent = colorScheme.surface.withValues(alpha: 0).toARGB32();
    List<double> stops = [
      ...app.app.categories.asMap().entries.map(
        (e) => ((e.key / (app.app.categories.length - 1)) - 0.0001),
      ),
      1,
    ];
    if (stops.length == 2) stops[0] = 0.9999;

    // App-type badge at bottom-right of icon — icon only, no background.
    final appType = classifyAppType(app);
    final (IconData appTypeIcon, Color appTypeColor) = switch (appType) {
      AppTypeGroup.user => (Icons.person_rounded, Colors.green),
      AppTypeGroup.system => (Icons.android_rounded, Colors.grey),
      AppTypeGroup.privileged => (Icons.security_rounded, Colors.grey.shade600),
    };
    // App type badge on icon (gated by showAppTypeBadge).
    final Widget iconWithBadge = showAppTypeBadge
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              iconWidget,
              Positioned(
                right: -3,
                bottom: -3,
                child: Icon(appTypeIcon, size: 14, color: appTypeColor),
              ),
            ],
          )
        : iconWidget;

    // Leading = [icon+type-badge] + [store column] inside ListTile.leading.
    // Store column always rendered (keeps title position stable); badge shown
    // only when showTrackedStoreBadge is true and sourceHost is known.
    final Widget leadingWidget = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        iconWithBadge,
        const SizedBox(width: 6),
        SizedBox(
          width: 20,
          child: Center(
            child: (showTrackedStoreBadge && sourceHost != null)
                ? Transform.scale(
                    scale: 1.25,
                    child: StoreSourceListBadge(host: sourceHost!),
                  )
                : null,
          ),
        ),
      ],
    );

    final Widget tile = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          stops: stops,
          begin: const Alignment(-1, 0),
          end: const Alignment(-0.97, 0),
          colors: [
            ...app.app.categories.map(
              (e) => Color(categoryColors[e] ?? transparent).withAlpha(255),
            ),
            Color(transparent),
          ],
        ),
      ),
      child: ListTile(
        tileColor: app.app.pinned
            ? Colors.grey.withValues(alpha: 0.1)
            : Colors.transparent,
        selectedTileColor: colorScheme.primary.withValues(
          alpha: app.app.pinned ? 0.2 : 0.1,
        ),
        selected: isSelected,
        onLongPress: onLongPress,
        leading: leadingWidget,
        title: Text(
          app.name,
          maxLines: 1,
          style: TextStyle(
            overflow: TextOverflow.ellipsis,
            fontWeight: app.app.pinned ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          tr('byX', args: [app.author]),
          maxLines: 1,
          style: TextStyle(
            overflow: TextOverflow.ellipsis,
            fontWeight: app.app.pinned ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        trailing: downloadProgress != null
            ? SizedBox(
                child: Text(
                  downloadProgress >= 0
                      ? tr(
                          'percentProgress',
                          args: [downloadProgress.toInt().toString()],
                        )
                      : tr('installing'),
                  textAlign: downloadProgress >= 0
                      ? TextAlign.start
                      : TextAlign.end,
                ),
              )
            : trailingRow,
        onTap: onTap,
      ),
    );

    if (itemBorderRadius != null) {
      return RepaintBoundary(
        child: Material(
          color: m3eGroupedListRowFill(colorScheme),
          shape: RoundedRectangleBorder(borderRadius: itemBorderRadius!),
          clipBehavior: Clip.antiAlias,
          child: tile,
        ),
      );
    }
    return RepaintBoundary(child: tile);
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
    slideUpPageRoute((_) => AdditionalOptionsPage(appId: appId)),
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
    this.appsListHeroFolderId,
  });

  final String appId;
  final String? appsListHeroFolderId;
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
              .downloadAndInstallLatestApps([
                widget.appId,
              ], globalNavigatorKey.currentContext)
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
                appsListHeroFolderId: widget.appsListHeroFolderId,
              ),
            ),
          );
        }
      case SwipeAction.delete:
        if (app != null) {
          // Capture messenger before the await – the widget may be disposed after removal
          final messenger = scaffoldMessengerKey.currentState;
          final RemoveAppsWithModalResult removeResult = await provider
              .removeAppsWithModal(context, [app]);
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
              child: Container(
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
  const AppsPage({super.key, this.onDemandOnlyList = false, this.folderId});

  /// When true, only apps with [App.additionalSettings] `onDemandOnly` are listed
  /// and pull-to-refresh checks only those IDs. When [folderId] is set,
  /// pull-to-refresh checks only apps in that folder. Otherwise (main list),
  /// pull-to-refresh checks all apps except on-demand-only (see
  /// [AppsProvider.getAppsSortedByUpdateCheckTime]).
  final bool onDemandOnlyList;

  /// When non-null, only apps belonging to this folder ID are shown.
  final String? folderId;

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
              ? InkWell(
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

void showAppsViewOptionsSheet(BuildContext context, {String? folderId}) {
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

          // Effective view-setting accessors — use per-folder overrides when
          // viewing a folder, otherwise fall back to global settings.
          final effectiveSortColumn = folderId != null
              ? settingsProvider.folderSortColumn(folderId)
              : settingsProvider.sortColumn;
          void setEffectiveSortColumn(SortColumnSettings v) => folderId != null
              ? settingsProvider.setFolderSortColumn(folderId, v)
              : (settingsProvider.sortColumn = v);

          final effectiveSortOrder = folderId != null
              ? settingsProvider.folderSortOrder(folderId)
              : settingsProvider.sortOrder;
          void setEffectiveSortOrder(SortOrderSettings v) => folderId != null
              ? settingsProvider.setFolderSortOrder(folderId, v)
              : (settingsProvider.sortOrder = v);

          final effectiveGroupBy = folderId != null
              ? settingsProvider.folderGroupBy(folderId)
              : settingsProvider.appsListGroupBy;
          void setEffectiveGroupBy(AppsListGroupBy v) => folderId != null
              ? settingsProvider.setFolderGroupBy(folderId, v)
              : (settingsProvider.appsListGroupBy = v);

          final effectivePinUpdates = folderId != null
              ? settingsProvider.folderPinUpdates(folderId)
              : settingsProvider.pinUpdates;
          void setEffectivePinUpdates(bool v) => folderId != null
              ? settingsProvider.setFolderPinUpdates(folderId, v)
              : (settingsProvider.pinUpdates = v);

          final effectiveBuryNonInstalled = folderId != null
              ? settingsProvider.folderBuryNonInstalled(folderId)
              : settingsProvider.buryNonInstalled;
          void setEffectiveBuryNonInstalled(bool v) => folderId != null
              ? settingsProvider.setFolderBuryNonInstalled(folderId, v)
              : (settingsProvider.buryNonInstalled = v);

          final effectiveGroupNonInstalledSeparately = folderId != null
              ? settingsProvider.folderGroupNonInstalledSeparately(folderId)
              : settingsProvider.groupNonInstalledSeparately;
          void setEffectiveGroupNonInstalledSeparately(bool v) =>
              folderId != null
              ? settingsProvider.setFolderGroupNonInstalledSeparately(
                  folderId,
                  v,
                )
              : (settingsProvider.groupNonInstalledSeparately = v);

          final effectiveGroupUpdatesSeparately = folderId != null
              ? settingsProvider.folderGroupUpdatesSeparately(folderId)
              : settingsProvider.groupUpdatesSeparately;
          void setEffectiveGroupUpdatesSeparately(bool v) => folderId != null
              ? settingsProvider.setFolderGroupUpdatesSeparately(folderId, v)
              : (settingsProvider.groupUpdatesSeparately = v);

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
                    Row(
                      children: [
                        Text(
                          tr('showBadges'),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(width: 12),
                        FilterChip(
                          avatar: const Icon(Icons.person_rounded, size: 16),
                          showCheckmark: false,
                          label: Text(tr('showAppTypeBadge')),
                          selected: settingsProvider.showAppTypeBadge,
                          onSelected: (value) {
                            settingsProvider.showAppTypeBadge = value;
                            setSheetState(() {});
                          },
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          avatar: const Icon(Icons.store_rounded, size: 16),
                          showCheckmark: false,
                          label: Text(tr('showTrackedStoreBadge')),
                          selected: settingsProvider.showTrackedStoreBadge,
                          onSelected: (value) {
                            settingsProvider.showTrackedStoreBadge = value;
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    Divider(color: colorScheme.outlineVariant),
                    const SizedBox(height: 8),
                    sectionLabel(tr('sortBy')),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        sortChip(
                          label: tr('authorName'),
                          selected:
                              effectiveSortColumn ==
                              SortColumnSettings.authorName,
                          onTap: () {
                            setEffectiveSortColumn(
                              SortColumnSettings.authorName,
                            );
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('nameAuthor'),
                          selected:
                              effectiveSortColumn ==
                              SortColumnSettings.nameAuthor,
                          onTap: () {
                            setEffectiveSortColumn(
                              SortColumnSettings.nameAuthor,
                            );
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('asAdded'),
                          selected:
                              effectiveSortColumn == SortColumnSettings.added,
                          onTap: () {
                            setEffectiveSortColumn(SortColumnSettings.added);
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('releaseDate'),
                          selected:
                              effectiveSortColumn ==
                              SortColumnSettings.releaseDate,
                          onTap: () {
                            setEffectiveSortColumn(
                              SortColumnSettings.releaseDate,
                            );
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('sortByLastUpdateCheck'),
                          selected:
                              effectiveSortColumn ==
                              SortColumnSettings.lastUpdateCheck,
                          onTap: () {
                            setEffectiveSortColumn(
                              SortColumnSettings.lastUpdateCheck,
                            );
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
                          selected:
                              effectiveSortOrder == SortOrderSettings.ascending,
                          onTap: () {
                            setEffectiveSortOrder(SortOrderSettings.ascending);
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('descending'),
                          selected:
                              effectiveSortOrder ==
                              SortOrderSettings.descending,
                          onTap: () {
                            setEffectiveSortOrder(SortOrderSettings.descending);
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
                          selected: effectiveGroupBy == AppsListGroupBy.none,
                          onTap: () {
                            setEffectiveGroupBy(AppsListGroupBy.none);
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('category'),
                          selected:
                              effectiveGroupBy == AppsListGroupBy.category,
                          onTap: () {
                            setEffectiveGroupBy(AppsListGroupBy.category);
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('groupByTrackedSource'),
                          selected: effectiveGroupBy == AppsListGroupBy.source,
                          onTap: () {
                            setEffectiveGroupBy(AppsListGroupBy.source);
                            setSheetState(() {});
                          },
                        ),
                        sortChip(
                          label: tr('groupByAppType'),
                          selected: effectiveGroupBy == AppsListGroupBy.appType,
                          onTap: () {
                            setEffectiveGroupBy(AppsListGroupBy.appType);
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    if (effectiveGroupBy != AppsListGroupBy.none)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('groupNonInstalledSeparately')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HelpHintIcon(
                              message: tr(
                                'groupNonInstalledSeparatelyDescription',
                              ),
                              padding: EdgeInsets.zero,
                            ),
                            Switch(
                              value: effectiveGroupNonInstalledSeparately,
                              onChanged: (value) {
                                setEffectiveGroupNonInstalledSeparately(value);
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                        onTap: () {
                          setEffectiveGroupNonInstalledSeparately(
                            !effectiveGroupNonInstalledSeparately,
                          );
                          setSheetState(() {});
                        },
                      ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('groupUpdatesSeparately')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          HelpHintIcon(
                            message: tr('groupUpdatesSeparatelyDescription'),
                            padding: EdgeInsets.zero,
                          ),
                          Switch(
                            value: effectiveGroupUpdatesSeparately,
                            onChanged: (value) {
                              setEffectiveGroupUpdatesSeparately(value);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        setEffectiveGroupUpdatesSeparately(
                          !effectiveGroupUpdatesSeparately,
                        );
                        setSheetState(() {});
                      },
                    ),
                    Divider(color: colorScheme.outlineVariant),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('pinUpdates')),
                      value: effectivePinUpdates,
                      onChanged: (value) {
                        setEffectivePinUpdates(value);
                        setSheetState(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr('moveNonInstalledAppsToBottom')),
                      value: effectiveBuryNonInstalled,
                      onChanged: (value) {
                        setEffectiveBuryNonInstalled(value);
                        setSheetState(() {});
                      },
                    ),
                    // Main-tab-only toggle: shows / hides foldered apps on
                    // this view AND scopes pull-to-refresh accordingly.
                    // Hidden when this sheet is opened from inside a folder
                    // view because the toggle has no meaning there - a
                    // folder always shows its own apps.
                    if (folderId == null)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('showFolderedAppsOnMainPage')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            HelpHintIcon(
                              message: tr('showFolderedAppsOnMainPageTooltip'),
                              padding: EdgeInsets.zero,
                            ),
                            Switch(
                              value:
                                  settingsProvider.showFolderedAppsOnMainPage,
                              onChanged: (value) {
                                settingsProvider.showFolderedAppsOnMainPage =
                                    value;
                                setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                        onTap: () {
                          settingsProvider.showFolderedAppsOnMainPage =
                              !settingsProvider.showFolderedAppsOnMainPage;
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

// Reserved settings key for the On-Demand Only page's per-view options.
const String _onDemandViewSettingsId = '__on_demand_only__';

class AppsPageState extends State<AppsPage> {
  AppsFilter filter = AppsFilter();
  final AppsFilter neutralFilter = AppsFilter();
  var updatesOnlyFilter = AppsFilter(
    includeUptodate: false,
    includeNonInstalled: false,
  );
  Set<String> selectedAppIds = {};
  DateTime? refreshingSince;
  bool initialAppLoadCompleted = false;

  bool clearSelected() {
    if (selectedAppIds.isNotEmpty) {
      setState(() {
        selectedAppIds.clear();
      });
      return true;
    }
    return false;
  }

  /// Called by [_HomePageState] when the system back button is pressed while
  /// this tab is active. Returns true if the back event was consumed.
  bool handleBack() {
    if (clearSelected()) return true;
    if (_searchExpanded) {
      setState(() {
        _searchExpanded = false;
        _searchController.clear();
        _searchFocusNode.unfocus();
      });
      return true;
    }
    final sp = context.read<SettingsProvider>();
    final isFilterActive =
        !filter.isIdenticalTo(neutralFilter, sp) || _searchField != 'appName';
    if (isFilterActive) {
      setState(() {
        filter = AppsFilter();
        _searchField = 'appName';
        _searchController.clear();
      });
      return true;
    }
    return false;
  }

  // Typed for [ExpressiveRefreshIndicatorState] (from expressive_refresh) so
  // we can call .show() to programmatically trigger the refresh from the
  // checkOnStart auto-refresh path. The state class mirrors Flutter's
  // [RefreshIndicatorState.show] API ({bool atTop = true}).
  final GlobalKey<ExpressiveRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<ExpressiveRefreshIndicatorState>();

  // ── Deferred background store-availability scan ───────────────────────────
  // The post-refresh APKMirror/F-Droid availability scan does ~50 HTTP fetches
  // and HTML parses (now off the UI isolate per [parseHtmlOffIsolate], but
  // still consumes radio + battery and can stutter network-dependent widgets).
  // We delay it by a few seconds after refresh completes so the user has
  // unimpeded scrolling during the immediate post-refresh window. Cancelled
  // on dispose and reset on each refresh.
  Timer? _deferredStoreScanTimer;
  static const Duration _deferredStoreScanDelay = Duration(seconds: 3);

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

  /// Maps [AppTypeGroup] → indices into [_listedAppsCache].
  Map<AppTypeGroup, List<int>> _appTypeGroupListedIndices = const {};
  List<int> _nonInstalledListedIndices = const [];

  /// Indices of apps shown in the "Updates" group (groupUpdatesSeparately).
  List<int> _updatesGroupListedIndices = const [];
  int? _lastGroupIndexCacheToken;

  // ── Group expansion state ─────────────────────────────────────────────────
  // Groups start expanded. When the user collapses one its key goes here and
  // its child tiles are no longer built, saving widget-tree work on rebuilds.
  final Set<String> _collapsedGroups = {};

  // ── Hero keep-alive ───────────────────────────────────────────────────────
  // Removed: previously held the appId of the row whose AppPage was open so
  // the row would stay mounted (via [_SwipeableListItem.keepAlive]) for the
  // back-pop Hero flight. With the [OpenContainer] (Container Transform)
  // migration in [getSingleAppHorizTile], the morph manages the source-row
  // lifecycle for the duration of the open animation, so manual keep-alive
  // is no longer required.

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

  // ── Effective view-setting helpers ─────────────────────────────────────────
  // When in a folder view, these return the folder's stored override or fall
  // back to the global setting. On the main page they just return the global.

  /// Returns the per-view settings key for this page, or null for the main page.
  String? get _viewSettingsId =>
      widget.folderId ??
      (widget.onDemandOnlyList ? _onDemandViewSettingsId : null);

  SortColumnSettings _effectiveSortColumn(SettingsProvider sp) {
    final id = _viewSettingsId;
    return id != null ? sp.folderSortColumn(id) : sp.sortColumn;
  }

  SortOrderSettings _effectiveSortOrder(SettingsProvider sp) {
    final id = _viewSettingsId;
    return id != null ? sp.folderSortOrder(id) : sp.sortOrder;
  }

  AppsListGroupBy _effectiveGroupBy(SettingsProvider sp) {
    final id = _viewSettingsId;
    return id != null ? sp.folderGroupBy(id) : sp.appsListGroupBy;
  }

  bool _effectivePinUpdates(SettingsProvider sp) {
    final id = _viewSettingsId;
    return id != null ? sp.folderPinUpdates(id) : sp.pinUpdates;
  }

  bool _effectiveBuryNonInstalled(SettingsProvider sp) {
    final id = _viewSettingsId;
    return id != null ? sp.folderBuryNonInstalled(id) : sp.buryNonInstalled;
  }

  bool _effectiveGroupNonInstalledSeparately(SettingsProvider sp) {
    final id = _viewSettingsId;
    return id != null
        ? sp.folderGroupNonInstalledSeparately(id)
        : sp.groupNonInstalledSeparately;
  }

  bool _effectiveGroupUpdatesSeparately(SettingsProvider sp) {
    final id = _viewSettingsId;
    return id != null
        ? sp.folderGroupUpdatesSeparately(id)
        : sp.groupUpdatesSeparately;
  }

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

  /// Switches the active search field, moving the current search text to the
  /// new field and clearing the old one.
  void _changeSearchField(String newField) {
    if (newField == _searchField) return;
    _changingSearchField = true;
    setState(() {
      final text = _searchController.text;
      // Clear the old field so the text isn't applied to two fields at once.
      _applySearchText(_searchField, '');
      _searchField = newField;
      // Move the current text to the new field.
      _applySearchText(newField, text);
      // Controller already has the text; no change needed.
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
    _deferredStoreScanTimer?.cancel();
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
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        suffix: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: showFilterSheet,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
      chips.add(
        _filterChip(
          tr('updatesOnly'),
          () => setState(() => filter.includeUptodate = true),
        ),
      );
    }

    if (!filter.includeNonInstalled) {
      chips.add(
        _filterChip(
          tr('installedOnly'),
          () => setState(() => filter.includeNonInstalled = true),
        ),
      );
    }

    if (filter.sourceFilter.isNotEmpty) {
      chips.add(
        _filterChip(
          '${tr('source')}: ${_getSourceName(filter.sourceFilter)}',
          () => setState(() => filter.sourceFilter = ''),
        ),
      );
    }

    for (final cat in filter.categoryFilter) {
      chips.add(
        _filterChip(
          cat,
          () => setState(
            () =>
                filter.categoryFilter = Set.from(filter.categoryFilter)
                  ..remove(cat),
          ),
        ),
      );
    }

    if (chips.isEmpty) return null;

    return PreferredSize(
      preferredSize: const Size.fromHeight(44),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          children: chips.expand((c) => [c, const SizedBox(width: 6)]).toList()
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
    final int appsToken = context.select<AppsProvider, int>(
      _appsPageAppsRebuildToken,
    );
    var appsProvider = context.read<AppsProvider>();
    // Narrow the SettingsProvider dependency to a hash of just the settings
    // that actually affect this page's build. The previous
    // `context.watch<SettingsProvider>()` subscribed to EVERY notification
    // - including ones for settings the apps page doesn't read (e.g.
    // useFGService, enableBackgroundUpdates, install-permission flags).
    // Each of those rebuilt the entire 4000+-line apps tree, which on
    // devices with many apps blocked the frame and made unrelated toggles
    // (in the view options sheet AND elsewhere) feel laggy.
    //
    // [context.select] only rebuilds the page when the returned hash
    // changes - so toggling foreground service in main settings, for
    // example, no longer triggers an apps-page rebuild at all.
    //
    // We still call [context.read] below for non-reactive access to
    // every other setting the page references (folder rule lookups,
    // setter calls, etc.).
    final String? watchedFolderId = widget.folderId;
    context.select<SettingsProvider, int>(
      (s) => Object.hash(
        s.showFolderedAppsOnMainPage,
        s.pinUpdates,
        s.buryNonInstalled,
        s.sortColumn,
        s.sortOrder,
        s.appsListGroupBy,
        s.groupNonInstalledSeparately,
        s.groupUpdatesSeparately,
        // categories is a Map<String?, int>; hash by length + sorted entries.
        Object.hashAll(s.categories.entries.map((e) => '${e.key}=${e.value}')),
        s.showAppTypeBadge,
        s.showTrackedStoreBadge,
        s.highlightTouchTargets,
        s.progressiveBlurEnabled,
        s.reduceVisualEffects,
        s.useGradientBackground,
        s.leftSwipeAction,
        s.rightSwipeAction,
        s.appFolders.length,
        // Folder-scoped overrides: only relevant when this page is a
        // folder view; a hash-as-zero collapse for the main-page case.
        watchedFolderId == null
            ? 0
            : Object.hash(
                s.folderPinUpdates(watchedFolderId),
                s.folderBuryNonInstalled(watchedFolderId),
                s.folderSortColumn(watchedFolderId).index,
                s.folderSortOrder(watchedFolderId).index,
                s.folderGroupBy(watchedFolderId).index,
                s.folderGroupNonInstalledSeparately(watchedFolderId),
                s.folderGroupUpdatesSeparately(watchedFolderId),
              ),
      ),
    );
    final SettingsProvider settingsProvider = context.read<SettingsProvider>();
    if (!initialAppLoadCompleted && !appsProvider.loadingApps) {
      initialAppLoadCompleted = true;
    }

    Future<void> backgroundScanStoreAvailability() async {
      late final List<String> idsForStoreHintScan;
      if (widget.onDemandOnlyList) {
        idsForStoreHintScan = appsProvider.apps.values
            .where((a) => a.app.additionalSettings['onDemandOnly'] == true)
            .map((a) => a.app.id)
            .toList();
      } else if (widget.folderId != null) {
        final String folderId = widget.folderId!;
        idsForStoreHintScan = appsProvider.apps.values
            .where((a) => folderIdsForApp(a.app).contains(folderId))
            .map((a) => a.app.id)
            .toList();
      } else {
        idsForStoreHintScan = appsProvider.apps.values
            .where((a) => a.app.additionalSettings['onDemandOnly'] != true)
            .map((a) => a.app.id)
            .toList();
      }
      if (idsForStoreHintScan.isEmpty) return;
      final cache = await BulkScanCache.load();
      final needsApkMirror = idsForStoreHintScan
          .where((id) => !(cache[id]?.containsKey('APKMirror') ?? false))
          .toList();
      final needsFDroid = idsForStoreHintScan
          .where((id) => !(cache[id]?.containsKey('F-Droid') ?? false))
          .toList();
      if (needsApkMirror.isEmpty && needsFDroid.isEmpty) return;
      await Future.wait([
        if (needsApkMirror.isNotEmpty)
          BulkImportService.checkApkMirror(
            needsApkMirror,
          ).then((r) => BulkScanCache.mergeStoreAndSave(cache, 'APKMirror', r)),
        if (needsFDroid.isNotEmpty)
          BulkImportService.checkFDroid(
            needsFDroid,
          ).then((r) => BulkScanCache.mergeStoreAndSave(cache, 'F-Droid', r)),
      ]);
    }

    refresh() {
      HapticFeedback.lightImpact();
      setState(() {
        refreshingSince = DateTime.now();
        // Note: [_appListIconWarmFutures] is intentionally NOT cleared here.
        // Clearing it caused every visible row to re-enter [updateAppIcon] on
        // every pull-to-refresh, which on 50+ apps means 50 disk reads of the
        // user-icon override file plus 50 platform-channel calls back to the
        // OS - all on the UI isolate, all while the user is trying to scroll.
        // Icons are keyed by [App.id] and don't change just because we ran
        // an update check, so the warm map stays valid across refreshes.
        // Forced re-decode of a specific app's icon already goes through
        // [AppsProvider.updateAppIcon] with `ignoreCache: true` from the
        // app-detail page, which bypasses this map.
      });
      final Future<List<App>> refreshFuture;
      if (widget.onDemandOnlyList) {
        refreshFuture = appsProvider.checkUpdates(
          specificIds: appsProvider.apps.values
              .where((a) => a.app.additionalSettings['onDemandOnly'] == true)
              .map((a) => a.app.id)
              .toList(),
        );
      } else if (widget.folderId != null) {
        final String folderId = widget.folderId!;
        refreshFuture = appsProvider.checkUpdates(
          specificIds: appsProvider.apps.values
              .where((a) => folderIdsForApp(a.app).contains(folderId))
              .map((a) => a.app.id)
              .toList(),
        );
      } else {
        // Main list: refresh scope matches what's visible on this tab.
        //
        // The pull-to-refresh contract is "refresh what I see". When
        // [SettingsProvider.showFolderedAppsOnMainPage] is on, foldered
        // apps are visible on the main tab and are included in the
        // refresh, just like before. When it's off, foldered apps are
        // hidden from the main tab - users have organized them into
        // folders specifically to declutter the main view - so we exclude
        // them from the refresh too. Each folder still has its own
        // pull-to-refresh that scans only that folder's apps.
        // Foldered apps are still picked up by background update checks
        // (when enabled), so they don't go indefinitely stale.
        //
        // [getAppsSortedByUpdateCheckTime] already skips on-demand-only
        // apps; we don't have to filter those out here.
        if (settingsProvider.showFolderedAppsOnMainPage) {
          refreshFuture = appsProvider.checkUpdates();
        } else {
          refreshFuture = appsProvider.checkUpdates(
            specificIds: appsProvider.apps.values
                .where((a) => folderIdsForApp(a.app).isEmpty)
                .map((a) => a.app.id)
                .toList(),
          );
        }
      }
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
            // Defer the background store-availability scan so the user gets
            // a few seconds of unimpeded UI right after the refresh
            // completes. Reset the timer if another refresh fires before the
            // delay elapses (debounce-ish behaviour: only the most recent
            // refresh's scan is queued at any time).
            _deferredStoreScanTimer?.cancel();
            _deferredStoreScanTimer = Timer(_deferredStoreScanDelay, () {
              _deferredStoreScanTimer = null;
              if (!mounted) return;
              unawaited(backgroundScanStoreAvailability());
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
      widget.folderId,
      settingsProvider.showFolderedAppsOnMainPage,
      filter.nameFilter,
      filter.authorFilter,
      filter.idFilter,
      filter.includeUptodate,
      filter.includeNonInstalled,
      Object.hashAll(filter.categoryFilter.toList()..sort()),
      filter.sourceFilter,
      _effectiveSortColumn(settingsProvider).index,
      _effectiveSortOrder(settingsProvider).index,
      _effectiveGroupBy(settingsProvider).index,
      _effectivePinUpdates(settingsProvider),
      _effectiveBuryNonInstalled(settingsProvider),
      _effectiveGroupNonInstalledSeparately(settingsProvider),
      _effectiveGroupUpdatesSeparately(settingsProvider),
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

      // ── Folder filter ───────────────────────────────────────────────────
      if (widget.folderId != null) {
        workingList = workingList
            .where(
              (appInMem) =>
                  folderIdsForApp(appInMem.app).contains(widget.folderId),
            )
            .toList();
      } else if (!widget.onDemandOnlyList &&
          !settingsProvider.showFolderedAppsOnMainPage) {
        // On the main page only: hide apps that belong to any folder.
        // The on-demand page shows all on-demand apps regardless of folder membership.
        workingList = workingList
            .where((appInMem) => folderIdsForApp(appInMem.app).isEmpty)
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

      final sortCol = _effectiveSortColumn(settingsProvider);
      final sortOrd = _effectiveSortOrder(settingsProvider);
      workingList.sort((a, b) {
        int result = 0;
        if (sortCol == SortColumnSettings.authorName) {
          result = ((a.author + a.name).toLowerCase()).compareTo(
            (b.author + b.name).toLowerCase(),
          );
        } else if (sortCol == SortColumnSettings.nameAuthor) {
          result = ((a.name + a.author).toLowerCase()).compareTo(
            (b.name + b.author).toLowerCase(),
          );
        } else if (sortCol == SortColumnSettings.releaseDate) {
          // Handle null dates: apps with unknown release dates go to end.
          final aDate = a.app.releaseDate;
          final bDate = b.app.releaseDate;
          final isDescending = sortOrd == SortOrderSettings.descending;
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
        } else if (sortCol == SortColumnSettings.lastUpdateCheck) {
          final aDate = a.app.lastUpdateCheck;
          final bDate = b.app.lastUpdateCheck;
          final isDescending = sortOrd == SortOrderSettings.descending;
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
        } else if (sortCol == SortColumnSettings.added) {
          result = 0;
        }
        return result;
      });

      if (sortOrd == SortOrderSettings.descending) {
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
      _newInstallsCache = appsProvider
          .findExistingUpdates(nonInstalledOnly: true)
          .toList();

      if (_effectivePinUpdates(settingsProvider)) {
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

      if (_effectiveBuryNonInstalled(settingsProvider)) {
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
    var listedApps = _listedAppsCache;
    final existingUpdates = _existingUpdatesCache;
    final newInstalls = _newInstallsCache;
    final int onDemandOnlyAppCount = appsProvider.apps.values
        .where((a) => a.app.additionalSettings['onDemandOnly'] == true)
        .length;

    // Folder counts: number of non-on-demand apps in each folder.
    final appFolders = settingsProvider.appFolders;
    final Map<String, int> folderAppCounts = {
      for (final f in appFolders)
        f.id: appsProvider.apps.values
            .where(
              (a) =>
                  a.app.additionalSettings['onDemandOnly'] != true &&
                  folderIdsForApp(a.app).contains(f.id),
            )
            .length,
    };
    // Update counts per folder (mirrors the badge logic on the home tab icon).
    final Map<String, int> folderUpdateCounts = {
      for (final f in appFolders)
        f.id: appsProvider.apps.values
            .where(
              (a) =>
                  a.app.additionalSettings['onDemandOnly'] != true &&
                  folderIdsForApp(a.app).contains(f.id) &&
                  (appHasActionableUpdate(a.app) ||
                      versionOrderUncertainUpdate(a.app)),
            )
            .length,
    };
    final String? currentFolderName = widget.folderId != null
        ? appFolders
              .where((f) => f.id == widget.folderId)
              .map((f) => f.name)
              .firstOrNull
        : null;

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

    final effectiveGroupBy = _effectiveGroupBy(settingsProvider);
    final segregateNonInstalled =
        _effectiveGroupNonInstalledSeparately(settingsProvider) &&
        (effectiveGroupBy == AppsListGroupBy.category ||
            effectiveGroupBy == AppsListGroupBy.source ||
            effectiveGroupBy == AppsListGroupBy.appType);
    final separateUpdates = _effectiveGroupUpdatesSeparately(settingsProvider);

    // Returns true when an app should be shown in the dedicated "Updates" group.
    bool isInUpdatesGroup(AppInMemory e) =>
        separateUpdates &&
        _existingUpdatesCache.contains(e.app.id) &&
        e.app.additionalSettings['onDemandOnly'] != true;

    var tempRenamed = <AppInMemory>[];
    var tempPinned = <AppInMemory>[];
    var tempNotPinned = <AppInMemory>[];
    for (final AppInMemory listedApp in listedApps) {
      if (listedApp.app.hasPendingRepoRename) {
        tempRenamed.add(listedApp);
      } else if (listedApp.app.pinned) {
        tempPinned.add(listedApp);
      } else {
        tempNotPinned.add(listedApp);
      }
    }
    listedApps = [...tempRenamed, ...tempPinned, ...tempNotPinned];

    // Apps that go into normal category/source/appType groups (excluding
    // segregated non-installed and the updates group when those features are on).
    List<AppInMemory> appsForGroups(List<AppInMemory> source) => source
        .where(
          (e) =>
              !(segregateNonInstalled && e.app.installedVersion == null) &&
              !isInUpdatesGroup(e),
        )
        .toList();

    final appsListedForCategoryKeys = appsForGroups(listedApps);
    final appsListedForSourceKeys = appsListedForCategoryKeys;
    final appsListedForAppTypeKeys = appsListedForCategoryKeys;
    final showNonInstalledGroupSection =
        segregateNonInstalled &&
        listedApps.any((e) => e.app.installedVersion == null);
    final showUpdatesGroupSection =
        separateUpdates && listedApps.any(isInUpdatesGroup);

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
      keys.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return keys;
    }

    var listedSources = getListedSourceKeys(appsListedForSourceKeys);

    // App types that are present in the non-updates, non-uninstalled subset.
    final listedAppTypes = AppTypeGroup.values
        .where(
          (t) => appsListedForAppTypeKeys.any((e) => classifyAppType(e) == t),
        )
        .toList();

    if (listBuildToken != _lastGroupIndexCacheToken) {
      _lastGroupIndexCacheToken = listBuildToken;
      final nextCategoryMap = <String, List<int>>{};
      for (
        int categoryIndex = 0;
        categoryIndex < listedCategories.length;
        categoryIndex++
      ) {
        final String? categoryNullable = listedCategories[categoryIndex];
        final String mapKey = categoryNullable ?? '__null__';
        final indices = <int>[];
        for (
          int listingIndex = 0;
          listingIndex < listedApps.length;
          listingIndex++
        ) {
          final AppInMemory row = listedApps[listingIndex];
          if (segregateNonInstalled && row.app.installedVersion == null) {
            continue;
          }
          if (isInUpdatesGroup(row)) continue;
          if (row.app.categories.contains(categoryNullable) ||
              (row.app.categories.isEmpty && categoryNullable == null)) {
            indices.add(listingIndex);
          }
        }
        nextCategoryMap[mapKey] = indices;
      }
      _categoryGroupListedIndices = nextCategoryMap;

      final nextSourceMap = <String, List<int>>{};
      for (
        int sourceIndex = 0;
        sourceIndex < listedSources.length;
        sourceIndex++
      ) {
        final String sourceKey = listedSources[sourceIndex];
        final indices = <int>[];
        for (
          int listingIndex = 0;
          listingIndex < listedApps.length;
          listingIndex++
        ) {
          final AppInMemory row = listedApps[listingIndex];
          if (segregateNonInstalled && row.app.installedVersion == null) {
            continue;
          }
          if (isInUpdatesGroup(row)) continue;
          if (sourceProvider
                  .getSource(
                    row.app.url,
                    overrideSource: row.app.overrideSource,
                  )
                  .runtimeType
                  .toString() ==
              sourceKey) {
            indices.add(listingIndex);
          }
        }
        nextSourceMap[sourceKey] = indices;
      }
      _sourceGroupListedIndices = nextSourceMap;

      final nextAppTypeMap = <AppTypeGroup, List<int>>{};
      for (final type in AppTypeGroup.values) {
        final indices = <int>[];
        for (
          int listingIndex = 0;
          listingIndex < listedApps.length;
          listingIndex++
        ) {
          final AppInMemory row = listedApps[listingIndex];
          if (segregateNonInstalled && row.app.installedVersion == null) {
            continue;
          }
          if (isInUpdatesGroup(row)) continue;
          if (classifyAppType(row) == type) {
            indices.add(listingIndex);
          }
        }
        if (indices.isNotEmpty) nextAppTypeMap[type] = indices;
      }
      _appTypeGroupListedIndices = nextAppTypeMap;

      final nonInstalled = <int>[];
      for (
        int listingIndex = 0;
        listingIndex < listedApps.length;
        listingIndex++
      ) {
        if (listedApps[listingIndex].app.installedVersion == null) {
          nonInstalled.add(listingIndex);
        }
      }
      _nonInstalledListedIndices = nonInstalled;

      final updatesIndices = <int>[];
      for (
        int listingIndex = 0;
        listingIndex < listedApps.length;
        listingIndex++
      ) {
        if (isInUpdatesGroup(listedApps[listingIndex])) {
          updatesIndices.add(listingIndex);
        }
      }
      _updatesGroupListedIndices = updatesIndices;
    }

    Set<App> selectedApps = listedApps
        .map((e) => e.app)
        .where((a) => selectedAppIds.contains(a.id))
        .toSet();

    getLoadingWidgets() {
      final String? progressFolderId = widget.folderId;
      final int folderMemberCountForProgress = progressFolderId == null
          ? 0
          : appsProvider.apps.values
                .where((a) => folderIdsForApp(a.app).contains(progressFolderId))
                .length;
      final int progressDenominator = widget.onDemandOnlyList
          ? (onDemandOnlyAppCount > 0 ? onDemandOnlyAppCount : 1)
          : progressFolderId != null
          ? (folderMemberCountForProgress > 0
                ? folderMemberCountForProgress
                : 1)
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
        // Show the bar only for explicit user-initiated refreshes
        // ([refreshingSince] != null) OR for the first app-load before this
        // page has seen loading complete. Silent foreground reloads also set
        // [loadingApps], and the app list can legitimately be empty then; the
        // one-shot guard prevents that empty-library edge case from flashing
        // the progress bar.
        if (refreshingSince != null ||
            (!initialAppLoadCompleted &&
                appsProvider.loadingApps &&
                appsProvider.apps.isEmpty))
          SliverToBoxAdapter(
            // Top padding pushes the bar clear of the [CustomAppBar] blur
            // overlay's bottom edge - sitting flush against it produced a
            // visible half-blurred line through the indicator.
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _RefreshProgressBar(
                refreshingSince: refreshingSince,
                progressDenominator: progressDenominator,
                onDemandOnlyList: widget.onDemandOnlyList,
                folderId: progressFolderId,
              ),
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
          tag: widget.folderId != null
              ? 'folder-${widget.folderId}-icon-$rowAppId'
              : 'app-icon-$rowAppId',
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
                appsListHeroFolderId: widget.folderId,
              ),
            ),
          );
        },
      );
    }

    getSingleAppHorizTile(
      int index, {
      M3eListGroupPosition? groupPosition,
      bool flatListBody = false,
    }) {
      final app = listedApps[index];
      final appId = app.app.id;
      final installed = app.app.installedVersion;
      final hasUpdate = installed != null && appHasActionableUpdate(app.app);
      final hasUncertainUpdate =
          installed != null && versionOrderUncertainUpdate(app.app);
      final downloadsRunning = appsProvider.areDownloadsRunning();
      final sourceHost = sourceProvider
          .getSource(app.app.url, overrideSource: app.app.overrideSource)
          .hosts
          .firstOrNull;
      // M3 Container Transform: tapping the row morphs the row's container
      // into the AppPage's container. Replaces the previous
      // `Navigator.push(heroFriendlyAppPageRoute(...))` flow plus the
      // `_heroKeepaliveAppId` keep-alive state machine - OpenContainer
      // owns the widget lifecycle during the morph, so we no longer
      // need to keep the source row alive manually.
      //
      // Selection mode (`selectedAppIds.isNotEmpty`) still routes the tap
      // to [toggleAppSelected]; it never triggers the morph in that mode.
      // Long-press still toggles selection. Swipe actions on the row are
      // unaffected because they're handled inside [_SwipeableListItem].
      // The icon's own onLongPress (which opens AppPage with the opposite
      // view) still uses the standard Navigator.push - that's a secondary
      // path and doesn't benefit from container transform.
      final BorderRadius? itemRadius = groupPosition != null
          ? m3eListGroupItemRadius(groupPosition, flatListBody: flatListBody)
          : null;

      // Builds the row visual given the callback that should fire when the
      // user taps a non-selected row. Used by both the OpenContainer path
      // (callback = openContainer) and the [reduceVisualEffects] fallback
      // path (callback = direct Navigator.push).
      Widget buildRowWith(VoidCallback navigateToAppPage) => _SwipeableListItem(
        key: ValueKey(appId),
        appId: appId,
        hasUpdate: hasUpdate || hasUncertainUpdate,
        isPinned: app.app.pinned,
        isInstalled: installed != null,
        areDownloadsRunning: downloadsRunning,
        keepAlive: false,
        rightAction: settingsProvider.rightSwipeAction,
        leftAction: settingsProvider.leftSwipeAction,
        appsListHeroFolderId: widget.folderId,
        child: _AppListItem(
          appId: appId,
          isSelected: selectedAppIds.contains(appId),
          areDownloadsRunning: downloadsRunning,
          iconWidget: getAppIcon(index),
          sourceHost: sourceHost,
          showAppTypeBadge: settingsProvider.showAppTypeBadge,
          showTrackedStoreBadge: settingsProvider.showTrackedStoreBadge,
          onTap: selectedAppIds.isNotEmpty
              ? () => toggleAppSelected(app.app)
              : navigateToAppPage,
          onLongPress: () => toggleAppSelected(app.app),
          highlightTouchTargets: settingsProvider.highlightTouchTargets,
          categoryColors: settingsProvider.categories,
          itemBorderRadius: itemRadius,
        ),
      );

      // M3 Container Transform: tapping the row morphs the row's container
      // into the AppPage's container. Replaces the previous
      // `Navigator.push(heroFriendlyAppPageRoute(...))` flow plus the
      // `_heroKeepaliveAppId` keep-alive state machine - OpenContainer
      // owns the widget lifecycle during the morph, so we no longer
      // need to keep the source row alive manually.
      //
      // When [SettingsProvider.reduceVisualEffects] is on, we skip the
      // morph entirely and use a plain page-route push. The morph
      // rasterizes the source AND target during the transition (both
      // expensive) and is one of the heavier paint costs in the app -
      // dropping it gives users on weaker hardware their frame budget
      // back during navigation.
      //
      // Selection mode (`selectedAppIds.isNotEmpty`) still routes the tap
      // to [toggleAppSelected]; it never triggers navigation in that mode.
      // Long-press still toggles selection. Swipe actions on the row are
      // unaffected because they're handled inside [_SwipeableListItem].
      // The icon's own onLongPress (which opens AppPage with the opposite
      // view) still uses the standard Navigator.push - that's a secondary
      // path and doesn't benefit from container transform.
      final Widget swipeItem = settingsProvider.reduceVisualEffects
          ? buildRowWith(
              () => Navigator.push(
                context,
                heroFriendlyAppPageRoute(
                  (_) => AppPage(
                    appId: appId,
                    appsListHeroFolderId: widget.folderId,
                  ),
                ),
              ),
            )
          : OpenContainer(
              key: ValueKey('open-$appId'),
              closedColor: Colors.transparent,
              openColor: Theme.of(context).scaffoldBackgroundColor,
              closedElevation: 0,
              openElevation: 0,
              transitionType: ContainerTransitionType.fadeThrough,
              transitionDuration: const Duration(milliseconds: 320),
              closedShape: itemRadius != null
                  ? RoundedRectangleBorder(borderRadius: itemRadius)
                  : const RoundedRectangleBorder(),
              // We drive the open trigger from [_AppListItem.onTap] ourselves
              // so selection-mode taps stay routed to [toggleAppSelected].
              tappable: false,
              openBuilder: (BuildContext _, VoidCallback _) =>
                  AppPage(appId: appId, appsListHeroFolderId: widget.folderId),
              closedBuilder: (BuildContext _, VoidCallback openContainer) =>
                  buildRowWith(openContainer),
            );
      if (groupPosition != null) {
        return ClipRRect(
          borderRadius: m3eListGroupItemRadius(
            groupPosition,
            flatListBody: flatListBody,
          ),
          child: swipeItem,
        );
      }
      return swipeItem;
    }

    /// Ungrouped list: each app as its own M3E card; corners follow [flatListBody]
    /// rules with [first]/[middle]/[last]/[only] by index in the run.
    Widget flatListAppRow(
      int listedAppIndex,
      int indexInRun,
      int runLength, {
      bool spacerBeforeFirstRow = false,
      bool spacerAfterLastRow = false,
    }) {
      final bool gapBeforeTile = indexInRun > 0 || spacerBeforeFirstRow;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (gapBeforeTile) const SizedBox(height: kM3eItemGap),
            if (indexInRun == 0 && !spacerBeforeFirstRow)
              const SizedBox(height: 6),
            getSingleAppHorizTile(
              listedAppIndex,
              groupPosition: runLength == 1
                  ? M3eListGroupPosition.only
                  : indexInRun == 0
                  ? M3eListGroupPosition.first
                  : indexInRun == runLength - 1
                  ? M3eListGroupPosition.last
                  : M3eListGroupPosition.middle,
              flatListBody: true,
            ),
            if (indexInRun == runLength - 1) ...[
              const SizedBox(height: 6),
              if (spacerAfterLastRow) const SizedBox(height: kM3eItemGap),
            ],
          ],
        ),
      );
    }

    // Builds a position-aware children list with 2px gaps for M3E grouped style.
    List<Widget> buildGroupedChildren(List<int> indices) {
      final int n = indices.length;
      return [
        for (int i = 0; i < n; i++) ...[
          if (i > 0) const SizedBox(height: kM3eItemGap),
          getSingleAppHorizTile(
            indices[i],
            groupPosition: n == 1
                ? M3eListGroupPosition.only
                : i == 0
                ? M3eListGroupPosition.first
                : i == n - 1
                ? M3eListGroupPosition.last
                : M3eListGroupPosition.middle,
          ),
        ],
      ];
    }

    getCategoryCollapsibleTile(int index) {
      final catKey = 'cat:${listedCategories[index] ?? '__null__'}';
      final isExpanded = !_collapsedGroups.contains(catKey);

      final String categoryMapKey = listedCategories[index] ?? '__null__';
      final matchingIndices =
          _categoryGroupListedIndices[categoryMapKey] ?? const <int>[];
      final tiles = isExpanded
          ? buildGroupedChildren(matchingIndices)
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
            color: _appsListGroupHeaderColor(theme.colorScheme),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey(catKey),
                shape: _appsExpansionTileExpandedShape,
                collapsedShape: _appsExpansionTileCollapsedShape,
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
                childrenPadding: EdgeInsets.zero,
                children: [
                  _appsGroupedExpansionListBody(
                    scheme: theme.colorScheme,
                    tiles: tiles,
                  ),
                ],
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
          ? buildGroupedChildren(matchingIndices)
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
            color: _appsListGroupHeaderColor(theme.colorScheme),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const PageStorageKey(nonInstalledKey),
                shape: _appsExpansionTileExpandedShape,
                collapsedShape: _appsExpansionTileCollapsedShape,
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
                childrenPadding: EdgeInsets.zero,
                children: [
                  _appsGroupedExpansionListBody(
                    scheme: theme.colorScheme,
                    tiles: tiles,
                  ),
                ],
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
          ? buildGroupedChildren(matchingIndices)
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
            color: _appsListGroupHeaderColor(theme.colorScheme),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey(groupKey),
                shape: _appsExpansionTileExpandedShape,
                collapsedShape: _appsExpansionTileCollapsedShape,
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
                childrenPadding: EdgeInsets.zero,
                children: [
                  _appsGroupedExpansionListBody(
                    scheme: theme.colorScheme,
                    tiles: tiles,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // ── Generic collapsible group tile ──────────────────────────────────────
    Widget buildCollapsibleTile({
      required String groupKey,
      required String title,
      required List<int> matchingIndices,
    }) {
      final isExpanded = !_collapsedGroups.contains(groupKey);
      final tiles = isExpanded
          ? buildGroupedChildren(matchingIndices)
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
            color: _appsListGroupHeaderColor(theme.colorScheme),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey(groupKey),
                shape: _appsExpansionTileExpandedShape,
                collapsedShape: _appsExpansionTileCollapsedShape,
                initiallyExpanded: isExpanded,
                onExpansionChanged: (expanded) => setState(() {
                  if (expanded) {
                    _collapsedGroups.remove(groupKey);
                  } else {
                    _collapsedGroups.add(groupKey);
                  }
                }),
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                trailing: Text(matchingIndices.length.toString()),
                childrenPadding: EdgeInsets.zero,
                children: [
                  _appsGroupedExpansionListBody(
                    scheme: theme.colorScheme,
                    tiles: tiles,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    getAppTypeCollapsibleTile(AppTypeGroup type) {
      final String groupKey = 'appType:${type.name}';
      final matchingIndices = _appTypeGroupListedIndices[type] ?? const <int>[];
      final String title = switch (type) {
        AppTypeGroup.user => tr('appTypeUser'),
        AppTypeGroup.system => tr('appTypeSystem'),
        AppTypeGroup.privileged => tr('appTypePrivileged'),
      };
      return buildCollapsibleTile(
        groupKey: groupKey,
        title: title,
        matchingIndices: matchingIndices,
      );
    }

    getUpdatesCollapsibleTile() {
      return buildCollapsibleTile(
        groupKey: '__updates__',
        title: tr('updatesGroup'),
        matchingIndices: _updatesGroupListedIndices,
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
                      Navigator.of(context).pop();
                      _showFolderAssignDialog(context, selectedApps);
                    },
                    child: Text(tr('addToFolder'), textAlign: TextAlign.center),
                  ),
                  const Divider(),
                  TextButton(
                    onPressed: () {
                      String urls = '';
                      for (var a in selectedApps) {
                        urls += '${a.url}\n';
                      }
                      urls = urls.substring(0, urls.length - 1);
                      SharePlus.instance.share(
                        ShareParams(
                          text: urls,
                          subject: 'ObtainX - ${tr('appsString')}',
                        ),
                      );
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
                            SharePlus.instance.share(
                              ShareParams(
                                text: urls,
                                subject: 'ObtainX - ${tr('appsString')}',
                              ),
                            );
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
                            SharePlus.instance.share(
                              ShareParams(
                                files: [f],
                                fileNameOverrides: ['$fn.json'],
                              ),
                            );
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
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
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
                        onChanged: (v) =>
                            update(() => filter.includeUptodate = v),
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
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: CategoryEditorSelector(
                          allowCategoryManagement: false,
                          preselected: filter.categoryFilter,
                          onSelected: (categories) {
                            update(() {
                              filter.categoryFilter = categories.toSet();
                            });
                          },
                        ),
                      ),

                      // ── Save as Folder ────────────────────────────────────
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          20,
                          12,
                          20,
                          20 + MediaQuery.of(context).viewPadding.bottom,
                        ),
                        child: OutlinedButton.icon(
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 18,
                          ),
                          label: Text(tr('saveAsFolder')),
                          onPressed: () {
                            Navigator.of(sheetCtx).pop();
                            _saveFilterAsFolder(context, filter);
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
                      final int removedCount =
                          removeResult.deferredUndoAppIds.isNotEmpty
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
                  onPressed: getMassObtainFunction(),
                  tooltip: tr('installUpdateSelectedApps'),
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
                onPressed: () => showAppsViewOptionsSheet(
                  context,
                  folderId: _viewSettingsId,
                ),
                icon: const Icon(Icons.tune),
              ),
            ),
          ),
        ],
      );
    }

    getDisplayedList() {
      final groupBy = effectiveGroupBy;
      final pinUpdatesEnabled = _effectivePinUpdates(settingsProvider);

      // Builds a SliverList where the optional updates group is prepended
      // (pinUpdatesEnabled=true) or appended (false) to [mainChildCount] items
      // built by [mainBuilder].
      SliverList buildGroupedSliver({
        required int mainChildCount,
        required Widget Function(int index) mainBuilder,
      }) {
        final totalCount =
            mainChildCount +
            (showNonInstalledGroupSection ? 1 : 0) +
            (showUpdatesGroupSection ? 1 : 0);
        return SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            int i = index;
            // Updates group pinned to top.
            if (showUpdatesGroupSection && pinUpdatesEnabled) {
              if (i == 0) return getUpdatesCollapsibleTile();
              i--;
            }
            // Main groups.
            if (i < mainChildCount) return mainBuilder(i);
            i -= mainChildCount;
            // Non-installed group.
            if (showNonInstalledGroupSection) {
              if (i == 0) return getNonInstalledCollapsibleTile();
              i--;
            }
            // Updates group at bottom (when not pinned).
            if (showUpdatesGroupSection && !pinUpdatesEnabled) {
              if (i == 0) return getUpdatesCollapsibleTile();
            }
            return null;
          }, childCount: totalCount),
        );
      }

      final useCategoryGroups =
          groupBy == AppsListGroupBy.category &&
          (segregateNonInstalled
              ? (listedCategories.isNotEmpty || showNonInstalledGroupSection)
              : !(listedCategories.isEmpty ||
                    (listedCategories.length == 1 &&
                        listedCategories[0] == null)));
      if (useCategoryGroups) {
        return buildGroupedSliver(
          mainChildCount: listedCategories.length,
          mainBuilder: (i) => getCategoryCollapsibleTile(i),
        );
      }

      final useSourceGroups =
          groupBy == AppsListGroupBy.source &&
          (listedSources.isNotEmpty || showNonInstalledGroupSection);
      if (useSourceGroups) {
        return buildGroupedSliver(
          mainChildCount: listedSources.length,
          mainBuilder: (i) => getSourceCollapsibleTile(i),
        );
      }

      final useAppTypeGroups =
          groupBy == AppsListGroupBy.appType &&
          (listedAppTypes.isNotEmpty || showNonInstalledGroupSection);
      if (useAppTypeGroups) {
        return buildGroupedSliver(
          mainChildCount: listedAppTypes.length,
          mainBuilder: (i) => getAppTypeCollapsibleTile(listedAppTypes[i]),
        );
      }

      // Flat list — still supports the updates group.
      if (showUpdatesGroupSection) {
        // Non-updates app indices (already in _listedAppsCache order, minus those in updates).
        final nonUpdatesIndices = [
          for (int i = 0; i < listedApps.length; i++)
            if (!isInUpdatesGroup(listedApps[i])) i,
        ];
        final totalCount = 1 + nonUpdatesIndices.length;
        return SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (pinUpdatesEnabled) {
              if (index == 0) return getUpdatesCollapsibleTile();
              final int runIndex = index - 1;
              return flatListAppRow(
                nonUpdatesIndices[runIndex],
                runIndex,
                nonUpdatesIndices.length,
                spacerBeforeFirstRow: runIndex == 0,
              );
            } else {
              if (index < nonUpdatesIndices.length) {
                return flatListAppRow(
                  nonUpdatesIndices[index],
                  index,
                  nonUpdatesIndices.length,
                  spacerAfterLastRow: index == nonUpdatesIndices.length - 1,
                );
              }
              return getUpdatesCollapsibleTile();
            }
          }, childCount: totalCount),
        );
      }

      return SliverList(
        delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
          return flatListAppRow(index, index, listedApps.length);
        }, childCount: listedApps.length),
      );
    }

    // Back intercept priority:
    // 1. Multi-select active → deselect all
    // 2. Search expanded → collapse search bar
    // 3. Filter active → reset filter
    // 4. Otherwise → normal pop (exit / go up)
    final bool isFilterActive =
        !filter.isIdenticalTo(neutralFilter, settingsProvider) ||
        _searchField != 'appName';
    final bool shouldInterceptBack =
        selectedAppIds.isNotEmpty || _searchExpanded || isFilterActive;

    final PreferredSizeWidget? filterChipsBar = _buildFilterChipsRow();

    return PopScope(
      canPop: !shouldInterceptBack,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (selectedAppIds.isNotEmpty) {
          clearSelected();
        } else if (_searchExpanded) {
          setState(() {
            _searchExpanded = false;
            _searchController.clear();
            _searchFocusNode.unfocus();
          });
        } else if (isFilterActive) {
          setState(() {
            filter = AppsFilter();
            _searchField = 'appName';
            _searchController.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              // [ExpressiveRefreshIndicator] is a drop-in replacement for the
              // stock [RefreshIndicator] - same API surface (child, onRefresh,
              // displacement, color, etc.) - but renders the M3 Expressive
              // morphing-polygon loading shape instead of the legacy circular
              // spinner. From package: expressive_refresh.
              child: ExpressiveRefreshIndicator(
                key: _refreshIndicatorKey,
                onRefresh: refresh,
                child: Scrollbar(
                  interactive: true,
                  controller: scrollController,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (settingsProvider.useGradientBackground)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: const [0, 0.38, 0.72, 1],
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.schemePageGradientTopColor,
                                  Theme.of(
                                    context,
                                  ).colorScheme.schemePageGradientMidColor,
                                  Theme.of(context).colorScheme.surface,
                                  Theme.of(context).colorScheme.surface,
                                ],
                              ),
                            ),
                          ),
                        ),
                      CustomScrollView(
                        key: PageStorageKey<String>(
                          'apps-scroll-${widget.folderId ?? (widget.onDemandOnlyList ? 'on-demand' : 'main')}',
                        ),
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        controller: scrollController,
                        cacheExtent: 1800,
                        slivers: <Widget>[
                          CustomAppBar(
                            leading:
                                (widget.onDemandOnlyList ||
                                    widget.folderId != null)
                                ? IconButton(
                                    icon: const Icon(Icons.arrow_back),
                                    onPressed: () =>
                                        Navigator.of(context).maybePop(),
                                    tooltip: MaterialLocalizations.of(
                                      context,
                                    ).backButtonTooltip,
                                  )
                                : null,
                            title: widget.onDemandOnlyList
                                ? tr('onDemandOnlyAppsTitle')
                                : currentFolderName ?? tr('appsString'),
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
                            bottom: filterChipsBar,
                          ),
                          ...getLoadingWidgets(),
                          getDisplayedList(),
                          // Extra bottom space for folder / on-demand pages so the
                          // last item isn't clipped by the phone's rounded corners.
                          if (widget.onDemandOnlyList ||
                              widget.folderId != null)
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 80),
                            ),
                          if (!widget.onDemandOnlyList &&
                              widget.folderId == null)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  20,
                                  16,
                                  0,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // Manage Folders button
                                    TextButton.icon(
                                      onPressed: () =>
                                          _showFolderManageDialog(context),
                                      icon: const Icon(
                                        Icons.folder_copy_outlined,
                                        size: 18,
                                      ),
                                      label: Text(tr('manageFolders')),
                                    ),
                                    // User-defined folder buttons
                                    if (appFolders.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      ...appFolders.map(
                                        (folder) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: FilledButton.icon(
                                            onPressed: () {
                                              Navigator.push(
                                                context,
                                                slideUpPageRoute(
                                                  (_) => AppsPage(
                                                    folderId: folder.id,
                                                  ),
                                                ),
                                              );
                                            },
                                            icon: () {
                                              final int upd =
                                                  folderUpdateCounts[folder
                                                      .id] ??
                                                  0;
                                              if (upd > 0) {
                                                return Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Badge(
                                                      label: Text('$upd'),
                                                      child: const SizedBox(
                                                        width: 4,
                                                        height: 16,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    const Icon(
                                                      Icons.folder_outlined,
                                                    ),
                                                  ],
                                                );
                                              }
                                              return const Icon(
                                                Icons.folder_outlined,
                                              );
                                            }(),
                                            label: Text(
                                              '${folder.name} '
                                              '(${folderAppCounts[folder.id] ?? 0} ${tr('appsString').toLowerCase()})',
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                    // On-Demand Only button (always last)
                                    FilledButton.icon(
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
                                        '($onDemandOnlyAppCount ${tr('appsString').toLowerCase()})',
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                  ],
                                ),
                              ),
                            ),
                          if (settingsProvider.progressiveBlurEnabled)
                            SliverToBoxAdapter(
                              child: SizedBox(
                                height: MediaQuery.paddingOf(context).bottom,
                              ),
                            ),
                        ],
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
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  color: Theme.of(context).colorScheme.surface,
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
      heroFriendlyAppPageRoute(
        (_) =>
            AppPage(appId: app.app.id, appsListHeroFolderId: widget.folderId),
      ),
    );
  }

  // ── Folder helpers ──────────────────────────────────────────────────────────

  /// Applies [folder]'s rule to every app, skipping excluded apps.
  Future<void> _applyFolderRuleToAllApps(AppFolder folder) async {
    if (folder.rule == null) return;
    final appsProvider = context.read<AppsProvider>();
    final sourceProvider = SourceProvider();
    final changed = <App>[];
    for (final appInMem in appsProvider.apps.values) {
      final app = appInMem.app;
      if (excludedFolderIdsForApp(app).contains(folder.id)) continue;
      final resolvedSource = sourceProvider
          .getSource(app.url, overrideSource: app.overrideSource)
          .runtimeType
          .toString();
      if (folder.rule!.matches(app, resolvedSource: resolvedSource)) {
        final before = List<String>.from(
          app.additionalSettings['folderIds'] as List? ?? [],
        );
        addAppToFolder(app, folder.id);
        final after = List<String>.from(
          app.additionalSettings['folderIds'] as List? ?? [],
        );
        if (before.length != after.length) changed.add(app);
      }
    }
    if (changed.isNotEmpty) {
      await appsProvider.saveApps(changed);
    }
  }

  /// Removes all traces of [folderId] from every app.
  Future<void> _removeFolderFromAllApps(String folderId) async {
    final appsProvider = context.read<AppsProvider>();
    final changed = <App>[];
    for (final appInMem in appsProvider.apps.values) {
      final app = appInMem.app;
      final hadId =
          folderIdsForApp(app).contains(folderId) ||
          excludedFolderIdsForApp(app).contains(folderId);
      if (hadId) {
        clearFolderFromApp(app, folderId);
        changed.add(app);
      }
    }
    if (changed.isNotEmpty) {
      await appsProvider.saveApps(changed);
    }
  }

  // ── Folder edit dialog ──────────────────────────────────────────────────────

  void _showFolderEditDialog(
    BuildContext context, {
    AppFolder? existing,
    FolderRule? prefillRule,
  }) {
    // Capture providers BEFORE entering the dialog builder.
    // context.read() must NOT be called inside a build/StatefulBuilder body.
    // SourceProvider is not in the widget tree — always instantiate directly.
    final sourceProvider = SourceProvider();
    final appsProvider = context.read<AppsProvider>();
    final settingsProvider = context.read<SettingsProvider>();

    int countRuleMatches(FolderRule rule) {
      return appsProvider.apps.values
          .where((a) => a.app.additionalSettings['onDemandOnly'] != true)
          .where((a) {
            final resolvedSource = sourceProvider
                .getSource(a.app.url, overrideSource: a.app.overrideSource)
                .runtimeType
                .toString();
            return rule.matches(a.app, resolvedSource: resolvedSource);
          })
          .length;
    }

    final initialRule = existing?.rule ?? prefillRule;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    var ruleEnabled = initialRule != null;
    var ruleField = initialRule?.field ?? FolderRuleField.name;
    var ruleMatch = initialRule?.matchType ?? FolderRuleMatchType.contains;
    final ruleValueCtrl = TextEditingController(text: initialRule?.value ?? '');

    showDialog<void>(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setDState) {
          final currentRule = ruleEnabled && ruleValueCtrl.text.isNotEmpty
              ? FolderRule(
                  field: ruleField,
                  matchType: ruleMatch,
                  value: ruleValueCtrl.text,
                )
              : null;
          // Safe: countRuleMatches uses the pre-captured providers,
          // not context.read() inside build.
          final matchCount = currentRule != null
              ? countRuleMatches(currentRule)
              : null;

          return AlertDialog(
            title: Text(existing == null ? tr('newFolder') : tr('editFolder')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: tr('folderName'),
                      border: const OutlineInputBorder(),
                    ),
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('folderRule'),
                          style: Theme.of(dCtx).textTheme.titleSmall,
                        ),
                      ),
                      Switch(
                        value: ruleEnabled,
                        onChanged: (v) => setDState(() => ruleEnabled = v),
                      ),
                    ],
                  ),
                  if (ruleEnabled) ...[
                    const SizedBox(height: 8),
                    // PopupMenuButton opens a floating menu without touching
                    // keyboard focus, so the keyboard stays open while picking.
                    PopupMenuButton<FolderRuleField>(
                      initialValue: ruleField,
                      onSelected: (v) => setDState(() => ruleField = v),
                      itemBuilder: (_) => FolderRuleField.values
                          .map(
                            (f) => PopupMenuItem(
                              value: f,
                              child: Text(_folderRuleFieldLabel(f)),
                            ),
                          )
                          .toList(),
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: tr('folderRuleField'),
                          border: const OutlineInputBorder(),
                          suffixIcon: const Icon(Icons.arrow_drop_down),
                          contentPadding: const EdgeInsets.fromLTRB(
                            12,
                            16,
                            4,
                            16,
                          ),
                        ),
                        child: Text(_folderRuleFieldLabel(ruleField)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    PopupMenuButton<FolderRuleMatchType>(
                      initialValue: ruleMatch,
                      onSelected: (v) => setDState(() => ruleMatch = v),
                      itemBuilder: (_) => FolderRuleMatchType.values
                          .map(
                            (m) => PopupMenuItem(
                              value: m,
                              child: Text(_folderRuleMatchLabel(m)),
                            ),
                          )
                          .toList(),
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: tr('folderRuleMatch'),
                          border: const OutlineInputBorder(),
                          suffixIcon: const Icon(Icons.arrow_drop_down),
                          contentPadding: const EdgeInsets.fromLTRB(
                            12,
                            16,
                            4,
                            16,
                          ),
                        ),
                        child: Text(_folderRuleMatchLabel(ruleMatch)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: ruleValueCtrl,
                      decoration: InputDecoration(
                        labelText: tr('folderRuleValue'),
                        border: const OutlineInputBorder(),
                        helperText: matchCount != null
                            ? tr(
                                'ruleMatchesXApps',
                                namedArgs: {'count': '$matchCount'},
                              )
                            : null,
                      ),
                      onChanged: (_) => setDState(() {}),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dCtx).pop(),
                child: Text(tr('cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final rule =
                      ruleEnabled && ruleValueCtrl.text.trim().isNotEmpty
                      ? FolderRule(
                          field: ruleField,
                          matchType: ruleMatch,
                          value: ruleValueCtrl.text.trim(),
                        )
                      : null;
                  final folders = List<AppFolder>.from(
                    settingsProvider.appFolders,
                  );
                  final AppFolder folder;
                  if (existing == null) {
                    folder = AppFolder(
                      id: AppFolder.generateId(),
                      name: name,
                      rule: rule,
                    );
                    folders.add(folder);
                  } else {
                    folder = existing.copyWith(
                      name: name,
                      rule: rule,
                      clearRule: rule == null,
                    );
                    final idx = folders.indexWhere((f) => f.id == existing.id);
                    if (idx >= 0) folders[idx] = folder;
                  }
                  settingsProvider.appFolders = folders;
                  if (!dCtx.mounted) return;
                  Navigator.of(dCtx).pop();
                  await _applyFolderRuleToAllApps(folder);
                },
                child: Text(tr('save')),
              ),
            ],
          );
        },
      ),
    );
  }

  String _folderRuleFieldLabel(FolderRuleField field) {
    switch (field) {
      case FolderRuleField.name:
        return tr('folderRuleFieldName');
      case FolderRuleField.author:
        return tr('folderRuleFieldAuthor');
      case FolderRuleField.id:
        return tr('folderRuleFieldId');
      case FolderRuleField.category:
        return tr('folderRuleFieldCategory');
      case FolderRuleField.source:
        return tr('folderRuleFieldSource');
    }
  }

  String _folderRuleMatchLabel(FolderRuleMatchType match) {
    switch (match) {
      case FolderRuleMatchType.contains:
        return tr('folderRuleMatchContains');
      case FolderRuleMatchType.equals:
        return tr('folderRuleMatchEquals');
      case FolderRuleMatchType.startsWith:
        return tr('folderRuleMatchStartsWith');
    }
  }

  // ── Save filter as folder ───────────────────────────────────────────────────

  void _saveFilterAsFolder(BuildContext context, AppsFilter currentFilter) {
    // Determine which filter fields are active.
    final activeFields = <FolderRuleField, String>{};
    if (currentFilter.nameFilter.isNotEmpty) {
      activeFields[FolderRuleField.name] = currentFilter.nameFilter;
    }
    if (currentFilter.authorFilter.isNotEmpty) {
      activeFields[FolderRuleField.author] = currentFilter.authorFilter;
    }
    if (currentFilter.idFilter.isNotEmpty) {
      activeFields[FolderRuleField.id] = currentFilter.idFilter;
    }
    if (currentFilter.categoryFilter.length == 1) {
      activeFields[FolderRuleField.category] =
          currentFilter.categoryFilter.first;
    }
    if (currentFilter.sourceFilter.isNotEmpty) {
      activeFields[FolderRuleField.source] = currentFilter.sourceFilter;
    }

    FolderRule? derivedRule;
    if (activeFields.length == 1) {
      // Exactly one active field — derive rule automatically.
      final entry = activeFields.entries.first;
      derivedRule = FolderRule(
        field: entry.key,
        matchType: FolderRuleMatchType.contains,
        value: entry.value,
      );
    }
    // Multiple fields or no fields → open edit dialog with no pre-filled rule;
    // the user can configure it manually.
    _showFolderEditDialog(context, prefillRule: derivedRule);
  }

  // ── Folder assign dialog ────────────────────────────────────────────────────

  void _showFolderAssignDialog(BuildContext context, Set<App> apps) {
    final settingsProvider = context.read<SettingsProvider>();
    // Mutable so newly created folders can be reflected without re-opening.
    var folders = settingsProvider.appFolders;

    // Determine which folders all selected apps already belong to.
    final commonFolderIds = folders
        .map((f) => f.id)
        .where((id) => apps.every((a) => folderIdsForApp(a).contains(id)))
        .toSet();
    final selected = Set<String>.from(commonFolderIds);

    // On-Demand Only: checked if ALL selected apps have onDemandOnly == true.
    const String onDemandKey = '__onDemandOnly__';
    final bool allOnDemand = apps.every(
      (a) => a.additionalSettings['onDemandOnly'] == true,
    );
    if (allOnDemand) selected.add(onDemandKey);

    showDialog<void>(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setDState) {
          Future<void> createNewFolder() async {
            final nameCtrl = TextEditingController();
            final name = await showDialog<String>(
              context: dCtx,
              builder: (ctx) => AlertDialog(
                title: Text(tr('newFolder')),
                content: TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: tr('folderName'),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) =>
                      Navigator.of(ctx).pop(nameCtrl.text.trim()),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(tr('cancel')),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(ctx).pop(nameCtrl.text.trim()),
                    child: Text(tr('ok')),
                  ),
                ],
              ),
            );
            nameCtrl.dispose();
            if (name == null || name.isEmpty) return;
            final newFolder = AppFolder(id: AppFolder.generateId(), name: name);
            final updatedFolders = [...settingsProvider.appFolders, newFolder];
            settingsProvider.appFolders = updatedFolders;
            setDState(() {
              folders = updatedFolders;
              selected.remove(onDemandKey);
              selected.add(newFolder.id);
            });
          }

          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            title: Text(tr('addToFolder')),
            contentPadding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...folders.map(
                      (f) => CheckboxListTile(
                        title: Text(f.name),
                        secondary: const Icon(Icons.folder_outlined),
                        value: selected.contains(f.id),
                        onChanged: (v) => setDState(() {
                          if (v == true) {
                            selected.add(f.id);
                            // Regular folder and On-Demand are mutually exclusive.
                            selected.remove(onDemandKey);
                          } else {
                            selected.remove(f.id);
                          }
                        }),
                      ),
                    ),
                    CheckboxListTile(
                      title: Text(tr('onDemandOnly')),
                      secondary: const Icon(Icons.folder_special_outlined),
                      value: selected.contains(onDemandKey),
                      onChanged: (v) => setDState(() {
                        if (v == true) {
                          // On-Demand is mutually exclusive with all regular folders.
                          selected
                            ..removeWhere((id) => id != onDemandKey)
                            ..add(onDemandKey);
                        } else {
                          selected.remove(onDemandKey);
                        }
                      }),
                    ),
                    const Divider(height: 8),
                    ListTile(
                      leading: const Icon(Icons.create_new_folder_outlined),
                      title: Text(tr('newFolder')),
                      onTap: createNewFolder,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dCtx).pop(),
                child: Text(tr('cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  final appsProvider = context.read<AppsProvider>();
                  final bool setOnDemand = selected.contains(onDemandKey);
                  for (final app in apps) {
                    // Add to newly-checked folders, remove from unchecked ones.
                    for (final f in folders) {
                      if (selected.contains(f.id)) {
                        addAppToFolder(app, f.id);
                      } else if (commonFolderIds.contains(f.id)) {
                        removeAppFromFolder(app, f.id);
                      }
                    }
                    // On-Demand Only: toggle setting when state changed.
                    if (setOnDemand) {
                      app.additionalSettings['onDemandOnly'] = true;
                    } else if (allOnDemand) {
                      // Was checked for all, now unchecked — clear it.
                      app.additionalSettings['onDemandOnly'] = false;
                    }
                  }
                  await appsProvider.saveApps(apps.toList());
                  if (!dCtx.mounted) return;
                  Navigator.of(dCtx).pop();
                },
                child: Text(tr('save')),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Folder manage dialog ────────────────────────────────────────────────────

  void _showFolderManageDialog(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final settingsProvider = sheetCtx.watch<SettingsProvider>();
          final folders = settingsProvider.appFolders;
          final bottomInset = MediaQuery.viewPaddingOf(sheetCtx).bottom;

          return Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    tr('folders'),
                    style: Theme.of(sheetCtx).textTheme.titleMedium,
                  ),
                ),
                if (folders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: Text(tr('noFolders'))),
                  )
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: folders.length,
                    itemBuilder: (_, i) {
                      final folder = folders[i];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.name),
                        subtitle: folder.rule != null
                            ? Text(
                                '${_folderRuleFieldLabel(folder.rule!.field)}'
                                ' ${_folderRuleMatchLabel(folder.rule!.matchType).toLowerCase()}'
                                ' "${folder.rule!.value}"',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: tr('editFolder'),
                              onPressed: () {
                                Navigator.of(sheetCtx).pop();
                                _showFolderEditDialog(
                                  context,
                                  existing: folder,
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outlined),
                              tooltip: tr('deleteFolder'),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: sheetCtx,
                                  builder: (dCtx) => AlertDialog(
                                    content: Text(
                                      tr(
                                        'deleteFolderConfirm',
                                        namedArgs: {'name': folder.name},
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dCtx).pop(false),
                                        child: Text(tr('cancel')),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.of(dCtx).pop(true),
                                        child: Text(tr('delete')),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm != true) return;
                                // ignore: use_build_context_synchronously
                                if (!context.mounted) return;
                                final sp = context.read<SettingsProvider>();
                                final updated = sp.appFolders
                                    .where((f) => f.id != folder.id)
                                    .toList();
                                sp.appFolders = updated;
                                sp.clearFolderViewSettings(folder.id);
                                await _removeFolderFromAllApps(folder.id);
                                if (sheetCtx.mounted) {
                                  setSheetState(() {});
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(sheetCtx).pop();
                      _showFolderEditDialog(context);
                    },
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: Text(tr('newFolder')),
                  ),
                ),
              ],
            ),
          );
        },
      ),
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
