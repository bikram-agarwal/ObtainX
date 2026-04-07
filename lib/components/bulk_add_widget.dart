import 'dart:math' as math;
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/apkpure.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:provider/provider.dart';

/// Which app types to include in the bulk scan list.
enum BulkAppFilter { userOnly, systemOnly, both }

/// A found-app entry: one package found on one or more stores.
class BulkFoundApp {
  final InstalledAppInfo info;
  // store name -> URL
  final Map<String, String> sources;

  BulkFoundApp({required this.info, required this.sources});

  /// Best URL to add: F-Droid > APKPure > APKMirror > GitHub.
  String get bestUrl {
    for (final store in ['F-Droid', 'APKPure', 'APKMirror', 'GitHub']) {
      if (sources.containsKey(store)) return sources[store]!;
    }
    return sources.values.first;
  }

  String get bestStore {
    for (final store in ['F-Droid', 'APKPure', 'APKMirror', 'GitHub']) {
      if (sources.containsKey(store)) return store;
    }
    return sources.keys.first;
  }
}

enum BulkStep { selectApps, scanning, results }

/// An embeddable bulk-add flow widget.
///
/// When [standalone] is true, it wraps itself in a [Scaffold] with a dynamic
/// [AppBar] and back-navigation, exactly as [BulkAddAppsPage] did before.
///
/// When [standalone] is false (embedded, e.g. inside [AddAppPage]'s tab), it
/// just renders the step content without its own scaffold. [onComplete] is
/// called when the user taps "Done" in embedded mode.
class BulkAddWidget extends StatefulWidget {
  final bool standalone;
  final VoidCallback? onComplete;

  const BulkAddWidget({super.key, this.standalone = false, this.onComplete});

  @override
  State<BulkAddWidget> createState() => BulkAddWidgetState();
}

class BulkAddWidgetState extends State<BulkAddWidget> {
  BulkStep _step = BulkStep.selectApps;
  bool _firstBuild = true;

  // --- Config step ---
  BulkAppFilter _appFilter = BulkAppFilter.userOnly;
  final Set<String> _selectedStores = {'APKMirror', 'APKPure', 'F-Droid'};
  bool _excludeAlreadyTracked = true;
  bool _excludeNonReplaceableSystem = true;
  bool _clearCacheBeforeScan = false;

  // --- App selection step ---
  // Full unfiltered list fetched once per session; filter applied in memory.
  List<InstalledAppInfo> _allInstalledApps = [];
  List<InstalledAppInfo> _installedApps = [];
  bool _loadingApps = false;
  final Set<String> _selectedPackages = {};
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  // Icon cache: packageName -> Uint8List | false (failed). Absent key = not loaded yet.
  final Map<String, Object?> _iconCache = {};
  final Map<String, Future<void>> _iconLoadFutures = {};

  // --- Scanning step ---
  String _scanStatus = '';
  int _apkMirrorDone = 0;
  int _apkMirrorTotal = 0;
  int _apkPureDone = 0;
  int _apkPureTotal = 0;
  int _fdroidDone = 0;
  int _fdroidTotal = 0;
  int _githubDone = 0;
  int _githubTotal = 0;

  // --- Results step ---
  List<BulkFoundApp> _foundApps = [];
  List<InstalledAppInfo> _notFoundApps = [];
  // Snapshot of tracked apps at scan time – prevents just-added apps showing as "already tracked"
  Set<String> _trackedAtScanTime = {};
  bool _addingApps = false;
  int _addingTotal = 0;
  int _addedCount = 0;
  int _failedCount = 0;
  bool _addingDone = false;
  String _addingStatus = '';
  List<BulkFoundApp> _addedApps = [];
  List<BulkFoundApp> _failedApps = [];
  final Set<String> _selectedNewFoundPackages = {};
  // Per-app source selection: package → store name. Empty = use bestStore default.
  final Map<String, String> _selectedSources = {};
  List<InstalledAppInfo> _cancelledApps = [];
  bool _scanCancelRequested = false;
  bool _addCancelRequested = false;

  /// Live maps while a bulk scan runs; used to show partial results as soon as
  /// the user cancels without waiting for in-flight HTTP to finish.
  final Map<String, Map<String, String>> _bulkScanCombined =
      <String, Map<String, String>>{};
  final Map<String, Set<String>> _bulkScanPackageStoresDone =
      <String, Set<String>>{};
  List<String> _bulkScanPackageNames = <String>[];
  bool _bulkScanResultsCommitted = false;

  late AppsProvider _appsProvider;
  static const List<String> _storeIconPriority = [
    'F-Droid',
    'APKPure',
    'APKMirror',
    'GitHub',
  ];

  static const List<String> _configurableBulkStores = <String>[
    'APKMirror',
    'APKPure',
    'F-Droid',
    'GitHub',
  ];

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appsProvider = context.read<AppsProvider>();
    if (_firstBuild) {
      _firstBuild = false;
      _proceedToAppList();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ─── Config Chip Rows (inline in select-apps step) ───────────────────────

  // Row 1: app type (User / System / All)
  Widget _buildAppTypeChipRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          FilterChip(
            avatar: const Icon(Icons.person_rounded, size: 16),
            showCheckmark: false,
            label: Text(tr('userAppsOnly')),
            selected: _appFilter == BulkAppFilter.userOnly,
            onSelected: (_) {
              setState(() => _appFilter = BulkAppFilter.userOnly);
              _proceedToAppList();
            },
          ),
          const SizedBox(width: 8),
          FilterChip(
            avatar: const Icon(Icons.android_rounded, size: 16),
            showCheckmark: false,
            label: Text(tr('systemAppsOnly')),
            selected: _appFilter == BulkAppFilter.systemOnly,
            onSelected: (_) {
              setState(() => _appFilter = BulkAppFilter.systemOnly);
              _proceedToAppList();
            },
          ),
          const SizedBox(width: 8),
          FilterChip(
            avatar: const Icon(Icons.apps_rounded, size: 16),
            showCheckmark: false,
            label: Text(tr('allApps')),
            selected: _appFilter == BulkAppFilter.both,
            onSelected: (_) {
              setState(() => _appFilter = BulkAppFilter.both);
              _proceedToAppList();
            },
          ),
        ],
      ),
    );
  }

  // Row 2: store chips
  Widget _buildStoreChipRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: _configurableBulkStores.map((store) {
          final selected = _selectedStores.contains(store);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              avatar: StoreSourceChipAvatar(
                host: _hostForBulkSourceBadge(store, ''),
                size: 16,
              ),
              showCheckmark: false,
              label: Text(store),
              selected: selected,
              onSelected: (v) {
                setState(() {
                  if (v) {
                    _selectedStores.add(store);
                  } else {
                    _selectedStores.remove(store);
                  }
                });
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  // Row 3: clear cache + skip tracked + skip privileged (all as chips)
  Widget _buildOptionsChipRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          FilterChip(
            avatar: const Icon(Icons.delete_sweep_outlined, size: 16),
            showCheckmark: false,
            label: Text(tr('deleteBulkScanHistory')),
            selected: _clearCacheBeforeScan,
            onSelected: (v) => setState(() => _clearCacheBeforeScan = v),
          ),
          const SizedBox(width: 8),
          FilterChip(
            showCheckmark: false,
            label: Text(tr('excludeAlreadyTrackedApps')),
            selected: _excludeAlreadyTracked,
            onSelected: (v) {
              setState(() => _excludeAlreadyTracked = v);
              _proceedToAppList();
            },
          ),
          if (_appFilter != BulkAppFilter.userOnly) ...[
            const SizedBox(width: 8),
            FilterChip(
              showCheckmark: false,
              label: Text(tr('excludeNonReplaceableSystem')),
              selected: _excludeNonReplaceableSystem,
              onSelected: (v) {
                setState(() => _excludeNonReplaceableSystem = v);
                _applyAppFilter();
              },
            ),
          ],
        ],
      ),
    );
  }

  List<String> _orderedStoreKeysForBadge(Set<String> keys) {
    final List<String> out = [];
    for (final String name in _storeIconPriority) {
      if (keys.contains(name)) out.add(name);
    }
    for (final String key in keys) {
      if (!out.contains(key)) out.add(key);
    }
    return out;
  }

  /// Host string for [StoreSourceListBadge], same resolution path as the Apps tab.
  String _hostForBulkSourceBadge(String storeKey, String url) {
    final String trimmed = url.trim();
    if (trimmed.isNotEmpty) {
      final Uri? uri = Uri.tryParse(trimmed);
      if (uri != null && uri.host.isNotEmpty) {
        return uri.host;
      }
    }
    return switch (storeKey) {
      'APKMirror' => 'www.apkmirror.com',
      'APKPure' => 'apkpure.net',
      'F-Droid' => 'f-droid.org',
      'GitHub' => 'github.com',
      _ => '',
    };
  }

  /// Fixed-width column of store badges (no overlap); keeps title/checkbox layout balanced.
  static const double _bulkAddResultBadgeColumnWidth = 24;
  static const double _bulkAddResultIconSlotWidth = 48;

  Widget _buildBulkResultStoreBadgeColumn(Map<String, String>? sourcesByStore) {
    if (sourcesByStore == null || sourcesByStore.isEmpty) {
      return const SizedBox(width: _bulkAddResultBadgeColumnWidth, height: 40);
    }
    final List<String> ordered = _orderedStoreKeysForBadge(
      sourcesByStore.keys.toSet(),
    );
    final List<String> keys = ordered.length > 5
        ? ordered.sublist(0, 5)
        : ordered;
    final List<Widget> badgeWidgets = <Widget>[];
    for (final String storeKey in keys) {
      final String? url = sourcesByStore[storeKey];
      if (url == null) continue;
      final String host = _hostForBulkSourceBadge(storeKey, url);
      if (host.isEmpty) continue;
      badgeWidgets.add(StoreSourceListBadge(host: host));
    }
    if (badgeWidgets.isEmpty) {
      return const SizedBox(width: _bulkAddResultBadgeColumnWidth, height: 40);
    }
    return SizedBox(
      width: _bulkAddResultBadgeColumnWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (int index = 0; index < badgeWidgets.length; index++) ...<Widget>[
            if (index > 0) const SizedBox(height: 5),
            badgeWidgets[index],
          ],
        ],
      ),
    );
  }

  /// Badge column for selectable rows with size-differentiated icons.
  /// The selected store badge is 20dp (full opacity); others are 13dp at 0.4 opacity.
  Widget _buildSelectableStaticBadgeColumn(
    Map<String, String> sourcesByStore,
    String selectedStore,
  ) {
    final List<String> ordered = _orderedStoreKeysForBadge(
      sourcesByStore.keys.toSet(),
    );
    final List<String> keys =
        ordered.length > 5 ? ordered.sublist(0, 5) : ordered;
    final List<Widget> badgeWidgets = <Widget>[];
    for (final String storeKey in keys) {
      final String? url = sourcesByStore[storeKey];
      if (url == null) continue;
      final String host = _hostForBulkSourceBadge(storeKey, url);
      if (host.isEmpty) continue;
      final bool isSelected = storeKey == selectedStore;
      badgeWidgets.add(
        Opacity(
          opacity: isSelected ? 1.0 : 0.4,
          child: StoreSourceChipAvatar(
            host: host,
            size: isSelected ? 20 : 14,
          ),
        ),
      );
    }
    if (badgeWidgets.isEmpty) {
      return const SizedBox(width: _bulkAddResultBadgeColumnWidth, height: 40);
    }
    return SizedBox(
      width: _bulkAddResultBadgeColumnWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (int index = 0; index < badgeWidgets.length; index++) ...<Widget>[
            if (index > 0) const SizedBox(height: 3),
            badgeWidgets[index],
          ],
        ],
      ),
    );
  }

  Widget _bulkAddAppListRow({
    required Widget leadingIcon,
    required String appName,
    required String packageName,
    required bool checkboxValue,
    ValueChanged<bool?>? onCheckboxChanged,
    Widget? titleSuffix,
  }) {
    return CheckboxListTile(
      checkboxShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
      ),
      controlAffinity: ListTileControlAffinity.trailing,
      secondary: leadingIcon,
      title: Row(
        children: [
          Expanded(
            child: Text(appName, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          ?titleSuffix,
        ],
      ),
      subtitle: Text(
        packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      value: checkboxValue,
      onChanged: onCheckboxChanged,
      dense: true,
    );
  }

  /// Same horizontal rhythm as [CheckboxListTile] on the select-apps step: trailing
  /// icon padding, [ListTileTheme.horizontalTitleGap], then title.
  double get _bulkAddListTileTitleGap =>
      Theme.of(context).listTileTheme.horizontalTitleGap ?? 16;

  /// Result / found rows: [icon] [store badges column] [titles] [checkbox].
  Widget _bulkAddResultAppRow({
    required Widget leadingIcon,
    required Widget storeBadgesColumn,
    required String appName,
    required String packageName,
    required bool checkboxValue,
    ValueChanged<bool?>? onCheckboxChanged,
    Widget? titleSuffix,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: SizedBox(
              width: _bulkAddResultIconSlotWidth,
              height: 48,
              child: Center(child: leadingIcon),
            ),
          ),
          const SizedBox(width: 8),
          storeBadgesColumn,
          SizedBox(width: _bulkAddListTileTitleGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        appName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    ?titleSuffix,
                  ],
                ),
                Text(
                  packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Checkbox(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            value: checkboxValue,
            onChanged: onCheckboxChanged,
          ),
        ],
      ),
    );
  }

  Widget _bulkAddNotFoundResultRow(InstalledAppInfo app) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: SizedBox(
              width: _bulkAddResultIconSlotWidth,
              height: 48,
              child: Center(child: _lazyBulkAppIcon(app.packageName)),
            ),
          ),
          const SizedBox(width: 8),
          _buildBulkResultStoreBadgeColumn(null),
          SizedBox(width: _bulkAddListTileTitleGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Text(
                  app.packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: Center(
              child: Icon(
                Icons.close_rounded,
                color: Theme.of(context).colorScheme.error,
                size: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, String?> _persistedStoreColumn(
    Map<String, Map<String, String>> persisted,
    List<String> packageNames,
    String storeName,
  ) {
    final Map<String, String?> out = {};
    for (final String packageName in packageNames) {
      final Map<String, String>? row = persisted[packageName];
      if (row == null || !row.containsKey(storeName)) continue;
      final String url = row[storeName]!;
      out[packageName] = url.isEmpty ? null : url;
    }
    return out;
  }

  Future<void> _proceedToAppList() async {
    final bool needsFetch = _allInstalledApps.isEmpty;
    setState(() {
      _loadingApps = needsFetch;
      _selectedPackages.clear();
    });
    if (needsFetch) {
      try {
        // Fetch everything once; subsequent calls just re-filter in memory.
        _allInstalledApps = await BulkImportService.getInstalledApps(
          includeSystem: true,
          includeUser: true,
        );
      } catch (e) {
        if (!mounted) return;
        setState(() => _loadingApps = false);
        showError(e, context);
        return;
      }
    }
    _applyAppFilter();
  }

  void _applyAppFilter() {
    List<InstalledAppInfo> apps = _allInstalledApps.where((a) {
      if (_appFilter == BulkAppFilter.userOnly) return !a.isSystemApp;
      if (_appFilter == BulkAppFilter.systemOnly) return a.isSystemApp;
      return true;
    }).toList();
    if (_excludeNonReplaceableSystem) {
      apps = apps.where((a) => !a.isLikelyNonReplaceable).toList();
    }
    if (_excludeAlreadyTracked) {
      final Set<String> tracked = _appsProvider.apps.keys.toSet();
      apps = apps.where((a) => !tracked.contains(a.packageName)).toList();
    }
    if (!mounted) return;
    setState(() {
      _installedApps = apps;
      _loadingApps = false;
    });
  }

  /// One fetch per package; visible list rows await the same future; only the
  /// icon subtree rebuilds when data arrives (no whole-list setState storms).
  Future<void> _ensurePackageIconLoaded(String packageName) {
    if (_iconCache.containsKey(packageName)) return Future<void>.value();
    return _iconLoadFutures.putIfAbsent(packageName, () async {
      try {
        final Uint8List? icon = await BulkImportService.getAppIcon(
          packageName,
        );
        if (!mounted) return;
        _iconCache.putIfAbsent(packageName, () => icon ?? false);
      } catch (_) {
        if (mounted) {
          _iconCache.putIfAbsent(packageName, () => false);
        }
      } finally {
        _iconLoadFutures.remove(packageName);
      }
    });
  }

  // ─── App Selection Step ────────────────────────────────────────────────

  List<InstalledAppInfo> get _filteredApps {
    if (_searchQuery.isEmpty) return _installedApps;
    final q = _searchQuery.toLowerCase();
    return _installedApps
        .where(
          (a) =>
              a.name.toLowerCase().contains(q) ||
              a.packageName.toLowerCase().contains(q),
        )
        .toList();
  }

  Widget _lazyBulkAppIcon(String packageName, {double size = 40}) {
    return _LazyBulkAppIcon(
      packageName: packageName,
      iconCache: _iconCache,
      requestLoad: _ensurePackageIconLoaded,
      size: size,
    );
  }

  Widget _buildSelectAppsStep() {
    final filtered = _filteredApps;
    final alreadyTracked = _appsProvider.apps.keys.toSet();

    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            _buildAppTypeChipRow(),
            const SizedBox(height: 8),
            _buildStoreChipRow(),
            const SizedBox(height: 8),
            _buildOptionsChipRow(),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: tr('search'),
                        prefixIcon: const Icon(Icons.search, size: 18),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onChanged: (String value) =>
                          setState(() => _searchQuery = value),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty)
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Text(
                    tr(
                      'selectedX',
                      args: [
                        '${_selectedPackages.length}/${_installedApps.length}',
                      ],
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(
                      () => _selectedPackages.addAll(
                        filtered.map((a) => a.packageName),
                      ),
                    ),
                    child: Text(tr('selectAll')),
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () => _selectedPackages.removeAll(
                        filtered.map((a) => a.packageName),
                      ),
                    ),
                    child: Text(tr('deselectAll')),
                  ),
                ],
              ),
            ),
            if (_loadingApps)
              Expanded(child: Center(child: _m3LoadingIndicator()))
            else if (_installedApps.isEmpty)
              Expanded(child: Center(child: Text(tr('noAppsFound'))))
            else
              Expanded(
                child: ListView.builder(
                  // Bottom padding reserves space so the last item isn't
                  // hidden behind the FAB.
                  padding: const EdgeInsets.only(bottom: 88),
                  cacheExtent: 1200,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final app = filtered[index];
                    final selected = _selectedPackages.contains(
                      app.packageName,
                    );
                    final tracked = alreadyTracked.contains(app.packageName);
                    return _bulkAddAppListRow(
                      leadingIcon: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _lazyBulkAppIcon(app.packageName),
                      ),
                      appName: app.name,
                      packageName: app.packageName,
                      checkboxValue: selected,
                      onCheckboxChanged: (bool? value) {
                        setState(() {
                          if (value == true) {
                            _selectedPackages.add(app.packageName);
                          } else {
                            _selectedPackages.remove(app.packageName);
                          }
                        });
                      },
                      titleSuffix: tracked
                          ? Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                tr('alreadyTracked'),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                                ),
                              ),
                            )
                          : null,
                    );
                  },
                ),
              ),
          ],
        ),
        // FAB — replaces the full-width button row.
        Align(
          alignment: Alignment.bottomRight,
          child: SafeArea(
            minimum: const EdgeInsets.all(16),
            child: Badge(
              isLabelVisible: _selectedPackages.isNotEmpty,
              label: Text('${_selectedPackages.length}'),
              child: FloatingActionButton(
                heroTag: 'bulkFindApps',
                onPressed: _selectedPackages.isEmpty ? null : _startScanning,
                child: const Icon(Icons.search_rounded),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── Scanning Step ─────────────────────────────────────────────────────

  /// Builds [found] / [notFound] / [cancelled] from live scan maps and moves
  /// to the results step. Safe to call while network work is still running
  /// (e.g. user tapped cancel) — only the first call applies.
  void _commitBulkScanResults() {
    if (_bulkScanResultsCommitted || !mounted) return;
    _bulkScanResultsCommitted = true;

    final Map<String, InstalledAppInfo> appInfoMap = {
      for (final InstalledAppInfo a in _installedApps) a.packageName: a,
    };
    final List<BulkFoundApp> found = <BulkFoundApp>[];
    final List<InstalledAppInfo> notFound = <InstalledAppInfo>[];
    final List<InstalledAppInfo> cancelledApps = <InstalledAppInfo>[];

    for (final String pkg in _bulkScanPackageNames) {
      final InstalledAppInfo? info = appInfoMap[pkg];
      if (info == null) continue;
      final Set<String>? doneForPackage = _bulkScanPackageStoresDone[pkg];
      final bool coveredAllSelectedStores = _selectedStores.every(
        (String storeLabel) => doneForPackage?.contains(storeLabel) ?? false,
      );
      if (!coveredAllSelectedStores) {
        cancelledApps.add(info);
        continue;
      }
      final Map<String, String>? sources = _bulkScanCombined[pkg];
      if (sources != null && sources.isNotEmpty) {
        found.add(BulkFoundApp(info: info, sources: sources));
      } else {
        notFound.add(info);
      }
    }

    final Set<String> newFoundIds = {
      for (final BulkFoundApp a in found)
        if (!_trackedAtScanTime.contains(a.info.packageName))
          a.info.packageName,
    };

    setState(() {
      _foundApps = found;
      _notFoundApps = notFound;
      _cancelledApps = cancelledApps;
      _selectedNewFoundPackages
        ..clear()
        ..addAll(newFoundIds);
      _step = BulkStep.results;
    });
  }

  Future<void> _startScanning() async {
    // Capture which apps are already tracked BEFORE we start, so results
    // display and add-loop can use this stable snapshot.
    _trackedAtScanTime = _appsProvider.apps.keys.toSet();

    if (_clearCacheBeforeScan) {
      await BulkScanCache.clearStores(_selectedStores);
      if (mounted) setState(() => _clearCacheBeforeScan = false);
    }
    Map<String, Map<String, String>> persistedScanCache =
        await BulkScanCache.load();

    _scanCancelRequested = false;

    setState(() {
      _step = BulkStep.scanning;
      _scanStatus = '';
      _apkMirrorDone = 0;
      _apkMirrorTotal = 0;
      _apkPureDone = 0;
      _apkPureTotal = 0;
      _fdroidDone = 0;
      _fdroidTotal = 0;
      _githubDone = 0;
      _githubTotal = 0;
      _foundApps = [];
      _notFoundApps = [];
      _cancelledApps = [];
    });

    _bulkScanCombined.clear();
    _bulkScanPackageStoresDone.clear();
    _bulkScanPackageNames = List<String>.from(_selectedPackages);
    _bulkScanResultsCommitted = false;

    void recordStoreCoverage(String storeLabel, Map<String, String?> results) {
      for (final String packageName in results.keys) {
        _bulkScanPackageStoresDone
            .putIfAbsent(packageName, () => <String>{})
            .add(storeLabel);
      }
    }

    bool shouldAbortScan() => _scanCancelRequested;

    final List<String> storeOrder = _configurableBulkStores
        .where((String storeName) => _selectedStores.contains(storeName))
        .toList();

    for (final String storeName in storeOrder) {
      if (!mounted || _bulkScanResultsCommitted) return;
      if (_scanCancelRequested) break;

      switch (storeName) {
        case 'APKMirror':
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['APKMirror']);
              _apkMirrorTotal = _bulkScanPackageNames.length;
              _apkMirrorDone = 0;
            });
          }
          final Map<String, String?> mirrorKnown = _persistedStoreColumn(
            persistedScanCache,
            _bulkScanPackageNames,
            'APKMirror',
          );
          final Map<String, String?> mirrorResults =
              await BulkImportService.checkApkMirror(
                _bulkScanPackageNames,
                alreadyKnown: mirrorKnown.isEmpty ? null : mirrorKnown,
                shouldAbort: shouldAbortScan,
                onProgress: (int done, int total) {
                  if (mounted) {
                    setState(() {
                      _apkMirrorDone = done;
                      _apkMirrorTotal = total;
                    });
                  }
                },
              );
          if (!mounted || _bulkScanResultsCommitted) return;
          recordStoreCoverage('APKMirror', mirrorResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'APKMirror',
            mirrorResults,
          );
          if (!mounted || _bulkScanResultsCommitted) return;
          if (mounted) {
            setState(() => _apkMirrorDone = _apkMirrorTotal);
          }
          mirrorResults.forEach((String pkg, String? url) {
            if (url != null) {
              _bulkScanCombined
                  .putIfAbsent(pkg, () => <String, String>{})['APKMirror'] =
                  url;
            }
          });
        case 'APKPure':
          if (!mounted || _bulkScanResultsCommitted) return;
          if (_scanCancelRequested) break;
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['APKPure']);
              _apkPureTotal = _bulkScanPackageNames.length;
              _apkPureDone = 0;
            });
          }
          final Map<String, String?> pureKnown = _persistedStoreColumn(
            persistedScanCache,
            _bulkScanPackageNames,
            'APKPure',
          );
          final Map<String, String?> pureResults =
              await BulkImportService.checkApkPure(
                _bulkScanPackageNames,
                alreadyKnown: pureKnown.isEmpty ? null : pureKnown,
                shouldAbort: shouldAbortScan,
                onProgress: (int done, int total) {
                  if (mounted) {
                    setState(() {
                      _apkPureDone = done;
                      _apkPureTotal = total;
                    });
                  }
                },
              );
          if (!mounted || _bulkScanResultsCommitted) return;
          recordStoreCoverage('APKPure', pureResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'APKPure',
            pureResults,
          );
          if (!mounted || _bulkScanResultsCommitted) return;
          if (mounted) {
            setState(() => _apkPureDone = _apkPureTotal);
          }
          pureResults.forEach((String pkg, String? url) {
            if (url != null) {
              _bulkScanCombined
                  .putIfAbsent(pkg, () => <String, String>{})['APKPure'] = url;
            }
          });
        case 'F-Droid':
          if (!mounted || _bulkScanResultsCommitted) return;
          if (_scanCancelRequested) break;
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['F-Droid']);
              _fdroidTotal = _bulkScanPackageNames.length;
              _fdroidDone = 0;
            });
          }
          final Map<String, String?> fdroidKnown = _persistedStoreColumn(
            persistedScanCache,
            _bulkScanPackageNames,
            'F-Droid',
          );
          final Map<String, String?> fdroidResults =
              await BulkImportService.checkFDroid(
                _bulkScanPackageNames,
                alreadyKnown: fdroidKnown.isEmpty ? null : fdroidKnown,
                shouldAbort: shouldAbortScan,
                onProgress: (int done, int total) {
                  if (mounted) {
                    setState(() {
                      _fdroidDone = done;
                      _fdroidTotal = total;
                    });
                  }
                },
              );
          if (!mounted || _bulkScanResultsCommitted) return;
          recordStoreCoverage('F-Droid', fdroidResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'F-Droid',
            fdroidResults,
          );
          if (!mounted || _bulkScanResultsCommitted) return;
          if (mounted) {
            setState(() => _fdroidDone = _fdroidTotal);
          }
          fdroidResults.forEach((String pkg, String? url) {
            if (url != null) {
              _bulkScanCombined
                  .putIfAbsent(pkg, () => <String, String>{})['F-Droid'] = url;
            }
          });
        case 'GitHub':
          if (!mounted || _bulkScanResultsCommitted) return;
          if (_scanCancelRequested) break;
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['GitHub']);
              _githubTotal = _bulkScanPackageNames.length;
              _githubDone = 0;
            });
          }
          final Map<String, String?> githubKnown = _persistedStoreColumn(
            persistedScanCache,
            _bulkScanPackageNames,
            'GitHub',
          );
          final Map<String, String?> githubResults =
              await BulkImportService.checkGitHub(
                _bulkScanPackageNames,
                alreadyKnown: githubKnown.isEmpty ? null : githubKnown,
                shouldAbort: shouldAbortScan,
                onProgress: (int done, int total) {
                  if (mounted) {
                    setState(() {
                      _githubDone = done;
                      _githubTotal = total;
                    });
                  }
                },
              );
          if (!mounted || _bulkScanResultsCommitted) return;
          recordStoreCoverage('GitHub', githubResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'GitHub',
            githubResults,
          );
          if (!mounted || _bulkScanResultsCommitted) return;
          if (mounted) {
            setState(() => _githubDone = _githubTotal);
          }
          githubResults.forEach((String pkg, String? url) {
            if (url != null) {
              _bulkScanCombined
                  .putIfAbsent(pkg, () => <String, String>{})['GitHub'] = url;
            }
          });
        default:
          break;
      }
    }

    if (!_bulkScanResultsCommitted) {
      _commitBulkScanResults();
    }
  }

  Widget _buildScanningStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: _m3LoadingIndicator(size: 80)),
          const SizedBox(height: 32),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _scanStatus,
              key: ValueKey<String>(_scanStatus),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 40),
          if (_selectedStores.contains('APKMirror'))
            _buildStoreCard('APKMirror', _apkMirrorDone, _apkMirrorTotal),
          if (_selectedStores.contains('APKPure'))
            _buildStoreCard('APKPure', _apkPureDone, _apkPureTotal),
          if (_selectedStores.contains('F-Droid'))
            _buildStoreCard('F-Droid', _fdroidDone, _fdroidTotal),
          if (_selectedStores.contains('GitHub'))
            _buildStoreCard('GitHub', _githubDone, _githubTotal),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () {
              _scanCancelRequested = true;
              _commitBulkScanResults();
            },
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(tr('cancelBulkScan')),
          ),
        ],
      ),
    );
  }

  Widget _buildStoreCard(String store, int done, int total) {
    final bool storeComplete = total > 0 && done >= total;
    final bool started = total > 0 && done > 0;
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final double? progressValue = total > 0
        ? (done / total).clamp(0.0, 1.0)
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: storeComplete
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            StoreSourceChipAvatar(
              host: _hostForBulkSourceBadge(store, ''),
              size: 32,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        store,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: storeComplete
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                      ),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: storeComplete
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: colorScheme.primary,
                                size: 20,
                                key: const ValueKey<String>('done'),
                              )
                            : Text(
                                total > 0
                                    ? tr(
                                        'bulkScanProgressXY',
                                        args: ['$done', '$total'],
                                      )
                                    : tr('pending'),
                                key: ValueKey<String>(
                                  total > 0 ? 'n-$done-$total' : 'pending',
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                      ),
                    ],
                  ),
                  if (!storeComplete) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: started ? progressValue : null,
                        minHeight: 4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Results Step ──────────────────────────────────────────────────────

  Widget _buildResultsStep() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    final List<BulkFoundApp> newFound = _foundApps
        .where(
          (BulkFoundApp a) => !_trackedAtScanTime.contains(a.info.packageName),
        )
        .toList();
    final List<BulkFoundApp> alreadyFoundTracked = _foundApps
        .where(
          (BulkFoundApp a) => _trackedAtScanTime.contains(a.info.packageName),
        )
        .toList();
    final int selectedNewFoundCount = newFound
        .where(
          (BulkFoundApp a) =>
              _selectedNewFoundPackages.contains(a.info.packageName),
        )
        .length;
    final int cancelledCount = _cancelledApps.length;
    final bool showFabDone = _addingDone || newFound.isEmpty;
    final bool showProgress = _addingApps && _addingTotal > 0;

    // Build all list items; banner goes first so it scrolls away naturally.
    final List<Widget> listItems = [
      _buildSummaryBanner(newFound, alreadyFoundTracked, cancelledCount),
    ];
    if (_addingDone) {
      if (_addedApps.isNotEmpty) {
        listItems.add(
          _buildSectionHeader(
            '${tr('added')} (${_addedApps.length})',
            colorScheme.primary,
          ),
        );
        listItems.addAll(
          _addedApps.map((a) => _buildFoundAppTile(a, addedResult: true)),
        );
      }
      if (_failedApps.isNotEmpty) {
        listItems.add(
          _buildSectionHeader(
            '${tr('failed')} (${_failedApps.length})',
            colorScheme.error,
          ),
        );
        listItems.addAll(
          _failedApps.map((a) => _buildFoundAppTile(a, failedResult: true)),
        );
      }
      if (_notFoundApps.isNotEmpty) {
        listItems.add(
          _buildSectionHeader(
            '${tr('notFound')} (${_notFoundApps.length})',
            colorScheme.error,
          ),
        );
        listItems.addAll(_notFoundApps.map(_buildNotFoundTile));
      }
    } else {
      if (newFound.isNotEmpty) {
        listItems.add(
          _buildSectionHeader(
            '${tr('found')} (${newFound.length})',
            colorScheme.primary,
          ),
        );
        listItems.addAll(
          newFound.map((a) => _buildFoundAppTile(a, selectable: true)),
        );
      }
      if (alreadyFoundTracked.isNotEmpty) {
        listItems.add(
          _buildSectionHeader(
            '${tr('alreadyTracked')} (${alreadyFoundTracked.length})',
            colorScheme.tertiary,
          ),
        );
        listItems.addAll(
          alreadyFoundTracked.map((a) => _buildFoundAppTile(a, tracked: true)),
        );
      }
      if (_notFoundApps.isNotEmpty) {
        listItems.add(
          _buildSectionHeader(
            '${tr('notFound')} (${_notFoundApps.length})',
            colorScheme.error,
          ),
        );
        listItems.addAll(_notFoundApps.map(_buildNotFoundTile));
      }
      if (_cancelledApps.isNotEmpty) {
        listItems.add(
          _buildSectionHeader(
            '${tr('bulkScanCancelled')} (${_cancelledApps.length})',
            colorScheme.onSurfaceVariant,
          ),
        );
        listItems.addAll(_cancelledApps.map(_bulkAddCancelledResultRow));
      }
    }

    return Stack(
      children: [
        // Full-height scrollable list; banner is item 0 so it scrolls away.
        _foundApps.isEmpty && _notFoundApps.isEmpty && _cancelledApps.isEmpty
            ? Center(child: Text(tr('noAppsFound')))
            : ListView(
                // Reserve space for the bottom FAB row.
                padding: const EdgeInsets.only(bottom: 88),
                children: listItems,
              ),

        // Bottom row: progress pill (when active, expanding to the left of the
        // FAB) + FAB. Both live in the same Positioned so they stay aligned.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (showProgress) ...[
                  Expanded(child: _buildProgressPill()),
                  const SizedBox(width: 8),
                ] else
                  const Spacer(),
                showFabDone
                    ? FloatingActionButton.extended(
                        heroTag: 'bulkResultsDone',
                        onPressed: () {
                          if (widget.standalone) {
                            Navigator.pop(context);
                          } else {
                            widget.onComplete?.call();
                          }
                        },
                        icon: const Icon(Icons.check_rounded),
                        label: Text(tr('done')),
                      )
                    : _addingApps
                    ? FloatingActionButton.extended(
                        heroTag: 'bulkResultsCancel',
                        onPressed: () =>
                            setState(() => _addCancelRequested = true),
                        backgroundColor: colorScheme.errorContainer,
                        foregroundColor: colorScheme.onErrorContainer,
                        icon: const Icon(Icons.stop_rounded),
                        label: Text(tr('cancel')),
                      )
                    : FloatingActionButton.extended(
                        heroTag: 'bulkResultsAdd',
                        onPressed: selectedNewFoundCount == 0
                            ? null
                            : () {
                                final List<BulkFoundApp> selectedToAdd =
                                    newFound
                                        .where(
                                          (BulkFoundApp a) =>
                                              _selectedNewFoundPackages
                                                  .contains(a.info.packageName),
                                        )
                                        .toList();
                                _addFoundApps(selectedToAdd);
                              },
                        icon: const Icon(Icons.save_rounded),
                        label: Text(
                          tr('addFoundApps', args: ['$selectedNewFoundCount']),
                        ),
                      ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Pill-shaped progress bar that fills from the left edge of the screen up to
  /// the FAB. Height matches a [FloatingActionButton.extended] (~56 dp).
  Widget _buildProgressPill() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final double progress = _addingTotal > 0
        ? (_addedCount + _failedCount) / _addingTotal
        : 0.0;

    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          // Background track
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.92,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          // Progress fill – grows from left to right
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress.clamp(0.0, 1.0),
                  heightFactor: 1.0,
                  child: Container(color: colorScheme.primaryContainer),
                ),
              ),
            ),
          ),
          // "Adding DoorDash..." centered in the pill
          Positioned.fill(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  _addingStatus,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBanner(
    List<BulkFoundApp> newFound,
    List<BulkFoundApp> alreadyFoundTracked,
    int cancelledCount,
  ) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    // Apps that were selected for adding but skipped because the user
    // cancelled before they were processed.
    final int addSkippedCount = _addingTotal - _addedCount - _failedCount;

    final List<Widget> metrics = _addingDone
        ? [
            Expanded(
              child: _buildSummaryMetricColumn(
                Icons.check_circle_rounded,
                '$_addedCount',
                tr('added'),
                colorScheme.primary,
              ),
            ),
            if (_failedCount > 0)
              Expanded(
                child: _buildSummaryMetricColumn(
                  Icons.error_rounded,
                  '$_failedCount',
                  tr('failed'),
                  colorScheme.error,
                ),
              ),
            if (addSkippedCount > 0)
              Expanded(
                child: _buildSummaryMetricColumn(
                  Icons.stop_circle_rounded,
                  '$addSkippedCount',
                  tr('cancelled'),
                  colorScheme.onSurfaceVariant,
                ),
              ),
            if (_notFoundApps.isNotEmpty)
              Expanded(
                child: _buildSummaryMetricColumn(
                  Icons.cancel_rounded,
                  '${_notFoundApps.length}',
                  tr('notFound'),
                  colorScheme.error,
                ),
              ),
          ]
        : [
            Expanded(
              child: _buildSummaryMetricColumn(
                Icons.check_circle_rounded,
                '${_foundApps.length}',
                tr('found'),
                colorScheme.primary,
              ),
            ),
            Expanded(
              child: _buildSummaryMetricColumn(
                Icons.cancel_rounded,
                '${_notFoundApps.length}',
                tr('notFound'),
                colorScheme.error,
              ),
            ),
            if (cancelledCount > 0)
              Expanded(
                child: _buildSummaryMetricColumn(
                  Icons.hourglass_disabled_rounded,
                  '$cancelledCount',
                  tr('bulkScanCancelled'),
                  colorScheme.onSurfaceVariant,
                ),
              ),
            if (alreadyFoundTracked.isNotEmpty)
              Expanded(
                child: _buildSummaryMetricColumn(
                  Icons.bookmark_rounded,
                  '${alreadyFoundTracked.length}',
                  tr('alreadyTracked'),
                  colorScheme.tertiary,
                ),
              ),
          ];

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(8),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: metrics,
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildSummaryMetricColumn(
    IconData icon,
    String value,
    String label,
    Color accentColor, {
    Color? labelColor,
  }) {
    final Color resolvedLabelColor =
        labelColor ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // SizedBox fixes the banner height independently of text or icon.
        const SizedBox(height: 90),
        // 81 dp = 90 % of 90 — fills most of the banner, stays entirely inside.
        Icon(icon, size: 90, color: accentColor.withValues(alpha: 0.15)),
        // Number + label only; no duplicate small icon
        Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: accentColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: resolvedLabelColor),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNotFoundTile(InstalledAppInfo app) {
    return _bulkAddNotFoundResultRow(app);
  }

  Widget _bulkAddCancelledResultRow(InstalledAppInfo app) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: SizedBox(
              width: _bulkAddResultIconSlotWidth,
              height: 48,
              child: Center(child: _lazyBulkAppIcon(app.packageName)),
            ),
          ),
          const SizedBox(width: 8),
          _buildBulkResultStoreBadgeColumn(null),
          SizedBox(width: _bulkAddListTileTitleGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Text(
                  app.packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: Center(
              child: Icon(
                Icons.pending_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFoundAppTile(
    BulkFoundApp app, {
    bool tracked = false,
    bool selectable = false,
    bool addedResult = false,
    bool failedResult = false,
  }) {
    final Widget leadingIcon = _lazyBulkAppIcon(app.info.packageName);
    final Widget storeBadgesColumn = _buildBulkResultStoreBadgeColumn(app.sources);

    if (selectable && !tracked) {
      final bool isSelected = _selectedNewFoundPackages.contains(
        app.info.packageName,
      );

      final String selectedStore =
          _selectedSources[app.info.packageName] ??
          (() {
            for (final s in ['F-Droid', 'APKPure', 'APKMirror', 'GitHub']) {
              if (app.sources.containsKey(s)) return s;
            }
            return app.sources.keys.first;
          })();

      // Single-source: render the one badge at 20dp directly — no loop or
      // selection logic needed.
      // Multi-source: use _buildSelectableStaticBadgeColumn to differentiate
      // selected (20dp) from unselected (14dp).
      Widget badgesColumnWidget = app.sources.length == 1
          ? SizedBox(
              width: _bulkAddResultBadgeColumnWidth,
              height: 40,
              child: Center(
                child: StoreSourceChipAvatar(
                  host: _hostForBulkSourceBadge(
                    selectedStore,
                    app.sources[selectedStore] ?? '',
                  ),
                  size: 20,
                ),
              ),
            )
          : _buildSelectableStaticBadgeColumn(app.sources, selectedStore);
      Widget leadingIconWidget = leadingIcon;

      if (app.sources.length > 1) {
        final List<String> ordered = _orderedStoreKeysForBadge(
          app.sources.keys.toSet(),
        );

        Future<void> openStorePopup(TapUpDetails details) async {
          final Offset pos = details.globalPosition;
          final RelativeRect rect = RelativeRect.fromLTRB(
            pos.dx,
            pos.dy,
            pos.dx + 1,
            pos.dy + 1,
          );
          final String? chosen = await showMenu<String>(
            context: context,
            position: rect,
            items: ordered.map((store) {
              final String host = _hostForBulkSourceBadge(
                store,
                app.sources[store] ?? '',
              );
              return PopupMenuItem<String>(
                value: store,
                child: Row(
                  children: [
                    StoreSourceChipAvatar(host: host, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        store,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (store == selectedStore)
                      Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              );
            }).toList(),
          );
          if (chosen != null && mounted) {
            setState(() => _selectedSources[app.info.packageName] = chosen);
          }
        }

        badgesColumnWidget = GestureDetector(
          onTapUp: openStorePopup,
          child: badgesColumnWidget,
        );
        leadingIconWidget = GestureDetector(
          onTapUp: openStorePopup,
          child: leadingIcon,
        );
      }

      return _bulkAddResultAppRow(
        leadingIcon: leadingIconWidget,
        storeBadgesColumn: badgesColumnWidget,
        appName: app.info.name,
        packageName: app.info.packageName,
        checkboxValue: isSelected,
        onCheckboxChanged: (bool? value) {
          setState(() {
            if (value == true) {
              _selectedNewFoundPackages.add(app.info.packageName);
            } else {
              _selectedNewFoundPackages.remove(app.info.packageName);
            }
          });
        },
      );
    }

    if (addedResult) {
      return _bulkAddResultAppRow(
        leadingIcon: leadingIcon,
        storeBadgesColumn: storeBadgesColumn,
        appName: app.info.name,
        packageName: app.info.packageName,
        checkboxValue: true,
        onCheckboxChanged: null,
      );
    }

    if (failedResult) {
      return _bulkAddResultAppRow(
        leadingIcon: leadingIcon,
        storeBadgesColumn: storeBadgesColumn,
        appName: app.info.name,
        packageName: app.info.packageName,
        checkboxValue: false,
        onCheckboxChanged: null,
        titleSuffix: Icon(
          Icons.error_outline_rounded,
          size: 20,
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }

    return _bulkAddResultAppRow(
      leadingIcon: leadingIcon,
      storeBadgesColumn: storeBadgesColumn,
      appName: app.info.name,
      packageName: app.info.packageName,
      checkboxValue: false,
      onCheckboxChanged: null,
      titleSuffix: tracked
          ? Icon(
              Icons.bookmark_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.tertiary,
            )
          : Icon(
              Icons.check_circle_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
    );
  }

  // ─── Add Apps ──────────────────────────────────────────────────────────

  Future<void> _addFoundApps(List<BulkFoundApp> apps) async {
    setState(() {
      _addingApps = true;
      _addCancelRequested = false;
      _addingTotal = apps.length;
      _addedCount = 0;
      _failedCount = 0;
      _addingStatus = '';
      _addedApps = [];
      _failedApps = [];
    });

    final logsProvider = context.read<LogsProvider>();
    final sourceProvider = SourceProvider();
    final apkMirrorSource = APKMirror();
    final apkPureSource = APKPure();
    final fdroidSource = FDroid();
    final githubSource = GitHub();

    AppSource sourceFor(String storeName) {
      switch (storeName) {
        case 'APKMirror':
          return apkMirrorSource;
        case 'APKPure':
          return apkPureSource;
        case 'F-Droid':
          return fdroidSource;
        case 'GitHub':
          return githubSource;
        default:
          return fdroidSource;
      }
    }

    Future<void> addOne(BulkFoundApp app) async {
      if (!mounted || _addCancelRequested) return;
      setState(() => _addingStatus = tr('addingApp', args: [app.info.name]));

      final String storeName =
          _selectedSources[app.info.packageName] ?? app.bestStore;
      final source = sourceFor(storeName);
      final settings = getDefaultValuesFromFormItems(
        source.combinedAppSpecificSettingFormItems,
      );
      // Force the known package name so store inference can't substitute a
      // wrong ID (e.g. APKMirror scraping the wrong package from page HTML).
      settings['appId'] = app.info.packageName;

      try {
        final newApp = await sourceProvider.getApp(
          source,
          app.sources[storeName] ?? app.bestUrl,
          settings,
          inferAppIdIfOptional: true,
        );
        await _appsProvider.saveApps([newApp], onlyIfExists: false);
        final liveApp = _appsProvider.apps[newApp.id]?.app;
        if (liveApp != null) {
          await _appsProvider.assignMatchingFoldersToAppIfNeeded(liveApp);
        }
        if (mounted) {
          setState(() {
            _addedCount++;
            _addedApps = [..._addedApps, app];
          });
        }
      } catch (e) {
        final String errMsg = e is ObtainiumError
            ? e.toString()
            : tr('unexpectedError');
        logsProvider.add(
          'Bulk add failed for ${app.info.name} (${app.info.packageName}): $errMsg',
          level: LogLevels.error,
        );
        if (mounted) {
          setState(() {
            _failedCount++;
            _failedApps = [..._failedApps, app];
            _addingStatus = '${tr('error')}: ${app.info.name} – $errMsg';
          });
        }
      }
    }

    // Process apps concurrently in chunks. The network fetch (getApp) is the
    // bottleneck; running a few in parallel cuts wall-clock time proportionally
    // without hammering any single store's rate limits.
    const int concurrency = 4;
    for (int i = 0; i < apps.length; i += concurrency) {
      if (!mounted || _addCancelRequested) break;
      final chunk = apps.sublist(i, math.min(i + concurrency, apps.length));
      await Future.wait(chunk.map(addOne));
    }

    if (mounted) {
      setState(() {
        _addingApps = false;
        _addingDone = true;
        _addingStatus = '';
      });
    }
  }

  // ─── Step Navigation ───────────────────────────────────────────────────

  /// True while adding is in progress OR while the result screen is visible.
  /// Used by [AddAppPageState] to suppress the home-page auto-navigate-to-apps
  /// logic so the user is not thrown back to the Apps tab mid-operation or
  /// before they have reviewed the results.
  bool get isAdding => _addingApps || _addingDone;

  /// Called by [AddAppPageState.handleBack] when the Device tab is active.
  /// Returns true if the back press was consumed (moved to previous step).
  bool handleBack() {
    if (_canGoBack()) {
      _goBack();
      return true;
    }
    return false;
  }

  String _stepTitle() {
    switch (_step) {
      case BulkStep.selectApps:
        return tr('selectAppsToImport');
      case BulkStep.scanning:
        return tr('scanning');
      case BulkStep.results:
        return tr('importResults');
    }
  }

  bool _canGoBack() {
    switch (_step) {
      case BulkStep.selectApps:
        return false;
      case BulkStep.scanning:
        return false;
      case BulkStep.results:
        return true;
    }
  }

  void _goBack() {
    if (_step == BulkStep.results) {
      setState(() => _step = BulkStep.selectApps);
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────────

  Widget _m3LoadingIndicator({double size = 64}) => BulkM3LoadingIndicator(
    size: size,
    color: Theme.of(context).colorScheme.primary,
  );

  // ─── Build ─────────────────────────────────────────────────────────────

  Widget _buildStepContent() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: KeyedSubtree(
        key: ValueKey(_step),
        child: switch (_step) {
          BulkStep.selectApps => _buildSelectAppsStep(),
          BulkStep.scanning => _buildScanningStep(),
          BulkStep.results => _buildResultsStep(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.standalone) {
      return PopScope(
        canPop: _step == BulkStep.selectApps,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _canGoBack()) {
            _goBack();
          }
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(_stepTitle()),
            automaticallyImplyLeading: _step != BulkStep.scanning,
            leading: _canGoBack()
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: _goBack,
                  )
                : null,
          ),
          body: _buildStepContent(),
        ),
      );
    }

    // Embedded mode: no Scaffold; back navigation handled via PopScope so
    // Android back moves through steps instead of popping AddAppPage.
    return PopScope(
      canPop: _step == BulkStep.selectApps,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack()) {
          _goBack();
        }
      },
      child: _buildStepContent(),
    );
  }
}

typedef _BulkIconRequestLoad = Future<void> Function(String packageName);

/// Loads one app icon on demand; only this widget rebuilds when bytes arrive.
class _LazyBulkAppIcon extends StatefulWidget {
  const _LazyBulkAppIcon({
    required this.packageName,
    required this.iconCache,
    required this.requestLoad,
    this.size = 40,
  });

  final String packageName;
  final Map<String, Object?> iconCache;
  final _BulkIconRequestLoad requestLoad;
  final double size;

  @override
  State<_LazyBulkAppIcon> createState() => _LazyBulkAppIconState();
}

class _LazyBulkAppIconState extends State<_LazyBulkAppIcon> {
  @override
  void initState() {
    super.initState();
    _requestIfMissing();
  }

  @override
  void didUpdateWidget(covariant _LazyBulkAppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName != widget.packageName) {
      _requestIfMissing();
    }
  }

  void _requestIfMissing() {
    if (widget.iconCache.containsKey(widget.packageName)) return;
    widget.requestLoad(widget.packageName).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final Object? cached = widget.iconCache[widget.packageName];
    if (cached is Uint8List) {
      final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final int cachePixels = (widget.size * devicePixelRatio).round();
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          cached,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          cacheWidth: cachePixels,
          cacheHeight: cachePixels,
          filterQuality: FilterQuality.low,
        ),
      );
    }
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.android_rounded,
        size: widget.size * 0.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Staggered-dot loading indicator used while bulk lists load or stores scan.
class BulkM3LoadingIndicator extends StatefulWidget {
  final double size;
  final Color color;

  const BulkM3LoadingIndicator({
    super.key,
    required this.size,
    required this.color,
  });

  @override
  State<BulkM3LoadingIndicator> createState() => _BulkM3LoadingIndicatorState();
}

class _BulkM3LoadingIndicatorState extends State<BulkM3LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const int _dotCount = 5;
  static const double _staggerFraction = 0.15;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double dotSize = widget.size / _dotCount * 0.7;
    return SizedBox(
      width: widget.size,
      height: widget.size * 0.45,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List<Widget>.generate(_dotCount, (int dotIndex) {
              final double wavePhase =
                  (_controller.value - dotIndex * _staggerFraction) % 1.0;
              final double scale =
                  0.35 + 0.65 * (0.5 - 0.5 * math.cos(wavePhase * 2 * math.pi));
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
