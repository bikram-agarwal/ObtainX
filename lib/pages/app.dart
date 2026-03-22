import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:provider/provider.dart';
import 'package:markdown/markdown.dart' as md;

Color _labelColorOnCategoryFill(Color categoryFill) {
  return categoryFill.computeLuminance() > 0.5
      ? const Color(0xFF1A1A1A)
      : const Color(0xFFF5F5F5);
}

bool _trackedUrlMatchesPlayStore(String? trackedUrl, String packageId) {
  if (trackedUrl == null ||
      trackedUrl.isEmpty ||
      packageId.isEmpty) {
    return false;
  }
  final uri = Uri.tryParse(trackedUrl);
  if (uri == null || uri.host.isEmpty) return false;
  final host = uri.host.toLowerCase();
  if (!host.contains('play.google.com')) return false;
  final idParam = uri.queryParameters['id'];
  if (idParam == packageId) return true;
  return uri.path.contains(packageId);
}

/// True when the tracked source URL is already on F-Droid (hide F-Droid chip).
bool _trackedUrlMatchesFdroid(String? trackedUrl) {
  if (trackedUrl == null || trackedUrl.isEmpty) return false;
  final uri = Uri.tryParse(trackedUrl);
  if (uri == null || uri.host.isEmpty) return false;
  return uri.host.toLowerCase().contains('f-droid.org');
}

/// True when the tracked source URL is already on APKMirror (hide APKMirror chip).
bool _trackedUrlMatchesApkmirror(String? trackedUrl) {
  if (trackedUrl == null || trackedUrl.isEmpty) return false;
  final uri = Uri.tryParse(trackedUrl);
  if (uri == null || uri.host.isEmpty) return false;
  return uri.host.toLowerCase().contains('apkmirror.com');
}

void _toastUrl(String url) {
  Fluttertoast.showToast(
    msg: url,
    toastLength: Toast.LENGTH_LONG,
    timeInSecForIosWeb: 5,
  );
}

/// Surfaces from [ColorScheme.fromImageProvider] are often very dark in dark mode;
/// blend them toward [ColorScheme.primary] so the hue reads clearly on the app page.
ColorScheme _appPageSurfacesWithVisibleAccent(ColorScheme scheme) {
  final double surfaceTint = scheme.brightness == Brightness.dark ? 0.12 : 0.18;
  final double outlineTint = scheme.brightness == Brightness.dark ? 0.18 : 0.28;
  Color tintTowardPrimary(Color base) =>
      Color.lerp(base, scheme.primary, surfaceTint) ?? base;
  Color tintOutline(Color base) =>
      Color.lerp(base, scheme.primary, outlineTint) ?? base;

  if (scheme.brightness == Brightness.dark) {
    return scheme.copyWith(
      surface: tintTowardPrimary(scheme.surface),
      surfaceDim: tintTowardPrimary(scheme.surfaceDim),
      surfaceBright: tintTowardPrimary(scheme.surfaceBright),
      surfaceContainerLowest:
          tintTowardPrimary(scheme.surfaceContainerLowest),
      surfaceContainerLow: tintTowardPrimary(scheme.surfaceContainerLow),
      surfaceContainer: tintTowardPrimary(scheme.surfaceContainer),
      surfaceContainerHigh: tintTowardPrimary(scheme.surfaceContainerHigh),
      surfaceContainerHighest:
          tintTowardPrimary(scheme.surfaceContainerHighest),
      outline: tintOutline(scheme.outline),
      outlineVariant: tintOutline(scheme.outlineVariant),
    );
  }
  return scheme.copyWith(
    surfaceContainer: tintTowardPrimary(scheme.surfaceContainer),
    surfaceContainerHigh: tintTowardPrimary(scheme.surfaceContainerHigh),
    surfaceContainerHighest:
        tintTowardPrimary(scheme.surfaceContainerHighest),
    outlineVariant: tintOutline(scheme.outlineVariant),
  );
}

/// Pulls icon-derived dark schemes a few steps toward black so UI feels less neon.
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

ColorScheme _darkenIconPageSchemeInDarkMode(ColorScheme scheme) {
  if (scheme.brightness != Brightness.dark) return scheme;
  const Color black = Color(0xFF000000);
  Color darken(Color color, double mix) =>
      Color.lerp(color, black, mix) ?? color;

  return scheme.copyWith(
    primary: darken(scheme.primary, 0.08),
    onPrimary: scheme.onPrimary,
    primaryContainer: darken(scheme.primaryContainer, 0.12),
    onPrimaryContainer: scheme.onPrimaryContainer,
    primaryFixed: darken(scheme.primaryFixed, 0.1),
    primaryFixedDim: darken(scheme.primaryFixedDim, 0.1),
    onPrimaryFixed: scheme.onPrimaryFixed,
    onPrimaryFixedVariant: scheme.onPrimaryFixedVariant,
    secondary: darken(scheme.secondary, 0.08),
    onSecondary: scheme.onSecondary,
    secondaryContainer: darken(scheme.secondaryContainer, 0.12),
    onSecondaryContainer: scheme.onSecondaryContainer,
    secondaryFixed: darken(scheme.secondaryFixed, 0.1),
    secondaryFixedDim: darken(scheme.secondaryFixedDim, 0.1),
    onSecondaryFixed: scheme.onSecondaryFixed,
    onSecondaryFixedVariant: scheme.onSecondaryFixedVariant,
    tertiary: darken(scheme.tertiary, 0.08),
    onTertiary: scheme.onTertiary,
    tertiaryContainer: darken(scheme.tertiaryContainer, 0.12),
    onTertiaryContainer: scheme.onTertiaryContainer,
    tertiaryFixed: darken(scheme.tertiaryFixed, 0.1),
    tertiaryFixedDim: darken(scheme.tertiaryFixedDim, 0.1),
    onTertiaryFixed: scheme.onTertiaryFixed,
    onTertiaryFixedVariant: scheme.onTertiaryFixedVariant,
    surface: darken(scheme.surface, 0.14),
    onSurface: scheme.onSurface,
    surfaceDim: darken(scheme.surfaceDim, 0.14),
    surfaceBright: darken(scheme.surfaceBright, 0.12),
    surfaceContainerLowest: darken(scheme.surfaceContainerLowest, 0.14),
    surfaceContainerLow: darken(scheme.surfaceContainerLow, 0.14),
    surfaceContainer: darken(scheme.surfaceContainer, 0.14),
    surfaceContainerHigh: darken(scheme.surfaceContainerHigh, 0.14),
    surfaceContainerHighest: darken(scheme.surfaceContainerHighest, 0.14),
    onSurfaceVariant: scheme.onSurfaceVariant,
    outline: darken(scheme.outline, 0.07),
    outlineVariant: darken(scheme.outlineVariant, 0.09),
    shadow: scheme.shadow,
    scrim: scheme.scrim,
    inverseSurface: scheme.inverseSurface,
    onInverseSurface: scheme.onInverseSurface,
    inversePrimary: scheme.inversePrimary,
    surfaceTint: darken(scheme.surfaceTint, 0.06),
  );
}

class AppPage extends StatefulWidget {
  const AppPage({
    super.key,
    required this.appId,
    this.showOppositeOfPreferredView = false,
    this.openInEditMode = false,
  });

  final String appId;
  final bool showOppositeOfPreferredView;
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
  Color? _lastWebViewSurfaceColorApplied;
  bool updating = false;

  ColorScheme? _iconDerivedColorScheme;
  String? _iconSchemeCacheKey;
  String? _iconSchemeLoadingForKey;
  String? _iconSchemeFailedCacheKey;

  final SourceProvider _sourceProvider = SourceProvider();

  // Cache for the per-page ThemeData derived from the icon color scheme.
  // Recomputed only when the icon scheme key or parent brightness changes.
  ThemeData? _cachedPageTheme;
  String? _cachedPageThemeKey;

  // ── Inline edit mode ────────────────────────────────────────────────────
  bool _editMode = false;
  bool _scheduledOpenInEditMode = false;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _packageController = TextEditingController();
  List<String> _editCategories = [];

  String _editBaselineName = '';
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
      _lastWebViewSurfaceColorApplied = null;
      _scheduledOpenInEditMode = false;
      _clearEditIconStaging();
    } else if (oldWidget.openInEditMode != widget.openInEditMode) {
      _scheduledOpenInEditMode = false;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _packageController.dispose();
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
    _editBaselineUrl = _urlController.text;
    _editBaselinePackage = _packageController.text;
    _editBaselineCategories = List<String>.from(_editCategories);
    _editBaselineIconFingerprint = _iconFingerprintForEditBaseline(appData.icon);
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
    if (_urlController.text != _editBaselineUrl) return true;
    if (_packageController.text != _editBaselinePackage) return true;
    if (!listEquals(_editCategories, _editBaselineCategories)) return true;
    if (_editIconStagingIsDirty()) return true;
    return false;
  }

  void _exitEditWithoutSaving() {
    _clearEditIconStaging();
    setState(() => _editMode = false);
  }

  Future<void> _onCancelEditPressed(
    BuildContext actionContext,
    AppInMemory? appData,
  ) async {
    if (!_isEditDirty(appData)) {
      _exitEditWithoutSaving();
      return;
    }
    final bool? discard = await showDialog<bool>(
      context: actionContext,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(tr('appEditsUnsavedTitle')),
          content: Text(tr('appEditsUnsavedBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr('keepEditing')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr('discard')),
            ),
          ],
        );
      },
    );
    if (discard == true && mounted) {
      _exitEditWithoutSaving();
    }
  }

  Future<bool> _confirmDiscardToLeaveAppPage(
    BuildContext actionContext,
    AppInMemory? appData,
  ) async {
    if (!_isEditDirty(appData)) return true;
    final bool? discard = await showDialog<bool>(
      context: actionContext,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(tr('appEditsUnsavedTitle')),
          content: Text(tr('appEditsUnsavedBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr('keepEditing')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr('discard')),
            ),
          ],
        );
      },
    );
    return discard == true;
  }

  void _startEdit(AppInMemory appData, AppsProvider appsProvider) {
    _clearEditIconStaging();
    _nameController.text = appData.name;
    _urlController.text = appData.app.url;
    _packageController.text = appData.app.id;
    _editCategories = List<String>.from(appData.app.categories);
    _editBaselineHadUserOverride =
        appsProvider.hasUserAppIconOverride(widget.appId);
    _captureEditBaseline(appData);
    setState(() => _editMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void placeCaretAtEnd(TextEditingController controller) {
        final String text = controller.text;
        controller.selection =
            TextSelection.collapsed(offset: text.length);
      }

      placeCaretAtEnd(_nameController);
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
    final newUrl = _urlController.text.trim();
    if (newUrl.isNotEmpty) updatedApp.url = newUrl;
    final newId = _packageController.text.trim();
    if (newId.isNotEmpty && newId != updatedApp.id) {
      updatedApp.allowIdChange = true;
      updatedApp.id = newId;
    }
    updatedApp.categories = _editCategories;

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
        if (mounted) showError(ObtainiumError(iconErr), context);
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
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
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
        showError(ObtainiumError(tr('changeAppIconInvalidPng')), context);
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
    setState(() {
      _editStagedIconBytes = null;
    });
    if (appsProvider.hasUserAppIconOverride(widget.appId)) {
      setState(() {
        _editStagedClearOverride = true;
        _editNonUserIconPreview = null;
      });
      final Uint8List? preview =
          await appsProvider.loadIconPreviewExcludingUserOverride(widget.appId);
      if (!mounted) return;
      setState(() {
        _editNonUserIconPreview = preview;
      });
    } else {
      setState(() {
        _editStagedClearOverride = false;
        _editNonUserIconPreview = null;
      });
    }
  }

  void _openIconWebSearch(AppInMemory appData) {
    final String query = '${appData.name} square app icon transparent background';
    launchUrlString(
      'https://images.google.com/search?tbm=isch&q=${Uri.encodeComponent(query)}',
      mode: LaunchMode.externalApplication,
    );
  }

  Widget _materialAppPageSectionCard(
    BuildContext ctx,
    String sectionTitle,
    List<Widget> children, {
    Color? sectionBackgroundColor,
    Color? sectionTitleColor,
  }) {
    final bool isDark = Theme.of(ctx).brightness == Brightness.dark;
    final ColorScheme colorScheme = Theme.of(ctx).colorScheme;
    final double sectionDeepen = isDark ? 0.055 : 0.045;
    final Color defaultSectionFill = isDark
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainer;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: sectionBackgroundColor ??
            (Color.lerp(defaultSectionFill, Colors.black, sectionDeepen) ??
                defaultSectionFill),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: colorScheme.outlineVariant,
          width: 1,
        ),
        boxShadow: [
          if (isDark)
            BoxShadow(
              color: colorScheme.shadow.withAlpha(180),
              blurRadius: 16,
              spreadRadius: 0,
              offset: const Offset(0, 4),
            )
          else
            BoxShadow(
              color: colorScheme.shadow.withAlpha(40),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sectionTitle,
              style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: sectionTitleColor ??
                        Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
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
        _materialAppPageSectionCard(
          ctx,
          tr('nameAndLinks').toUpperCase(),
          [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: tr('appName'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _packageController,
              decoration: InputDecoration(
                labelText: tr('package'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: tr('trackedSource'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        _materialAppPageSectionCard(
          ctx,
          tr('appIconActionsTitle').toUpperCase(),
          [
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
          ],
        ),
        _materialAppPageSectionCard(
          ctx,
          tr('categories').toUpperCase(),
          [
            CategoryEditorSelector(
              key: ValueKey(_editCategories.join(',')),
              preselected: _editCategories.toSet(),
              alignment: WrapAlignment.start,
              showLabelWhenNotEmpty: false,
              onSelected: (cats) =>
                  setState(() => _editCategories = cats),
            ),
          ],
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
  }) {
    final Uint8List? bytesForImage = iconMemoryBytes ?? appInMemory?.icon;
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
          ),
        ),
      );
    } else {
      iconChild = GestureDetector(
        onTap: onTap,
        child: emptyPlaceholder,
      );
    }
    if (heroTag != null) {
      return Hero(tag: heroTag, child: iconChild);
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
    try {
      if (!mounted) return;
      final brightness = Theme.of(context).brightness;
      // Use fidelity, not expressive: expressive deliberately shifts primary hue
      // away from the seed for variety, which makes icon-based theming wrong
      // (e.g. blue icon producing green accents).
      final ColorScheme scheme = await ColorScheme.fromImageProvider(
        provider: MemoryImage(iconBytes),
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );
      if (!context.mounted) return;
      final AppsProvider apps =
          Provider.of<AppsProvider>(context, listen: false);
      if (!identical(apps.apps[widget.appId]?.icon, iconBytes)) return;
      final SettingsProvider settings =
          Provider.of<SettingsProvider>(context, listen: false);
      if (!settings.matchAppPageToIconColors) return;
      setState(() {
        if (_iconSchemeLoadingForKey == cacheKey) {
          _iconDerivedColorScheme = scheme;
          _iconSchemeCacheKey = cacheKey;
          _iconSchemeLoadingForKey = null;
          _iconSchemeFailedCacheKey = null;
        }
      });
    } catch (_) {
      if (!context.mounted) return;
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
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame == true) {
              showError(
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

  Future<void> _runCheckUpdate(String id, {bool resetVersion = false}) async {
    final AppsProvider appsProvider =
        Provider.of<AppsProvider>(context, listen: false);
    try {
      setState(() {
        updating = true;
      });
      await appsProvider.checkUpdate(id);
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
      if (context.mounted) {
        showError(err, context);
      }
    } finally {
      if (mounted) {
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
        : Icon(
            Icons.link,
            size: _storeSourceIconSize * 0.75,
            color: colorScheme.primary,
          );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => launchUrlString(
          url,
          mode: LaunchMode.externalApplication,
        ),
        onLongPress: () => _toastUrl(url),
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

    final AppsProvider appsProvider =
        Provider.of<AppsProvider>(context, listen: false);
    final SettingsProvider settingsProvider =
        Provider.of<SettingsProvider>(context, listen: false);

    final bool useIconPageColors = settingsProvider.matchAppPageToIconColors;
    var showAppWebpageFinal =
        (settingsProvider.showAppWebpage &&
            !widget.showOppositeOfPreferredView) ||
        (!settingsProvider.showAppWebpage &&
            widget.showOppositeOfPreferredView);

    bool areDownloadsRunning = appsProvider.areDownloadsRunning();

    AppInMemory? app = appsProvider.apps[widget.appId];
    if (!_requestedMissingIconLoad &&
        app != null &&
        app.icon == null) {
      _requestedMissingIconLoad = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Provider.of<AppsProvider>(context, listen: false)
            .updateAppIcon(widget.appId, ignoreCache: false);
      });
    }
    if (widget.openInEditMode &&
        !_scheduledOpenInEditMode &&
        app != null &&
        !_editMode) {
      _scheduledOpenInEditMode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final AppInMemory? freshApp =
            Provider.of<AppsProvider>(context, listen: false).apps[widget.appId];
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
        : _darkenIconPageSchemeInDarkMode(
            _appPageSurfacesWithVisibleAccent(_iconDerivedColorScheme!),
          );
    final Brightness pageBrightness = pageColorSchemeForPage.brightness;
    final double appPageSurfaceDeepen =
        pageBrightness == Brightness.dark ? 0.055 : 0.045;
    Color appPageDeeperSurface(Color base) =>
        Color.lerp(base, Colors.black, appPageSurfaceDeepen) ?? base;
    // ThemeData.copyWith() is expensive — cache it and recompute only when the
    // icon scheme or parent brightness actually changes.
    final String pageThemeKey =
        '${_iconSchemeCacheKey ?? "none"}_${themeBrightness.name}';
    if (_cachedPageThemeKey != pageThemeKey || _cachedPageTheme == null) {
      _cachedPageThemeKey = pageThemeKey;
      _cachedPageTheme = parentThemeForPage.copyWith(
        colorScheme: pageColorSchemeForPage,
        primaryColor: pageColorSchemeForPage.primary,
        cardColor: appPageDeeperSurface(
          pageColorSchemeForPage.surfaceContainerHighest,
        ),
      );
    }
    final ThemeData pageThemeForPage = _cachedPageTheme!;

    if (!_scheduledDetailPageRefresh &&
        app != null &&
        settingsProvider.checkUpdateOnDetailPage &&
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

    bool installedVersionIsEstimate = app?.app != null
        ? isVersionPseudo(app!.app)
        : false;

    if (showAppWebpageFinal && app != null && !_webViewUrlLoaded) {
      _webViewUrlLoaded = true;
      final String webUrl = app.app.url;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _webViewController.loadRequest(Uri.parse(webUrl));
        }
      });
    }

    String _formatDateTimeToMinute(DateTime dateTime) {
      final local = dateTime.toLocal();
      final year = local.year.toString();
      final month = local.month.toString().padLeft(2, '0');
      final day = local.day.toString().padLeft(2, '0');
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '$year-$month-$day $hour:$minute';
    }

    Widget _detailRow(
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

    Widget _versionVerdictRow(BuildContext ctx, Widget chip) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: _versionRowLabelWidth,
              child: Text(
                tr('verdict'),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
            const SizedBox(width: 8),
            chip,
          ],
        ),
      );
    }

    Widget _versionRow(BuildContext ctx, String label, String value) {
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

    Widget _versionRowWithLink(
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
                child: Text(
                  value,
                  style: linkStyle,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget _buildDownloadLink() {
      if (app?.app.apkUrls.isEmpty != false &&
          app?.app.otherAssetUrls.isEmpty != false) return const SizedBox.shrink();
      return GestureDetector(
        onTap: app?.app == null || updating
            ? null
            : () async {
                try {
                  await appsProvider.downloadAppAssets(
                      [app!.app.id], context);
                } catch (e) {
                  showError(e, context);
                }
              },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: settingsProvider.highlightTouchTargets
                    ? (Theme.of(context).brightness == Brightness.light
                          ? Theme.of(context).primaryColor
                          : Theme.of(context).primaryColorLight)
                        .withAlpha(
                            Theme.of(context).brightness == Brightness.light
                                ? 20
                                : 40)
                    : null,
              ),
              padding: settingsProvider.highlightTouchTargets
                  ? const EdgeInsetsDirectional.fromSTEB(12, 6, 12, 6)
                  : const EdgeInsetsDirectional.fromSTEB(0, 2, 0, 2),
              margin: const EdgeInsetsDirectional.fromSTEB(0, 2, 0, 0),
              child: Text(
                tr('downloadX',
                    args: [lowerCaseIfEnglish(tr('releaseAsset'))]),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall!.copyWith(
                      decoration: TextDecoration.underline,
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    Widget _buildCertBlock() {
      if (app == null || app!.certificateHashes.isEmpty) return const SizedBox.shrink();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: app!.certificateHashes.map((hash) {
          return GestureDetector(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: hash));
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr('copiedToClipboard'))));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
              child: SelectableText(
                hash,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          );
        }).toList(),
      );
    }

    Widget _buildAboutBlock(BuildContext themeContext) {
      if (app?.app.additionalSettings['about'] is! String ||
          (app?.app.additionalSettings['about'] as String).isEmpty)
        return const SizedBox.shrink();
      return GestureDetector(
        onLongPress: () {
          Clipboard.setData(
              ClipboardData(
                  text: app?.app.additionalSettings['about'] ?? ''));
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr('copiedToClipboard'))));
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
          data: app?.app.additionalSettings['about'] as String,
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
      bool upToDate = app?.app.installedVersion == app?.app.latestVersion ||
          (app?.app.installedVersion != null &&
              (versionsEffectivelyEqual(
                  app!.app.installedVersion!, app.app.latestVersion) ||
                  installedVersionIsNewerOrEqual(
                      app!.app.installedVersion!, app.app.latestVersion)));
      final effectivelyEqual = installed &&
          app!.app.installedVersion != null &&
          app.app.installedVersion != app.app.latestVersion &&
          versionsEffectivelyEqual(
              app.app.installedVersion!, app.app.latestVersion);
      if (undeterminedTrackOnlyInstalled) {
        upToDate = false;
      }
      var changeLogFn = app != null ? getChangeLogFn(context, app.app) : null;

      final lastUpdateCheckLabel =
          tr('lastUpdateCheckX', args: [tr('never')]).split(':').first.trim();
      final lastUpdateCheckValue = app?.app.lastUpdateCheck == null
          ? tr('never')
          : _formatDateTimeToMinute(app!.app.lastUpdateCheck!);

      Future<void> markTrackOnlyAsNotInstalledOnDevice() async {
        if (app == null) return;
        setState(() {
          updating = true;
        });
        try {
          final App appToSave = app!.app.deepCopy();
          appToSave.additionalSettings['trackOnlyUndeterminedInstalledVersion'] =
              false;
          await appsProvider.saveApps([appToSave]);
        } catch (err) {
          if (context.mounted) {
            showError(err, context);
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
        final packageIdController = TextEditingController(text: app!.app.id);
        final submittedPackageId = await showDialog<String>(
          context: context,
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
            MaterialPageRoute<void>(
              builder: (ctx) => AppPage(appId: submittedPackageId),
            ),
          );
        } catch (err) {
          if (context.mounted) {
            showError(err, context);
          }
        } finally {
          if (context.mounted) {
            setState(() {
              updating = false;
            });
          }
        }
      }

      final versionCardChildren = <Widget>[];
      if (undeterminedTrackOnlyInstalled) {
        versionCardChildren.add(
          _versionRow(pageThemeContext, tr('installed'), tr('unknown')),
        );
        versionCardChildren.add(
          _versionRow(pageThemeContext, tr('latest'), app?.app.latestVersion ?? '-'),
        );
        versionCardChildren.add(
          _versionRow(pageThemeContext, lastUpdateCheckLabel, lastUpdateCheckValue),
        );
        if (changeLogFn != null || app?.app.releaseDate != null) {
          versionCardChildren.add(
            _versionRowWithLink(
              pageThemeContext,
              tr('changelog'),
              app?.app.releaseDate == null
                  ? tr('changes')
                  : _formatDateTimeToMinute(app!.app.releaseDate!),
              changeLogFn,
            ),
          );
        }
        if ((app?.app.apkUrls.length ?? 0) > 0) {
          versionCardChildren.add(
            _versionRowWithLink(
              pageThemeContext,
              tr('assets'),
              app!.app.apkUrls.length == 1
                  ? app!.app.apkUrls[0].key
                  : plural('apk', app!.app.apkUrls.length),
              app?.app == null || updating
                  ? null
                  : () async {
                      try {
                        await appsProvider.downloadAppAssets(
                            [app!.app.id], context);
                      } catch (e) {
                        showError(e, context);
                      }
                    },
            ),
          );
        }
      } else {
        if (installed) {
          versionCardChildren.add(
            _versionRow(pageThemeContext, tr('installed'), app?.app.installedVersion ?? ''),
          );
        } else {
          versionCardChildren.add(
            _versionRow(pageThemeContext, tr('installed'), tr('notInstalled')),
          );
        }
        versionCardChildren.add(
          _versionRow(pageThemeContext, tr('latest'), app?.app.latestVersion ?? '-'),
        );
        if (effectivelyEqual) {
          versionCardChildren.add(_versionVerdictRow(
            pageThemeContext,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: pageTheme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tr('effectivelyEqual'),
                style: pageTheme.textTheme.labelSmall?.copyWith(
                      color: pageTheme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
          ));
        } else if (upToDate) {
          versionCardChildren.add(_versionVerdictRow(
            pageThemeContext,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: pageTheme.brightness == Brightness.dark
                    ? const Color(0xFF2E7D32).withAlpha(60)
                    : const Color(0xFFC8E6C9),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tr('sameVersion'),
                style: pageTheme.textTheme.labelSmall?.copyWith(
                      color: pageTheme.brightness == Brightness.dark
                          ? const Color(0xFFA5D6A7)
                          : const Color(0xFF1B5E20),
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
          ));
        } else if (installed) {
          versionCardChildren.add(_versionVerdictRow(
            pageThemeContext,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: pageTheme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tr('updateAvailable'),
                style: pageTheme.textTheme.labelSmall?.copyWith(
                      color: pageTheme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
          ));
        }
        versionCardChildren.add(
          _versionRow(pageThemeContext, lastUpdateCheckLabel, lastUpdateCheckValue),
        );
        if (changeLogFn != null || app?.app.releaseDate != null) {
          versionCardChildren.add(
            _versionRowWithLink(
              pageThemeContext,
              tr('changelog'),
              app?.app.releaseDate == null
                  ? tr('changes')
                  : _formatDateTimeToMinute(app!.app.releaseDate!),
              changeLogFn,
            ),
          );
        }
        if ((app?.app.apkUrls.length ?? 0) > 0) {
          versionCardChildren.add(
            _versionRowWithLink(
              pageThemeContext,
              tr('assets'),
              app!.app.apkUrls.length == 1
                  ? app!.app.apkUrls[0].key
                  : plural('apk', app!.app.apkUrls.length),
              app?.app == null || updating
                  ? null
                  : () async {
                      try {
                        await appsProvider.downloadAppAssets(
                            [app!.app.id], context);
                      } catch (e) {
                        showError(e, context);
                      }
                    },
            ),
          );
        }
      }
      final versionCard = _materialAppPageSectionCard(
        pageThemeContext,
        tr('version').toUpperCase(),
        versionCardChildren,
      );

      final bool trackOnlyUsesTemporaryPackageId =
          app?.app.additionalSettings['trackOnlyTemporaryPackageId'] == true;
      final Widget? trackOnlyInstalledErrorCard =
          undeterminedTrackOnlyInstalled
              ? _materialAppPageSectionCard(
                  pageThemeContext,
                  tr('error').toUpperCase(),
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
                  sectionBackgroundColor:
                      pageTheme.colorScheme.errorContainer,
                  sectionTitleColor:
                      pageTheme.colorScheme.onErrorContainer,
                )
              : null;

      final detailsValueStyle =
          pageTheme.textTheme.bodySmall!.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              );
      final detailsMonoValueStyle =
          detailsValueStyle.copyWith(fontFamily: 'monospace');

      final String? alternateStoresPackageId = app?.app.id;
      final String? alternateStoresTrackedUrl = app?.app.url;
      final bool showPlayStoreIcon = alternateStoresPackageId != null &&
          alternateStoresPackageId.isNotEmpty &&
          !_trackedUrlMatchesPlayStore(
            alternateStoresTrackedUrl,
            alternateStoresPackageId,
          );
      final bool showApkmirrorIcon = alternateStoresPackageId != null &&
          alternateStoresPackageId.isNotEmpty &&
          !_trackedUrlMatchesApkmirror(alternateStoresTrackedUrl);
      final bool showFdroidIcon = alternateStoresPackageId != null &&
          alternateStoresPackageId.isNotEmpty &&
          !_trackedUrlMatchesFdroid(alternateStoresTrackedUrl);
      final bool showAlternateSourcesRow = showPlayStoreIcon ||
          showApkmirrorIcon ||
          showFdroidIcon;

      final detailsChildren = <Widget>[
        if (app?.app.id != null && app!.app.id!.isNotEmpty)
          _detailRow(
            pageThemeContext,
            tr('package'),
            app!.app.id!,
            valueStyle: detailsMonoValueStyle,
          ),
        if (app?.app.url != null && app!.app.url!.isNotEmpty)
          _detailRowTrackedSource(
            pageThemeContext,
            tr('trackedSource'),
            app!.app.url!,
          ),
        if (showAlternateSourcesRow && alternateStoresPackageId != null)
          Padding(
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
                      if (showPlayStoreIcon)
                        _buildStoreSourceLaunchIcon(
                          iconContext: pageThemeContext,
                          url:
                              'https://play.google.com/store/apps/details?id=$alternateStoresPackageId',
                          assetPath: StoreSourceIconPaths.playStore,
                        ),
                      if (showApkmirrorIcon)
                        _buildStoreSourceLaunchIcon(
                          iconContext: pageThemeContext,
                          url:
                              'https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=${Uri.encodeComponent(alternateStoresPackageId)}',
                          assetPath: StoreSourceIconPaths.apkmirror,
                        ),
                      if (showFdroidIcon)
                        _buildStoreSourceLaunchIcon(
                          iconContext: pageThemeContext,
                          url:
                              'https://f-droid.org/packages/$alternateStoresPackageId/',
                          assetPath: StoreSourceIconPaths.fdroid,
                        ),
                    ],
                  ),
                ),
              ],
            ),
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
                            ...(app?.app.categories ?? []).map(
                              (categoryName) {
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
                              },
                            ),
                          ],
                        ),
              ),
            ],
          ),
        ),
      ];
      final detailsCard = _materialAppPageSectionCard(
        pageThemeContext,
        tr('details').toUpperCase(),
        detailsChildren,
      );

      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          if (trackOnlyInstalledErrorCard != null)
            trackOnlyInstalledErrorCard,
          versionCard,
          detailsCard,
          if (app?.app.additionalSettings['about'] is String &&
              app?.app.additionalSettings['about'].isNotEmpty)
            _materialAppPageSectionCard(
              pageThemeContext,
              tr('about').toUpperCase(),
              [_buildAboutBlock(pageThemeContext)],
            ),
        ],
      );
    }

    Widget _buildDetailHeroContent(BuildContext themeContext) {
      const double heroScale = 1.2;
      const heroIconSize = 58.0;
      final scaledIconSize = heroIconSize * heroScale;
      final titleStyle = Theme.of(themeContext).textTheme.titleLarge;
      final bylineStyle = Theme.of(themeContext).textTheme.bodySmall;
      final iconWidget = _tappableAppIconDisplay(
        themeContext: themeContext,
        appInMemory: app,
        size: scaledIconSize,
        borderRadius: 16,
        heroTag: 'app-icon-${widget.appId}',
        iconMemoryBytes: _heroIconMemoryOverrideForEdit(app),
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
                SizedBox(width: 12 * heroScale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_editMode)
                        ListenableBuilder(
                          listenable: _nameController,
                          builder: (BuildContext context, Widget? child) {
                            final ColorScheme heroScheme =
                                Theme.of(themeContext).colorScheme;
                            final String previewText =
                                _nameController.text.isEmpty
                                    ? tr('app')
                                    : _nameController.text;
                            return Text(
                              previewText,
                              style: titleStyle?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize: (titleStyle.fontSize ?? 22) *
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
                                fontSize: (titleStyle.fontSize ?? 22) *
                                    heroScale *
                                    1.06,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      SizedBox(height: 2 * heroScale),
                      Text(
                        tr('byX', args: [app?.author ?? tr('unknown')]),
                        style: bylineStyle?.copyWith(
                              color: Theme.of(themeContext)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: (bylineStyle?.fontSize ?? 12) *
                                  heroScale *
                                  1.08,
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
                              color: dialogColumnTheme
                                  .colorScheme.onSurfaceVariant,
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
      final Color webViewSurface = Color.lerp(
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
      return showDialog(
        context: context,
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
                  var updatedApp = app?.app;
                  if (updatedApp != null) {
                    updatedApp.installedVersion = updatedApp.latestVersion;
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

    showAdditionalOptionsDialog() async {
      return await showDialog<Map<String, dynamic>?>(
        context: context,
        builder: (BuildContext ctx) {
          var items = (source?.combinedAppSpecificSettingFormItems ?? []).map((
            row,
          ) {
            row = row.map((e) {
              if (app?.app.additionalSettings[e.key] != null) {
                e.defaultValue = app?.app.additionalSettings[e.key];
              }
              return e;
            }).toList();
            return row;
          }).toList();

          return Theme(
            data: pageThemeForPage,
            child: GeneratedFormModal(
              title: tr('additionalOptions'),
              items: items,
            ),
          );
        },
      );
    }

    handleAdditionalOptionChanges(Map<String, dynamic>? values) {
      if (app != null && values != null) {
        Map<String, dynamic> originalSettings = app.app.additionalSettings;
        app.app.additionalSettings = values;
        if (source?.enforceTrackOnly == true) {
          app.app.additionalSettings['trackOnly'] = true;
          // ignore: use_build_context_synchronously
          showMessage(tr('appsFromSourceAreTrackOnly'), context);
        }
        var versionDetectionEnabled =
            app.app.additionalSettings['versionDetection'] == true &&
            originalSettings['versionDetection'] != true;
        var releaseDateVersionEnabled =
            app.app.additionalSettings['releaseDateAsVersion'] == true &&
            originalSettings['releaseDateAsVersion'] != true;
        var releaseDateVersionDisabled =
            app.app.additionalSettings['releaseDateAsVersion'] != true &&
            originalSettings['releaseDateAsVersion'] == true;
        if (releaseDateVersionEnabled) {
          if (app.app.releaseDate != null) {
            bool isUpdated = app.app.installedVersion == app.app.latestVersion ||
                (app.app.installedVersion != null &&
                    versionsEffectivelyEqual(
                        app.app.installedVersion!, app.app.latestVersion));
            app.app.latestVersion = app.app.releaseDate!.microsecondsSinceEpoch
                .toString();
            if (isUpdated) {
              app.app.installedVersion = app.app.latestVersion;
            }
          }
        } else if (releaseDateVersionDisabled) {
          app.app.installedVersion =
              app.installedInfo?.versionName ?? app.app.installedVersion;
        }
        if (versionDetectionEnabled) {
          app.app.additionalSettings['versionDetection'] = true;
          app.app.additionalSettings['releaseDateAsVersion'] = false;
        }
        appsProvider.saveApps([app.app]).then((value) {
          _runCheckUpdate(app.app.id, resetVersion: versionDetectionEnabled);
        });
      }
    }

    getBottomCenterActions(BuildContext themeContext) {
      final ThemeData actionTheme = Theme.of(themeContext);
      const double expressiveRadius = 26;
      const EdgeInsets expressivePadding =
          EdgeInsets.symmetric(horizontal: 16, vertical: 14);
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
        disabledBackgroundColor:
            actionTheme.colorScheme.onSurface.withAlpha(31),
        disabledForegroundColor:
            actionTheme.colorScheme.onSurface.withAlpha(97),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

      if (_editMode) {
        const double editActionsHeight = 52;
        return SizedBox(
          height: editActionsHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: expressiveMinimumSize,
                    maximumSize: expressiveMaximumSize,
                    padding: expressivePadding,
                    shape: expressiveShape,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: updating
                      ? null
                      : () => _onCancelEditPressed(themeContext, app),
                  child: Text(tr('cancel')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: expressiveFilled,
                  onPressed: app == null ||
                          updating ||
                          app.downloadProgress != null
                      ? null
                      : () => _saveEdit(app, appsProvider),
                  child: Text(tr('save')),
                ),
              ),
            ],
          ),
        );
      }

      final bool actionBlocked = updating || areDownloadsRunning;
      final installedVersion = app?.app.installedVersion;
      final bool installedVersionIsNull = installedVersion == null;
      final bool versionBehind = installedVersion != null &&
          installedVersion != app!.app.latestVersion &&
          !versionsEffectivelyEqual(installedVersion, app.app.latestVersion) &&
          !installedVersionIsNewerOrEqual(installedVersion, app.app.latestVersion);
      final bool trackOnlyHasVersionUpdate = trackOnly && versionBehind;
      final bool nonStandardVersionBehind =
          !trackOnly && !isVersionDetectionStandard && versionBehind;
      final bool primaryActionEnabled =
          !actionBlocked && (installedVersionIsNull || versionBehind);

      Future<void> runInstallOrMarkUpdated() async {
        try {
          final successMessage = installedVersionIsNull
              ? tr('installed')
              : tr('appsUpdated');
          HapticFeedback.heavyImpact();
          final res = await appsProvider.downloadAndInstallLatestApps(
            app?.app.id != null ? [app!.app.id] : [],
            globalNavigatorKey.currentContext,
          );
          if (res.isNotEmpty && !trackOnly && mounted) {
            showMessage(successMessage, context);
          }
          if (res.isNotEmpty && mounted) {
            Navigator.of(context).pop();
          }
        } catch (e) {
          if (mounted) {
            showError(e, context);
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

      if (trackOnlyHasVersionUpdate) {
        // Outer Row is in a Column with unbounded max height. A nested Row of
        // two horizontal Expanded children + stretch can get infinite cross-axis
        // extent and break layout (blank page). Fixed height bounds the inner Row.
        const double dualButtonBarHeight = 52;
        return SizedBox(
          height: dualButtonBarHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FilledButton(
                  style: expressiveFilled,
                  onPressed: actionBlocked ? null : openTrackOnlyReleasePage,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      tr('update'),
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
        );
      }

      if (nonStandardVersionBehind) {
        const double dualButtonBarHeight = 52;
        final bool markUpdatedActionBlocked =
            updating || app?.downloadProgress != null;
        return SizedBox(
          height: dualButtonBarHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FilledButton(
                  style: expressiveFilled,
                  onPressed: actionBlocked ? null : runInstallOrMarkUpdated,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      tr('update'),
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
                  onPressed:
                      markUpdatedActionBlocked ? null : showMarkUpdatedDialog,
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
        );
      }

      return FilledButton(
        style: expressiveFilled,
        onPressed: primaryActionEnabled ? runInstallOrMarkUpdated : null,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Text(
            installedVersionIsNull
                ? (!trackOnly ? tr('install') : tr('markInstalled'))
                : (!trackOnly ? tr('update') : tr('markUpdated')),
            maxLines: 1,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    getBottomSheetMenu(BuildContext themeContext) => Padding(
      padding: EdgeInsets.fromLTRB(
        0,
        0,
        0,
        MediaQuery.of(themeContext).padding.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(themeContext).brightness == Brightness.dark
              ? Theme.of(themeContext).colorScheme.surfaceContainerHigh
              : Theme.of(themeContext).colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(
              color: Theme.of(themeContext).brightness == Brightness.dark
                  ? Theme.of(themeContext)
                      .colorScheme.outlineVariant
                      .withAlpha(140)
                  : Theme.of(themeContext)
                      .colorScheme.outlineVariant
                      .withAlpha(70),
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(themeContext).colorScheme.shadow.withAlpha(
                    Theme.of(themeContext).brightness == Brightness.dark
                        ? 130
                        : 40,
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (app != null && app.installedInfo != null)
                      IconButton(
                        color: Theme.of(themeContext).colorScheme.primary,
                        iconSize: 24,
                        onPressed: () {
                          appsProvider.openAppSettings(app.app.id);
                        },
                        icon: const Icon(Icons.info_outline),
                        tooltip: tr('appPageAppInfo'),
                      ),
                    if (app != null &&
                        !_editMode &&
                        app.downloadProgress == null &&
                        !updating)
                      IconButton(
                        color: Theme.of(themeContext).colorScheme.primary,
                        iconSize: 24,
                        onPressed: () => _startEdit(app, appsProvider),
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: tr('editAppInfo'),
                      ),
                    if (source != null &&
                        source.combinedAppSpecificSettingFormItems.isNotEmpty)
                      IconButton(
                        color: Theme.of(themeContext).colorScheme.primary,
                        iconSize: 24,
                        onPressed: app?.downloadProgress != null || updating
                            ? null
                            : () async {
                                var values =
                                    await showAdditionalOptionsDialog();
                                handleAdditionalOptionChanges(values);
                              },
                        tooltip: tr('appOptions'),
                        icon: const Icon(Icons.tune),
                      ),
                    if (app != null && showAppWebpageFinal)
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
                                            Navigator.of(dialogRouteContext)
                                                .pop();
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
                    if ((!isVersionDetectionStandard || trackOnly) &&
                        app?.app.installedVersion != null &&
                        (app?.app.installedVersion ==
                                app?.app.latestVersion ||
                            versionsEffectivelyEqual(
                                app!.app.installedVersion!,
                                app.app.latestVersion) ||
                            installedVersionIsNewerOrEqual(
                                app!.app.installedVersion!,
                                app.app.latestVersion)))
                      IconButton(
                        color: Theme.of(themeContext).colorScheme.primary,
                        iconSize: 24,
                        onPressed: app?.app == null || updating
                            ? null
                            : () {
                                app!.app.installedVersion = null;
                                appsProvider.saveApps([app.app]);
                              },
                        icon: const Icon(Icons.restore_rounded),
                        tooltip: tr('resetInstallStatus'),
                      ),
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
                              final List<App> removalSnapshot = [
                                appRow.app.deepCopy(),
                              ];
                              final bool removed =
                                  await appsProvider.removeAppsWithModal(
                                context,
                                [appRow.app],
                              );
                              if (removed && messenger != null) {
                                messenger
                                  ..clearSnackBars()
                                  ..showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        tr('xAppsRemoved', args: ['1']),
                                      ),
                                      duration: const Duration(seconds: 5),
                                      behavior: SnackBarBehavior.floating,
                                      action: SnackBarAction(
                                        label: tr('undo'),
                                        onPressed: () => appsProvider.saveApps(
                                          removalSnapshot,
                                          onlyIfExists: false,
                                        ),
                                      ),
                                    ),
                                  );
                              }
                              if (removed && context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                      tooltip: tr('remove'),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                if (app?.downloadProgress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
              child: LinearProgressIndicator(
                value: app!.downloadProgress! >= 0
                    ? app.downloadProgress! / 100
                    : null,
              ),
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
            canPop: !_editMode || !_isEditDirty(app),
            onPopInvokedWithResult: (bool didPop, Object? result) async {
              if (didPop) return;
              if (!mounted || !_editMode) return;
              final AppInMemory? freshApp = Provider.of<AppsProvider>(
                    themedPageContext,
                    listen: false,
                  ).apps[widget.appId];
              final bool leave = await _confirmDiscardToLeaveAppPage(
                themedPageContext,
                freshApp,
              );
              if (leave && themedPageContext.mounted) {
                Navigator.of(themedPageContext).pop();
              }
            },
            child: Scaffold(
            appBar: showAppWebpageFinal ? AppBar() : null,
            backgroundColor: appPageDeeperSurface(pageColorSchemeForPage.surface),
            body: RefreshIndicator(
              child: showAppWebpageFinal
                  ? getAppWebView(themedPageContext)
                  : CustomScrollView(
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
                                        onPressed: updating
                                            ? null
                                            : () => Navigator.of(
                                                  themedPageContext,
                                                ).maybePop(),
                                        tooltip: MaterialLocalizations.of(
                                                themedPageContext)
                                            .backButtonTooltip,
                                      ),
                                      Expanded(
                                        child: _buildDetailHeroContent(
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
                                        16, 0, 16, 16),
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
                                  SizedBox(
                                    height: MediaQuery.of(themedPageContext)
                                        .padding
                                        .bottom,
                                  ),
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
