import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/app_bottom_sheet.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
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
  });

  final Set<String> selectedAppIds;
  final bool importSettings;
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

/// The picker for a link import (`obtainium://app/` or `apps/`).
///
/// [newApps] are the listings the link would add ([LinkImportPlan.toAdd]),
/// all selected to start with. [alreadyTracked] are shown for reference only:
/// a link never overwrites a tracked app. [rawJson] is the link's payload,
/// shown collapsed. Returns the listing keys chosen, or null when cancelled.
Future<Set<String>?> showLinkImportPickerSheet({
  required BuildContext context,
  required List<App> newApps,
  required List<App> alreadyTracked,
  required Map<String, AppInMemory> existingApps,
  String? rawJson,
}) async {
  final BackupImportSelection? selection =
      await showAppModalSheet<BackupImportSelection>(
        context: context,
        builder: (BuildContext sheetContext) {
          return BackupImportSheet(
            backupApps: newApps,
            hasSettings: false,
            hasSecrets: false,
            existingApps: existingApps,
            linkAlreadyTrackedApps: alreadyTracked,
            linkRawJson: rawJson,
          );
        },
      );
  return selection?.selectedAppIds;
}

enum _BackupImportSectionId { settings, existingApps, newApps, rawJson }

class BackupImportSheet extends StatefulWidget {
  const BackupImportSheet({
    super.key,
    required this.backupApps,
    required this.hasSettings,
    required this.hasSecrets,
    required this.existingApps,
    this.isRestore = false,
    this.linkAlreadyTrackedApps,
    this.linkRawJson,
  });

  final List<App> backupApps;
  final bool hasSettings;
  final bool hasSecrets;
  final Map<String, AppInMemory> existingApps;

  /// Whether this picker is being shown for a "Restore" (wipe + replace) vs a
  /// plain additive "Import" — only changes the action button's label.
  final bool isRestore;

  /// Set for a link import (see [showLinkImportPickerSheet]): the listings
  /// the link duplicates. Unlike a backup's, they can't be selected.
  final List<App>? linkAlreadyTrackedApps;

  /// The link's payload, for a link import.
  final String? linkRawJson;

  bool get isLinkImport => linkAlreadyTrackedApps != null;

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

  // What a row's selection is keyed by. A backup restores by package ID; a
  // link can carry one package from two stores, and each becomes a listing of
  // its own, so link rows are keyed by the listing key they will be saved as.
  String _key(App app) => widget.isLinkImport ? app.listingKey : app.id;

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
  }

  List<App> get existingBackupApps {
    // For a link, "already tracked" means the same package from the same
    // store (see planLinkImport), which a package ID lookup can't tell.
    final list = widget.isLinkImport
        ? List<App>.from(widget.linkAlreadyTrackedApps!)
        : widget.backupApps
              .where((a) => widget.existingApps.containsKey(a.id))
              .toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  List<App> get newBackupApps {
    final list = widget.isLinkImport
        ? List<App>.from(widget.backupApps)
        : widget.backupApps
              .where((a) => !widget.existingApps.containsKey(a.id))
              .toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  int get totalItems => widget.backupApps.length + (widget.hasSettings ? 1 : 0);

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

  void toggleAppGroup(List<App> groupApps) {
    hapticSelection();
    final groupIds = groupApps.map(_key).toList();
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
  }) {
    final AppInMemory? existingApp = widget.existingApps[app.id];
    final bool isSelected = selectable && selectedAppIds.contains(_key(app));
    // A link's apps have no version yet; what matters is where each one will
    // be tracked from.
    final String versionLabel = widget.isLinkImport
        ? app.url
        : app.latestVersion.isNotEmpty
        ? app.latestVersion
        : (app.installedVersion ?? '');
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
        leading: _BackupAppIconWidget(
          app: app,
          existingApp: existingApp,
          // A link comes from another app, and fetching its iconUrl would tell
          // that URL's server the link was opened, before the user agreed to
          // anything. Link rows use only icons already on the device.
          allowNetworkIcon: !widget.isLinkImport,
        ),
        title: Text(
          app.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (app.author.isNotEmpty)
              Text(
                tr('byX', args: [app.author]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (versionLabel.isNotEmpty)
              Text(versionLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        trailing: selectable
            ? Checkbox(
                value: isSelected,
                onChanged: (bool? selected) {
                  if (selected != null) {
                    toggleAppSelected(_key(app), selected);
                  }
                },
              )
            : null,
        onTap: selectable
            ? () => toggleAppSelected(_key(app), !isSelected)
            : null,
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

    final bool isExpanded = expandedSectionIds.contains(sectionId);
    final int selectedInGroup = apps
        .where((a) => selectedAppIds.contains(_key(a)))
        .length;
    final bool allSelected = apps.every(
      (a) => selectedAppIds.contains(_key(a)),
    );
    final bool someSelected = selectedInGroup > 0 && !allSelected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        M3eCollapsibleGroupHeader(
          title: title,
          count: apps.length,
          countText: selectable ? '$selectedInGroup/${apps.length}' : null,
          isExpanded: isExpanded,
          onTap: () => toggleSectionExpanded(sectionId),
          collapsedRadius: collapsedHeaderRadius,
          colorScheme: colorScheme,
          trailingAction: selectable
              ? Semantics(
                  label: allSelected
                      ? tr('deselectX', args: [apps.length.toString()])
                      : tr('selectAll'),
                  child: Checkbox(
                    value: allSelected ? true : (someSelected ? null : false),
                    tristate: true,
                    onChanged: (_) => toggleAppGroup(apps),
                  ),
                )
              : null,
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
                        for (int i = 0; i < apps.length; i++) ...[
                          SizedBox(
                            height: i == 0
                                ? kM3eHeaderToFirstCardGap
                                : kM3eItemGap,
                          ),
                          buildAppRow(
                            app: apps[i],
                            colorScheme: colorScheme,
                            position: apps.length == 1
                                ? M3eListGroupPosition.only
                                : i == 0
                                ? M3eListGroupPosition.first
                                : i == apps.length - 1
                                ? M3eListGroupPosition.last
                                : M3eListGroupPosition.middle,
                            itemOuterRadius: itemOuterRadius,
                            itemInnerRadius: itemInnerRadius,
                            selectable: selectable,
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
    final String? rawJson = widget.linkRawJson;
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
                widget.isLinkImport
                    ? Icons.link_rounded
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
                // A link never overwrites a tracked app.
                selectable: !widget.isLinkImport,
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
            if (widget.isLinkImport) ...[
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
  const _BackupAppIconWidget({
    required this.app,
    required this.existingApp,
    this.allowNetworkIcon = true,
  });

  final App app;
  final AppInMemory? existingApp;
  final bool allowNetworkIcon;

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
    if (_iconBytes != null) {
      final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final int iconCachePx = (40 * devicePixelRatio).round();
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          _iconBytes!,
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

    final String? iconUrl = widget.app.iconUrl;
    if (widget.allowNetworkIcon &&
        iconUrl != null &&
        iconUrl.startsWith('http')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          iconUrl,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (imageContext, imageError, imageStackTrace) =>
              _buildFallbackIcon(context),
        ),
      );
    }

    return _buildFallbackIcon(context);
  }

  Widget _buildFallbackIcon(BuildContext context) {
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
