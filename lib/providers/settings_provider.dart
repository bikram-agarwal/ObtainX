// Exposes functions used to save/load app settings

import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

String obtainiumTempId = 'bikram-agarwal_ObtainX_${GitHub().hosts[0]}';
String obtainiumId = 'dev.bikram.obtainx';
String obtainiumUrl = 'https://github.com/bikram-agarwal/ObtainX';
Color obtainiumThemeColor = const Color(0xFF6438B5);

enum ThemeSettings { system, light, dark }

enum SortColumnSettings {
  added,
  nameAuthor,
  authorName,
  releaseDate,
  lastUpdateCheck,
}

enum SortOrderSettings { ascending, descending }

enum AppsListGroupBy { none, category, source, appType }

enum SwipeAction {
  update,
  pin,
  appOptions,
  delete,
  open,
  appInfo,
  edit,
  none,
}

/// Order for settings dropdowns: alphabetical by localized action label,
/// with [SwipeAction.none] ("None") always last.
List<SwipeAction> swipeActionsSortedByLocalizedLabel() {
  final List<SwipeAction> actions = List<SwipeAction>.from(SwipeAction.values);
  actions.sort((SwipeAction first, SwipeAction second) {
    if (first == SwipeAction.none) return 1;
    if (second == SwipeAction.none) return -1;
    final String labelFirst = tr('swipeAction_${first.name}').toLowerCase();
    final String labelSecond = tr('swipeAction_${second.name}').toLowerCase();
    return labelFirst.compareTo(labelSecond);
  });
  return actions;
}

class SettingsProvider with ChangeNotifier {
  SharedPreferences? prefs;
  String? defaultAppDir;
  bool justStarted = true;

  /// Mirrors last [setCategories] write; [getString] can lag [setString] briefly.
  Map<String, int>? _categoriesMemory;

  String sourceUrl = 'https://github.com/bikram-agarwal/ObtainX';

  // Not done in constructor as we want to be able to await it
  Future<void> initializeSettings() async {
    prefs = await SharedPreferences.getInstance();
    _categoriesMemory = null;
    defaultAppDir = (await getAppStorageDir()).path;
    _migrateShizukuSetting();
    _migrateSwipeActionPrefs();
    _syncSwipeActionNameStringsIfMissing();
    _migrateThemeAccentPrefs();
    notifyListeners();
  }

  void _migrateThemeAccentPrefs() {
    if (prefs == null) return;
    if (prefs!.containsKey('appAccentColorSource')) return;
    final bool oldMaterialYou = prefs!.getBool('useMaterialYou') ?? false;
    if (oldMaterialYou) {
      prefs!.setString(
        'appAccentColorSource',
        AppAccentColorSource.materialYou.name,
      );
    } else {
      prefs!.setString(
        'appAccentColorSource',
        AppAccentColorSource.custom.name,
      );
      final int? colorCode = prefs!.getInt('themeColor');
      final Color fromLegacy =
          (colorCode != null) ? Color(colorCode) : obtainiumThemeColor;
      final String hex = colorToCanonicalHex(fromLegacy);
      prefs!.setString('activeCustomSeedHex', hex);
      prefs!.setString('savedCustomSeedHexList', jsonEncode([hex]));
    }
    prefs!.setString(
      'appThemePaletteStyle',
      AppThemePaletteStyle.tonalSpot.name,
    );
  }

  static const String _rightSwipeNameKey = 'rightSwipeActionName';
  static const String _leftSwipeNameKey = 'leftSwipeActionName';

  /// v1: [SwipeAction.none] was index 6 on the 7-value enum. v2 remaps that to index 7.
  /// v3 clears stored swipe name prefs once so they are rebuilt from ints (fixes stale
  /// [rightSwipeActionName] / [leftSwipeActionName] from older ObtainX builds).
  void _migrateSwipeActionPrefs() {
    if (prefs == null) return;
    int schemaVersion = prefs!.getInt('swipeActionEnumVersion') ?? 0;

    if (schemaVersion < 2) {
      for (final String prefKey in ['rightSwipeAction', 'leftSwipeAction']) {
        if (prefs!.containsKey(prefKey) && prefs!.getInt(prefKey) == 6) {
          prefs!.setInt(prefKey, SwipeAction.none.index);
        }
      }
      prefs!.setInt('swipeActionEnumVersion', 2);
      schemaVersion = 2;
    }

    if (schemaVersion < 3) {
      prefs!.remove(_rightSwipeNameKey);
      prefs!.remove(_leftSwipeNameKey);
      prefs!.setInt('swipeActionEnumVersion', 3);
    }
  }

  /// Prefer stable enum [SwipeAction.name] in prefs so reordering does not break gestures.
  void _syncSwipeActionNameStringsIfMissing() {
    if (prefs == null) return;
    void syncOne(String intKey, String nameKey, int defaultIndex) {
      if (prefs!.containsKey(nameKey)) return;
      final int raw = prefs!.getInt(intKey) ?? defaultIndex;
      final SwipeAction action =
          SwipeAction.values[raw.clamp(0, SwipeAction.values.length - 1)];
      prefs!.setString(nameKey, action.name);
    }

    syncOne('rightSwipeAction', _rightSwipeNameKey, SwipeAction.update.index);
    syncOne('leftSwipeAction', _leftSwipeNameKey, SwipeAction.pin.index);
  }

  SwipeAction _swipeActionFromPrefs(
    String intKey,
    String nameKey,
    int defaultIndex,
  ) {
    final String? storedName = prefs?.getString(nameKey);
    if (storedName != null && storedName.isNotEmpty) {
      for (final SwipeAction candidate in SwipeAction.values) {
        if (candidate.name == storedName) return candidate;
      }
    }
    final int index = prefs?.getInt(intKey) ?? defaultIndex;
    return SwipeAction.values[index.clamp(0, SwipeAction.values.length - 1)];
  }

  void _migrateShizukuSetting() {
    if (prefs?.containsKey('installerMode') == true) return;
    if (prefs?.getBool('useShizuku') == true) {
      prefs?.setString('installerMode', 'shizuku');
    }
    prefs?.remove('useShizuku');
  }

  bool get useSystemFont {
    return prefs?.getBool('useSystemFont') ?? false;
  }

  set useSystemFont(bool useSystemFont) {
    prefs?.setBool('useSystemFont', useSystemFont);
    notifyListeners();
  }

  // 'stock' = default Android installer, 'shizuku' = Shizuku, 'Third-Party' = third-party installer (user-chosen app; stored value unchanged for prefs compatibility)
  String get installerMode {
    return prefs?.getString('installerMode') ?? 'stock';
  }

  set installerMode(String mode) {
    prefs?.setString('installerMode', mode);
    notifyListeners();
  }

  bool get useShizuku {
    return installerMode == 'shizuku';
  }

  set useShizuku(bool useShizuku) {
    installerMode = useShizuku ? 'shizuku' : 'stock';
  }

  String? get legacyInstallerPackage {
    final value = prefs?.getString('legacyInstallerPackage');
    return (value != null && value.isNotEmpty) ? value : null;
  }

  set legacyInstallerPackage(String? pkg) {
    if (pkg == null || pkg.isEmpty) {
      prefs?.remove('legacyInstallerPackage');
    } else {
      prefs?.setString('legacyInstallerPackage', pkg);
    }
    notifyListeners();
  }

  String? get legacyInstallerActivity {
    final value = prefs?.getString('legacyInstallerActivity');
    return (value != null && value.isNotEmpty) ? value : null;
  }

  set legacyInstallerActivity(String? activity) {
    if (activity == null || activity.isEmpty) {
      prefs?.remove('legacyInstallerActivity');
    } else {
      prefs?.setString('legacyInstallerActivity', activity);
    }
    notifyListeners();
  }

  ThemeSettings get theme {
    return ThemeSettings.values[prefs?.getInt('theme') ??
        ThemeSettings.system.index];
  }

  set theme(ThemeSettings t) {
    prefs?.setInt('theme', t.index);
    notifyListeners();
  }

  Color get themeColor {
    final Color? fromHex =
        colorFromNormalizedHex(normalizeCustomSeedHexOrNull(activeCustomSeedHex));
    if (fromHex != null) return fromHex;
    final int? colorCode = prefs?.getInt('themeColor');
    return (colorCode != null) ? Color(colorCode) : obtainiumThemeColor;
  }

  set themeColor(Color themeColor) {
    prefs?.setInt('themeColor', themeColor.toARGB32());
    final String hex = colorToCanonicalHex(themeColor);
    prefs?.setString('activeCustomSeedHex', hex);
    prefs?.setString('appAccentColorSource', AppAccentColorSource.custom.name);
    prefs?.setBool('useMaterialYou', false);
    _ensureHexInSavedList(hex);
    notifyListeners();
  }

  AppAccentColorSource get appAccentColorSource {
    final AppAccentColorSource? parsed = AppAccentColorSourceX.tryParse(
      prefs?.getString('appAccentColorSource'),
    );
    if (parsed != null) return parsed;
    return (prefs?.getBool('useMaterialYou') ?? false)
        ? AppAccentColorSource.materialYou
        : AppAccentColorSource.custom;
  }

  set appAccentColorSource(AppAccentColorSource source) {
    prefs?.setString('appAccentColorSource', source.name);
    prefs?.setBool(
      'useMaterialYou',
      source == AppAccentColorSource.materialYou,
    );
    notifyListeners();
  }

  AppThemePaletteStyle get appThemePaletteStyle {
    return AppThemePaletteStyleX.tryParse(prefs?.getString('appThemePaletteStyle')) ??
        AppThemePaletteStyle.tonalSpot;
  }

  set appThemePaletteStyle(AppThemePaletteStyle style) {
    prefs?.setString('appThemePaletteStyle', style.name);
    notifyListeners();
  }

  String get activeCustomSeedHex {
    final String? stored = prefs?.getString('activeCustomSeedHex');
    final String? normalized =
        stored != null ? normalizeCustomSeedHexOrNull(stored) : null;
    if (normalized != null) return normalized;
    final int? colorCode = prefs?.getInt('themeColor');
    return colorToCanonicalHex(
      (colorCode != null) ? Color(colorCode) : obtainiumThemeColor,
    );
  }

  set activeCustomSeedHex(String value) {
    final String? normalized = normalizeCustomSeedHexOrNull(value);
    if (normalized == null) return;
    prefs?.setString('activeCustomSeedHex', normalized);
    final Color? c = colorFromNormalizedHex(normalized);
    if (c != null) prefs?.setInt('themeColor', c.toARGB32());
    notifyListeners();
  }

  List<String> get savedCustomSeedHexes {
    final String? raw = prefs?.getString('savedCustomSeedHexList');
    if (raw == null || raw.isEmpty) {
      return [activeCustomSeedHex];
    }
    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      final List<String> out = decoded
          .map((dynamic e) => normalizeCustomSeedHexOrNull(e.toString()))
          .whereType<String>()
          .toList();
      if (out.isEmpty) return [activeCustomSeedHex];
      return out;
    } catch (_) {
      return [activeCustomSeedHex];
    }
  }

  void _persistSavedCustomSeedHexes(List<String> list) {
    prefs?.setString('savedCustomSeedHexList', jsonEncode(list));
  }

  void _ensureHexInSavedList(String normalizedHex) {
    final List<String> list = savedCustomSeedHexes.toList();
    if (!list.contains(normalizedHex)) {
      list.add(normalizedHex);
      _persistSavedCustomSeedHexes(list);
    }
  }

  void addCustomSeedHex(String raw) {
    final String? normalized = normalizeCustomSeedHexOrNull(raw);
    if (normalized == null) return;
    final List<String> list = savedCustomSeedHexes.toList();
    if (!list.contains(normalized)) list.add(normalized);
    _persistSavedCustomSeedHexes(list);
    activeCustomSeedHex = normalized;
    appAccentColorSource = AppAccentColorSource.custom;
  }

  void removeCustomSeedHex(String raw) {
    final String? normalized = normalizeCustomSeedHexOrNull(raw);
    if (normalized == null) return;
    final List<String> list =
        savedCustomSeedHexes.where((String h) => h != normalized).toList();
    if (list.isEmpty) {
      list.add(colorToCanonicalHex(obtainiumThemeColor));
    }
    _persistSavedCustomSeedHexes(list);
    if (activeCustomSeedHex == normalized) {
      prefs?.setString('activeCustomSeedHex', list.first);
      final Color? c = colorFromNormalizedHex(list.first);
      if (c != null) prefs?.setInt('themeColor', c.toARGB32());
    }
    notifyListeners();
  }

  void selectSavedCustomSeedHex(String raw) {
    final String? normalized = normalizeCustomSeedHexOrNull(raw);
    if (normalized == null) return;
    activeCustomSeedHex = normalized;
    appAccentColorSource = AppAccentColorSource.custom;
    notifyListeners();
  }

  bool get progressiveBlurEnabled {
    return prefs?.getBool('progressiveBlurEnabled') ?? true;
  }

  set progressiveBlurEnabled(bool value) {
    prefs?.setBool('progressiveBlurEnabled', value);
    notifyListeners();
  }

  bool get useGradientBackground {
    return prefs?.getBool('useGradientBackground') ?? true;
  }

  set useGradientBackground(bool value) {
    prefs?.setBool('useGradientBackground', value);
    notifyListeners();
  }

  bool get useMaterialYou {
    return appAccentColorSource == AppAccentColorSource.materialYou;
  }

  set useMaterialYou(bool useMaterialYou) {
    prefs?.setBool('useMaterialYou', useMaterialYou);
    if (useMaterialYou) {
      prefs?.setString(
        'appAccentColorSource',
        AppAccentColorSource.materialYou.name,
      );
    } else {
      prefs?.setString(
        'appAccentColorSource',
        AppAccentColorSource.custom.name,
      );
    }
    notifyListeners();
  }

  bool get useBlackTheme {
    return prefs?.getBool('useBlackTheme') ?? false;
  }

  set useBlackTheme(bool useBlackTheme) {
    prefs?.setBool('useBlackTheme', useBlackTheme);
    notifyListeners();
  }

  bool get matchAppPageToIconColors {
    return prefs?.getBool('matchAppPageToIconColors') ?? true;
  }

  set matchAppPageToIconColors(bool matchAppPageToIconColors) {
    prefs?.setBool('matchAppPageToIconColors', matchAppPageToIconColors);
    notifyListeners();
  }

  bool get showAppTypeBadge {
    return prefs?.getBool('showAppTypeBadge') ?? true;
  }

  set showAppTypeBadge(bool value) {
    prefs?.setBool('showAppTypeBadge', value);
    notifyListeners();
  }

  bool get showTrackedStoreBadge {
    return prefs?.getBool('showTrackedStoreBadge') ?? true;
  }

  set showTrackedStoreBadge(bool value) {
    prefs?.setBool('showTrackedStoreBadge', value);
    notifyListeners();
  }

  int get updateInterval {
    return prefs?.getInt('updateInterval') ?? 360;
  }

  set updateInterval(int min) {
    prefs?.setInt('updateInterval', min);
    notifyListeners();
  }

  double get updateIntervalSliderVal {
    return prefs?.getDouble('updateIntervalSliderVal') ?? 6.0;
  }

  set updateIntervalSliderVal(double val) {
    prefs?.setDouble('updateIntervalSliderVal', val);
    notifyListeners();
  }

  bool get checkOnStart {
    return prefs?.getBool('checkOnStart') ?? false;
  }

  set checkOnStart(bool checkOnStart) {
    prefs?.setBool('checkOnStart', checkOnStart);
    notifyListeners();
  }

  SortColumnSettings get sortColumn {
    final stored = prefs?.getInt('sortColumn');
    if (stored == null) return SortColumnSettings.nameAuthor;
    if (stored < 0 || stored >= SortColumnSettings.values.length) {
      return SortColumnSettings.nameAuthor;
    }
    return SortColumnSettings.values[stored];
  }

  set sortColumn(SortColumnSettings sortColumnSetting) {
    prefs?.setInt('sortColumn', sortColumnSetting.index);
    notifyListeners();
  }

  SortOrderSettings get sortOrder {
    return SortOrderSettings.values[prefs?.getInt('sortOrder') ??
        SortOrderSettings.ascending.index];
  }

  set sortOrder(SortOrderSettings s) {
    prefs?.setInt('sortOrder', s.index);
    notifyListeners();
  }

  bool checkAndFlipFirstRun() {
    bool result = prefs?.getBool('firstRun') ?? true;
    if (result) {
      prefs?.setBool('firstRun', false);
    }
    return result;
  }

  bool get welcomeShown {
    return prefs?.getBool('welcomeShown') ?? false;
  }

  set welcomeShown(bool welcomeShown) {
    prefs?.setBool('welcomeShown', welcomeShown);
    notifyListeners();
  }

  bool get googleVerificationWarningShown {
    return prefs?.getBool('googleVerificationWarningShown') ?? false;
  }

  set googleVerificationWarningShown(bool googleVerificationWarningShown) {
    prefs?.setBool(
      'googleVerificationWarningShown',
      googleVerificationWarningShown,
    );
    notifyListeners();
  }

  bool checkJustStarted() {
    if (justStarted) {
      justStarted = false;
      return true;
    }
    return false;
  }

  Future<bool> getInstallPermission({bool enforce = false}) async {
    while (!(await Permission.requestInstallPackages.isGranted)) {
      // Explicit request as InstallPlugin request sometimes bugged
      Fluttertoast.showToast(
        msg: tr('pleaseAllowInstallPerm'),
        toastLength: Toast.LENGTH_LONG,
      );
      if ((await Permission.requestInstallPackages.request()) ==
          PermissionStatus.granted) {
        return true;
      }
      if (!enforce) {
        return false;
      }
    }
    return true;
  }

  bool get showAppWebpage {
    return prefs?.getBool('showAppWebpage') ?? false;
  }

  set showAppWebpage(bool show) {
    prefs?.setBool('showAppWebpage', show);
    notifyListeners();
  }

  bool get pinUpdates {
    return prefs?.getBool('pinUpdates') ?? true;
  }

  set pinUpdates(bool show) {
    prefs?.setBool('pinUpdates', show);
    notifyListeners();
  }

  bool get buryNonInstalled {
    return prefs?.getBool('buryNonInstalled') ?? false;
  }

  set buryNonInstalled(bool show) {
    prefs?.setBool('buryNonInstalled', show);
    notifyListeners();
  }

  bool get groupNonInstalledSeparately {
    return prefs?.getBool('groupNonInstalledSeparately') ?? false;
  }

  set groupNonInstalledSeparately(bool show) {
    prefs?.setBool('groupNonInstalledSeparately', show);
    notifyListeners();
  }

  bool get groupUpdatesSeparately {
    return prefs?.getBool('groupUpdatesSeparately') ?? false;
  }

  set groupUpdatesSeparately(bool value) {
    prefs?.setBool('groupUpdatesSeparately', value);
    notifyListeners();
  }

  AppsListGroupBy get appsListGroupBy {
    if (prefs?.containsKey('appsListGroupBy') == true) {
      final stored = prefs!.getInt('appsListGroupBy');
      if (stored != null &&
          stored >= 0 &&
          stored < AppsListGroupBy.values.length) {
        return AppsListGroupBy.values[stored];
      }
    }
    if (prefs?.getBool('groupByCategory') == true) {
      return AppsListGroupBy.category;
    }
    return AppsListGroupBy.none;
  }

  set appsListGroupBy(AppsListGroupBy mode) {
    prefs?.setInt('appsListGroupBy', mode.index);
    prefs?.setBool('groupByCategory', mode == AppsListGroupBy.category);
    notifyListeners();
  }

  bool get groupByCategory => appsListGroupBy == AppsListGroupBy.category;

  set groupByCategory(bool show) {
    appsListGroupBy =
        show ? AppsListGroupBy.category : AppsListGroupBy.none;
  }

  bool get hideTrackOnlyWarning {
    return prefs?.getBool('hideTrackOnlyWarning') ?? false;
  }

  set hideTrackOnlyWarning(bool show) {
    prefs?.setBool('hideTrackOnlyWarning', show);
    notifyListeners();
  }

  bool get hideAPKOriginWarning {
    return prefs?.getBool('hideAPKOriginWarning') ?? false;
  }

  set hideAPKOriginWarning(bool show) {
    prefs?.setBool('hideAPKOriginWarning', show);
    notifyListeners();
  }

  String? getSettingString(String settingId) {
    String? str = prefs?.getString(settingId);
    return str?.isNotEmpty == true ? str : null;
  }

  void setSettingString(String settingId, String value) {
    prefs?.setString(settingId, value);
    notifyListeners();
  }

  bool? getSettingBool(String settingId) {
    return prefs?.getBool(settingId) ?? false;
  }

  void setSettingBool(String settingId, bool value) {
    prefs?.setBool(settingId, value);
    notifyListeners();
  }

  Map<String, int> get categories {
    if (_categoriesMemory != null) {
      return Map<String, int>.from(_categoriesMemory!);
    }
    return Map<String, int>.from(
      jsonDecode(prefs?.getString('categories') ?? '{}'),
    );
  }

  void setCategories(Map<String, int> cats, {AppsProvider? appsProvider}) {
    if (appsProvider != null) {
      // Detect a rename: one key removed from old map, one key added to new map.
      // Each UI action (rename, delete) fires a separate call, so at most one
      // rename is in flight per call.
      final Map<String, int> oldCats = categories;
      final Set<String> removed =
          oldCats.keys.toSet().difference(cats.keys.toSet());
      final Set<String> added =
          cats.keys.toSet().difference(oldCats.keys.toSet());
      final String? renamedFrom =
          (removed.length == 1 && added.length == 1) ? removed.first : null;
      final String? renamedTo =
          (removed.length == 1 && added.length == 1) ? added.first : null;

      List<App> changedApps = appsProvider
          .getAppValues()
          .map((a) {
            bool changed = false;
            if (renamedFrom != null && renamedTo != null) {
              final idx = a.app.categories.indexOf(renamedFrom);
              if (idx >= 0) {
                a.app.categories[idx] = renamedTo;
                changed = true;
              }
            }
            final n1 = a.app.categories.length;
            a.app.categories.removeWhere((c) => !cats.keys.contains(c));
            if (a.app.categories.length < n1) changed = true;
            return changed ? a.app : null;
          })
          .where((element) => element != null)
          .map((e) => e as App)
          .toList();
      if (changedApps.isNotEmpty) {
        appsProvider.saveApps(changedApps);
      }
    }
    _categoriesMemory = Map<String, int>.from(cats);
    prefs?.setString('categories', jsonEncode(cats));
    notifyListeners();
  }

  List<AppFolder> get appFolders {
    final raw = prefs?.getString('appFolders') ?? '[]';
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => AppFolder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  set appFolders(List<AppFolder> folders) {
    prefs?.setString('appFolders', jsonEncode(folders.map((f) => f.toJson()).toList()));
    notifyListeners();
  }

  bool get showFolderedAppsOnMainPage =>
      prefs?.getBool('showFolderedAppsOnMainPage') ?? false;

  set showFolderedAppsOnMainPage(bool value) {
    prefs?.setBool('showFolderedAppsOnMainPage', value);
    notifyListeners();
  }

  // ── Per-folder view settings ──────────────────────────────────────────────
  // Stored as JSON maps in SharedPreferences under 'folderView_<id>'.
  // Each getter falls back to the global setting when no override is stored.

  Map<String, dynamic>? _getFolderViewRaw(String folderId) {
    final raw = prefs?.getString('folderView_$folderId');
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  void _setFolderViewField(String folderId, String key, dynamic value) {
    final data = _getFolderViewRaw(folderId) ?? {};
    data[key] = value;
    prefs?.setString('folderView_$folderId', jsonEncode(data));
    notifyListeners();
  }

  void clearFolderViewSettings(String folderId) {
    prefs?.remove('folderView_$folderId');
    notifyListeners();
  }

  SortColumnSettings folderSortColumn(String id) {
    final idx = _getFolderViewRaw(id)?['sortColumn'] as int?;
    if (idx == null) return sortColumn;
    return SortColumnSettings.values[idx.clamp(0, SortColumnSettings.values.length - 1)];
  }

  void setFolderSortColumn(String id, SortColumnSettings v) =>
      _setFolderViewField(id, 'sortColumn', v.index);

  SortOrderSettings folderSortOrder(String id) {
    final idx = _getFolderViewRaw(id)?['sortOrder'] as int?;
    if (idx == null) return sortOrder;
    return SortOrderSettings.values[idx.clamp(0, SortOrderSettings.values.length - 1)];
  }

  void setFolderSortOrder(String id, SortOrderSettings v) =>
      _setFolderViewField(id, 'sortOrder', v.index);

  AppsListGroupBy folderGroupBy(String id) {
    final idx = _getFolderViewRaw(id)?['groupBy'] as int?;
    if (idx == null) return appsListGroupBy;
    return AppsListGroupBy.values[idx.clamp(0, AppsListGroupBy.values.length - 1)];
  }

  void setFolderGroupBy(String id, AppsListGroupBy v) =>
      _setFolderViewField(id, 'groupBy', v.index);

  bool folderPinUpdates(String id) =>
      (_getFolderViewRaw(id)?['pinUpdates'] as bool?) ?? pinUpdates;

  void setFolderPinUpdates(String id, bool v) =>
      _setFolderViewField(id, 'pinUpdates', v);

  bool folderBuryNonInstalled(String id) =>
      (_getFolderViewRaw(id)?['buryNonInstalled'] as bool?) ?? buryNonInstalled;

  void setFolderBuryNonInstalled(String id, bool v) =>
      _setFolderViewField(id, 'buryNonInstalled', v);

  bool folderGroupNonInstalledSeparately(String id) =>
      (_getFolderViewRaw(id)?['groupNonInstalledSeparately'] as bool?) ??
      groupNonInstalledSeparately;

  void setFolderGroupNonInstalledSeparately(String id, bool v) =>
      _setFolderViewField(id, 'groupNonInstalledSeparately', v);

  bool folderGroupUpdatesSeparately(String id) =>
      (_getFolderViewRaw(id)?['groupUpdatesSeparately'] as bool?) ??
      groupUpdatesSeparately;

  void setFolderGroupUpdatesSeparately(String id, bool v) =>
      _setFolderViewField(id, 'groupUpdatesSeparately', v);

  Locale? get forcedLocale {
    var flSegs = prefs?.getString('forcedLocale')?.split('-');
    var fl = flSegs != null && flSegs.isNotEmpty
        ? Locale(flSegs[0], flSegs.length > 1 ? flSegs[1] : null)
        : null;
    var set = supportedLocales.where((element) => element.key == fl).isNotEmpty
        ? fl
        : null;
    return set;
  }

  set forcedLocale(Locale? fl) {
    if (fl == null) {
      prefs?.remove('forcedLocale');
    } else if (supportedLocales
        .where((element) => element.key == fl)
        .isNotEmpty) {
      prefs?.setString('forcedLocale', fl.toLanguageTag());
    }
    notifyListeners();
  }

  bool setEqual(Set<String> a, Set<String> b) =>
      a.length == b.length && a.union(b).length == a.length;

  void resetLocaleSafe(BuildContext context) {
    if (context.supportedLocales.contains(context.deviceLocale)) {
      context.resetLocale();
    } else {
      context.setLocale(context.fallbackLocale!);
      context.deleteSaveLocale();
    }
  }

  bool get removeOnExternalUninstall {
    return prefs?.getBool('removeOnExternalUninstall') ?? false;
  }

  set removeOnExternalUninstall(bool show) {
    prefs?.setBool('removeOnExternalUninstall', show);
    notifyListeners();
  }

  bool get checkUpdateOnDetailPage {
    return prefs?.getBool('checkUpdateOnDetailPage') ?? false;
  }

  set checkUpdateOnDetailPage(bool show) {
    prefs?.setBool('checkUpdateOnDetailPage', show);
    notifyListeners();
  }

  bool get disablePageTransitions {
    return prefs?.getBool('disablePageTransitions') ?? false;
  }

  set disablePageTransitions(bool show) {
    prefs?.setBool('disablePageTransitions', show);
    notifyListeners();
  }

  bool get reversePageTransitions {
    return prefs?.getBool('reversePageTransitions') ?? false;
  }

  set reversePageTransitions(bool show) {
    prefs?.setBool('reversePageTransitions', show);
    notifyListeners();
  }

  bool get enableBackgroundUpdates {
    return prefs?.getBool('enableBackgroundUpdates') ?? true;
  }

  set enableBackgroundUpdates(bool val) {
    prefs?.setBool('enableBackgroundUpdates', val);
    notifyListeners();
  }

  bool get bgUpdatesOnWiFiOnly {
    return prefs?.getBool('bgUpdatesOnWiFiOnly') ?? false;
  }

  set bgUpdatesOnWiFiOnly(bool val) {
    prefs?.setBool('bgUpdatesOnWiFiOnly', val);
    notifyListeners();
  }

  bool get bgUpdatesWhileChargingOnly {
    return prefs?.getBool('bgUpdatesWhileChargingOnly') ?? false;
  }

  set bgUpdatesWhileChargingOnly(bool val) {
    prefs?.setBool('bgUpdatesWhileChargingOnly', val);
    notifyListeners();
  }

  DateTime get lastCompletedBGCheckTime {
    int? temp = prefs?.getInt('lastCompletedBGCheckTime');
    return temp != null
        ? DateTime.fromMillisecondsSinceEpoch(temp)
        : DateTime.fromMillisecondsSinceEpoch(0);
  }

  set lastCompletedBGCheckTime(DateTime val) {
    prefs?.setInt('lastCompletedBGCheckTime', val.millisecondsSinceEpoch);
    notifyListeners();
  }

  bool get showDebugOpts {
    return prefs?.getBool('showDebugOpts') ?? false;
  }

  set showDebugOpts(bool val) {
    prefs?.setBool('showDebugOpts', val);
    notifyListeners();
  }

  bool get highlightTouchTargets {
    return prefs?.getBool('highlightTouchTargets') ?? false;
  }

  set highlightTouchTargets(bool val) {
    prefs?.setBool('highlightTouchTargets', val);
    notifyListeners();
  }

  Future<Uri?> getExportDir() async {
    final String? uriString = prefs?.getString('exportDir');
    if (uriString == null) {
      return null;
    }
    final Uri uri = Uri.parse(uriString);
    Future<bool> canAccessExportTree(Uri treeUri) async {
      final bool readable = await saf.canRead(treeUri) ?? false;
      final bool writable = await saf.canWrite(treeUri) ?? false;
      return readable && writable;
    }
    if (!await canAccessExportTree(uri)) {
      // Transient SAF failures should not wipe a still-valid grant.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await canAccessExportTree(uri)) {
        prefs?.remove('exportDir');
        notifyListeners();
        return null;
      }
    }
    return uri;
  }

  /// Lets the user pick a folder for exports. Cancelling the system picker
  /// leaves the previous folder and persisted URI permission unchanged.
  /// Only the replaced export URI is released when the user picks a new tree.
  Future<void> pickExportDir({bool remove = false}) async {
    if (remove) {
      final String? saved = prefs?.getString('exportDir');
      prefs?.remove('exportDir');
      notifyListeners();
      if (saved != null && saved.isNotEmpty) {
        try {
          await saf.releasePersistableUriPermission(Uri.parse(saved));
        } catch (_) {}
      }
      return;
    }

    final String? previousExportDirString = prefs?.getString('exportDir');
    final Uri? newUri = await saf.openDocumentTree();

    if (newUri == null) {
      return;
    }

    final String newUriString = newUri.toString();
    if (previousExportDirString == newUriString) {
      return;
    }

    prefs?.setString('exportDir', newUriString);
    notifyListeners();

    if (previousExportDirString != null && previousExportDirString.isNotEmpty) {
      try {
        await saf.releasePersistableUriPermission(
          Uri.parse(previousExportDirString),
        );
      } catch (_) {}
    }
  }

  Future<Uri?> getApkSaveDir() async {
    final String? uriString = prefs?.getString('apkSaveDir');
    if (uriString == null) {
      return null;
    }
    final Uri uri = Uri.parse(uriString);
    Future<bool> canAccessApkSaveTree(Uri treeUri) async {
      final bool readable = await saf.canRead(treeUri) ?? false;
      final bool writable = await saf.canWrite(treeUri) ?? false;
      return readable && writable;
    }
    if (!await canAccessApkSaveTree(uri)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await canAccessApkSaveTree(uri)) {
        prefs?.remove('apkSaveDir');
        notifyListeners();
        return null;
      }
    }
    return uri;
  }

  /// Lets the user pick a folder for saved APK copies. Cancelling leaves the
  /// previous folder and persisted URI permission unchanged.
  Future<void> pickApkSaveDir({bool remove = false}) async {
    if (remove) {
      final String? saved = prefs?.getString('apkSaveDir');
      prefs?.remove('apkSaveDir');
      notifyListeners();
      if (saved != null && saved.isNotEmpty) {
        try {
          await saf.releasePersistableUriPermission(Uri.parse(saved));
        } catch (_) {}
      }
      return;
    }

    final String? previousApkSaveDirString = prefs?.getString('apkSaveDir');
    final Uri? newUri = await saf.openDocumentTree();

    if (newUri == null) {
      return;
    }

    final String newUriString = newUri.toString();
    if (previousApkSaveDirString == newUriString) {
      return;
    }

    prefs?.setString('apkSaveDir', newUriString);
    notifyListeners();

    if (previousApkSaveDirString != null &&
        previousApkSaveDirString.isNotEmpty) {
      try {
        await saf.releasePersistableUriPermission(
          Uri.parse(previousApkSaveDirString),
        );
      } catch (_) {}
    }
  }

  /// When true (and an APK save folder is set), copies of downloaded APKs are
  /// persisted under the SAF tree. Default false so picking a folder alone does
  /// not enable copying until the user turns this on.
  bool get saveDownloadedApkCopies {
    return prefs?.getBool('saveDownloadedApkCopies') ?? false;
  }

  set saveDownloadedApkCopies(bool value) {
    prefs?.setBool('saveDownloadedApkCopies', value);
    notifyListeners();
  }

  bool get autoExportOnChanges {
    return prefs?.getBool('autoExportOnChanges') ?? false;
  }

  set autoExportOnChanges(bool val) {
    prefs?.setBool('autoExportOnChanges', val);
    notifyListeners();
  }

  bool get onlyCheckInstalledOrTrackOnlyApps {
    return prefs?.getBool('onlyCheckInstalledOrTrackOnlyApps') ?? false;
  }

  set onlyCheckInstalledOrTrackOnlyApps(bool val) {
    prefs?.setBool('onlyCheckInstalledOrTrackOnlyApps', val);
    notifyListeners();
  }

  int get exportSettings {
    try {
      return prefs?.getInt('exportSettings') ??
          1; // 0 for no, 1 for yes but no secrets, 2 for everything
    } catch (e) {
      var val = prefs?.getBool('exportSettings') == true ? 1 : 0;
      prefs?.setInt('exportSettings', val);
      return val;
    }
  }

  set exportSettings(int val) {
    prefs?.setInt('exportSettings', val > 2 || val < 0 ? 1 : val);
    notifyListeners();
  }

  bool get parallelDownloads {
    return prefs?.getBool('parallelDownloads') ?? false;
  }

  set parallelDownloads(bool val) {
    prefs?.setBool('parallelDownloads', val);
    notifyListeners();
  }

  List<String> get searchDeselected {
    return prefs?.getStringList('searchDeselected') ??
        SourceProvider().sources.map((s) => s.name).toList();
  }

  set searchDeselected(List<String> list) {
    prefs?.setStringList('searchDeselected', list);
    notifyListeners();
  }

  bool get beforeNewInstallsShareToAppVerifier {
    return prefs?.getBool('beforeNewInstallsShareToAppVerifier') ?? true;
  }

  set beforeNewInstallsShareToAppVerifier(bool val) {
    prefs?.setBool('beforeNewInstallsShareToAppVerifier', val);
    notifyListeners();
  }

  bool get shizukuPretendToBeGooglePlay {
    return prefs?.getBool('shizukuPretendToBeGooglePlay') ?? false;
  }

  set shizukuPretendToBeGooglePlay(bool val) {
    prefs?.setBool('shizukuPretendToBeGooglePlay', val);
    notifyListeners();
  }

  bool get useFGService {
    return prefs?.getBool('useFGService') ?? false;
  }

  set useFGService(bool val) {
    prefs?.setBool('useFGService', val);
    notifyListeners();
  }

  SwipeAction get rightSwipeAction {
    return _swipeActionFromPrefs(
      'rightSwipeAction',
      _rightSwipeNameKey,
      SwipeAction.update.index,
    );
  }

  set rightSwipeAction(SwipeAction action) {
    prefs?.setInt('rightSwipeAction', action.index);
    prefs?.setString(_rightSwipeNameKey, action.name);
    notifyListeners();
  }

  SwipeAction get leftSwipeAction {
    return _swipeActionFromPrefs(
      'leftSwipeAction',
      _leftSwipeNameKey,
      SwipeAction.pin.index,
    );
  }

  set leftSwipeAction(SwipeAction action) {
    prefs?.setInt('leftSwipeAction', action.index);
    prefs?.setString(_leftSwipeNameKey, action.name);
    notifyListeners();
  }
}
