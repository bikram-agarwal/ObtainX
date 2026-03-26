import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/version_regex_assist_dialog.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_page_icon_colors.dart';
import 'package:provider/provider.dart';

import 'page_route_slide_up.dart';

enum _AdditionalOptionsUnsavedAction { keepEditing, discard, saveAndExit }

/// Prefer [slideUpPageRoute]; kept for call sites that still use this name.
PageRouteBuilder<T> additionalOptionsPageRoute<T>(WidgetBuilder builder) =>
    slideUpPageRoute<T>(builder);

/// Merges [formValues] into the app, applies version/release-date rules, saves.
/// Returns whether version detection was newly enabled (for follow-up refresh).
Future<bool> persistAdditionalOptionsForm({
  required BuildContext context,
  required AppsProvider appsProvider,
  required String appId,
  required Map<String, dynamic> formValues,
}) async {
  final AppInMemory? appInMem = appsProvider.apps[appId];
  if (appInMem == null) return false;
  final App app = appInMem.app;
  final AppSource source = SourceProvider().getSource(
    app.url,
    overrideSource: app.overrideSource,
  );

  final Map<String, dynamic> originalSettings =
      Map<String, dynamic>.from(app.additionalSettings);
  app.additionalSettings = {...originalSettings, ...formValues};

  if (source.enforceTrackOnly) {
    app.additionalSettings['trackOnly'] = true;
    if (context.mounted) {
      showMessage(tr('appsFromSourceAreTrackOnly'), context);
    }
  }

  final bool versionDetectionEnabled =
      app.additionalSettings['versionDetection'] == true &&
          originalSettings['versionDetection'] != true;
  final bool releaseDateVersionEnabled =
      app.additionalSettings['releaseDateAsVersion'] == true &&
          originalSettings['releaseDateAsVersion'] != true;
  final bool releaseDateVersionDisabled =
      app.additionalSettings['releaseDateAsVersion'] != true &&
          originalSettings['releaseDateAsVersion'] == true;

  if (releaseDateVersionEnabled && app.releaseDate != null) {
    final bool isUpdated = app.installedVersion == app.latestVersion ||
        (app.installedVersion != null &&
            versionsEffectivelyEqual(
                app.installedVersion!, app.latestVersion));
    app.latestVersion =
        app.releaseDate!.microsecondsSinceEpoch.toString();
    if (isUpdated) app.installedVersion = app.latestVersion;
  } else if (releaseDateVersionDisabled) {
    app.installedVersion =
        appInMem.installedInfo?.versionName ?? app.installedVersion;
  }

  if (versionDetectionEnabled) {
    app.additionalSettings['versionDetection'] = true;
    app.additionalSettings['releaseDateAsVersion'] = false;
  }

  await appsProvider.saveApps([app]);
  return versionDetectionEnabled;
}

/// Full-screen editor for per-app additional options (keyboard-friendly).
class AdditionalOptionsPage extends StatefulWidget {
  const AdditionalOptionsPage({
    super.key,
    required this.appId,
    this.onAfterSave,
  });

  final String appId;

  /// Optional follow-up after a successful save (e.g. metadata refresh on [AppPage]).
  final Future<void> Function(
    String appId,
    bool versionDetectionJustEnabled,
  )? onAfterSave;

  @override
  State<AdditionalOptionsPage> createState() => _AdditionalOptionsPageState();
}

class _AdditionalOptionsPageState extends State<AdditionalOptionsPage> {
  late List<List<GeneratedFormItem>> _items;
  Map<String, dynamic> _values = {};
  Map<String, dynamic> _baselineValues = {};
  bool _baselineReady = false;
  bool _valid = false;
  bool _saving = false;

  ColorScheme? _iconDerivedColorScheme;
  String? _iconSchemeCacheKey;
  String? _iconSchemeLoadingForKey;
  String? _iconSchemeFailedCacheKey;
  ThemeData? _cachedPageTheme;
  String? _cachedPageThemeKey;
  bool _requestedMissingIconLoad = false;

  @override
  void initState() {
    super.initState();
    final AppsProvider appsProvider = context.read<AppsProvider>();
    final AppInMemory? appInMem = appsProvider.apps[widget.appId];
    if (appInMem == null) {
      _items = [];
      _valid = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }
    final App app = appInMem.app;
    final AppSource source = SourceProvider().getSource(
      app.url,
      overrideSource: app.overrideSource,
    );
    _items = cloneFormItems(source.combinedAppSpecificSettingFormItems);
    for (final List<GeneratedFormItem> row in _items) {
      for (final GeneratedFormItem element in row) {
        if (app.additionalSettings[element.key] != null) {
          element.defaultValue = app.additionalSettings[element.key];
        }
      }
    }
    _baselineValues =
        Map<String, dynamic>.from(getDefaultValuesFromFormItems(_items));
    _baselineReady = _items.isNotEmpty;
    attachRegexAssistToItems(
      _items,
      rawLatestVersionFromSource: app.rawLatestVersionFromSource,
      rawApkNamesFromSource: app.rawApkNamesFromSource,
      rawReleaseTitlesFromSource: app.rawReleaseTitlesFromSource,
    );
    _valid = _items.isEmpty;
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

  Future<void> _onSave() async {
    if (!_valid || _saving) return;
    setState(() {
      _saving = true;
    });
    try {
      final AppsProvider appsProvider = context.read<AppsProvider>();
      final bool versionDetectionEnabled = await persistAdditionalOptionsForm(
        context: context,
        appsProvider: appsProvider,
        appId: widget.appId,
        formValues: _values,
      );
      if (!mounted) return;
      if (widget.onAfterSave != null) {
        await widget.onAfterSave!(
          widget.appId,
          versionDetectionEnabled,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) showError(err, context);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  bool _formValuesEqual(
    Map<String, dynamic> current,
    Map<String, dynamic> baseline,
  ) {
    if (current.length != baseline.length) {
      return false;
    }
    for (final MapEntry<String, dynamic> entry in current.entries) {
      if (baseline[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  bool _isDirty() {
    return _baselineReady && !_formValuesEqual(_values, _baselineValues);
  }

  Future<_AdditionalOptionsUnsavedAction?> _showUnsavedChangesDialog(
    BuildContext dialogHostContext,
    ThemeData dialogTheme,
  ) {
    return showDialog<_AdditionalOptionsUnsavedAction>(
      context: dialogHostContext,
      builder: (BuildContext dialogContext) {
        return Theme(
          data: dialogTheme,
          child: AlertDialog(
            title: Text(tr('appEditsUnsavedTitle')),
            content: Text(tr('appEditsUnsavedBody')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _AdditionalOptionsUnsavedAction.discard,
                ),
                child: Text(tr('discard')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _AdditionalOptionsUnsavedAction.keepEditing,
                ),
                child: Text(tr('keepEditing')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _AdditionalOptionsUnsavedAction.saveAndExit,
                ),
                child: Text(tr('saveAndExit')),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleLeaveRequest(
    BuildContext actionContext,
    ThemeData pageTheme,
  ) async {
    if (_saving) {
      return;
    }
    if (!_isDirty()) {
      if (mounted) {
        Navigator.of(actionContext).pop();
      }
      return;
    }
    final _AdditionalOptionsUnsavedAction? action =
        await _showUnsavedChangesDialog(actionContext, pageTheme);
    if (!actionContext.mounted) {
      return;
    }
    switch (action) {
      case _AdditionalOptionsUnsavedAction.discard:
        Navigator.of(actionContext).pop();
        break;
      case _AdditionalOptionsUnsavedAction.saveAndExit:
        await _onSave();
        break;
      case _AdditionalOptionsUnsavedAction.keepEditing:
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    context.select<SettingsProvider, bool>(
      (SettingsProvider settings) => settings.matchAppPageToIconColors,
    );
    context.select<AppsProvider, int>(
      (AppsProvider provider) {
        final AppInMemory? inMemory = provider.apps[widget.appId];
        return Object.hash(
          identityHashCode(inMemory?.icon),
          inMemory?.icon?.length,
        );
      },
    );

    final ThemeData parentTheme = Theme.of(context);
    final Brightness themeBrightness = parentTheme.brightness;
    final AppsProvider appsProvider = context.read<AppsProvider>();
    final SettingsProvider settingsProvider = context.read<SettingsProvider>();
    final AppInMemory? appInMem = appsProvider.apps[widget.appId];

    if (appInMem != null &&
        appInMem.icon == null &&
        !_requestedMissingIconLoad) {
      _requestedMissingIconLoad = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        appsProvider.updateAppIcon(widget.appId, ignoreCache: false);
      });
    }

    final Uint8List? iconBytes = appInMem?.icon;
    final bool useIconPageColors = settingsProvider.matchAppPageToIconColors;

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

    final bool applyIconDerivedPageTheming =
        useIconPageColors && _iconDerivedColorScheme != null;
    final ColorScheme pageColorSchemeForPage = !applyIconDerivedPageTheming
        ? parentTheme.colorScheme
        : darkenIconPageSchemeInDarkMode(
            appPageSurfacesWithVisibleAccent(_iconDerivedColorScheme!),
          );
    final Brightness pageBrightness = pageColorSchemeForPage.brightness;

    final String pageThemeKey =
        '${_iconSchemeCacheKey ?? "none"}_${themeBrightness.name}';
    if (_cachedPageThemeKey != pageThemeKey || _cachedPageTheme == null) {
      _cachedPageThemeKey = pageThemeKey;
      _cachedPageTheme = buildAppPageThemedData(
        parentTheme,
        pageColorSchemeForPage,
      );
    }
    final ThemeData pageThemeForPage = _cachedPageTheme!;

    final Color scaffoldBackground = appPageDeeperSurfaceColor(
      pageColorSchemeForPage.surface,
      pageBrightness,
    );

    if (_items.isEmpty) {
      return Theme(
        data: pageThemeForPage,
        child: Scaffold(
          backgroundColor: scaffoldBackground,
          appBar: AppBar(title: Text(tr('additionalOptions'))),
          body: const Center(child: SizedBox.shrink()),
        ),
      );
    }

    final double fabBottomPadding =
        MediaQuery.of(context).padding.bottom + 16;

    return Theme(
      data: pageThemeForPage,
      child: PopScope(
        canPop: !_saving && !_isDirty(),
        onPopInvokedWithResult: (bool didPop, dynamic result) async {
          if (didPop) {
            return;
          }
          if (_saving) {
            return;
          }
          await _handleLeaveRequest(context, pageThemeForPage);
        },
        child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: scaffoldBackground,
        appBar: AppBar(
          title: Text(tr('additionalOptions')),
        ),
        floatingActionButton: Padding(
          padding: EdgeInsets.only(bottom: fabBottomPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.small(
                heroTag: 'additional_options_cancel',
                tooltip: tr('cancel'),
                onPressed: _saving
                    ? null
                    : () => _handleLeaveRequest(context, pageThemeForPage),
                child: const Icon(Icons.close),
              ),
              const SizedBox(height: 12),
              FloatingActionButton(
                heroTag: 'additional_options_save',
                tooltip: tr('continue'),
                onPressed: (!_valid || _saving) ? null : _onSave,
                child: _saving
                    ? SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: pageThemeForPage.colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.check),
              ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        body: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, 8, 12, fabBottomPadding + 124),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: GeneratedForm(
            items: _items,
            outlinedInputFields: true,
            prominentSectionHeaders: true,
            wrapFormSectionsInCards: true,
            onValueChanges: (values, valid, isBuilding) {
              if (isBuilding) {
                _values = values;
                _valid = valid;
              } else {
                setState(() {
                  _values = values;
                  _valid = valid;
                });
              }
            },
          ),
        ),
      ),
    ),
    );
  }
}
