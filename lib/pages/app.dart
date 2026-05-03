import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/components/app_page_section_title.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/page_route_slide_up.dart';
import 'package:obtainium/theme/app_form_field_styles.dart';
import 'package:obtainium/theme/app_page_icon_colors.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:provider/provider.dart';
import 'package:markdown/markdown.dart' as md;

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  } else if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  } else if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  } else {
    return '$bytes B';
  }
}

/// Optional debug logger — guarded by the consolidated [apkMirrorSizeDebug]
/// flag so it short-circuits in release builds.
void _logApkMirrorSizeDebugFromAppPage(String message) {
  if (!apkMirrorSizeDebug) {
    return;
  }
  unawaited(() async {
    try {
      await LogsProvider(
        runDefaultClear: false,
      ).add('OBTAINX-APK-SIZE-DEBUG AppPage: $message', level: LogLevels.debug);
    } catch (_) {}
  }());
}

Color _labelColorOnCategoryFill(Color categoryFill) {
  return categoryFill.computeLuminance() > 0.5
      ? const Color(0xFF1A1A1A)
      : const Color(0xFFF5F5F5);
}

/// True when [trackedUrl]'s host contains [hostFragment].
/// Used to suppress an "other sources" chip when the app is already tracked
/// from that store (e.g. pass `'apkmirror.com'` to hide the APKMirror chip).
bool _trackedUrlIsFromHost(String? trackedUrl, String hostFragment) {
  if (trackedUrl == null || trackedUrl.isEmpty) return false;
  final uri = Uri.tryParse(trackedUrl);
  if (uri == null || uri.host.isEmpty) return false;
  return uri.host.toLowerCase().contains(hostFragment);
}

/// Resolves the URL to display for a store chip, consulting the bulk-scan cache.
/// Returns null when the chip should be hidden.
///
/// Logic:
/// - [alreadyTracked] → hide (user already tracks this store)
/// - [storeData] == null → app never scanned → show [fallbackUrl] (unverified)
/// - cache entry == `""` → confirmed absent → hide
/// - cache entry is a non-empty URL → show with that URL
/// - cache entry missing for this store (but app was scanned for others) → hide
///   (we have scan data for this app; don't surface unconfirmed stores)
String? _resolveStoreUrl({
  required Map<String, String>? storeData,
  required String storeName,
  required String? fallbackUrl,
  required bool alreadyTracked,
}) {
  if (alreadyTracked) return null;
  // Key absent means this store was never explicitly checked for this app
  // (either no scan at all, or a different store's check ran first).
  // In both cases show the fallback URL — don't suppress unverified stores.
  if (storeData == null || !storeData.containsKey(storeName)) {
    return fallbackUrl;
  }
  final entry = storeData[storeName]!;
  if (entry.isEmpty) return null; // confirmed absent (empty string sentinel)
  return entry; // confirmed present
}

/// Checks whether a package exists on the Play Store by sending a HEAD request
/// without following redirects. Play Store returns 200 for valid listings and
/// 302 (redirect to search) for non-existent packages.
///
/// Returns the Play Store URL if the app is present, or null if absent.
/// Returns null also on network error — caller should not cache the result.
Future<String?> _checkPlayStoreAvailability(String packageId) async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=$packageId&hl=en&gl=US',
    );
    final request = await client.headUrl(uri);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
    );
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>();
    client.close();
    if (response.statusCode == 200) {
      return 'https://play.google.com/store/apps/details?id=$packageId';
    }
    return null; // 302 = redirect to search (not found); 404 = also not found
  } catch (_) {
    return null; // network error — caller skips caching
  }
}

void _toastUrl(String url) {
  Fluttertoast.showToast(
    msg: url,
    toastLength: Toast.LENGTH_LONG,
    timeInSecForIosWeb: 5,
  );
}

int _additionalSettingsRebuildToken(Map<String, dynamic> map) {
  if (map.isEmpty) return 0;
  final List<String> keys = map.keys.map((k) => k.toString()).toList()..sort();
  int accumulator = map.length;
  for (final String key in keys) {
    accumulator = Object.hash(accumulator, key, map[key]?.hashCode ?? 0);
  }
  return accumulator;
}

int _apkUrlEntriesRebuildToken(List<MapEntry<String, String>> entries) {
  int accumulator = entries.length;
  for (final MapEntry<String, String> entry in entries) {
    accumulator = Object.hash(accumulator, entry.key, entry.value);
  }
  return accumulator;
}

/// Fingerprint so [AppPage] rebuilds only when this app or global download
/// state changes, not on every [AppsProvider.notifyListeners].
int appPageAppsRebuildToken(AppsProvider provider, String appId) {
  final bool downloadsRunning = provider.areDownloadsRunning();
  final AppInMemory? inMemory = provider.apps[appId];
  if (inMemory == null) {
    return Object.hash(appId, downloadsRunning, 0);
  }
  final App model = inMemory.app;
  final dynamic packageInfo = inMemory.installedInfo;
  return Object.hashAll([
    downloadsRunning,
    appId,
    inMemory.downloadProgress,
    identityHashCode(inMemory.icon),
    inMemory.icon?.length,
    model.id,
    model.url,
    model.name,
    model.author,
    model.installedVersion,
    model.latestVersion,
    model.pinned,
    model.lastUpdateCheck,
    model.releaseDate,
    model.changeLog?.hashCode,
    model.preferredApkIndex,
    model.overrideSource,
    _apkUrlEntriesRebuildToken(model.apkUrls),
    _apkUrlEntriesRebuildToken(model.otherAssetUrls),
    _additionalSettingsRebuildToken(model.additionalSettings),
    model.categories.length,
    Object.hashAll(model.categories),
    // Do not touch [AppInMemory.certificateHashes] here: it runs SHA256 per hash
    // and this selector runs on every [AppsProvider.notifyListeners].
    packageInfo?.versionName,
    packageInfo?.packageName,
    model.iconUrl,
    model.apkSizeBytes,
  ]);
}

int appPageSettingsRebuildToken(SettingsProvider settings) {
  return Object.hash(
    settings.matchAppPageToIconColors,
    settings.showAppWebpage,
    settings.checkUpdateOnDetailPage,
    settings.highlightTouchTargets,
    settings.categories.hashCode,
  );
}

enum _UnsavedAction { keepEditing, discard, saveAndExit }

class _MeasureSize extends StatefulWidget {
  const _MeasureSize({required this.child, required this.onChanged});

  final Widget child;
  final ValueChanged<Size> onChanged;

  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  Size? _previousSize;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final Size? newSize = context.size;
      if (newSize == null || newSize == _previousSize) {
        return;
      }
      _previousSize = newSize;
      widget.onChanged(newSize);
    });
    return widget.child;
  }
}

class AppPage extends StatefulWidget {
  const AppPage({
    super.key,
    required this.appId,
    this.showOppositeOfPreferredView = false,
    this.openInEditMode = false,
    this.appsListHeroFolderId,
  });

  final String appId;
  final bool showOppositeOfPreferredView;

  /// Folder id when opened from [AppsPage] with [AppsPage.folderId]; matches list [Hero] tags.
  final String? appsListHeroFolderId;

  /// When true (e.g. swipe-to-edit), enter inline edit mode once the app is loaded.
  final bool openInEditMode;

  @override
  State<AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<AppPage> {
  static const double _versionRowLabelWidth = 120;

  late final WebViewController _webViewController;
  bool _webViewUrlLoaded = false;
  bool _scheduledDetailPageRefresh = false;
  bool _requestedMissingIconLoad = false;
  // Once true, the lazy APKMirror size resolver has fired for this AppPage
  // mount and won't run again until the user navigates to a different app.
  // Re-resets in [didUpdateWidget] when [widget.appId] changes.
  bool _attemptedApkMirrorSizeResolution = false;
  Color? _lastWebViewSurfaceColorApplied;
  bool updating = false;

  ColorScheme? _iconDerivedColorScheme;
  String? _iconSchemeCacheKey;
  String? _iconSchemeLoadingForKey;
  String? _iconSchemeFailedCacheKey;

  final SourceProvider _sourceProvider = SourceProvider();

  /// Resolves to this app's store-availability map from [BulkScanCache], or null.
  Future<Map<String, String>?>? _storeAvailabilityCacheFuture;

  // Cache for the per-page ThemeData derived from the icon color scheme.
  // Recomputed only when the icon scheme key or parent brightness changes.
  ThemeData? _cachedPageTheme;
  String? _cachedPageThemeKey;

  // ── Inline edit mode ────────────────────────────────────────────────────
  bool _editMode = false;
  bool _scheduledOpenInEditMode = false;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _authorController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _packageController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final ScrollController _appPageScrollController = ScrollController();
  final FocusNode _notesEditFocusNode = FocusNode();
  final GlobalKey _notesEditSectionKey = GlobalKey();
  double _bottomSheetMenuHeight = 0;
  List<String> _editCategories = [];

  String _editBaselineName = '';
  String _editBaselineAuthor = '';
  String _editBaselineNotes = '';
  String _editBaselineUrl = '';
  String _editBaselinePackage = '';
  List<String> _editBaselineCategories = [];
  int _editBaselineIconFingerprint = 0;
  bool _editBaselineHadUserOverride = false;

  Uint8List? _editStagedIconBytes;
  bool _editStagedClearOverride = false;
  Uint8List? _editNonUserIconPreview;

  @override
  void didUpdateWidget(covariant AppPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appId != widget.appId) {
      _iconDerivedColorScheme = null;
      _iconSchemeCacheKey = null;
      _iconSchemeLoadingForKey = null;
      _iconSchemeFailedCacheKey = null;
      _cachedPageTheme = null;
      _cachedPageThemeKey = null;
      _webViewUrlLoaded = false;
      _scheduledDetailPageRefresh = false;
      _requestedMissingIconLoad = false;
      _attemptedApkMirrorSizeResolution = false;
      _lastWebViewSurfaceColorApplied = null;
      _scheduledOpenInEditMode = false;
      _clearEditIconStaging();
      _storeAvailabilityCacheFuture = BulkScanCache.load().then(
        (cache) => cache[widget.appId],
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_maybeLazyResolveApkMirrorSize());
      });
    } else if (oldWidget.openInEditMode != widget.openInEditMode) {
      _scheduledOpenInEditMode = false;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _authorController.dispose();
    _urlController.dispose();
    _packageController.dispose();
    _notesController.dispose();
    _appPageScrollController.dispose();
    _notesEditFocusNode.dispose();
    super.dispose();
  }

  // ── Edit mode helpers ───────────────────────────────────────────────────

  int _iconFingerprintForEditBaseline(Uint8List? iconBytes) {
    if (iconBytes == null || iconBytes.isEmpty) return 0;
    return Object.hash(
      iconBytes.length,
      iconBytes[0],
      iconBytes[iconBytes.length ~/ 2],
    );
  }

  void _captureEditBaseline(AppInMemory appData) {
    _editBaselineName = _nameController.text;
    _editBaselineAuthor = _authorController.text;
    _editBaselineUrl = _urlController.text;
    _editBaselinePackage = _packageController.text;
    _editBaselineNotes = _notesController.text;
    _editBaselineCategories = List<String>.from(_editCategories);
    _editBaselineIconFingerprint = _iconFingerprintForEditBaseline(
      appData.icon,
    );
  }

  void _clearEditIconStaging() {
    _editStagedIconBytes = null;
    _editStagedClearOverride = false;
    _editNonUserIconPreview = null;
  }

  bool _editIconStagingIsDirty() {
    if (_editStagedClearOverride && _editBaselineHadUserOverride) return true;
    if (_editStagedIconBytes != null) {
      return _iconFingerprintForEditBaseline(_editStagedIconBytes) !=
          _editBaselineIconFingerprint;
    }
    return false;
  }

  Uint8List? _heroIconMemoryOverrideForEdit(AppInMemory? appInMemory) {
    if (!_editMode) return null;
    if (_editStagedIconBytes != null) return _editStagedIconBytes;
    if (_editStagedClearOverride) return _editNonUserIconPreview;
    return null;
  }

  bool _isEditDirty(AppInMemory? currentApp) {
    if (!_editMode || currentApp == null) return false;
    if (_nameController.text != _editBaselineName) return true;
    if (_authorController.text != _editBaselineAuthor) return true;
    if (_urlController.text != _editBaselineUrl) return true;
    if (_packageController.text != _editBaselinePackage) return true;
    if (_notesController.text != _editBaselineNotes) return true;
    if (!listEquals(_editCategories, _editBaselineCategories)) return true;
    if (_editIconStagingIsDirty()) return true;
    return false;
  }

  void _exitEditWithoutSaving() {
    _clearEditIconStaging();
    setState(() => _editMode = false);
  }

  // --- Unsaved changes dialog ---
  Future<_UnsavedAction?> _showUnsavedChangesDialog(
    BuildContext context,
    ThemeData dialogTheme,
  ) {
    return showDialog<_UnsavedAction>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Theme(
          data: dialogTheme,
          child: AlertDialog(
            title: Text(tr('appEditsUnsavedTitle')),
            content: Text(tr('appEditsUnsavedBody')),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _UnsavedAction.discard),
                child: Text(tr('discard')),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _UnsavedAction.keepEditing),
                child: Text(tr('keepEditing')),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _UnsavedAction.saveAndExit),
                child: Text(tr('saveAndExit')),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _onCancelEditPressed(
    BuildContext actionContext,
    AppInMemory? appData,
    ThemeData dialogTheme,
  ) async {
    if (!_isEditDirty(appData)) {
      _exitEditWithoutSaving();
      return;
    }
    final _UnsavedAction? action = await _showUnsavedChangesDialog(
      actionContext,
      dialogTheme,
    );

    if (!actionContext.mounted || appData == null) return;

    switch (action) {
      case _UnsavedAction.discard:
        _exitEditWithoutSaving();
        break;
      case _UnsavedAction.saveAndExit:
        final appsProvider = Provider.of<AppsProvider>(
          actionContext,
          listen: false,
        );
        await _saveEdit(appData, appsProvider);
        break;
      case _UnsavedAction.keepEditing:
      default:
        break;
    }
  }

  Widget? _editModeFloatingActionButtons(
    BuildContext themeContext,
    AppInMemory? appData,
    AppsProvider appsProvider,
    ThemeData pageThemeForDialogs,
  ) {
    if (!_editMode || appData == null) return null;
    return Padding(
      padding: EdgeInsets.only(bottom: _bottomSheetMenuHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'app_page_edit_cancel',
            tooltip: tr('cancel'),
            onPressed: updating
                ? null
                : () => _onCancelEditPressed(
                    themeContext,
                    appData,
                    pageThemeForDialogs,
                  ),
            child: const Icon(Icons.close),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'app_page_edit_save',
            tooltip: tr('save'),
            onPressed: appData.downloadProgress != null || updating
                ? null
                : () => _saveEdit(appData, appsProvider),
            child: const Icon(Icons.check),
          ),
        ],
      ),
    );
  }

  void _startEdit(AppInMemory appData, AppsProvider appsProvider) {
    _clearEditIconStaging();
    _nameController.text = appData.name;
    _authorController.text = appData.author;
    final dynamic aboutRaw = appData.app.additionalSettings['about'];
    _notesController.text = aboutRaw is String
        ? aboutRaw
        : (aboutRaw?.toString() ?? '');
    _urlController.text = appData.app.url;
    _packageController.text = appData.app.id;
    _editCategories = List<String>.from(appData.app.categories);
    _editBaselineHadUserOverride = appsProvider.hasUserAppIconOverride(
      widget.appId,
    );
    _captureEditBaseline(appData);
    setState(() => _editMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void placeCaretAtEnd(TextEditingController controller) {
        final String text = controller.text;
        controller.selection = TextSelection.collapsed(offset: text.length);
      }

      placeCaretAtEnd(_nameController);
      placeCaretAtEnd(_authorController);
      placeCaretAtEnd(_notesController);
      placeCaretAtEnd(_urlController);
      placeCaretAtEnd(_packageController);
    });
  }

  Future<void> _saveEdit(AppInMemory appData, AppsProvider appsProvider) async {
    final updatedApp = appData.app.deepCopy();
    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      updatedApp.additionalSettings.remove('appName');
    } else {
      updatedApp.additionalSettings['appName'] = newName;
    }
    final String newAuthor = _authorController.text.trim();
    if (newAuthor.isEmpty) {
      updatedApp.additionalSettings.remove('appAuthor');
    } else {
      updatedApp.additionalSettings['appAuthor'] = newAuthor;
    }
    final newUrl = _urlController.text.trim();
    updatedApp.url = newUrl;
    final newId = _packageController.text.trim();
    if (newId.isNotEmpty && newId != updatedApp.id) {
      updatedApp.allowIdChange = true;
      updatedApp.id = newId;
    }
    updatedApp.categories = _editCategories;

    final String notesText = _notesController.text.trim();
    if (notesText.isEmpty) {
      updatedApp.additionalSettings.remove('about');
    } else {
      updatedApp.additionalSettings['about'] = notesText;
    }

    if (_editStagedClearOverride &&
        appsProvider.hasUserAppIconOverride(widget.appId)) {
      await appsProvider.resetAppIconToDefault(widget.appId);
    }
    if (_editStagedIconBytes != null) {
      final String? iconErr = await appsProvider.applyUserAppIconPngBytes(
        widget.appId,
        _editStagedIconBytes!,
      );
      if (iconErr != null) {
        if (mounted) _showPageError(ObtainiumError(iconErr), context);
        return;
      }
    }

    await appsProvider.saveApps([updatedApp], onlyIfExists: true);
    await appsProvider.updateAppIcon(updatedApp.id);
    if (mounted) {
      _clearEditIconStaging();
      setState(() => _editMode = false);
    }
  }

  Future<void> _pickEditIcon(AppsProvider appsProvider) async {
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png'],
      withData: true,
    );
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;
    final PlatformFile picked = result.files.single;
    Uint8List? bytes = picked.bytes;
    if (bytes == null && picked.path != null) {
      bytes = await File(picked.path!).readAsBytes();
    }
    if (bytes == null) return;
    if (!appsProvider.validateUserAppIconPngBytes(bytes)) {
      if (mounted) {
        _showPageError(ObtainiumError(tr('changeAppIconInvalidPng')), context);
      }
      return;
    }
    setState(() {
      _editStagedIconBytes = bytes;
      _editStagedClearOverride = false;
      _editNonUserIconPreview = null;
    });
  }

  Future<void> _onResetEditIconPressed(AppsProvider appsProvider) async {
    Uint8List? preview;
    bool shouldClearOverride = false;

    // If there is a user-set icon override, we load the non-override icon
    // so we can show it live. We also set a flag to clear the override on save.
    // If there is no override but the user has picked a new icon in this edit
    // session, all we need to do is null out the staged icon bytes.
    if (appsProvider.hasUserAppIconOverride(widget.appId)) {
      shouldClearOverride = true;
      preview = await appsProvider.loadIconPreviewExcludingUserOverride(
        widget.appId,
      );
    }

    if (!mounted) return;

    setState(() {
      _editStagedIconBytes = null;
      _editStagedClearOverride = shouldClearOverride;
      _editNonUserIconPreview = preview;
    });
  }

  void _openIconWebSearch(AppInMemory appData) {
    final String query =
        '${appData.name} square app icon transparent background';
    launchUrlString(
      'https://images.google.com/search?tbm=isch&q=${Uri.encodeComponent(query)}',
      mode: LaunchMode.externalApplication,
    );
  }

  void _showPageError(dynamic error, BuildContext hostContext) {
    if (!hostContext.mounted) return;
    showError(error, hostContext, theme: _cachedPageTheme);
  }

  void _showPageMessage(dynamic message, BuildContext hostContext) {
    if (!hostContext.mounted) return;
    showMessage(message, hostContext, theme: _cachedPageTheme);
  }

  Future<T?> _showPageDialog<T>({
    required BuildContext hostContext,
    required WidgetBuilder builder,
  }) {
    final ThemeData? pageTheme = _cachedPageTheme;
    return showDialog<T>(
      context: hostContext,
      builder: (BuildContext dialogContext) {
        final Widget dialog = builder(dialogContext);
        return pageTheme == null
            ? dialog
            : Theme(data: pageTheme, child: dialog);
      },
    );
  }

  Widget _materialAppPageSectionCard(
    BuildContext ctx,
    String sectionTitle,
    List<Widget> children, {
    Color? sectionBackgroundColor,
    Color? sectionTitleColor,
    Widget? headerStripe,
    Widget? cardWatermark,
  }) {
    final BoxDecoration baseDecoration = appPageSectionCardDecoration(ctx);
    final BoxDecoration decoration = sectionBackgroundColor != null
        ? baseDecoration.copyWith(color: sectionBackgroundColor)
        : baseDecoration;

    final Widget bodyColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        appPageCardSectionHeaderLabel(
          ctx,
          sectionTitle,
          color: sectionTitleColor,
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );

    final Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      child: cardWatermark != null
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                bodyColumn,
                Positioned(bottom: 0, right: 0, child: cardWatermark),
              ],
            )
          : bodyColumn,
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: decoration,
      clipBehavior: (headerStripe != null || cardWatermark != null)
          ? Clip.antiAlias
          : Clip.none,
      child: headerStripe != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [headerStripe, body],
            )
          : body,
    );
  }

  Widget _buildEditMetadataSection(
    BuildContext ctx,
    AppInMemory appData,
    AppsProvider appsProvider,
    SettingsProvider settingsProvider,
  ) {
    final bool showResetIconButton =
        appsProvider.hasUserAppIconOverride(widget.appId) ||
        _editStagedIconBytes != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _materialAppPageSectionCard(ctx, tr('nameAndLinks'), [
          TextField(
            controller: _nameController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('appName'),
              isDense: true,
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _authorController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('author'),
              isDense: true,
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _packageController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('package'),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('trackedSource'),
              isDense: true,
            ),
            keyboardType: TextInputType.url,
          ),
        ]),
        _materialAppPageSectionCard(ctx, tr('appIconActionsTitle'), [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonal(
                onPressed: () => _pickEditIcon(appsProvider),
                child: Text(tr('changeAppIcon')),
              ),
              OutlinedButton(
                onPressed: () => _openIconWebSearch(appData),
                child: Text(tr('searchWebForAppIcon')),
              ),
              if (showResetIconButton)
                OutlinedButton(
                  onPressed: updating
                      ? null
                      : () => _onResetEditIconPressed(appsProvider),
                  child: Text(tr('resetAppIcon')),
                ),
            ],
          ),
        ]),
        _materialAppPageSectionCard(ctx, tr('categories'), [
          CategoryEditorSelector(
            key: ValueKey<String>('app_categories_${widget.appId}'),
            preselected: _editCategories.toSet(),
            alignment: WrapAlignment.start,
            showLabelWhenNotEmpty: false,
            onSelected: (cats) => setState(() => _editCategories = cats),
          ),
        ]),
        KeyedSubtree(
          key: _notesEditSectionKey,
          child: _materialAppPageSectionCard(ctx, tr('notes'), [
            TextField(
              controller: _notesController,
              focusNode: _notesEditFocusNode,
              scrollPadding: const EdgeInsets.only(bottom: 160),
              decoration: appPageOutlinedInputDecoration(
                ctx,
                labelText: null,
                hintText: tr('notes'),
                isDense: true,
              ),
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildRepoRenameWarning({
    required AppInMemory? app,
    required AppsProvider appsProvider,
    required Future<void> Function(String id) onUpdate,
  }) {
    if (app?.app.hasPendingRepoRename != true) {
      return const SizedBox.shrink();
    }
    var appValue = app!;
    var pendingUrl = appValue.app.pendingRepoRenameUrl!;
    final colorScheme = ColorScheme.of(context);
    final textTheme = TextTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 2,
      children: [
        Material(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(16),
              bottom: Radius.circular(4),
            ),
          ),
          color: colorScheme.surfaceContainer,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                spacing: 12,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 24,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          tr('repoRenamed'),
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          tr('repoRenamedExplanation'),
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Material(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          color: colorScheme.surfaceContainer,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                spacing: 12,
                children: [
                  Icon(
                    Icons.link_rounded,
                    size: 24,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          tr('newUrl'),
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          pendingUrl,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Material(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(4),
              bottom: Radius.circular(16),
            ),
          ),
          color: colorScheme.surfaceContainer,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                // Min tap target has a height of 48dp
                vertical: 10 - 4,
              ),
              child: Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.fromMap({
                          WidgetState.disabled: colorScheme.onSurface
                              .withValues(alpha: 0.10),
                          WidgetState.any: Colors.transparent,
                        }),
                        side: WidgetStatePropertyAll(
                          BorderSide(
                            width: 1,
                            strokeAlign: BorderSide.strokeAlignInside,
                            color: colorScheme.outlineVariant,
                          ),
                        ),
                        elevation: const WidgetStatePropertyAll(0),
                        overlayColor: WidgetStateProperty.fromMap({
                          WidgetState.disabled: colorScheme.onSurfaceVariant
                              .withAlpha(0),
                          WidgetState.pressed: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.10),
                          WidgetState.focused: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.10),
                          WidgetState.hovered: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.08),
                          WidgetState.any: colorScheme.onSurfaceVariant
                              .withAlpha(0),
                        }),
                        foregroundColor: WidgetStateProperty.fromMap({
                          WidgetState.disabled: colorScheme.onSurface
                              .withValues(alpha: 0.38),
                          WidgetState.any: colorScheme.onSurfaceVariant,
                        }),
                        textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
                      ),
                      onPressed: () async {
                        await appsProvider.updatePendingRepoRename(
                          appValue.app.id,
                          null,
                        );
                      },
                      child: Text(tr('dismiss')),
                    ),
                  ),
                  Expanded(
                    child: FilledButton.tonal(
                      style: ButtonStyle(
                        elevation: const WidgetStatePropertyAll(0),
                        textStyle: WidgetStatePropertyAll(
                          textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      onPressed: () async {
                        await appsProvider.acceptRepoRename(
                          appValue.app.id,
                          pendingUrl,
                        );
                        if (mounted) {
                          onUpdate(appValue.app.id);
                        }
                      },
                      child: Text(tr('updateUrl')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Hero / dialog icons must not use [FutureBuilder] + [updateAppIcon] in build:
  /// a new [Future] every rebuild restarts the work, and [ignoreCache] forces
  /// expensive installed-app icon reloads and [notifyListeners] in a loop.
  Widget _tappableAppIconDisplay({
    required BuildContext themeContext,
    required AppInMemory? appInMemory,
    required double size,
    required double borderRadius,
    required Widget emptyPlaceholder,
    Object? heroTag,
    VoidCallback? onTap,
    Uint8List? iconMemoryBytes,
    bool exclusiveIconMemoryBytes = false,
  }) {
    final Uint8List? bytesForImage = exclusiveIconMemoryBytes
        ? iconMemoryBytes
        : (iconMemoryBytes ?? appInMemory?.icon);
    // Cap the decoded bitmap at the rendered logical size × DPR. Without
    // this hint, [Image.memory] decodes the full source PNG (often 512×512
    // for a launcher icon) and keeps it in the raster cache at full
    // resolution even when displayed at 56 logical px. Sizing the cache
    // here keeps RAM usage bounded for the AppPage's hero icon and the
    // large-format dialog preview.
    final int iconCachePx =
        (size * MediaQuery.devicePixelRatioOf(themeContext)).round();
    Widget iconChild;
    if (bytesForImage != null) {
      iconChild = GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.memory(
            bytesForImage,
            height: size,
            width: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: iconCachePx,
            cacheHeight: iconCachePx,
          ),
        ),
      );
    } else {
      iconChild = GestureDetector(onTap: onTap, child: emptyPlaceholder);
    }
    if (heroTag != null) {
      return Hero(
        tag: heroTag,
        flightShuttleBuilder:
            (
              BuildContext flightContext,
              Animation<double> animation,
              HeroFlightDirection flightDirection,
              BuildContext fromHeroContext,
              BuildContext toHeroContext,
            ) {
              final Uint8List? shuttleBytes = bytesForImage;
              if (shuttleBytes != null) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(borderRadius),
                  child: Image.memory(
                    shuttleBytes,
                    height: size,
                    width: size,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: iconCachePx,
                    cacheHeight: iconCachePx,
                  ),
                );
              }
              return emptyPlaceholder;
            },
        child: iconChild,
      );
    }
    return iconChild;
  }

  void _startIconSchemeLoadIfNeeded(Uint8List iconBytes, String cacheKey) {
    if (!mounted) return;
    if (_iconSchemeCacheKey == cacheKey) return;
    if (_iconSchemeLoadingForKey == cacheKey) return;
    _iconSchemeLoadingForKey = cacheKey;
    _extractColorSchemeFromIcon(iconBytes, cacheKey);
  }

  Future<void> _extractColorSchemeFromIcon(
    Uint8List iconBytes,
    String cacheKey,
  ) async {
    if (!context.mounted) return;
    final Brightness brightness = Theme.of(context).brightness;
    final ColorScheme? scheme = await loadColorSchemeFromAppIcon(
      iconBytes: iconBytes,
      brightness: brightness,
    );
    if (!context.mounted) return;
    final AppsProvider apps =
        // ignore: use_build_context_synchronously
        Provider.of<AppsProvider>(context, listen: false);
    if (!identical(apps.apps[widget.appId]?.icon, iconBytes)) return;
    final SettingsProvider settings =
        // ignore: use_build_context_synchronously
        Provider.of<SettingsProvider>(context, listen: false);
    if (!settings.matchAppPageToIconColors) return;
    if (scheme != null) {
      setState(() {
        if (_iconSchemeLoadingForKey == cacheKey) {
          _iconDerivedColorScheme = scheme;
          _iconSchemeCacheKey = cacheKey;
          _iconSchemeLoadingForKey = null;
          _iconSchemeFailedCacheKey = null;
        }
      });
    } else {
      setState(() {
        if (_iconSchemeLoadingForKey == cacheKey) {
          _iconSchemeLoadingForKey = null;
          _iconSchemeFailedCacheKey = cacheKey;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _storeAvailabilityCacheFuture = BulkScanCache.load().then(
      (cache) => cache[widget.appId],
    );
    // Defer to post-frame so the first paint isn't competing with our
    // SourceProvider lookup. The actual HTTP walk inside is fully async.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_maybeLazyResolveApkMirrorSize());
    });
    _notesEditFocusNode.addListener(() {
      if (!_notesEditFocusNode.hasFocus || !mounted) return;
      void scrollNotesIntoView() {
        if (!mounted || !_notesEditFocusNode.hasFocus) return;
        final BuildContext? notesContext = _notesEditSectionKey.currentContext;
        if (notesContext == null) return;
        Scrollable.ensureVisible(
          notesContext,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.1,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollNotesIntoView();
        Future<void>.delayed(
          const Duration(milliseconds: 120),
          scrollNotesIntoView,
        );
      });
    });
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame == true) {
              _showPageError(
                ObtainiumError(error.description, unexpected: true),
                context,
              );
            }
          },
          onNavigationRequest: (NavigationRequest request) =>
              !(request.url.startsWith("http://") ||
                  request.url.startsWith("https://") ||
                  request.url.startsWith("ftp://") ||
                  request.url.startsWith("ftps://"))
              ? NavigationDecision.prevent
              : NavigationDecision.navigate,
        ),
      );
  }

  /// After a pull-to-refresh, checks all 4 stores (APKMirror, F-Droid, APKPure,
  /// Play Store) for this single app concurrently, skipping any store already
  /// cached or already tracked from that source. Caches results and triggers a
  /// FutureBuilder rebuild so the Other Sources row updates in place.
  Future<void> _maybeCheckAndCacheAllStores() async {
    final pid = widget.appId;
    if (pid.isEmpty) return;

    final trackedUrl = Provider.of<AppsProvider>(
      context,
      listen: false,
    ).apps[pid]?.app.url;

    final cache = await BulkScanCache.load();
    final storeData = cache[pid] ?? {};

    final futures = <Future<MapEntry<String, String?>>>[];

    if (!_trackedUrlIsFromHost(trackedUrl, 'apkmirror.com') &&
        !storeData.containsKey('APKMirror')) {
      futures.add(
        BulkImportService.checkApkMirror([
          pid,
        ]).then((r) => MapEntry('APKMirror', r[pid])),
      );
    }
    if (!_trackedUrlIsFromHost(trackedUrl, 'f-droid.org') &&
        !storeData.containsKey('F-Droid')) {
      futures.add(
        BulkImportService.checkFDroid([
          pid,
        ]).then((r) => MapEntry('F-Droid', r[pid])),
      );
    }
    if (!_trackedUrlIsFromHost(trackedUrl, 'apkpure.') &&
        !storeData.containsKey('APKPure')) {
      futures.add(
        BulkImportService.checkApkPure([
          pid,
        ]).then((r) => MapEntry('APKPure', r[pid])),
      );
    }
    if (!_trackedUrlIsFromHost(trackedUrl, 'play.google.com') &&
        !storeData.containsKey('PlayStore')) {
      futures.add(
        _checkPlayStoreAvailability(
          pid,
        ).then((url) => MapEntry('PlayStore', url)),
      );
    }

    if (futures.isEmpty) return;

    final results = await Future.wait(futures);

    final entry = cache.putIfAbsent(pid, () => {});
    for (final r in results) {
      entry[r.key] = r.value ?? '';
    }
    await BulkScanCache.save(cache);

    if (mounted) {
      setState(() {
        _storeAvailabilityCacheFuture = Future.value(cache[pid]);
      });
    }
  }

  /// Lazily fills in [App.apkSizeBytes] for APKMirror apps the first time
  /// the user opens the AppPage after a refresh that bumped the version.
  ///
  /// Why this lives here and not in the update-check pipeline:
  /// resolving an APKMirror size requires walking the release page plus
  /// one GET per ranked download candidate, so doing it on every refresh
  /// for every APKMirror app — just to display " · 43 MB" next to the
  /// install/update button — was the worst single offender in the update
  /// path. Doing it lazily on AppPage open means at most one app pays
  /// the cost, and only when the user actually looks at it.
  ///
  /// The resolved value is persisted onto the App via [AppsProvider.saveApps];
  /// [SourceProvider.getApp] preserves it across refreshes that don't
  /// change [App.latestVersion] and clears it when the version changes,
  /// so the cache key is effectively `(appId, latestVersion)`.
  Future<void> _maybeLazyResolveApkMirrorSize() async {
    if (_attemptedApkMirrorSizeResolution) return;
    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    final App? currentApp = appsProvider.apps[widget.appId]?.app;
    if (currentApp == null) return;
    if (currentApp.apkSizeBytes != null) {
      // Already cached on the App itself.
      _attemptedApkMirrorSizeResolution = true;
      return;
    }
    final AppSource source = SourceProvider().getSource(
      currentApp.url,
      overrideSource: currentApp.overrideSource,
    );
    if (source is! APKMirror) return;
    _attemptedApkMirrorSizeResolution = true;
    try {
      final int? resolvedSize = await source.resolveLatestApkSizeBytes(
        releasePageUrl: currentApp.changeLog,
        additionalSettings: currentApp.additionalSettings,
      );
      if (!mounted || resolvedSize == null) return;
      final App? freshApp = appsProvider.apps[widget.appId]?.app;
      if (freshApp == null) return;
      // The user may have navigated away or the app may have been
      // refreshed onto a new version while the network walk was running;
      // in either case we want to skip the stale write.
      if (freshApp.latestVersion != currentApp.latestVersion) return;
      if (freshApp.apkSizeBytes == resolvedSize) return;
      final App updated = freshApp.deepCopy()..apkSizeBytes = resolvedSize;
      await appsProvider.saveApps(
        [updated],
        // No need to re-export to disk just because we filled in a size.
        autoExportAfterSave: false,
      );
      _logApkMirrorSizeDebugFromAppPage(
        'lazy resolve persisted id=${widget.appId} size=$resolvedSize',
      );
    } catch (error) {
      _logApkMirrorSizeDebugFromAppPage(
        'lazy resolve error id=${widget.appId} error=${error.toString()}',
      );
    }
  }

  Future<void> _runCheckUpdate(String id, {bool resetVersion = false}) async {
    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    try {
      setState(() {
        updating = true;
      });
      await appsProvider.checkUpdate(id);
      // saveApps (called inside checkUpdate) replaces the in-memory icon with
      // null for non-installed apps.  Reset the one-shot flag so the rebuild
      // that follows will re-invoke updateAppIcon and restore any user icon.
      // Also reload the bulk-scan cache: the page's future was resolved at
      // initState time and won't see cache writes made by a bulk scan that ran
      // while this page was already open in the navigation stack.
      setState(() {
        _requestedMissingIconLoad = false;
        _storeAvailabilityCacheFuture = BulkScanCache.load().then(
          (cache) => cache[widget.appId],
        );
      });
      // Independently check Play Store in the background so other store
      // buttons (F-Droid, APKPure, APKMirror) appear immediately from cache
      // without waiting for the Play Store network round-trip.
      _maybeCheckAndCacheAllStores();
      // The version may have just bumped, in which case [SourceProvider.getApp]
      // cleared the cached size and we need to walk APKMirror again. The
      // resolver is a no-op when the size is still present.
      _attemptedApkMirrorSizeResolution = false;
      unawaited(_maybeLazyResolveApkMirrorSize());
      if (resetVersion) {
        appsProvider.apps[id]?.app.additionalSettings['versionDetection'] =
            true;
        if (appsProvider.apps[id]?.app.installedVersion != null) {
          appsProvider.apps[id]?.app.installedVersion =
              appsProvider.apps[id]?.app.latestVersion;
        }
        appsProvider.saveApps([appsProvider.apps[id]!.app]);
      }
    } catch (err) {
      if (err is RepositoryRenamedError && context.mounted) {
        await appsProvider.updatePendingRepoRename(id, err.newUrl);
      } else if (context.mounted) {
        // ignore: use_build_context_synchronously
        _showPageError(err, context);
      }
    } finally {
      if (context.mounted) {
        setState(() {
          updating = false;
        });
      }
    }
  }

  void _applyWebViewSurfaceColorIfNeeded(Color background) {
    if (_lastWebViewSurfaceColorApplied == background) return;
    _lastWebViewSurfaceColorApplied = background;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _webViewController.setBackgroundColor(background);
      }
    });
  }

  static const double _storeSourceIconSize = 40;

  Widget _buildStoreSourceLaunchIcon({
    required BuildContext iconContext,
    required String url,
    String? assetPath,
  }) {
    final ColorScheme colorScheme = Theme.of(iconContext).colorScheme;
    final Widget picture = assetPath != null
        ? StoreSourceIconImage(
            assetPath: assetPath,
            size: _storeSourceIconSize,
            errorBuilder: (context, error, stackTrace) => Icon(
              Icons.link,
              size: _storeSourceIconSize * 0.75,
              color: colorScheme.primary,
            ),
          )
        : StoreSourceIconForUrl(url: url, size: _storeSourceIconSize);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => launchUrlString(url, mode: LaunchMode.externalApplication),
        onLongPress: () {
          _toastUrl(url);
          Clipboard.setData(ClipboardData(text: url));
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: picture,
        ),
      ),
    );
  }

  Widget _detailRowTrackedSource(BuildContext ctx, String label, String url) {
    final String? assetPath = storeSourceAssetPathForUrl(url);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildStoreSourceLaunchIcon(
                iconContext: ctx,
                url: url,
                assetPath: assetPath,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.select<SettingsProvider, int>(appPageSettingsRebuildToken);
    context.select<AppsProvider, int>(
      (AppsProvider provider) =>
          appPageAppsRebuildToken(provider, widget.appId),
    );

    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    final SettingsProvider settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    final bool useIconPageColors = settingsProvider.matchAppPageToIconColors;
    var showAppWebpageFinal =
        (settingsProvider.showAppWebpage &&
            !widget.showOppositeOfPreferredView) ||
        (!settingsProvider.showAppWebpage &&
            widget.showOppositeOfPreferredView);

    bool areDownloadsRunning = appsProvider.areDownloadsRunning();

    AppInMemory? app = appsProvider.apps[widget.appId];
    if (!_requestedMissingIconLoad && app != null && app.icon == null) {
      _requestedMissingIconLoad = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Provider.of<AppsProvider>(
          context,
          listen: false,
        ).updateAppIcon(widget.appId, ignoreCache: false);
      });
    }
    if (widget.openInEditMode &&
        !_scheduledOpenInEditMode &&
        app != null &&
        !_editMode) {
      _scheduledOpenInEditMode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final AppInMemory? freshApp = Provider.of<AppsProvider>(
          context,
          listen: false,
        ).apps[widget.appId];
        if (freshApp != null) {
          _startEdit(freshApp, appsProvider);
        }
      });
    }
    var source = app != null
        ? _sourceProvider.getSource(
            app.app.url,
            overrideSource: app.app.overrideSource,
          )
        : null;

    final Uint8List? iconBytes = app?.icon;
    final Brightness themeBrightness = Theme.of(context).brightness;
    if (useIconPageColors && iconBytes != null) {
      final String iconSchemeCacheKey =
          '${identityHashCode(iconBytes)}_${themeBrightness.name}';
      if (_iconSchemeCacheKey != iconSchemeCacheKey &&
          _iconSchemeLoadingForKey != iconSchemeCacheKey &&
          _iconSchemeFailedCacheKey != iconSchemeCacheKey) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _startIconSchemeLoadIfNeeded(iconBytes, iconSchemeCacheKey);
        });
      }
    } else {
      if (_iconDerivedColorScheme != null ||
          _iconSchemeCacheKey != null ||
          _iconSchemeLoadingForKey != null ||
          _iconSchemeFailedCacheKey != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _iconDerivedColorScheme = null;
            _iconSchemeCacheKey = null;
            _iconSchemeLoadingForKey = null;
            _iconSchemeFailedCacheKey = null;
          });
        });
      }
    }

    final ThemeData parentThemeForPage = Theme.of(context);
    final bool applyIconDerivedPageTheming =
        useIconPageColors && _iconDerivedColorScheme != null;
    final ColorScheme pageColorSchemeForPage = !applyIconDerivedPageTheming
        ? parentThemeForPage.colorScheme
        : darkenIconPageSchemeInDarkMode(
            appPageSurfacesWithVisibleAccent(_iconDerivedColorScheme!),
          );
    final Brightness pageBrightness = pageColorSchemeForPage.brightness;
    // ThemeData.copyWith() is expensive — cache it and recompute only when the
    // icon scheme or parent brightness actually changes.
    final String pageThemeKey =
        '${_iconSchemeCacheKey ?? "none"}_${themeBrightness.name}';
    if (_cachedPageThemeKey != pageThemeKey || _cachedPageTheme == null) {
      _cachedPageThemeKey = pageThemeKey;
      _cachedPageTheme = buildAppPageThemedData(
        parentThemeForPage,
        pageColorSchemeForPage,
      );
    }
    final ThemeData pageThemeForPage = _cachedPageTheme!;

    if (!_scheduledDetailPageRefresh &&
        app != null &&
        settingsProvider.checkUpdateOnDetailPage &&
        app.app.additionalSettings['onDemandOnly'] != true &&
        !areDownloadsRunning) {
      _scheduledDetailPageRefresh = true;
      final String refreshAppId = app.app.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Let the push transition start before network + notifyListeners churn.
        Future<void>.delayed(const Duration(milliseconds: 320), () {
          if (mounted) {
            _runCheckUpdate(refreshAppId);
          }
        });
      });
    }
    var trackOnly = app?.app.additionalSettings['trackOnly'] == true;

    bool isVersionDetectionStandard =
        app?.app.additionalSettings['versionDetection'] == true;

    if (showAppWebpageFinal && app != null && !_webViewUrlLoaded) {
      _webViewUrlLoaded = true;
      final String webUrl = app.app.url;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _webViewController.loadRequest(Uri.parse(webUrl));
        }
      });
    }

    String formatDateTimeToMinute(DateTime dateTime) {
      final local = dateTime.toLocal();
      final year = local.year.toString();
      final month = local.month.toString().padLeft(2, '0');
      final day = local.day.toString().padLeft(2, '0');
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '$year-$month-$day $hour:$minute';
    }

    Widget detailRow(
      BuildContext ctx,
      String label,
      String value, {
      TextStyle? valueStyle,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: valueStyle ?? Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    Widget versionRow(BuildContext ctx, String label, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: _versionRowLabelWidth,
              child: Text(
                label,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                value,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget versionLatestRow(
      BuildContext ctx,
      String value, {
      required bool skipActive,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: _versionRowLabelWidth,
              child: Text(
                tr('latest'),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  SelectableText(
                    value,
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  if (skipActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        tr('latestVersionSkipped'),
                        style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget versionRowWithLink(
      BuildContext ctx,
      String label,
      String value,
      VoidCallback? onTap,
    ) {
      final linkStyle = Theme.of(ctx).textTheme.bodySmall?.copyWith(
        color: Theme.of(ctx).colorScheme.primary,
        decoration: onTap != null ? TextDecoration.underline : null,
        fontWeight: FontWeight.w500,
        fontSize: 14,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: _versionRowLabelWidth,
              child: Text(
                label,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: onTap,
                child: Text(value, style: linkStyle),
              ),
            ),
          ],
        ),
      );
    }

    Widget buildAboutBlock(BuildContext themeContext) {
      if (app?.app.additionalSettings['about'] is! String ||
          (app?.app.additionalSettings['about'] as String).isEmpty) {
        return const SizedBox.shrink();
      }
      final String aboutRaw = app?.app.additionalSettings['about'] as String;
      // GFM collapses single newlines; two spaces before newline = hard break so
      // multi-line notes match what was typed in the editor.
      final String aboutForMarkdown = aboutRaw
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .replaceAll('\n', '  \n');
      return GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: aboutRaw));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('copiedToClipboard')),
              duration: const Duration(seconds: 4),
            ),
          );
        },
        child: Markdown(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          styleSheet: MarkdownStyleSheet(
            blockquoteDecoration: BoxDecoration(
              color: Theme.of(themeContext).cardColor,
            ),
            textAlign: WrapAlignment.center,
          ),
          data: aboutForMarkdown,
          onTapLink: (text, href, title) {
            if (href != null) {
              launchUrlString(href, mode: LaunchMode.externalApplication);
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
      );
    }

    getInfoColumn(BuildContext pageThemeContext, {bool small = false}) {
      final ThemeData pageTheme = Theme.of(pageThemeContext);
      final undeterminedTrackOnlyInstalled =
          trackOnly &&
          app?.app.additionalSettings['trackOnlyUndeterminedInstalledVersion'] ==
              true &&
          app?.app.installedVersion == null;
      bool installed = app?.app.installedVersion != null;
      final String? installedVerStr = app?.app.installedVersion;
      final String latestVerStr = app?.app.latestVersion ?? '';
      final effectivelyEqual =
          installed &&
          installedVerStr != null &&
          installedVerStr != latestVerStr &&
          versionsEffectivelyEqual(installedVerStr, latestVerStr);
      final bool versionOrderUnclearState =
          installedVerStr != null &&
          latestVerStr.isNotEmpty &&
          versionOrderIsUnclear(installedVerStr, latestVerStr);
      final int? versionCmp = installedVerStr != null && latestVerStr.isNotEmpty
          ? compareVersionsByNumericSegments(installedVerStr, latestVerStr)
          : null;
      final bool newerOnDeviceState =
          installed &&
          installedVerStr != null &&
          installedVerStr != latestVerStr &&
          !effectivelyEqual &&
          versionCmp == 1;
      final bool sameVersionVerdict =
          installed &&
          installedVerStr != null &&
          latestVerStr.isNotEmpty &&
          !effectivelyEqual &&
          !versionOrderUnclearState &&
          versionCmp != 1 &&
          installedVersionIsNewerOrEqual(installedVerStr, latestVerStr);
      var changeLogFn = app != null ? getChangeLogFn(context, app.app) : null;

      final lastUpdateCheckLabel = tr(
        'lastUpdateCheckX',
        args: [tr('never')],
      ).split(':').first.trim();
      final lastUpdateCheckValue = app?.app.lastUpdateCheck == null
          ? tr('never')
          : formatDateTimeToMinute(app!.app.lastUpdateCheck!);

      Future<void> markTrackOnlyAsNotInstalledOnDevice() async {
        if (app == null) return;
        setState(() {
          updating = true;
        });
        try {
          final App appToSave = app.app.deepCopy();
          appToSave
                  .additionalSettings['trackOnlyUndeterminedInstalledVersion'] =
              false;
          await appsProvider.saveApps([appToSave]);
        } catch (err) {
          if (context.mounted) {
            _showPageError(err, context);
          }
        } finally {
          if (context.mounted) {
            setState(() {
              updating = false;
            });
          }
        }
      }

      Future<void> openFixTrackOnlyPackageIdDialog() async {
        if (app == null) return;
        final packageIdController = TextEditingController(text: app.app.id);
        final submittedPackageId = await _showPageDialog<String>(
          hostContext: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(tr('fixPackageId')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    tr('fixPackageIdExplanation'),
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: packageIdController,
                    decoration: InputDecoration(
                      labelText: tr('package'),
                      isDense: true,
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: updating ? null : () => Navigator.pop(dialogContext),
                child: Text(tr('cancel')),
              ),
              FilledButton(
                onPressed: updating
                    ? null
                    : () => Navigator.pop(
                        dialogContext,
                        packageIdController.text.trim(),
                      ),
                child: Text(tr('ok')),
              ),
            ],
          ),
        );
        packageIdController.dispose();
        if (!context.mounted) return;
        if (submittedPackageId == null || submittedPackageId.isEmpty) return;
        if (submittedPackageId == widget.appId) return;
        try {
          setState(() {
            updating = true;
          });
          await appsProvider.changeTrackOnlyAppPackageId(
            widget.appId,
            submittedPackageId,
          );
          if (!context.mounted) return;
          await appsProvider.checkUpdate(submittedPackageId);
          if (!context.mounted) return;
          Navigator.of(context).pushReplacement(
            heroFriendlyAppPageRoute<void>(
              (ctx) => AppPage(appId: submittedPackageId),
            ),
          );
        } catch (err) {
          if (context.mounted) {
            _showPageError(err, context);
          }
        } finally {
          if (context.mounted) {
            setState(() {
              updating = false;
            });
          }
        }
      }

      // #1 — verdict stripe (A: trailing icon, B: card watermark).
      Widget? verdictStripe;
      Widget? verdictWatermark;
      if (!undeterminedTrackOnlyInstalled) {
        Color? stripeColor;
        Color? stripeTextColor;
        String? stripeLabel;
        IconData? verdictIcon;
        if (effectivelyEqual) {
          stripeColor = pageTheme.colorScheme.surfaceContainerHigh;
          stripeTextColor = pageTheme.colorScheme.onSurfaceVariant;
          stripeLabel = tr('effectivelyEqual');
          verdictIcon = Icons.balance;
        } else if (installed && versionOrderUnclearState) {
          stripeColor = pageTheme.colorScheme.surfaceContainerHighest;
          stripeTextColor = pageTheme.colorScheme.onSurfaceVariant;
          stripeLabel = tr('versionOrderUnclear');
          verdictIcon = Icons.help_outline_rounded;
        } else if (newerOnDeviceState) {
          stripeColor = pageTheme.colorScheme.primaryContainer;
          stripeTextColor = pageTheme.colorScheme.onPrimaryContainer;
          stripeLabel = tr('newerOnDevice');
          verdictIcon = Icons.phone_android_rounded;
        } else if (sameVersionVerdict ||
            (installedVerStr != null && installedVerStr == latestVerStr)) {
          stripeColor = pageTheme.brightness == Brightness.dark
              ? const Color(0xFF2E7D32).withAlpha(60)
              : const Color(0xFFC8E6C9);
          stripeTextColor = pageTheme.brightness == Brightness.dark
              ? const Color(0xFFA5D6A7)
              : const Color(0xFF1B5E20);
          stripeLabel = tr('sameVersion');
          verdictIcon = Icons.verified_rounded;
        } else if (installed) {
          stripeColor = pageTheme.colorScheme.secondaryContainer;
          stripeTextColor = pageTheme.colorScheme.onSecondaryContainer;
          stripeLabel = tr('updateAvailable');
          verdictIcon = Icons.new_releases_rounded;
        } else if (!installed) {
          stripeColor = pageTheme.colorScheme.surfaceContainerHighest;
          stripeTextColor = pageTheme.colorScheme.onSurfaceVariant;
          stripeLabel = tr('notInstalled');
          verdictIcon = Icons.install_mobile_rounded;
        }
        if (stripeLabel != null && verdictIcon != null) {
          // A — trailing icon in the stripe.
          // Fix flush: use BoxDecoration with top-only borderRadius matching the
          // card's 28px corners so the stripe fills the curved corner areas and
          // no card-fill bleeds through at the top edges.
          verdictStripe = Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: stripeColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        stripeLabel,
                        style: pageTheme.textTheme.labelMedium?.copyWith(
                          color: stripeTextColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (versionOrderUnclearState)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            tr('versionOrderUnclearSubtitle'),
                            style: pageTheme.textTheme.bodySmall?.copyWith(
                              color: stripeTextColor?.withAlpha(210),
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(verdictIcon, size: 15, color: stripeTextColor),
              ],
            ),
          );
          // B — large faded watermark at bottom-right of the card body.
          verdictWatermark = Icon(
            verdictIcon,
            size: 52,
            color: stripeTextColor?.withAlpha(28),
          );
        }
      }

      // #4 — subtle "last checked" caption shown at the bottom of the version card.
      final Widget lastCheckedCaption = Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '$lastUpdateCheckLabel: $lastUpdateCheckValue',
          textAlign: TextAlign.right,
          style: pageTheme.textTheme.labelSmall?.copyWith(
            color: pageTheme.colorScheme.onSurfaceVariant.withAlpha(130),
            fontSize: 11,
          ),
        ),
      );

      final versionCardChildren = <Widget>[];
      if (undeterminedTrackOnlyInstalled) {
        versionCardChildren.add(
          versionRow(pageThemeContext, tr('installed'), tr('unknown')),
        );
        versionCardChildren.add(
          versionRow(
            pageThemeContext,
            tr('latest'),
            app?.app.latestVersion ?? '-',
          ),
        );
        if (changeLogFn != null || app?.app.releaseDate != null) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('changelog'),
              app?.app.releaseDate == null
                  ? tr('changes')
                  : formatDateTimeToMinute(app!.app.releaseDate!),
              changeLogFn,
            ),
          );
        }
        if ((app?.app.apkUrls.length ?? 0) > 0) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('assets'),
              app!.app.apkUrls.length == 1
                  ? app.app.apkUrls[0].key
                  : plural('apk', app.app.apkUrls.length),
              updating
                  ? null
                  : () async {
                      try {
                        await appsProvider.downloadAppAssets(
                          [app.app.id],
                          context,
                          dialogTheme: pageTheme,
                        );
                      } catch (e) {
                        if (!context.mounted) return;
                        _showPageError(e, context);
                      }
                    },
            ),
          );
        }
      } else {
        if (installed) {
          versionCardChildren.add(
            versionRow(
              pageThemeContext,
              tr('installed'),
              app?.app.installedVersion ?? '',
            ),
          );
        } else {
          versionCardChildren.add(
            versionRow(pageThemeContext, tr('installed'), tr('none')),
          );
        }
        versionCardChildren.add(
          versionLatestRow(
            pageThemeContext,
            latestVerStr.isEmpty ? '-' : latestVerStr,
            skipActive: app != null && isSkipActiveForCurrentLatest(app.app),
          ),
        );
        if (changeLogFn != null || app?.app.releaseDate != null) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('changelog'),
              app?.app.releaseDate == null
                  ? tr('changes')
                  : formatDateTimeToMinute(app!.app.releaseDate!),
              changeLogFn,
            ),
          );
        }
        if ((app?.app.apkUrls.length ?? 0) > 0) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('assets'),
              app!.app.apkUrls.length == 1
                  ? app.app.apkUrls[0].key
                  : plural('apk', app.app.apkUrls.length),
              updating
                  ? null
                  : () async {
                      try {
                        await appsProvider.downloadAppAssets(
                          [app.app.id],
                          context,
                          dialogTheme: pageTheme,
                        );
                      } catch (e) {
                        if (!context.mounted) return;
                        _showPageError(e, context);
                      }
                    },
            ),
          );
        }
      }

      // #4 — last-checked caption at the bottom.
      versionCardChildren.add(lastCheckedCaption);

      final versionCard = _materialAppPageSectionCard(
        pageThemeContext,
        tr('version'),
        versionCardChildren,
        headerStripe: verdictStripe,
        cardWatermark: verdictWatermark,
      );

      final bool trackOnlyUsesTemporaryPackageId =
          app?.app.additionalSettings['trackOnlyTemporaryPackageId'] == true;
      final Widget? trackOnlyInstalledErrorCard = undeterminedTrackOnlyInstalled
          ? _materialAppPageSectionCard(
              pageThemeContext,
              tr('error'),
              [
                SelectableText(
                  trackOnlyUsesTemporaryPackageId
                      ? tr('trackOnlyTempPackageIdInstalledVersion')
                      : tr('trackOnlyUndeterminedInstalledVersion'),
                  style: pageTheme.textTheme.bodySmall?.copyWith(
                    color: pageTheme.colorScheme.onErrorContainer,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: updating || app == null
                          ? null
                          : openFixTrackOnlyPackageIdDialog,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      label: Text(tr('fixPackageId')),
                    ),
                    FilledButton.tonal(
                      onPressed: updating || app == null
                          ? null
                          : markTrackOnlyAsNotInstalledOnDevice,
                      child: Text(tr('itsNotInstalled')),
                    ),
                  ],
                ),
              ],
              sectionBackgroundColor: pageTheme.colorScheme.errorContainer,
              sectionTitleColor: pageTheme.colorScheme.onErrorContainer,
            )
          : null;

      final detailsValueStyle = pageTheme.textTheme.bodySmall!.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      );
      final detailsMonoValueStyle = detailsValueStyle.copyWith(
        fontFamily: 'monospace',
      );

      final String? alternateStoresPackageId = app?.app.id;
      final String? alternateStoresTrackedUrl = app?.app.url;

      final detailsChildren = <Widget>[
        if (app?.app.id != null && app!.app.id.isNotEmpty)
          detailRow(
            pageThemeContext,
            tr('package'),
            app.app.id,
            valueStyle: detailsMonoValueStyle,
          ),
        if (app?.installedInfo != null)
          () {
            final appType = classifyAppType(app!);
            final (
              IconData typeIcon,
              Color typeColor,
              String typeLabel,
            ) = switch (appType) {
              AppTypeGroup.user => (
                Icons.person_rounded,
                Colors.green,
                tr('appTypeUser'),
              ),
              AppTypeGroup.system => (
                Icons.android_rounded,
                Colors.grey,
                tr('appTypeSystem'),
              ),
              AppTypeGroup.privileged => (
                Icons.security_rounded,
                Colors.grey.shade600,
                tr('appTypePrivileged'),
              ),
            };
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(
                      tr('appType'),
                      style: Theme.of(pageThemeContext).textTheme.bodySmall
                          ?.copyWith(
                            color: Theme.of(
                              pageThemeContext,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                    ),
                  ),
                  Icon(typeIcon, size: 14, color: typeColor),
                  const SizedBox(width: 4),
                  Text(
                    typeLabel,
                    style: Theme.of(pageThemeContext).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          }(),
        if (app?.app.url != null && app!.app.url.isNotEmpty)
          _detailRowTrackedSource(
            pageThemeContext,
            tr('trackedSource'),
            app.app.url,
          ),
        if (alternateStoresPackageId != null &&
            alternateStoresPackageId.isNotEmpty)
          FutureBuilder<Map<String, String>?>(
            future: _storeAvailabilityCacheFuture,
            builder: (context, snapshot) {
              final storeData = snapshot.data;
              final pid = alternateStoresPackageId;
              final trackedUrl = alternateStoresTrackedUrl;

              // Play Store: only show when confirmed present in cache.
              // Populated by _maybeCheckAndCachePlayStore on pull-to-refresh.
              final playStoreUrl = _resolveStoreUrl(
                storeData: storeData,
                storeName: 'PlayStore',
                fallbackUrl: null,
                alreadyTracked: _trackedUrlIsFromHost(
                  trackedUrl,
                  'play.google.com',
                ),
              );

              final fdroidUrl = _resolveStoreUrl(
                storeData: storeData,
                storeName: 'F-Droid',
                fallbackUrl: 'https://f-droid.org/packages/$pid/',
                alreadyTracked: _trackedUrlIsFromHost(
                  trackedUrl,
                  'f-droid.org',
                ),
              );

              final apkpureUrl = _resolveStoreUrl(
                storeData: storeData,
                storeName: 'APKPure',
                fallbackUrl:
                    null, // search-by-package-ID is not useful; only show confirmed URL
                alreadyTracked: _trackedUrlIsFromHost(trackedUrl, 'apkpure.'),
              );

              final apkmirrorUrl = _resolveStoreUrl(
                storeData: storeData,
                storeName: 'APKMirror',
                fallbackUrl:
                    'https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=${Uri.encodeComponent(pid)}',
                alreadyTracked: _trackedUrlIsFromHost(
                  trackedUrl,
                  'apkmirror.com',
                ),
              );

              if (playStoreUrl == null &&
                  fdroidUrl == null &&
                  apkpureUrl == null &&
                  apkmirrorUrl == null) {
                return const SizedBox.shrink();
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text(
                        tr('otherSources'),
                        style: pageTheme.textTheme.bodySmall?.copyWith(
                          color: pageTheme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (playStoreUrl != null)
                            _buildStoreSourceLaunchIcon(
                              iconContext: pageThemeContext,
                              url: playStoreUrl,
                              assetPath: StoreSourceIconPaths.playStore,
                            ),
                          if (fdroidUrl != null)
                            _buildStoreSourceLaunchIcon(
                              iconContext: pageThemeContext,
                              url: fdroidUrl,
                              assetPath: StoreSourceIconPaths.fdroid,
                            ),
                          if (apkpureUrl != null)
                            _buildStoreSourceLaunchIcon(
                              iconContext: pageThemeContext,
                              url: apkpureUrl,
                              assetPath: StoreSourceIconPaths.apkpure,
                            ),
                          if (apkmirrorUrl != null)
                            _buildStoreSourceLaunchIcon(
                              iconContext: pageThemeContext,
                              url: apkmirrorUrl,
                              assetPath: StoreSourceIconPaths.apkmirror,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 100,
                child: Text(
                  tr('categories'),
                  style: pageTheme.textTheme.bodySmall?.copyWith(
                    color: pageTheme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: (app?.app.categories ?? []).isEmpty
                    ? Text(tr('none'), style: detailsValueStyle)
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        alignment: WrapAlignment.start,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ...(app?.app.categories ?? []).map((categoryName) {
                            final colorArgb =
                                settingsProvider.categories[categoryName];
                            if (colorArgb != null) {
                              final fill = Color(colorArgb);
                              return Chip(
                                label: Text(
                                  categoryName,
                                  style: TextStyle(
                                    color: _labelColorOnCategoryFill(fill),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                backgroundColor: fill,
                                side: BorderSide.none,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 2,
                                ),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              );
                            }
                            return Chip(
                              label: Text(
                                categoryName,
                                style: detailsValueStyle,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            );
                          }),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ];
      final detailsCard = _materialAppPageSectionCard(
        pageThemeContext,
        tr('details'),
        detailsChildren,
      );

      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          ?trackOnlyInstalledErrorCard,
          versionCard,
          detailsCard,
          if (app?.app.additionalSettings['about'] is String &&
              app?.app.additionalSettings['about'].isNotEmpty)
            _materialAppPageSectionCard(pageThemeContext, tr('notes'), [
              buildAboutBlock(pageThemeContext),
            ]),
        ],
      );
    }

    Widget buildDetailHeroContent(BuildContext themeContext) {
      const double heroScale = 1.2;
      const heroIconSize = 58.0;
      final scaledIconSize = heroIconSize * heroScale;
      final titleStyle = Theme.of(themeContext).textTheme.titleLarge;
      final bylineStyle = Theme.of(themeContext).textTheme.bodySmall;
      final String listHeroTag = widget.appsListHeroFolderId != null
          ? 'folder-${widget.appsListHeroFolderId}-icon-${widget.appId}'
          : 'app-icon-${widget.appId}';
      final iconWidget = _tappableAppIconDisplay(
        themeContext: themeContext,
        appInMemory: app,
        size: scaledIconSize,
        borderRadius: 16,
        heroTag: listHeroTag,
        iconMemoryBytes: _heroIconMemoryOverrideForEdit(app),
        exclusiveIconMemoryBytes: _editStagedClearOverride,
        onTap: _editMode
            ? null
            : (app?.installedInfo != null
                  ? () => pm.openApp(widget.appId)
                  : null),
        emptyPlaceholder: Container(
          height: scaledIconSize,
          width: scaledIconSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Theme.of(themeContext).colorScheme.primary,
                Theme.of(themeContext).colorScheme.primary.withAlpha(200),
              ],
            ),
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                iconWidget,
                const SizedBox(width: 12 * heroScale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_editMode)
                        ListenableBuilder(
                          listenable: _nameController,
                          builder: (BuildContext context, Widget? child) {
                            final ColorScheme heroScheme = Theme.of(
                              themeContext,
                            ).colorScheme;
                            final String previewText =
                                _nameController.text.isEmpty
                                ? tr('app')
                                : _nameController.text;
                            return Text(
                              previewText,
                              style: titleStyle?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize:
                                    (titleStyle.fontSize ?? 22) *
                                    heroScale *
                                    1.06,
                                color: _nameController.text.isEmpty
                                    ? heroScheme.onSurfaceVariant
                                    : null,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        )
                      else
                        Text(
                          app?.name ?? tr('app'),
                          style: titleStyle?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize:
                                (titleStyle.fontSize ?? 22) * heroScale * 1.06,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 2 * heroScale),
                      Text(
                        tr('byX', args: [app?.author ?? tr('unknown')]),
                        style: bylineStyle?.copyWith(
                          color: Theme.of(
                            themeContext,
                          ).colorScheme.onSurfaceVariant,
                          fontSize:
                              (bylineStyle.fontSize ?? 12) * heroScale * 1.08,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    getFullInfoColumn(BuildContext themeContext, {bool small = false}) {
      final ThemeData dialogColumnTheme = Theme.of(themeContext);
      const heroIconSize = 48.0;
      final double dialogIconSize = small ? 70 : heroIconSize;
      final double dialogIconRadius = small ? 12 : 16;
      final iconWidget = _tappableAppIconDisplay(
        themeContext: themeContext,
        appInMemory: app,
        size: dialogIconSize,
        borderRadius: dialogIconRadius,
        iconMemoryBytes: _heroIconMemoryOverrideForEdit(app),
        exclusiveIconMemoryBytes: _editStagedClearOverride,
        emptyPlaceholder: small
            ? const SizedBox(height: 70, width: 70)
            : Container(
                height: heroIconSize,
                width: heroIconSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      dialogColumnTheme.colorScheme.primary,
                      dialogColumnTheme.colorScheme.primary.withAlpha(200),
                    ],
                  ),
                ),
              ),
      );

      if (small) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 0),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [iconWidget],
            ),
            const SizedBox(height: 10),
            Text(
              app?.name ?? tr('app'),
              textAlign: TextAlign.center,
              style: dialogColumnTheme.textTheme.displaySmall,
            ),
            Text(
              tr('byX', args: [app?.author ?? tr('unknown')]),
              textAlign: TextAlign.center,
              style: dialogColumnTheme.textTheme.headlineSmall,
            ),
            SizedBox(height: settingsProvider.highlightTouchTargets ? 2 : 8),
            getInfoColumn(themeContext, small: true),
            const SizedBox(height: 24),
          ],
        );
      }

      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                iconWidget,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        app?.name ?? tr('app'),
                        style: dialogColumnTheme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr('byX', args: [app?.author ?? tr('unknown')]),
                        style: dialogColumnTheme.textTheme.bodySmall?.copyWith(
                          color: dialogColumnTheme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildRepoRenameWarning(
                          app: app,
                          appsProvider: appsProvider,
                          onUpdate: (String appId) async {
                            await _runCheckUpdate(appId);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          getInfoColumn(themeContext, small: false),
          const SizedBox(height: 24),
        ],
      );
    }

    Widget getAppWebView(BuildContext themeContext) {
      if (app == null) return const SizedBox.shrink();
      final Color webViewSurface =
          Color.lerp(
            Theme.of(themeContext).colorScheme.surface,
            Colors.black,
            Theme.of(themeContext).brightness == Brightness.dark
                ? 0.055
                : 0.045,
          ) ??
          Theme.of(themeContext).colorScheme.surface;
      _applyWebViewSurfaceColorIfNeeded(webViewSurface);
      return WebViewWidget(
        key: ObjectKey(_webViewController),
        controller: _webViewController,
      );
    }

    showMarkUpdatedDialog() {
      return _showPageDialog(
        hostContext: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            title: Text(tr('alreadyUpToDateQuestion')),
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
                  final App? updatedApp = app?.app.deepCopy();
                  if (updatedApp != null) {
                    updatedApp.installedVersion = updatedApp.latestVersion;
                    updatedApp.additionalSettings.remove(
                      'skippedLatestVersion',
                    );
                    appsProvider.saveApps([updatedApp]);
                  }
                  Navigator.of(context).pop();
                },
                child: Text(tr('yesMarkUpdated')),
              ),
            ],
          );
        },
      );
    }

    getBottomCenterActions(BuildContext themeContext) {
      final ThemeData actionTheme = Theme.of(themeContext);
      const double expressiveRadius = 26;
      const EdgeInsets expressivePadding = EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      );
      const Size expressiveMinimumSize = Size(48, 52);
      final RoundedRectangleBorder expressiveShape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(expressiveRadius),
      );
      const Size expressiveMaximumSize = Size(double.infinity, 52);
      final ButtonStyle expressiveFilled = FilledButton.styleFrom(
        minimumSize: expressiveMinimumSize,
        maximumSize: expressiveMaximumSize,
        padding: expressivePadding,
        shape: expressiveShape,
        elevation: 1,
        shadowColor: actionTheme.colorScheme.shadow,
        backgroundColor: actionTheme.colorScheme.primary,
        foregroundColor: actionTheme.colorScheme.onPrimary,
        disabledBackgroundColor: actionTheme.colorScheme.onSurface.withAlpha(
          31,
        ),
        disabledForegroundColor: actionTheme.colorScheme.onSurface.withAlpha(
          97,
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

      if (_editMode) {
        return const SizedBox.shrink();
      }

      // Update label shows size when known from the source metadata.
      final int? knownApkSizeBytes = app?.app.apkSizeBytes;
      // Appends "· 43 MB" to install/update labels when size is known.
      String sizeAnnotated(String base) {
        if (knownApkSizeBytes == null) {
          return base;
        }
        return '$base · ${_formatBytes(knownApkSizeBytes)}';
      }

      final String updateLabel = sizeAnnotated(tr('update'));
      final String installLabel = sizeAnnotated(tr('install'));
      final String markInstalledLabel = sizeAnnotated(tr('markInstalled'));
      final String markUpdatedLabel = sizeAnnotated(tr('markUpdated'));

      // #2 — inline progress button replaces the action button while downloading/installing.
      if (app?.downloadProgress != null) {
        final double dp = app!.downloadProgress!;
        final bool isInstalling = dp < 0;
        final int? totalBytes = app.downloadTotalBytes;
        final String bytesLabel = !isInstalling && totalBytes != null
            ? ' · ${_formatBytes((dp / 100 * totalBytes).round())} / ${_formatBytes(totalBytes)}'
            : '';
        final String label = isInstalling
            ? '${tr('installing')}…'
            : 'Downloading ${dp.round()}%$bytesLabel';
        final Widget progressBar = ClipRRect(
          borderRadius: BorderRadius.circular(expressiveRadius),
          child: SizedBox(
            height: 52,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  color: actionTheme.colorScheme.onSurface.withAlpha(31),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: isInstalling ? 1.0 : dp / 100,
                    child: Container(
                      color: actionTheme.colorScheme.primary.withAlpha(
                        isInstalling ? 55 : 220,
                      ),
                    ),
                  ),
                ),
                if (isInstalling)
                  LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                    color: actionTheme.colorScheme.primary.withAlpha(120),
                  ),
                Center(
                  child: Text(
                    label,
                    style: actionTheme.textTheme.labelLarge?.copyWith(
                      color: actionTheme.colorScheme.onSurface.withAlpha(200),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            progressBar,
            if (!isInstalling)
              Center(
                child: TextButton(
                  onPressed: () => appsProvider.cancelDownload(app.app.id),
                  child: Text(tr('cancel')),
                ),
              ),
          ],
        );
      }

      final bool actionBlocked = updating || areDownloadsRunning;
      final installedVersion = app?.app.installedVersion;
      final bool installedVersionIsNull = installedVersion == null;
      final bool actionableUpdate =
          app != null && appHasActionableUpdate(app.app);
      final bool uncertainUpdate =
          app != null && versionOrderUncertainUpdate(app.app);
      final bool skipActive =
          app != null && isSkipActiveForCurrentLatest(app.app);
      final bool trackOnlyHasVersionUpdate =
          trackOnly && (actionableUpdate || uncertainUpdate);
      final bool nonStandardVersionBehind =
          !trackOnly &&
          !isVersionDetectionStandard &&
          (actionableUpdate || uncertainUpdate);
      // Version order unclear: user should use Update and/or Skip only; no manual
      // "mark as latest" second button (mutually exclusive with actionableUpdate).
      final bool uncertainOnly = uncertainUpdate;
      final bool primaryActionEnabled =
          !actionBlocked &&
          (installedVersionIsNull ||
              ((actionableUpdate || uncertainUpdate) && !skipActive));
      final bool trackedFromApkMirror =
          Uri.tryParse(app?.app.url ?? '')?.host.contains('apkmirror.com') ==
          true;
      if (trackedFromApkMirror) {
        _logApkMirrorSizeDebugFromAppPage(
          'button id=${app?.app.id ?? "<null>"} url=${app?.app.url ?? "<null>"} size=${knownApkSizeBytes?.toString() ?? "<null>"} trackOnly=$trackOnly installed=${installedVersion ?? "<null>"} latest=${app?.app.latestVersion ?? "<null>"} actionable=$actionableUpdate uncertain=$uncertainUpdate skip=$skipActive trackOnlyHasVersionUpdate=$trackOnlyHasVersionUpdate installedVersionIsNull=$installedVersionIsNull primaryActionEnabled=$primaryActionEnabled updateLabel="$updateLabel" markUpdatedLabel="$markUpdatedLabel"',
        );
      }

      Widget wrapPrimaryBarWithSkip(Widget primaryBar) {
        final App? appForSkip = app?.app;
        if (appForSkip == null || appForSkip.installedVersion == null) {
          return primaryBar;
        }
        final bool showSkipToggle =
            appHasActionableUpdate(appForSkip) ||
            versionOrderUncertainUpdate(appForSkip) ||
            isSkipActiveForCurrentLatest(appForSkip);
        if (!showSkipToggle) {
          return primaryBar;
        }
        Future<void> toggleSkipVersion() async {
          if (app == null) return;
          final App copy = app.app.deepCopy();
          if (isSkipActiveForCurrentLatest(copy)) {
            copy.additionalSettings.remove('skippedLatestVersion');
          } else {
            copy.additionalSettings['skippedLatestVersion'] =
                copy.latestVersion;
          }
          await appsProvider.saveApps([copy]);
          if (mounted) {
            setState(() {});
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            primaryBar,
            Center(
              child: TextButton(
                onPressed: actionBlocked ? null : () => toggleSkipVersion(),
                child: Text(
                  isSkipActiveForCurrentLatest(appForSkip)
                      ? tr('unskipVersion')
                      : tr('skipVersion'),
                ),
              ),
            ),
          ],
        );
      }

      Future<void> runInstallOrMarkUpdated() async {
        try {
          final successMessage = installedVersionIsNull
              ? tr('installed')
              : tr('appsUpdated');
          HapticFeedback.heavyImpact();
          final res = await appsProvider.downloadAndInstallLatestApps(
            app?.app.id != null ? [app!.app.id] : [],
            context,
            dialogTheme: _cachedPageTheme,
          );
          if (res.isNotEmpty && !trackOnly && context.mounted) {
            _showPageMessage(successMessage, context);
          }
        } catch (e) {
          if (context.mounted) {
            _showPageError(e, context);
          }
        }
      }

      void openTrackOnlyReleasePage() {
        if (app == null) return;
        launchUrlString(
          trackOnlyDownloadPageUrl(app.app),
          mode: LaunchMode.externalApplication,
        );
      }

      if (trackOnlyHasVersionUpdate && !uncertainOnly) {
        // Outer Row is in a Column with unbounded max height. A nested Row of
        // two horizontal Expanded children + stretch can get infinite cross-axis
        // extent and break layout (blank page). Fixed height bounds the inner Row.
        const double dualButtonBarHeight = 52;
        return wrapPrimaryBarWithSkip(
          SizedBox(
            height: dualButtonBarHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: actionBlocked || skipActive
                        ? null
                        : openTrackOnlyReleasePage,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        updateLabel,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: actionBlocked ? null : runInstallOrMarkUpdated,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        tr('markUpdated'),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      if (trackOnlyHasVersionUpdate && uncertainOnly) {
        return wrapPrimaryBarWithSkip(
          FilledButton(
            style: expressiveFilled,
            onPressed: actionBlocked || skipActive
                ? null
                : openTrackOnlyReleasePage,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Text(
                updateLabel,
                maxLines: 1,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }

      if (nonStandardVersionBehind && !uncertainOnly) {
        const double dualButtonBarHeight = 52;
        final bool markUpdatedActionBlocked =
            updating || app.downloadProgress != null;
        return wrapPrimaryBarWithSkip(
          SizedBox(
            height: dualButtonBarHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: actionBlocked || skipActive
                        ? null
                        : runInstallOrMarkUpdated,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        updateLabel,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: markUpdatedActionBlocked
                        ? null
                        : showMarkUpdatedDialog,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        tr('markUpdated'),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      if (nonStandardVersionBehind && uncertainOnly) {
        return wrapPrimaryBarWithSkip(
          FilledButton(
            style: expressiveFilled,
            onPressed: actionBlocked || skipActive
                ? null
                : runInstallOrMarkUpdated,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Text(
                updateLabel,
                maxLines: 1,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }

      final Widget singlePrimaryButton = FilledButton(
        style: expressiveFilled,
        onPressed: primaryActionEnabled ? runInstallOrMarkUpdated : null,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Text(
            installedVersionIsNull
                ? (!trackOnly ? installLabel : markInstalledLabel)
                : (!trackOnly ? updateLabel : markUpdatedLabel),
            maxLines: 1,
            textAlign: TextAlign.center,
          ),
        ),
      );
      return wrapPrimaryBarWithSkip(
        skipActive
            ? Tooltip(
                message: tr('updateDisabledWhileVersionSkipped'),
                child: singlePrimaryButton,
              )
            : singlePrimaryButton,
      );
    }

    getBottomSheetMenu(BuildContext themeContext) => _MeasureSize(
      onChanged: (Size size) {
        if ((_bottomSheetMenuHeight - size.height).abs() < 0.5) {
          return;
        }
        setState(() {
          _bottomSheetMenuHeight = size.height;
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(themeContext).brightness == Brightness.dark
              ? Theme.of(themeContext).colorScheme.surfaceContainerHigh
              : Theme.of(themeContext).colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(
              color: Theme.of(themeContext).brightness == Brightness.dark
                  ? Theme.of(
                      themeContext,
                    ).colorScheme.outlineVariant.withAlpha(140)
                  : Theme.of(
                      themeContext,
                    ).colorScheme.outlineVariant.withAlpha(70),
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(themeContext).colorScheme.shadow.withAlpha(
                Theme.of(themeContext).brightness == Brightness.dark ? 130 : 40,
              ),
              blurRadius: Theme.of(themeContext).brightness == Brightness.dark
                  ? 18
                  : 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Builder(
                  builder: (BuildContext _) {
                    final List<Widget> bottomBarActions = <Widget>[];
                    if (app != null && app.installedInfo != null) {
                      bottomBarActions.add(
                        IconButton(
                          color: Theme.of(themeContext).colorScheme.primary,
                          iconSize: 24,
                          onPressed: () {
                            appsProvider.openAppSettings(app.app.id);
                          },
                          icon: const Icon(Icons.info_outline),
                          tooltip: tr('appPageAppInfo'),
                        ),
                      );
                    }
                    if (app != null &&
                        !_editMode &&
                        app.downloadProgress == null &&
                        !updating) {
                      bottomBarActions.add(
                        IconButton(
                          color: Theme.of(themeContext).colorScheme.primary,
                          iconSize: 24,
                          onPressed: () => _startEdit(app, appsProvider),
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: tr('editAppInfo'),
                        ),
                      );
                    }
                    if (source != null) {
                      bottomBarActions.add(
                        IconButton(
                          color: Theme.of(themeContext).colorScheme.primary,
                          iconSize: 24,
                          onPressed: app?.downloadProgress != null || updating
                              ? null
                              : () async {
                                  await Navigator.push<void>(
                                    context,
                                    slideUpPageRoute(
                                      (_) => AdditionalOptionsPage(
                                        appId: widget.appId,
                                        onAfterSave:
                                            (
                                              String savedAppId,
                                              bool versionDetectionJustEnabled,
                                            ) async {
                                              await _runCheckUpdate(
                                                savedAppId,
                                                resetVersion:
                                                    versionDetectionJustEnabled,
                                              );
                                            },
                                      ),
                                    ),
                                  );
                                },
                          tooltip: tr('appOptions'),
                          icon: const Icon(Icons.tune),
                        ),
                      );
                    }
                    if (app != null && showAppWebpageFinal) {
                      bottomBarActions.add(
                        IconButton(
                          color: Theme.of(themeContext).colorScheme.primary,
                          iconSize: 24,
                          onPressed: () {
                            showDialog<void>(
                              context: context,
                              builder: (BuildContext dialogRouteContext) {
                                return Theme(
                                  data: pageThemeForPage,
                                  child: Builder(
                                    builder:
                                        (BuildContext dialogThemedContext) {
                                          return AlertDialog(
                                            scrollable: true,
                                            content: getFullInfoColumn(
                                              dialogThemedContext,
                                              small: true,
                                            ),
                                            title: Text(app.name),
                                            actions: [
                                              TextButton(
                                                onPressed: () {
                                                  Navigator.of(
                                                    dialogRouteContext,
                                                  ).pop();
                                                },
                                                child: Text(tr('continue')),
                                              ),
                                            ],
                                          );
                                        },
                                  ),
                                );
                              },
                            );
                          },
                          icon: const Icon(Icons.more_horiz),
                          tooltip: tr('more'),
                        ),
                      );
                    }
                    if ((!isVersionDetectionStandard || trackOnly) &&
                        app?.app.installedVersion != null) {
                      final String ins = app!.app.installedVersion!;
                      final String lat = app.app.latestVersion;
                      final bool showResetInstall =
                          ins == lat ||
                          versionsEffectivelyEqual(ins, lat) ||
                          (installedVersionIsNewerOrEqual(ins, lat) &&
                              !versionOrderIsUnclear(ins, lat));
                      if (showResetInstall) {
                        bottomBarActions.add(
                          IconButton(
                            color: Theme.of(themeContext).colorScheme.primary,
                            iconSize: 24,
                            onPressed: updating
                                ? null
                                : () {
                                    app.app.installedVersion = null;
                                    appsProvider.saveApps([app.app]);
                                  },
                            icon: const Icon(Icons.restore_rounded),
                            tooltip: tr('resetInstallStatus'),
                          ),
                        );
                      }
                    }
                    bottomBarActions.add(
                      IconButton(
                        color: Theme.of(themeContext).colorScheme.primary,
                        iconSize: 24,
                        onPressed: app?.downloadProgress != null || updating
                            ? null
                            : () async {
                                final ScaffoldMessengerState? messenger =
                                    scaffoldMessengerKey.currentState;
                                final AppInMemory? appRow = app;
                                if (appRow == null) return;
                                final RemoveAppsWithModalResult removeResult =
                                    await appsProvider.removeAppsWithModal(
                                      themeContext,
                                      [appRow.app],
                                    );
                                if (removeResult.shouldShowSnackBar &&
                                    messenger != null) {
                                  final Set<String> undoAppIds =
                                      removeResult.deferredUndoAppIds;
                                  messenger
                                    ..clearSnackBars()
                                    ..showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          tr('xAppsRemoved', args: ['1']),
                                        ),
                                        persist: false,
                                        duration: const Duration(seconds: 5),
                                        behavior: SnackBarBehavior.floating,
                                        action: undoAppIds.isNotEmpty
                                            ? SnackBarAction(
                                                label: tr('undo'),
                                                onPressed: () => appsProvider
                                                    .undoDeferredObtainiumRemovals(
                                                      undoAppIds,
                                                    ),
                                              )
                                            : null,
                                      ),
                                    );
                                }
                                if (removeResult
                                        .obtainiumEntryRemovedOrScheduled &&
                                    themeContext.mounted) {
                                  Navigator.of(themeContext).pop();
                                }
                              },
                        tooltip: tr('remove'),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    );
                    return Row(
                      children: [
                        for (final Widget actionWidget in bottomBarActions)
                          Expanded(child: Center(child: actionWidget)),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Theme(
      data: pageThemeForPage,
      child: Builder(
        builder: (BuildContext themedPageContext) {
          return PopScope(
            canPop: !_editMode,
            onPopInvokedWithResult: (bool didPop, dynamic result) async {
              if (didPop) return;
              // If canPop was false, we're in edit mode.
              // Handle unsaved changes before allowing a pop.
              final AppInMemory? freshApp = Provider.of<AppsProvider>(
                themedPageContext,
                listen: false,
              ).apps[widget.appId];

              // If not dirty, just exit/pop without a dialog.
              if (!_isEditDirty(freshApp)) {
                if (widget.openInEditMode && mounted) {
                  Navigator.of(themedPageContext).pop();
                } else {
                  _exitEditWithoutSaving();
                }
                return;
              }

              // If dirty, show the dialog
              final _UnsavedAction? action = await _showUnsavedChangesDialog(
                themedPageContext,
                pageThemeForPage,
              );

              if (!themedPageContext.mounted || freshApp == null) return;

              bool shouldPopPage = false;

              switch (action) {
                case _UnsavedAction.discard:
                  _exitEditWithoutSaving();
                  if (widget.openInEditMode) {
                    shouldPopPage = true;
                  }
                  break;
                case _UnsavedAction.saveAndExit:
                  final appsProvider = Provider.of<AppsProvider>(
                    themedPageContext,
                    listen: false,
                  );
                  await _saveEdit(freshApp, appsProvider);
                  if (widget.openInEditMode) {
                    shouldPopPage = true;
                  }
                  break;
                case _UnsavedAction.keepEditing:
                default:
                  // Do nothing, stay on the page in edit mode.
                  break;
              }

              if (shouldPopPage && themedPageContext.mounted) {
                Navigator.of(themedPageContext).pop();
              }
            },
            child: Scaffold(
              resizeToAvoidBottomInset: true,
              appBar: showAppWebpageFinal ? AppBar() : null,
              backgroundColor: appPageDeeperSurfaceColor(
                pageColorSchemeForPage.surface,
                pageBrightness,
              ),
              floatingActionButton: _editModeFloatingActionButtons(
                themedPageContext,
                app,
                appsProvider,
                pageThemeForPage,
              ),
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.endFloat,
              body: RefreshIndicator(
                displacement: 20,
                child: showAppWebpageFinal
                    ? getAppWebView(themedPageContext)
                    : CustomScrollView(
                        controller: _appPageScrollController,
                        cacheExtent: 1600,
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        slivers: [
                          SliverToBoxAdapter(
                            child: SafeArea(
                              top: true,
                              bottom: false,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.arrow_back),
                                          // Pin to the per-app PRIMARY
                                          // colour. The previous attempt
                                          // used [colorScheme.onSurface],
                                          // which on light themes is a
                                          // near-black and on dark themes
                                          // a near-white - effectively the
                                          // same value the main app theme
                                          // produces, so the per-app tint
                                          // wasn't visible.
                                          // [colorScheme.primary] is the
                                          // accent derived from this app's
                                          // icon, so the back button now
                                          // visibly belongs to the page.
                                          color: pageThemeForPage
                                              .colorScheme
                                              .primary,
                                          onPressed: updating
                                              ? null
                                              : () => Navigator.of(
                                                  themedPageContext,
                                                ).maybePop(),
                                          tooltip: MaterialLocalizations.of(
                                            themedPageContext,
                                          ).backButtonTooltip,
                                        ),
                                        Expanded(
                                          child: buildDetailHeroContent(
                                            themedPageContext,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_editMode && app != null)
                                      _buildEditMetadataSection(
                                        themedPageContext,
                                        app,
                                        appsProvider,
                                        settingsProvider,
                                      )
                                    else
                                      getInfoColumn(
                                        themedPageContext,
                                        small: false,
                                      ),
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        16,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: getBottomCenterActions(
                                              themedPageContext,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_editMode) const SizedBox(height: 104),
                                    SizedBox(height: _bottomSheetMenuHeight),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                onRefresh: () async {
                  if (_editMode) return;
                  if (app != null) {
                    await _runCheckUpdate(app.app.id);
                  }
                },
              ),
              bottomSheet: getBottomSheetMenu(themedPageContext),
            ),
          );
        },
      ),
    );
  }
}
