import 'dart:async';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/app_bottom_sheet.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:provider/provider.dart';

class BackupImportSelection {
  const BackupImportSelection({
    required this.selectedAppIds,
    required this.importSettings,
    this.fetchedApps = const [],
    this.downloadedIcons = const {},
  });

  final Set<String> selectedAppIds;
  final bool importSettings;

  /// For Import from URL list: the chosen apps, as the sheet fetched them.
  final List<App> fetchedApps;

  /// The icons downloaded to show [fetchedApps], by package ID, for the add
  /// to keep ([NewAppLook.downloadedIcon]).
  final Map<String, Uint8List> downloadedIcons;
}

Future<BackupImportSelection?> showBackupImportPickerSheet({
  required BuildContext context,
  required List<App> backupApps,
  required bool hasSettings,
  required bool hasSecrets,
  required Map<String, AppInMemory> existingApps,
  bool isRestore = false,
}) {
  return showAppModalSheet<BackupImportSelection>(
    context: context,
    builder: (BuildContext sheetContext) {
      return BackupImportSheet(
        backupApps: backupApps,
        hasSettings: hasSettings,
        hasSecrets: hasSecrets,
        existingApps: existingApps,
        isRestore: isRestore,
      );
    },
  );
}

/// The picker for adding apps: Import from URL list, whatever its box held,
/// and `obtainium://` links another app sends.
///
/// [alreadyTracked] show at once, for reference: they are skipped. Each of
/// [urls] is fetched with [fetchApp] while the sheet is open, and selected once
/// it arrives; one that fails shows why. [trackedListingFor] catches an app
/// that is tracked under a different URL, which only its fetch can reveal.
/// [lookFor] names and draws each fetched app as it will be once added.
/// [urls] are really keys: [urlFor] gives the URL a row shows until its app
/// arrives (two links can share one URL), the key itself by default.
/// [rawJson], a link's or pasted JSON, is shown collapsed.
/// Returns the fetched apps chosen ([BackupImportSelection.fetchedApps]) and
/// the icons downloaded for them, or null when cancelled.
Future<BackupImportSelection?> showUrlListImportPickerSheet({
  required BuildContext context,
  required List<String> urls,
  required List<App> alreadyTracked,
  required Map<String, AppInMemory> existingApps,
  required Future<App> Function(String url) fetchApp,
  required AppInMemory? Function(App app) trackedListingFor,
  Future<NewAppLook> Function(App app)? lookFor,
  String Function(String url)? urlFor,
  String? rawJson,
}) {
  return showAppModalSheet<BackupImportSelection>(
    context: context,
    builder: (BuildContext sheetContext) {
      return BackupImportSheet(
        backupApps: const [],
        hasSettings: false,
        hasSecrets: false,
        existingApps: existingApps,
        alreadyTrackedApps: alreadyTracked,
        rawJson: rawJson,
        urlsToFetch: urls,
        fetchUrlApp: fetchApp,
        trackedListingFor: trackedListingFor,
        lookFor: lookFor,
        urlFor: urlFor,
      );
    },
  );
}

enum _BackupImportSectionId { settings, existingApps, newApps, rawJson }

/// How many URL-list apps are fetched at once: enough that a long list isn't
/// fetched one app at a time, few enough not to flood a source.
const int _urlFetchConcurrency = 4;

class BackupImportSheet extends StatefulWidget {
  const BackupImportSheet({
    super.key,
    required this.backupApps,
    required this.hasSettings,
    required this.hasSecrets,
    required this.existingApps,
    this.isRestore = false,
    this.alreadyTrackedApps,
    this.rawJson,
    this.urlsToFetch,
    this.fetchUrlApp,
    this.trackedListingFor,
    this.lookFor,
    this.urlFor,
  });

  final List<App> backupApps;
  final bool hasSettings;
  final bool hasSecrets;
  final Map<String, AppInMemory> existingApps;

  /// Whether this picker is being shown for a "Restore" (wipe + replace) vs a
  /// plain additive "Import" — only changes the action button's label.
  final bool isRestore;

  /// For an add ([showUrlListImportPickerSheet]): the listings it duplicates.
  /// Unlike a backup's, they can't be selected.
  final List<App>? alreadyTrackedApps;

  /// For an add from a link or JSON: that JSON, shown collapsed.
  final String? rawJson;

  /// For an add ([showUrlListImportPickerSheet]): the URLs whose apps the
  /// sheet fetches, and how.
  final List<String>? urlsToFetch;
  final Future<App> Function(String url)? fetchUrlApp;
  final AppInMemory? Function(App app)? trackedListingFor;

  /// For an add: how each new app will be named and drawn once saved
  /// ([AppsProviderLifecycle.newAppLook]), so that this sheet shows what the
  /// apps list then shows. Without it, rows show the app as it arrived.
  final Future<NewAppLook> Function(App app)? lookFor;

  /// The URL a row of [urlsToFetch] shows until its app arrives.
  final String Function(String url)? urlFor;

  /// Adding apps, rather than importing a backup.
  bool get isUrlImport => urlsToFetch != null;

  @override
  State<BackupImportSheet> createState() => _BackupImportSheetState();
}

class _BackupImportSheetState extends State<BackupImportSheet> {
  late Set<String> selectedAppIds;
  late bool importSettings;
  late Set<_BackupImportSectionId> expandedSectionIds;

  // Guards the restore confirmation dialog shown on top of this sheet (see
  // the footer FilledButton below) against double-taps while it's up.
  bool _isConfirmingRestore = false;

  // What a row's selection is keyed by. A backup restores by package ID. A
  // URL-list row is keyed by its URL instead, which it has before its app.
  String _key(App app) => app.id;

  // Import from URL list only: each URL's app once fetched, or why it wasn't.
  // A fetched app that turns out to be tracked under another URL joins the
  // already-tracked group instead (as its listing), and its URL leaves.
  final Map<String, App> _fetchedApps = {};
  final Map<String, Object> _fetchErrors = {};
  final List<App> _foundTrackedApps = [];
  final Set<String> _foundTrackedUrls = {};

  // Each new row's [NewAppLook], by its selection key, once known.
  final Map<String, NewAppLook> _looks = {};

  @override
  void initState() {
    super.initState();
    selectedAppIds = widget.backupApps.map(_key).toSet();
    importSettings = widget.hasSettings;
    expandedSectionIds = {
      if (widget.hasSettings) _BackupImportSectionId.settings,
      _BackupImportSectionId.existingApps,
      _BackupImportSectionId.newApps,
    };
    if (widget.isUrlImport) unawaited(_fetchUrlApps());
  }

  Future<NewAppLook?> _lookFor(App app) async {
    try {
      return await widget.lookFor?.call(app);
    } catch (_) {
      // The row shows the app as it arrived instead.
      return null;
    }
  }

  Future<void> _fetchUrlApps() async {
    final List<String> queue = List<String>.from(widget.urlsToFetch!);
    Future<void> fetchNext() async {
      while (queue.isNotEmpty && mounted) {
        final String url = queue.removeAt(0);
        App? app;
        Object? error;
        try {
          app = await widget.fetchUrlApp!(url);
        } catch (e) {
          error = e;
        }
        final AppInMemory? tracked = app == null
            ? null
            : widget.trackedListingFor?.call(app);
        // Part of the fetch: the row arrives with its name and icon final.
        final NewAppLook? look = app != null && tracked == null
            ? await _lookFor(app)
            : null;
        // Closed, or imported with what had arrived: the rest isn't wanted.
        if (!mounted) return;
        setState(() {
          if (app == null) {
            _fetchErrors[url] = error!;
            return;
          }
          if (tracked == null) {
            _fetchedApps[url] = app;
            if (look != null) _looks[url] = look;
            selectedAppIds.add(url);
            return;
          }
          _foundTrackedUrls.add(url);
          final bool shown = [
            ...widget.alreadyTrackedApps!,
            ..._foundTrackedApps,
          ].any((App shown) => shown.listingKey == tracked.listingKey);
          if (!shown) _foundTrackedApps.add(tracked.app);
        });
      }
    }

    await Future.wait([
      for (int i = 0; i < _urlFetchConcurrency; i++) fetchNext(),
    ]);
  }

  /// The URL-list rows still new: fetching, fetched or failed, as typed.
  List<String> get _newUrls => widget.urlsToFetch!
      .where((String url) => !_foundTrackedUrls.contains(url))
      .toList();

  List<App> get existingBackupApps {
    // For an add, "already tracked" means the same package from the same store
    // (see planUrlImport), which a package ID lookup can't tell.
    final list = widget.isUrlImport
        ? [...widget.alreadyTrackedApps!, ..._foundTrackedApps]
        : widget.backupApps
              .where((a) => widget.existingApps.containsKey(a.id))
              .toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  // An add's new apps are its URL rows ([buildUrlSection]), not these.
  List<App> get newBackupApps {
    final list = widget.backupApps
        .where((a) => !widget.existingApps.containsKey(a.id))
        .toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  // A URL that failed can never be selected, so it isn't counted.
  int get totalItems => widget.isUrlImport
      ? _newUrls.where((String url) => !_fetchErrors.containsKey(url)).length
      : widget.backupApps.length + (widget.hasSettings ? 1 : 0);

  int get totalSelected =>
      selectedAppIds.length + (widget.hasSettings && importSettings ? 1 : 0);

  void toggleAppSelected(String appId, bool selected) {
    hapticSelection();
    setState(() {
      if (selected) {
        selectedAppIds.add(appId);
      } else {
        selectedAppIds.remove(appId);
      }
    });
  }

  void toggleSettingsSelected(bool selected) {
    hapticSelection();
    setState(() {
      importSettings = selected;
    });
  }

  void toggleAppGroup(Iterable<String> groupIds) {
    hapticSelection();
    setState(() {
      final bool allSelected = groupIds.every(selectedAppIds.contains);
      if (allSelected) {
        selectedAppIds.removeAll(groupIds);
      } else {
        selectedAppIds.addAll(groupIds);
      }
    });
  }

  void toggleSectionExpanded(_BackupImportSectionId sectionId) {
    hapticSelection();
    setState(() {
      if (expandedSectionIds.contains(sectionId)) {
        expandedSectionIds.remove(sectionId);
      } else {
        expandedSectionIds.add(sectionId);
      }
    });
  }

  Widget buildAppRow({
    required App app,
    required ColorScheme colorScheme,
    required M3eListGroupPosition position,
    required double itemOuterRadius,
    required double itemInnerRadius,
    bool selectable = true,
    String? selectionKey,
  }) {
    final AppInMemory? existingApp = widget.existingApps[app.id];
    final String key = selectionKey ?? _key(app);
    final bool isSelected = selectable && selectedAppIds.contains(key);
    // A new app, drawn as the apps list will draw it once it's added.
    final bool showsLook = selectable && widget.lookFor != null;
    final NewAppLook? look = showsLook ? _looks[key] : null;
    final BorderRadius cardBorderRadius = m3eListGroupItemRadius(
      position,
      flatListBody: false,
      outerRadius: itemOuterRadius,
      innerRadius: itemInnerRadius,
    );

    return Material(
      color: m3eGroupedListRowFill(colorScheme),
      elevation: 0,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: cardBorderRadius,
        side: m3ePureBlackOutlineSide(colorScheme),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: cardBorderRadius),
        selected: isSelected,
        tileColor: Colors.transparent,
        selectedTileColor: Colors.transparent,
        contentPadding: const EdgeInsets.only(left: 12, right: 16),
        leading: showsLook
            ? _AppIconImage(look?.icon)
            : _BackupAppIconWidget(app: app, existingApp: existingApp),
        title: Text(
          look?.name ?? app.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        // Two lines only, name and author. A version here would be the one
        // the backup or link recorded, which is neither installed nor latest.
        subtitle: app.author.isEmpty
            ? null
            : Text(
                tr('byX', args: [app.author]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: selectable
            ? Checkbox(
                value: isSelected,
                onChanged: (bool? selected) {
                  if (selected != null) {
                    toggleAppSelected(key, selected);
                  }
                },
              )
            : null,
        onTap: selectable ? () => toggleAppSelected(key, !isSelected) : null,
      ),
    );
  }

  // A URL-list row whose app is still being fetched, or couldn't be.
  Widget buildPendingUrlRow({
    required String url,
    required Object? error,
    required ColorScheme colorScheme,
    required M3eListGroupPosition position,
    required double itemOuterRadius,
    required double itemInnerRadius,
  }) {
    final BorderRadius cardBorderRadius = m3eListGroupItemRadius(
      position,
      flatListBody: false,
      outerRadius: itemOuterRadius,
      innerRadius: itemInnerRadius,
    );
    return Material(
      color: m3eGroupedListRowFill(colorScheme),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: cardBorderRadius,
        side: m3ePureBlackOutlineSide(colorScheme),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: cardBorderRadius),
        contentPadding: const EdgeInsets.only(left: 12, right: 16),
        leading: const _FallbackAppIcon(),
        // Not an app yet, so not styled as one: muted and regular weight, where
        // an app's name is semi-bold.
        title: Text(
          (widget.urlFor?.call(url) ?? url).replaceFirst(
            RegExp(r'^https?://'),
            '',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        subtitle: error == null
            ? null
            : Text(
                // Its URL is the row's title already.
                error is ObtainiumError ? error.message : error.toString(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.error),
              ),
        trailing: error == null
            ? const ExpressiveLoadingIndicator(
                constraints: BoxConstraints.tightFor(width: 24, height: 24),
              )
            : Icon(Icons.error_outline_rounded, color: colorScheme.error),
      ),
    );
  }

  Widget buildSettingsRow({
    required ColorScheme colorScheme,
    required double itemOuterRadius,
    required double itemInnerRadius,
  }) {
    final BorderRadius cardBorderRadius = m3eListGroupItemRadius(
      M3eListGroupPosition.only,
      flatListBody: false,
      outerRadius: itemOuterRadius,
      innerRadius: itemInnerRadius,
    );

    return Material(
      color: m3eGroupedListRowFill(colorScheme),
      elevation: 0,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: cardBorderRadius,
        side: m3ePureBlackOutlineSide(colorScheme),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: cardBorderRadius),
        selected: importSettings,
        tileColor: Colors.transparent,
        selectedTileColor: Colors.transparent,
        contentPadding: const EdgeInsets.only(left: 12, right: 16),
        leading: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: Icon(
              Icons.tune_rounded,
              color: colorScheme.primary,
              size: 24,
            ),
          ),
        ),
        title: Text(
          tr('importSettingsTitle'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          widget.hasSecrets ? tr('withSecrets') : tr('noSecrets'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Checkbox(
          value: importSettings,
          onChanged: (bool? selected) {
            if (selected != null) {
              toggleSettingsSelected(selected);
            }
          },
        ),
        onTap: () => toggleSettingsSelected(!importSettings),
      ),
    );
  }

  Widget buildAppSection({
    required _BackupImportSectionId sectionId,
    required String title,
    required List<App> apps,
    required ColorScheme colorScheme,
    required double groupCardRadius,
    required double collapsedHeaderRadius,
    required double itemOuterRadius,
    required double itemInnerRadius,
    bool selectable = true,
  }) {
    if (apps.isEmpty) return const SizedBox.shrink();
    return buildGroup(
      sectionId: sectionId,
      title: title,
      count: apps.length,
      selectableKeys: selectable ? apps.map(_key).toList() : null,
      rowCount: apps.length,
      buildRow: (int index, M3eListGroupPosition position) => buildAppRow(
        app: apps[index],
        colorScheme: colorScheme,
        position: position,
        itemOuterRadius: itemOuterRadius,
        itemInnerRadius: itemInnerRadius,
        selectable: selectable,
      ),
      colorScheme: colorScheme,
      groupCardRadius: groupCardRadius,
      collapsedHeaderRadius: collapsedHeaderRadius,
    );
  }

  // The URL list's new apps, in the order typed: each row starts out fetching,
  // then shows its app, or why it couldn't be fetched.
  Widget buildUrlSection({
    required ColorScheme colorScheme,
    required double groupCardRadius,
    required double collapsedHeaderRadius,
    required double itemOuterRadius,
    required double itemInnerRadius,
  }) {
    final List<String> urls = _newUrls;
    if (urls.isEmpty) return const SizedBox.shrink();
    return buildGroup(
      sectionId: _BackupImportSectionId.newApps,
      title: tr('newApps'),
      count: urls.length,
      selectableKeys: urls.where(_fetchedApps.containsKey).toList(),
      countTotal: totalItems,
      rowCount: urls.length,
      buildRow: (int index, M3eListGroupPosition position) {
        final String url = urls[index];
        final App? app = _fetchedApps[url];
        if (app == null) {
          return buildPendingUrlRow(
            url: url,
            error: _fetchErrors[url],
            colorScheme: colorScheme,
            position: position,
            itemOuterRadius: itemOuterRadius,
            itemInnerRadius: itemInnerRadius,
          );
        }
        return buildAppRow(
          app: app,
          selectionKey: url,
          colorScheme: colorScheme,
          position: position,
          itemOuterRadius: itemOuterRadius,
          itemInnerRadius: itemInnerRadius,
        );
      },
      colorScheme: colorScheme,
      groupCardRadius: groupCardRadius,
      collapsedHeaderRadius: collapsedHeaderRadius,
    );
  }

  // A collapsible group of rows. [selectableKeys] are the rows its header's
  // checkbox selects (null: a read-only group); [countTotal] is what their
  // count reads out of, when not every row can be selected.
  Widget buildGroup({
    required _BackupImportSectionId sectionId,
    required String title,
    required int count,
    required List<String>? selectableKeys,
    int? countTotal,
    required int rowCount,
    required Widget Function(int index, M3eListGroupPosition position) buildRow,
    required ColorScheme colorScheme,
    required double groupCardRadius,
    required double collapsedHeaderRadius,
  }) {
    final bool isExpanded = expandedSectionIds.contains(sectionId);
    final List<String> keys = selectableKeys ?? const [];
    final int selectedInGroup = keys.where(selectedAppIds.contains).length;
    final bool allSelected =
        keys.isNotEmpty && keys.every(selectedAppIds.contains);
    final bool someSelected = selectedInGroup > 0 && !allSelected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        M3eCollapsibleGroupHeader(
          title: title,
          count: count,
          countText: selectableKeys == null
              ? null
              : '$selectedInGroup/${countTotal ?? count}',
          isExpanded: isExpanded,
          onTap: () => toggleSectionExpanded(sectionId),
          collapsedRadius: collapsedHeaderRadius,
          colorScheme: colorScheme,
          trailingAction: selectableKeys == null
              ? null
              : Semantics(
                  label: allSelected
                      ? tr('deselectX', args: [keys.length.toString()])
                      : tr('selectAll'),
                  child: Checkbox(
                    value: allSelected ? true : (someSelected ? null : false),
                    tristate: true,
                    // Nothing to select until a row's app has arrived.
                    onChanged: keys.isEmpty
                        ? null
                        : (_) => toggleAppGroup(keys),
                  ),
                ),
        ),
        SizedBox(
          width: double.infinity,
          child: AnimatedSize(
            duration: kM3eGroupExpandDuration,
            reverseDuration: kM3eGroupCollapseDuration,
            curve: kM3eGroupTransitionCurve,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(groupCardRadius),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int i = 0; i < rowCount; i++) ...[
                          SizedBox(
                            height: i == 0
                                ? kM3eHeaderToFirstCardGap
                                : kM3eItemGap,
                          ),
                          buildRow(
                            i,
                            rowCount == 1
                                ? M3eListGroupPosition.only
                                : i == 0
                                ? M3eListGroupPosition.first
                                : i == rowCount - 1
                                ? M3eListGroupPosition.last
                                : M3eListGroupPosition.middle,
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget buildSettingsSection({
    required ColorScheme colorScheme,
    required double groupCardRadius,
    required double collapsedHeaderRadius,
    required double itemOuterRadius,
    required double itemInnerRadius,
  }) {
    if (!widget.hasSettings) return const SizedBox.shrink();

    final bool isExpanded = expandedSectionIds.contains(
      _BackupImportSectionId.settings,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        M3eCollapsibleGroupHeader(
          title: tr('settings'),
          count: 1,
          countText: importSettings ? '1/1' : '0/1',
          isExpanded: isExpanded,
          onTap: () => toggleSectionExpanded(_BackupImportSectionId.settings),
          collapsedRadius: collapsedHeaderRadius,
          colorScheme: colorScheme,
          trailingAction: Semantics(
            label: importSettings
                ? tr('deselectX', args: ['1'])
                : tr('selectAll'),
            child: Checkbox(
              value: importSettings,
              onChanged: (bool? selected) {
                if (selected != null) {
                  toggleSettingsSelected(selected);
                }
              },
            ),
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: AnimatedSize(
            duration: kM3eGroupExpandDuration,
            reverseDuration: kM3eGroupCollapseDuration,
            curve: kM3eGroupTransitionCurve,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(groupCardRadius),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: kM3eHeaderToFirstCardGap),
                        buildSettingsRow(
                          colorScheme: colorScheme,
                          itemOuterRadius: itemOuterRadius,
                          itemInnerRadius: itemInnerRadius,
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  // The link's payload as sent, collapsed by default: the summary rows above
  // show what gets imported, and this is there for anyone who wants every
  // field (filters and other settings included).
  Widget buildRawJsonSection({
    required ColorScheme colorScheme,
    required double collapsedHeaderRadius,
    required double itemOuterRadius,
    required double itemInnerRadius,
  }) {
    final String? rawJson = widget.rawJson;
    if (rawJson == null || rawJson.isEmpty) return const SizedBox.shrink();
    final bool isExpanded = expandedSectionIds.contains(
      _BackupImportSectionId.rawJson,
    );
    final BorderRadius cardBorderRadius = m3eListGroupItemRadius(
      M3eListGroupPosition.only,
      flatListBody: false,
      outerRadius: itemOuterRadius,
      innerRadius: itemInnerRadius,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        M3eCollapsibleGroupHeader(
          title: tr('rawJson'),
          count: 1,
          countText: '',
          isExpanded: isExpanded,
          onTap: () => toggleSectionExpanded(_BackupImportSectionId.rawJson),
          collapsedRadius: collapsedHeaderRadius,
          colorScheme: colorScheme,
        ),
        SizedBox(
          width: double.infinity,
          child: AnimatedSize(
            duration: kM3eGroupExpandDuration,
            reverseDuration: kM3eGroupCollapseDuration,
            curve: kM3eGroupTransitionCurve,
            alignment: Alignment.topCenter,
            child: isExpanded
                ? Padding(
                    padding: const EdgeInsets.only(
                      top: kM3eHeaderToFirstCardGap,
                    ),
                    child: Material(
                      color: m3eGroupedListRowFill(colorScheme),
                      shape: RoundedRectangleBorder(
                        borderRadius: cardBorderRadius,
                        side: m3ePureBlackOutlineSide(colorScheme),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          rawJson,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final bool isTelevision = context.read<SettingsProvider>().isTV;
    final double cardCornerScale = context.select<SettingsProvider, double>(
      (SettingsProvider settings) => settings.cardCornerScale,
    );
    final double groupCardRadius = SettingsProvider.cardCornerRadiusForScale(
      kM3eGroupCardRadius,
      cardCornerScale,
    );
    final double collapsedHeaderRadius =
        SettingsProvider.cardCornerRadiusForScale(
          SettingsProvider.baseCollapsedHeaderRadius,
          cardCornerScale,
        );
    final double itemOuterRadius = SettingsProvider.cardCornerRadiusForScale(
      kM3eOuterRadius,
      cardCornerScale,
    );
    final double itemInnerRadius = SettingsProvider.cardCornerRadiusForScale(
      kM3eInnerRadius,
      cardCornerScale,
    );

    final existingAppsList = existingBackupApps;
    final newAppsList = newBackupApps;

    return AppSheetScaffold(
      expand: false,
      headerPadding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      footerPadding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      header: Row(
        children: [
          Material(
            color: colorScheme.tertiaryContainer,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: SizedBox.square(
              dimension: 40,
              child: Icon(
                widget.isUrlImport
                    ? Icons.playlist_add_rounded
                    : Icons.restore_rounded,
                color: colorScheme.onTertiaryContainer,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${tr('selectAppsToImport')} ($totalSelected/$totalItems)',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.hasSettings) ...[
              buildSettingsSection(
                colorScheme: colorScheme,
                groupCardRadius: groupCardRadius,
                collapsedHeaderRadius: collapsedHeaderRadius,
                itemOuterRadius: itemOuterRadius,
                itemInnerRadius: itemInnerRadius,
              ),
            ],
            if (existingAppsList.isNotEmpty) ...[
              if (widget.hasSettings)
                const SizedBox(height: SettingsProvider.collapsedHeaderGap),
              buildAppSection(
                sectionId: _BackupImportSectionId.existingApps,
                title: tr('alreadyTrackedApps'),
                apps: existingAppsList,
                colorScheme: colorScheme,
                groupCardRadius: groupCardRadius,
                collapsedHeaderRadius: collapsedHeaderRadius,
                itemOuterRadius: itemOuterRadius,
                itemInnerRadius: itemInnerRadius,
                // An add never overwrites a tracked app.
                selectable: !widget.isUrlImport,
              ),
            ],
            if (widget.isUrlImport && _newUrls.isNotEmpty) ...[
              if (existingAppsList.isNotEmpty)
                const SizedBox(height: SettingsProvider.collapsedHeaderGap),
              buildUrlSection(
                colorScheme: colorScheme,
                groupCardRadius: groupCardRadius,
                collapsedHeaderRadius: collapsedHeaderRadius,
                itemOuterRadius: itemOuterRadius,
                itemInnerRadius: itemInnerRadius,
              ),
            ],
            if (newAppsList.isNotEmpty) ...[
              if (widget.hasSettings || existingAppsList.isNotEmpty)
                const SizedBox(height: SettingsProvider.collapsedHeaderGap),
              buildAppSection(
                sectionId: _BackupImportSectionId.newApps,
                title: tr('newApps'),
                apps: newAppsList,
                colorScheme: colorScheme,
                groupCardRadius: groupCardRadius,
                collapsedHeaderRadius: collapsedHeaderRadius,
                itemOuterRadius: itemOuterRadius,
                itemInnerRadius: itemInnerRadius,
              ),
            ],
            if (widget.rawJson != null) ...[
              const SizedBox(height: SettingsProvider.collapsedHeaderGap),
              buildRawJsonSection(
                colorScheme: colorScheme,
                collapsedHeaderRadius: collapsedHeaderRadius,
                itemOuterRadius: itemOuterRadius,
                itemInnerRadius: itemInnerRadius,
              ),
            ],
          ],
        ),
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            autofocus: isTelevision,
            onPressed: () => Navigator.of(context).pop(null),
            child: Text(tr('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            onPressed: totalSelected == 0 || _isConfirmingRestore
                ? null
                : () async {
                    hapticSelection();
                    if (widget.isRestore) {
                      // Shown as a dialog ON TOP of this still-open sheet
                      // (not after popping it) so cancelling just dismisses
                      // the dialog and leaves the selection intact, instead
                      // of the sheet closing and a separate dialog popping
                      // up after it - which read as the sheet crashing.
                      setState(() => _isConfirmingRestore = true);
                      final bool confirmed =
                          (await showDialog<Map<String, dynamic>?>(
                            context: context,
                            builder: (BuildContext dialogContext) {
                              return GeneratedFormModal(
                                title: tr('restoreBackupConfirmTitle'),
                                items: const [],
                                initValid: true,
                                message: tr('restoreBackupConfirmBody'),
                                primaryActionColour: Theme.of(
                                  dialogContext,
                                ).colorScheme.error,
                              );
                            },
                          )) !=
                          null;
                      if (!mounted) return;
                      setState(() => _isConfirmingRestore = false);
                      if (!confirmed) return;
                    }
                    if (!context.mounted) return;
                    Navigator.of(context).pop(
                      BackupImportSelection(
                        selectedAppIds: selectedAppIds,
                        importSettings: importSettings,
                        fetchedApps: widget.isUrlImport
                            ? [
                                for (final String url in _newUrls)
                                  if (selectedAppIds.contains(url))
                                    _fetchedApps[url]!,
                              ]
                            : const [],
                        downloadedIcons: widget.isUrlImport
                            ? {
                                for (final String url in _newUrls)
                                  if (selectedAppIds.contains(url) &&
                                      _looks[url]?.downloadedIcon != null)
                                    _fetchedApps[url]!.id:
                                        _looks[url]!.downloadedIcon!,
                              }
                            : const {},
                      ),
                    );
                  },
            child: Text(tr(widget.isRestore ? 'obtainiumRestore' : 'import')),
          ),
        ],
      ),
    );
  }
}

class _BackupAppIconWidget extends StatefulWidget {
  const _BackupAppIconWidget({required this.app, required this.existingApp});

  final App app;
  final AppInMemory? existingApp;

  @override
  State<_BackupAppIconWidget> createState() => _BackupAppIconWidgetState();
}

class _BackupAppIconWidgetState extends State<_BackupAppIconWidget> {
  Uint8List? _iconBytes;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(_BackupAppIconWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app.id != widget.app.id ||
        oldWidget.existingApp?.icon != widget.existingApp?.icon) {
      _loadIcon();
    }
  }

  Future<void> _loadIcon() async {
    final AppsProvider? appsProvider = widget.existingApp != null
        ? context.read<AppsProvider>()
        : null;
    if (widget.existingApp?.icon != null) {
      if (mounted) {
        setState(() {
          _iconBytes = widget.existingApp!.icon;
        });
      }
      return;
    }

    final bytes = await BulkImportService.getAppIcon(widget.app.id);
    if (bytes != null && mounted) {
      setState(() {
        _iconBytes = bytes;
      });
      return;
    }

    if (appsProvider != null && mounted) {
      await appsProvider.updateAppIcon(widget.app.id);
      if (mounted && widget.existingApp?.icon != null) {
        setState(() {
          _iconBytes = widget.existingApp!.icon;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_iconBytes != null) return _AppIconImage(_iconBytes);

    final String? iconUrl = widget.app.iconUrl;
    if (iconUrl != null && iconUrl.startsWith('http')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          iconUrl,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (imageContext, imageError, imageStackTrace) =>
              const _FallbackAppIcon(),
        ),
      );
    }

    return const _FallbackAppIcon();
  }
}

/// An app's icon from its bytes, or [_FallbackAppIcon] without them.
class _AppIconImage extends StatelessWidget {
  const _AppIconImage(this.bytes);

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final Uint8List? iconBytes = bytes;
    if (iconBytes == null) return const _FallbackAppIcon();
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final int iconCachePx = (40 * devicePixelRatio).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.memory(
        iconBytes,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: iconCachePx,
        cacheHeight: iconCachePx,
        filterQuality: FilterQuality.low,
      ),
    );
  }
}

/// The ObtainX mark, for an app with no icon to show (yet).
class _FallbackAppIcon extends StatelessWidget {
  const _FallbackAppIcon();

  @override
  Widget build(BuildContext context) {
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
