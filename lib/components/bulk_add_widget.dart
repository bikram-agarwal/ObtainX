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

enum BulkStep { config, selectApps, scanning, results }

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
  BulkStep _step = BulkStep.config;

  // --- Config step ---
  BulkAppFilter _appFilter = BulkAppFilter.userOnly;
  final Set<String> _selectedStores = {'APKMirror', 'APKPure', 'F-Droid'};
  bool _excludeAlreadyTracked = true;
  bool _deleteScanHistoryBeforeScan = false;

  // --- App selection step ---
  List<InstalledAppInfo> _installedApps = [];
  bool _loadingApps = false;
  final Set<String> _selectedPackages = {};
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  // Icon cache: packageName -> icon bytes (null while loading, Uint8List or false when done)
  final Map<String, Object?> _iconCache =
      {}; // Object? = Uint8List | false | null

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
  int _addedCount = 0;
  int _failedCount = 0;
  bool _addingDone = false;
  String _addingStatus = '';
  List<BulkFoundApp> _addedApps = [];
  List<BulkFoundApp> _failedApps = [];
  final Set<String> _selectedNewFoundPackages = {};
  List<InstalledAppInfo> _cancelledApps = [];
  bool _scanCancelRequested = false;

  late AppsProvider _appsProvider;

  static const Color _summaryFoundGreen = Color(0xFF2E7D32);
  static const Color _summaryNotFoundRed = Color(0xFFC62828);
  static const Color _summaryAlreadyTrackedBlue = Color(0xFF1565C0);
  static const Color _summaryCancelledGrey = Color(0xFF757575);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appsProvider = context.read<AppsProvider>();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ─── Config Step ─────────────────────────────────────────────────────────

  Widget _buildConfigStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('appTypeFilter'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          SegmentedButton<BulkAppFilter>(
            segments: [
              ButtonSegment(
                value: BulkAppFilter.userOnly,
                label: Text(tr('userAppsOnly')),
                icon: const Icon(Icons.person_rounded),
              ),
              ButtonSegment(
                value: BulkAppFilter.systemOnly,
                label: Text(tr('systemAppsOnly')),
                icon: const Icon(Icons.android_rounded),
              ),
              ButtonSegment(
                value: BulkAppFilter.both,
                label: Text(tr('allApps')),
                icon: const Icon(Icons.apps_rounded),
              ),
            ],
            selected: {_appFilter},
            onSelectionChanged: (v) => setState(() => _appFilter = v.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('excludeAlreadyTrackedApps')),
            value: _excludeAlreadyTracked,
            onChanged: (bool value) =>
                setState(() => _excludeAlreadyTracked = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('deleteBulkScanHistory')),
            subtitle: Text(
              tr('deleteBulkScanHistorySubtitle'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: _deleteScanHistoryBeforeScan,
            onChanged: (bool value) =>
                setState(() => _deleteScanHistoryBeforeScan = value),
          ),
          const SizedBox(height: 24),
          Text(
            tr('storesToSearch'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: _configurableBulkStores.map((String store) {
              final selected = _selectedStores.contains(store);
              return SwitchListTile(
                title: Text(store),
                value: selected,
                onChanged: (bool value) {
                  setState(() {
                    if (value) {
                      _selectedStores.add(store);
                    } else {
                      _selectedStores.remove(store);
                    }
                  });
                },
                secondary: _storeLogo(store, size: 36),
              );
            }).toList(),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('bulkScanCacheNote'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_selectedStores.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr('selectAtLeastOneStore'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _selectedStores.isEmpty ? null : _proceedToAppList,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(tr('next')),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  String _appFilterChipLabel() {
    return switch (_appFilter) {
      BulkAppFilter.userOnly => tr('bulkAddChipUserApps'),
      BulkAppFilter.systemOnly => tr('bulkAddChipSystemApps'),
      BulkAppFilter.both => tr('bulkAddChipAllApps'),
    };
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
  static const double _bulkAddResultBadgeColumnWidth = 22;
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
              child: Center(child: _buildAppIcon(app.packageName)),
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
    setState(() {
      _loadingApps = true;
      _step = BulkStep.selectApps;
      _installedApps = [];
      _selectedPackages.clear();
      _iconCache.clear();
    });
    try {
      List<InstalledAppInfo> apps = await BulkImportService.getInstalledApps(
        includeSystem: _appFilter != BulkAppFilter.userOnly,
        includeUser: _appFilter != BulkAppFilter.systemOnly,
      );
      if (_excludeAlreadyTracked) {
        final Set<String> tracked = _appsProvider.apps.keys.toSet();
        apps = apps
            .where((InstalledAppInfo a) => !tracked.contains(a.packageName))
            .toList();
      }
      if (!mounted) return;
      setState(() {
        _installedApps = apps;
        _loadingApps = false;
      });
      // Start loading icons in batches after the list is displayed
      _loadIconsBatched();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingApps = false);
      showError(e, context);
    }
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

  /// Loads all app icons in batches, calling setState once per batch.
  /// This avoids per-icon rebuilds that cause visible stutter.
  Future<void> _loadIconsBatched() async {
    const batchSize = 20;
    final packages = _installedApps.map((a) => a.packageName).toList();
    for (int i = 0; i < packages.length; i += batchSize) {
      if (!mounted) return;
      final batch = packages.sublist(
        i,
        (i + batchSize).clamp(0, packages.length),
      );
      await Future.wait(
        batch.map((pkg) async {
          if (_iconCache.containsKey(pkg)) return;
          final icon = await BulkImportService.getAppIcon(pkg);
          _iconCache[pkg] = icon ?? false;
        }),
      );
      if (mounted) setState(() {});
    }
  }

  Widget _buildAppIcon(String packageName, {double size = 40}) {
    // Icons are populated by _loadIconsBatched; no loading triggered here.
    final cached = _iconCache[packageName];
    if (cached is Uint8List) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          cached,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.android_rounded,
        size: size * 0.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildSelectAppsStep() {
    final filtered = _filteredApps;
    final alreadyTracked = _appsProvider.apps.keys.toSet();

    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Column(
          children: [
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
                        suffixIcon: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Align(
                            widthFactor: 1,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _appFilterChipLabel(),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
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
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final app = filtered[index];
                    final selected =
                        _selectedPackages.contains(app.packageName);
                    final tracked = alreadyTracked.contains(app.packageName);
                    return _bulkAddAppListRow(
                      leadingIcon: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: _buildAppIcon(app.packageName),
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

  Future<void> _startScanning() async {
    // Capture which apps are already tracked BEFORE we start, so results
    // display and add-loop can use this stable snapshot.
    _trackedAtScanTime = _appsProvider.apps.keys.toSet();

    if (_deleteScanHistoryBeforeScan) {
      await BulkScanCache.clear();
      if (mounted) {
        setState(() => _deleteScanHistoryBeforeScan = false);
      }
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

    final List<String> pkgList = _selectedPackages.toList();
    final Map<String, Map<String, String>> combined =
        <String, Map<String, String>>{};
    final Map<String, Set<String>> packageStoresDone = <String, Set<String>>{};

    void recordStoreCoverage(String storeLabel, Map<String, String?> results) {
      for (final String packageName in results.keys) {
        packageStoresDone
            .putIfAbsent(packageName, () => <String>{})
            .add(storeLabel);
      }
    }

    bool shouldAbortScan() => _scanCancelRequested;

    final List<String> storeOrder = _configurableBulkStores
        .where((String storeName) => _selectedStores.contains(storeName))
        .toList();

    for (final String storeName in storeOrder) {
      if (!mounted) return;
      if (_scanCancelRequested) break;

      switch (storeName) {
        case 'APKMirror':
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['APKMirror']);
              _apkMirrorTotal = pkgList.length;
              _apkMirrorDone = 0;
            });
          }
          final Map<String, String?> mirrorKnown = _persistedStoreColumn(
            persistedScanCache,
            pkgList,
            'APKMirror',
          );
          final Map<String, String?> mirrorResults =
              await BulkImportService.checkApkMirror(
                pkgList,
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
          recordStoreCoverage('APKMirror', mirrorResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'APKMirror',
            mirrorResults,
          );
          if (mounted) {
            setState(() => _apkMirrorDone = _apkMirrorTotal);
          }
          mirrorResults.forEach((String pkg, String? url) {
            if (url != null) {
              combined.putIfAbsent(pkg, () => <String, String>{})['APKMirror'] =
                  url;
            }
          });
        case 'APKPure':
          if (!mounted || _scanCancelRequested) break;
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['APKPure']);
              _apkPureTotal = pkgList.length;
              _apkPureDone = 0;
            });
          }
          final Map<String, String?> pureKnown = _persistedStoreColumn(
            persistedScanCache,
            pkgList,
            'APKPure',
          );
          final Map<String, String?> pureResults =
              await BulkImportService.checkApkPure(
                pkgList,
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
          recordStoreCoverage('APKPure', pureResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'APKPure',
            pureResults,
          );
          if (mounted) {
            setState(() => _apkPureDone = _apkPureTotal);
          }
          pureResults.forEach((String pkg, String? url) {
            if (url != null) {
              combined.putIfAbsent(pkg, () => <String, String>{})['APKPure'] =
                  url;
            }
          });
        case 'F-Droid':
          if (!mounted || _scanCancelRequested) break;
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['F-Droid']);
              _fdroidTotal = pkgList.length;
              _fdroidDone = 0;
            });
          }
          final Map<String, String?> fdroidKnown = _persistedStoreColumn(
            persistedScanCache,
            pkgList,
            'F-Droid',
          );
          final Map<String, String?> fdroidResults =
              await BulkImportService.checkFDroid(
                pkgList,
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
          recordStoreCoverage('F-Droid', fdroidResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'F-Droid',
            fdroidResults,
          );
          if (mounted) {
            setState(() => _fdroidDone = _fdroidTotal);
          }
          fdroidResults.forEach((String pkg, String? url) {
            if (url != null) {
              combined.putIfAbsent(pkg, () => <String, String>{})['F-Droid'] =
                  url;
            }
          });
        case 'GitHub':
          if (!mounted || _scanCancelRequested) break;
          if (mounted) {
            setState(() {
              _scanStatus = tr('scanningStore', args: ['GitHub']);
              _githubTotal = pkgList.length;
              _githubDone = 0;
            });
          }
          final Map<String, String?> githubKnown = _persistedStoreColumn(
            persistedScanCache,
            pkgList,
            'GitHub',
          );
          final Map<String, String?> githubResults =
              await BulkImportService.checkGitHub(
                pkgList,
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
          recordStoreCoverage('GitHub', githubResults);
          await BulkScanCache.mergeStoreAndSave(
            persistedScanCache,
            'GitHub',
            githubResults,
          );
          if (mounted) {
            setState(() => _githubDone = _githubTotal);
          }
          githubResults.forEach((String pkg, String? url) {
            if (url != null) {
              combined.putIfAbsent(pkg, () => <String, String>{})['GitHub'] =
                  url;
            }
          });
        default:
          break;
      }
    }

    final Map<String, InstalledAppInfo> appInfoMap = {
      for (final InstalledAppInfo a in _installedApps) a.packageName: a,
    };
    final List<BulkFoundApp> found = <BulkFoundApp>[];
    final List<InstalledAppInfo> notFound = <InstalledAppInfo>[];
    final List<InstalledAppInfo> cancelledApps = <InstalledAppInfo>[];

    for (final String pkg in pkgList) {
      final InstalledAppInfo? info = appInfoMap[pkg];
      if (info == null) continue;
      final Set<String>? doneForPackage = packageStoresDone[pkg];
      final bool coveredAllSelectedStores = _selectedStores.every(
        (String storeLabel) => doneForPackage?.contains(storeLabel) ?? false,
      );
      if (!coveredAllSelectedStores) {
        cancelledApps.add(info);
        continue;
      }
      final Map<String, String>? sources = combined[pkg];
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

    if (mounted) {
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
            onPressed: () => setState(() => _scanCancelRequested = true),
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
            _storeLogo(store, size: 32),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary banner
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _addingDone
                ? [
                    Expanded(
                      child: _buildSummaryMetricColumn(
                        Icons.check_circle_rounded,
                        '$_addedCount',
                        tr('added'),
                        _summaryFoundGreen,
                      ),
                    ),
                    if (_failedCount > 0)
                      Expanded(
                        child: _buildSummaryMetricColumn(
                          Icons.error_rounded,
                          '$_failedCount',
                          tr('failed'),
                          _summaryNotFoundRed,
                        ),
                      ),
                    Expanded(
                      child: _buildSummaryMetricColumn(
                        Icons.cancel_rounded,
                        '${_notFoundApps.length}',
                        tr('notFound'),
                        _summaryNotFoundRed,
                      ),
                    ),
                  ]
                : [
                    Expanded(
                      child: _buildSummaryMetricColumn(
                        Icons.check_circle_rounded,
                        '${_foundApps.length}',
                        tr('found'),
                        _summaryFoundGreen,
                        labelColor: _summaryFoundGreen,
                      ),
                    ),
                    Expanded(
                      child: _buildSummaryMetricColumn(
                        Icons.cancel_rounded,
                        '${_notFoundApps.length}',
                        tr('notFound'),
                        _summaryNotFoundRed,
                        labelColor: _summaryNotFoundRed,
                      ),
                    ),
                    if (cancelledCount > 0)
                      Expanded(
                        child: _buildSummaryMetricColumn(
                          Icons.hourglass_disabled_rounded,
                          '$cancelledCount',
                          tr('bulkScanCancelled'),
                          _summaryCancelledGrey,
                          labelColor: _summaryCancelledGrey,
                        ),
                      ),
                    if (alreadyFoundTracked.isNotEmpty)
                      Expanded(
                        child: _buildSummaryMetricColumn(
                          Icons.bookmark_rounded,
                          '${alreadyFoundTracked.length}',
                          tr('alreadyTracked'),
                          _summaryAlreadyTrackedBlue,
                        ),
                      ),
                  ],
          ),
        ),

        // App list
        Expanded(
          child:
              _foundApps.isEmpty &&
                  _notFoundApps.isEmpty &&
                  _cancelledApps.isEmpty
              ? Center(child: Text(tr('noAppsFound')))
              : ListView(
                  clipBehavior: Clip.none,
                  children: [
                    if (_addingDone) ...[
                      if (_addedApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('added')} (${_addedApps.length})',
                          Theme.of(context).colorScheme.primary,
                        ),
                        ..._addedApps.map(
                          (a) => _buildFoundAppTile(a, addedResult: true),
                        ),
                      ],
                      if (_failedApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('failed')} (${_failedApps.length})',
                          Theme.of(context).colorScheme.error,
                        ),
                        ..._failedApps.map(
                          (a) => _buildFoundAppTile(a, failedResult: true),
                        ),
                      ],
                      if (_notFoundApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('notFound')} (${_notFoundApps.length})',
                          _summaryNotFoundRed,
                        ),
                        ..._notFoundApps.map(_buildNotFoundTile),
                      ],
                    ] else ...[
                      if (newFound.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('found')} (${newFound.length})',
                          _summaryFoundGreen,
                        ),
                        ...newFound.map(
                          (a) => _buildFoundAppTile(a, selectable: true),
                        ),
                      ],
                      if (alreadyFoundTracked.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('alreadyTracked')} (${alreadyFoundTracked.length})',
                          Theme.of(context).colorScheme.tertiary,
                        ),
                        ...alreadyFoundTracked.map(
                          (a) => _buildFoundAppTile(a, tracked: true),
                        ),
                      ],
                      if (_notFoundApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('notFound')} (${_notFoundApps.length})',
                          _summaryNotFoundRed,
                        ),
                        ..._notFoundApps.map(_buildNotFoundTile),
                      ],
                      if (_cancelledApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('bulkScanCancelled')} (${_cancelledApps.length})',
                          _summaryCancelledGrey,
                        ),
                        ..._cancelledApps.map(_bulkAddCancelledResultRow),
                      ],
                    ],
                  ],
                ),
        ),

        // Action buttons
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_addingStatus.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _addingStatus,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (!_addingDone && newFound.isNotEmpty)
                  FilledButton.icon(
                    onPressed: _addingApps || selectedNewFoundCount == 0
                        ? null
                        : () {
                            final List<BulkFoundApp> selectedToAdd = newFound
                                .where(
                                  (BulkFoundApp a) => _selectedNewFoundPackages
                                      .contains(a.info.packageName),
                                )
                                .toList();
                            _addFoundApps(selectedToAdd);
                          },
                    icon: _addingApps
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_rounded),
                    label: Text(
                      _addingApps
                          ? tr('addingApps')
                          : tr(
                              'addFoundApps',
                              args: ['$selectedNewFoundCount'],
                            ),
                    ),
                  ),
                if (_addingDone || newFound.isEmpty)
                  FilledButton.icon(
                    onPressed: () {
                      if (widget.standalone) {
                        Navigator.pop(context);
                      } else {
                        widget.onComplete?.call();
                      }
                    },
                    icon: const Icon(Icons.check_rounded),
                    label: Text(tr('done')),
                  ),
              ],
            ),
          ),
        ),
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: accentColor, size: 28),
        const SizedBox(height: 4),
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
              child: Center(child: _buildAppIcon(app.packageName)),
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
                color: _summaryCancelledGrey,
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
    final Widget leadingIcon = _buildAppIcon(app.info.packageName);
    final Widget storeBadgesColumn = _buildBulkResultStoreBadgeColumn(
      app.sources,
    );

    if (selectable && !tracked) {
      final bool isSelected = _selectedNewFoundPackages.contains(
        app.info.packageName,
      );
      return _bulkAddResultAppRow(
        leadingIcon: leadingIcon,
        storeBadgesColumn: storeBadgesColumn,
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
      _addedCount = 0;
      _failedCount = 0;
      _addingStatus = '';
      _addedApps = [];
      _failedApps = [];
    });

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

    for (final app in apps) {
      if (!mounted) break;

      setState(() => _addingStatus = tr('addingApp', args: [app.info.name]));

      final store = app.bestStore;
      final url = app.bestUrl;
      final source = sourceFor(store);
      final settings = getDefaultValuesFromFormItems(
        source.combinedAppSpecificSettingFormItems,
      );
      // Force the known package name so store inference can't substitute a
      // wrong ID (e.g. APKMirror scraping the wrong package from page HTML).
      settings['appId'] = app.info.packageName;

      try {
        final newApp = await sourceProvider.getApp(
          source,
          url,
          settings,
          inferAppIdIfOptional: true,
        );
        await _appsProvider.saveApps([newApp], onlyIfExists: false);
        setState(() {
          _addedCount++;
          _addedApps = [..._addedApps, app];
        });
      } catch (e) {
        setState(() {
          _failedCount++;
          _failedApps = [..._failedApps, app];
          _addingStatus =
              '${tr('error')}: ${app.info.name} – ${e is ObtainiumError ? e.toString() : tr('unexpectedError')}';
        });
        // Small pause so the user can see the error briefly
        await Future.delayed(const Duration(milliseconds: 600));
      }
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
      case BulkStep.config:
        return tr('bulkAddApps');
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
      case BulkStep.config:
        return false;
      case BulkStep.selectApps:
        return true;
      case BulkStep.scanning:
        return false;
      case BulkStep.results:
        return true;
    }
  }

  void _goBack() {
    switch (_step) {
      case BulkStep.selectApps:
        setState(() => _step = BulkStep.config);
        break;
      case BulkStep.results:
        setState(() => _step = BulkStep.selectApps);
        break;
      default:
        break;
    }
  }

  // ─── Helpers ───────────────────────────────────────────────────────────

  Widget _m3LoadingIndicator({double size = 64}) => BulkM3LoadingIndicator(
    size: size,
    color: Theme.of(context).colorScheme.primary,
  );

  Widget _storeLogo(String store, {double size = 24}) {
    switch (store) {
      case 'APKMirror':
        return Image.asset(
          'assets/graphics/ic_apkmirror.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      case 'APKPure':
        return Image.asset(
          'assets/graphics/ic_apkpure.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      case 'F-Droid':
        return Image.asset(
          'assets/graphics/ic_fdroid.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      case 'GitHub':
        return Image.asset(
          'assets/graphics/ic_github.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      default:
        return Icon(Icons.store_rounded, size: size);
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  Widget _buildStepContent() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: KeyedSubtree(
        key: ValueKey(_step),
        child: switch (_step) {
          BulkStep.config => _buildConfigStep(),
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
        canPop: _step == BulkStep.config,
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
      canPop: _step == BulkStep.config,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack()) {
          _goBack();
        }
      },
      child: _buildStepContent(),
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
