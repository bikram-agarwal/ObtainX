import 'dart:math' as math;
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/apkpure.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:provider/provider.dart';

/// Which app types to include in the bulk scan list.
enum _AppFilter { userOnly, systemOnly, both }

/// A found-app entry: one package found on one or more stores.
class _FoundApp {
  final InstalledAppInfo info;
  // store name -> URL
  final Map<String, String> sources;

  _FoundApp({required this.info, required this.sources});

  /// Best URL to add: F-Droid > APKPure > APKMirror.
  String get bestUrl {
    for (final store in ['F-Droid', 'APKPure', 'APKMirror']) {
      if (sources.containsKey(store)) return sources[store]!;
    }
    return sources.values.first;
  }

  String get bestStore {
    for (final store in ['F-Droid', 'APKPure', 'APKMirror']) {
      if (sources.containsKey(store)) return store;
    }
    return sources.keys.first;
  }
}

enum _Step { config, selectApps, scanning, results }

class BulkAddAppsPage extends StatefulWidget {
  const BulkAddAppsPage({super.key});

  @override
  State<BulkAddAppsPage> createState() => _BulkAddAppsPageState();
}

class _BulkAddAppsPageState extends State<BulkAddAppsPage> {
  _Step _step = _Step.config;

  // --- Config step ---
  _AppFilter _appFilter = _AppFilter.userOnly;
  final Set<String> _selectedStores = {'APKMirror', 'APKPure', 'F-Droid'};

  // --- App selection step ---
  List<InstalledAppInfo> _installedApps = [];
  bool _loadingApps = false;
  final Set<String> _selectedPackages = {};
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  // Icon cache: packageName -> icon bytes (null while loading, Uint8List or false when done)
  final Map<String, Object?> _iconCache = {}; // Object? = Uint8List | false | null

  // --- Scanning step ---
  String _scanStatus = '';
  double _apkMirrorProgress = 0;
  double _apkPureProgress = 0;
  double _fdroidProgress = 0;

  // --- Results step ---
  List<_FoundApp> _foundApps = [];
  List<InstalledAppInfo> _notFoundApps = [];
  // Snapshot of tracked apps at scan time – prevents just-added apps showing as "already tracked"
  Set<String> _trackedAtScanTime = {};
  bool _addingApps = false;
  int _addedCount = 0;
  int _failedCount = 0;
  bool _addingDone = false;
  String _addingStatus = '';
  List<_FoundApp> _addedApps = [];
  List<_FoundApp> _failedApps = [];

  late AppsProvider _appsProvider;

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
          SegmentedButton<_AppFilter>(
            segments: [
              ButtonSegment(
                value: _AppFilter.userOnly,
                label: Text(tr('userAppsOnly')),
                icon: const Icon(Icons.person_rounded),
              ),
              ButtonSegment(
                value: _AppFilter.systemOnly,
                label: Text(tr('systemAppsOnly')),
                icon: const Icon(Icons.android_rounded),
              ),
              ButtonSegment(
                value: _AppFilter.both,
                label: Text(tr('allApps')),
                icon: const Icon(Icons.apps_rounded),
              ),
            ],
            selected: {_appFilter},
            onSelectionChanged: (v) => setState(() => _appFilter = v.first),
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            tr('storesToSearch'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: ['APKMirror', 'APKPure', 'F-Droid'].map((store) {
              final selected = _selectedStores.contains(store);
              return FilterChip(
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
                avatar: _storeLogo(store, size: 18),
              );
            }).toList(),
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
        ],
      ),
    );
  }

  Future<void> _proceedToAppList() async {
    setState(() {
      _loadingApps = true;
      _step = _Step.selectApps;
      _installedApps = [];
      _selectedPackages.clear();
      _iconCache.clear();
    });
    try {
      final apps = await BulkImportService.getInstalledApps(
        includeSystem: _appFilter != _AppFilter.userOnly,
        includeUser: _appFilter != _AppFilter.systemOnly,
      );
      if (!mounted) return;
      setState(() {
        _installedApps = apps;
        _selectedPackages.addAll(apps.map((a) => a.packageName));
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
      final batch = packages.sublist(i, (i + batchSize).clamp(0, packages.length));
      await Future.wait(batch.map((pkg) async {
        if (_iconCache.containsKey(pkg)) return;
        final icon = await BulkImportService.getAppIcon(pkg);
        _iconCache[pkg] = icon ?? false;
      }));
      if (mounted) setState(() {});
    }
  }

  Widget _buildAppIcon(String packageName, {double size = 40}) {
    // Icons are populated by _loadIconsBatched; no loading triggered here.
    final cached = _iconCache[packageName];
    if (cached is Uint8List) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(cached, width: size, height: size, fit: BoxFit.cover),
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: tr('search'),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Text(
                tr('selectedX', args: [
                  '${_selectedPackages.length}/${_installedApps.length}',
                ]),
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
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final app = filtered[index];
                final selected = _selectedPackages.contains(app.packageName);
                final tracked = alreadyTracked.contains(app.packageName);
                return CheckboxListTile(
                  value: selected,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selectedPackages.add(app.packageName);
                      } else {
                        _selectedPackages.remove(app.packageName);
                      }
                    });
                  },
                  secondary: _buildAppIcon(app.packageName),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (tracked)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tr('alreadyTracked'),
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSecondaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Text(
                    app.packageName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  dense: true,
                );
              },
            ),
          ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _selectedPackages.isEmpty ? null : _startScanning,
              icon: const Icon(Icons.search_rounded),
              label: Text(
                tr('scanApps', args: ['${_selectedPackages.length}']),
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

    setState(() {
      _step = _Step.scanning;
      _scanStatus = '';
      _apkMirrorProgress = 0;
      _apkPureProgress = 0;
      _fdroidProgress = 0;
      _foundApps = [];
      _notFoundApps = [];
    });

    final pkgList = _selectedPackages.toList();
    // packageName -> { storeName: url }
    final combined = <String, Map<String, String>>{};

    // Scan each selected store
    if (_selectedStores.contains('APKMirror')) {
      if (mounted) setState(() => _scanStatus = tr('scanningStore', args: ['APKMirror']));
      final r = await BulkImportService.checkApkMirror(
        pkgList,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _apkMirrorProgress = done / total);
          }
        },
      );
      if (mounted) setState(() => _apkMirrorProgress = 1.0);
      r.forEach((pkg, url) {
        if (url != null) {
          combined.putIfAbsent(pkg, () => {})['APKMirror'] = url;
        }
      });
    }

    if (_selectedStores.contains('APKPure')) {
      if (mounted) setState(() => _scanStatus = tr('scanningStore', args: ['APKPure']));
      final r = await BulkImportService.checkApkPure(
        pkgList,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _apkPureProgress = done / total);
          }
        },
      );
      if (mounted) setState(() => _apkPureProgress = 1.0);
      r.forEach((pkg, url) {
        if (url != null) {
          combined.putIfAbsent(pkg, () => {})['APKPure'] = url;
        }
      });
    }

    if (_selectedStores.contains('F-Droid')) {
      if (mounted) setState(() => _scanStatus = tr('scanningStore', args: ['F-Droid']));
      final r = await BulkImportService.checkFDroid(
        pkgList,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _fdroidProgress = done / total);
          }
        },
      );
      if (mounted) setState(() => _fdroidProgress = 1.0);
      r.forEach((pkg, url) {
        if (url != null) {
          combined.putIfAbsent(pkg, () => {})['F-Droid'] = url;
        }
      });
    }

    // Build results
    final appInfoMap = {for (final a in _installedApps) a.packageName: a};
    final found = <_FoundApp>[];
    final notFound = <InstalledAppInfo>[];

    for (final pkg in pkgList) {
      final sources = combined[pkg];
      final info = appInfoMap[pkg];
      if (info == null) continue;
      if (sources != null && sources.isNotEmpty) {
        found.add(_FoundApp(info: info, sources: sources));
      } else {
        notFound.add(info);
      }
    }

    if (mounted) {
      setState(() {
        _foundApps = found;
        _notFoundApps = notFound;
        _step = _Step.results;
      });
    }
  }

  Widget _buildScanningStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
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
              key: ValueKey(_scanStatus),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 40),
          if (_selectedStores.contains('APKMirror'))
            _buildStoreCard('APKMirror', _apkMirrorProgress),
          if (_selectedStores.contains('APKPure'))
            _buildStoreCard('APKPure', _apkPureProgress),
          if (_selectedStores.contains('F-Droid'))
            _buildStoreCard('F-Droid', _fdroidProgress),
        ],
      ),
    );
  }

  Widget _buildStoreCard(String store, double progress) {
    final done = progress >= 1.0;
    final started = progress > 0;
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: done ? cs.primaryContainer : cs.surfaceContainerHighest,
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
                          color: done ? cs.onPrimaryContainer : cs.onSurface,
                        ),
                      ),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: done
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: cs.primary,
                                size: 20,
                                key: const ValueKey('done'),
                              )
                            : Text(
                                started
                                    ? '${(progress * 100).round()}%'
                                    : tr('pending'),
                                key: ValueKey(started ? 'progress' : 'pending'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                      ),
                    ],
                  ),
                  if (!done) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: started ? progress : null,
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
    // Use the snapshot taken at scan time, so just-added apps don't appear
    // as "already tracked" after _addFoundApps runs.
    final newFound =
        _foundApps.where((a) => !_trackedAtScanTime.contains(a.info.packageName)).toList();
    final alreadyFoundTracked =
        _foundApps.where((a) => _trackedAtScanTime.contains(a.info.packageName)).toList();

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
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: _addingDone
                ? [
                    _buildStat(
                      Icons.check_circle_rounded,
                      '$_addedCount',
                      tr('added'),
                      Theme.of(context).colorScheme.primary,
                    ),
                    if (_failedCount > 0)
                      _buildStat(
                        Icons.error_rounded,
                        '$_failedCount',
                        tr('failed'),
                        Theme.of(context).colorScheme.error,
                      ),
                    _buildStat(
                      Icons.cancel_rounded,
                      '${_notFoundApps.length}',
                      tr('notFound'),
                      Theme.of(context).colorScheme.outline,
                    ),
                  ]
                : [
                    _buildStat(
                      Icons.check_circle_rounded,
                      '${_foundApps.length}',
                      tr('found'),
                      Theme.of(context).colorScheme.primary,
                    ),
                    _buildStat(
                      Icons.cancel_rounded,
                      '${_notFoundApps.length}',
                      tr('notFound'),
                      Theme.of(context).colorScheme.error,
                    ),
                    if (alreadyFoundTracked.isNotEmpty)
                      _buildStat(
                        Icons.bookmark_rounded,
                        '${alreadyFoundTracked.length}',
                        tr('alreadyTracked'),
                        Theme.of(context).colorScheme.tertiary,
                      ),
                  ],
          ),
        ),

        // App list
        Expanded(
          child: _foundApps.isEmpty && _notFoundApps.isEmpty
              ? Center(child: Text(tr('noAppsFound')))
              : ListView(
                  children: [
                    if (_addingDone) ...[
                      // ── Post-add view ──────────────────────────────────
                      if (_addedApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('added')} (${_addedApps.length})',
                          Theme.of(context).colorScheme.primary,
                        ),
                        ..._addedApps.map((a) => _buildFoundAppTile(a)),
                      ],
                      if (_failedApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('failed')} (${_failedApps.length})',
                          Theme.of(context).colorScheme.error,
                        ),
                        ..._failedApps.map((a) => _buildFoundAppTile(a)),
                      ],
                      if (_notFoundApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('notFound')} (${_notFoundApps.length})',
                          Theme.of(context).colorScheme.outline,
                        ),
                        ..._notFoundApps.map((a) => _buildNotFoundTile(a)),
                      ],
                    ] else ...[
                      // ── Pre-add view ───────────────────────────────────
                      if (newFound.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('found')} (${newFound.length})',
                          Theme.of(context).colorScheme.primary,
                        ),
                        ...newFound.map((a) => _buildFoundAppTile(a)),
                      ],
                      if (alreadyFoundTracked.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('alreadyTracked')} (${alreadyFoundTracked.length})',
                          Theme.of(context).colorScheme.tertiary,
                        ),
                        ...alreadyFoundTracked.map((a) => _buildFoundAppTile(a, tracked: true)),
                      ],
                      if (_notFoundApps.isNotEmpty) ...[
                        _buildSectionHeader(
                          '${tr('notFound')} (${_notFoundApps.length})',
                          Theme.of(context).colorScheme.error,
                        ),
                        ..._notFoundApps.map((a) => _buildNotFoundTile(a)),
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
                    onPressed: _addingApps ? null : () => _addFoundApps(newFound),
                    icon: _addingApps
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded),
                    label: Text(
                      _addingApps
                          ? tr('addingApps')
                          : tr('addFoundApps', args: ['${newFound.length}']),
                    ),
                  ),
                if (_addingDone || newFound.isEmpty)
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context),
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

  Widget _buildStat(IconData icon, String value, String label, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildNotFoundTile(InstalledAppInfo a) {
    return ListTile(
      leading: _buildAppIcon(a.packageName),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        a.packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Icon(Icons.cancel_rounded, color: Theme.of(context).colorScheme.error),
      dense: true,
    );
  }

  Widget _buildFoundAppTile(_FoundApp app, {bool tracked = false}) {
    return ListTile(
      leading: _buildAppIcon(app.info.packageName),
      title: Text(
        app.info.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            app.info.packageName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 4,
            children: app.sources.keys
                .map(
                  (store) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: tracked
                          ? Theme.of(context).colorScheme.tertiaryContainer
                          : Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      store,
                      style: TextStyle(
                        fontSize: 10,
                        color: tracked
                            ? Theme.of(context).colorScheme.onTertiaryContainer
                            : Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
      trailing: tracked
          ? Icon(Icons.bookmark_rounded,
              color: Theme.of(context).colorScheme.tertiary)
          : Icon(Icons.check_circle_rounded,
              color: Theme.of(context).colorScheme.primary),
      dense: true,
      isThreeLine: true,
    );
  }

  // ─── Add Apps ──────────────────────────────────────────────────────────

  Future<void> _addFoundApps(List<_FoundApp> apps) async {
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

    AppSource sourceFor(String storeName) {
      switch (storeName) {
        case 'APKMirror':
          return apkMirrorSource;
        case 'APKPure':
          return apkPureSource;
        case 'F-Droid':
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

  // ─── Helpers ───────────────────────────────────────────────────────────

  /// Returns the store's actual logo.
  /// M3 Expressive loading indicator – 5 dots with staggered wave scale.
  Widget _m3LoadingIndicator({double size = 80}) {
    return _M3LoadingIndicator(
      size: size,
      color: Theme.of(context).colorScheme.primary,
    );
  }

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
      default:
        return Icon(Icons.store_rounded, size: size);
    }
  }

  String _stepTitle() {
    switch (_step) {
      case _Step.config:
        return tr('bulkAddApps');
      case _Step.selectApps:
        return tr('selectAppsToImport');
      case _Step.scanning:
        return tr('scanning');
      case _Step.results:
        return tr('importResults');
    }
  }

  bool _canGoBack() {
    switch (_step) {
      case _Step.config:
        return false;
      case _Step.selectApps:
        return true;
      case _Step.scanning:
        return false;
      case _Step.results:
        return true;
    }
  }

  void _goBack() {
    switch (_step) {
      case _Step.selectApps:
        setState(() => _step = _Step.config);
      case _Step.results:
        setState(() => _step = _Step.selectApps);
      default:
        break;
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Only allow system back on config; all other steps handle it manually
      canPop: _step == _Step.config,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack()) {
          _goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_stepTitle()),
          // Hide back button during scanning to prevent aborting mid-scan
          automaticallyImplyLeading: _step != _Step.scanning,
          leading: _canGoBack()
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: _goBack,
                )
              : null,
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(
            key: ValueKey(_step),
            child: switch (_step) {
              _Step.config => _buildConfigStep(),
              _Step.selectApps => _buildSelectAppsStep(),
              _Step.scanning => _buildScanningStep(),
              _Step.results => _buildResultsStep(),
            },
          ),
        ),
      ),
    );
  }
}

/// M3 Expressive loading indicator: 5 dots with a staggered sine-wave scale.
class _M3LoadingIndicator extends StatefulWidget {
  final double size;
  final Color color;

  const _M3LoadingIndicator({required this.size, required this.color});

  @override
  State<_M3LoadingIndicator> createState() => _M3LoadingIndicatorState();
}

class _M3LoadingIndicatorState extends State<_M3LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _dotCount = 5;
  // Fraction of the 1500 ms cycle that each dot is offset from the next.
  static const _staggerFraction = 0.15;

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
    final dotSize = widget.size / _dotCount * 0.7;

    return SizedBox(
      width: widget.size,
      height: widget.size * 0.45,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(_dotCount, (i) {
              final phase = (i * _staggerFraction);
              final t = (_controller.value - phase) % 1.0;
              // Sinusoidal scale: oscillates between 0.35 and 1.0
              final scale = 0.35 + 0.65 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
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
