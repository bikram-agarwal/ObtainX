import 'package:easy_localization/easy_localization.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:obtainium/components/app_page_section_title.dart';
import 'package:obtainium/components/bulk_add_widget.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/version_regex_assist_dialog.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/pages/page_route_slide_up.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:obtainium/theme/app_form_field_styles.dart';
import 'package:obtainium/theme/app_page_icon_colors.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

enum _AddMode { byUrl, search, fromDevice }

class AddAppPage extends StatefulWidget {
  const AddAppPage({super.key});

  @override
  State<AddAppPage> createState() => AddAppPageState();
}

class AddAppPageState extends State<AddAppPage> {
  // ─── Mode ──────────────────────────────────────────────────────────────
  _AddMode _mode = _AddMode.byUrl;

  // ─── URL mode state ────────────────────────────────────────────────────
  bool gettingAppInfo = false;
  String userInput = '';
  String? pickedSourceOverride;
  String? previousPickedSourceOverride;
  AppSource? pickedSource;
  Map<String, dynamic> additionalSettings = {};
  bool additionalSettingsValid = true;
  bool inferAppIdIfOptional = true;
  List<String> pickedCategories = [];
  SourceProvider sourceProvider = SourceProvider();
  late final TextEditingController _urlFieldController;

  // ─── Device mode state ────────────────────────────────────────────────
  final GlobalKey<BulkAddWidgetState> _bulkWidgetKey = GlobalKey();

  /// True while the Device tab's bulk-add is actively saving apps.
  /// Used by [HomePageState] to suppress auto-navigation during bulk add.
  bool get isBulkAdding =>
      _mode == _AddMode.fromDevice &&
      (_bulkWidgetKey.currentState?.isAdding ?? false);

  /// Called by [HomePageState] when the user presses back while this tab is
  /// active. Returns true if the bulk flow consumed the event (moved one step
  /// back). Returns false so the caller falls through to normal tab navigation.
  bool handleBack() {
    if (_mode == _AddMode.fromDevice) {
      return _bulkWidgetKey.currentState?.handleBack() ?? false;
    }
    if (_mode == _AddMode.byUrl && _byUrlOpenedFromSearchPick) {
      setState(() {
        _byUrlOpenedFromSearchPick = false;
        _mode = _AddMode.search;
      });
      return true;
    }
    return false;
  }

  // ─── Search mode state ─────────────────────────────────────────────────
  bool searching = false;
  String searchQuery = '';
  // Searchable-source names the user has selected (null = not yet initialised)
  Set<String>? _searchSelectedStores;
  // Interleaved search results: key=URL/identifier, value=(sourceName, subtitleLines)
  Map<String, MapEntry<String, List<String>>> _searchResults = {};
  bool _searchHasSearched = false;
  String _searchResultFilter = '';
  bool _byUrlOpenedFromSearchPick = false;
  late final TextEditingController _searchSomeSourcesController;
  late final TextEditingController _searchResultFilterController;
  late final FocusNode _searchSomeSourcesFocusNode;

  void linkFn(String input) {
    try {
      if (input.isEmpty) {
        throw UnsupportedURLError();
      }
      sourceProvider.getSource(input);
      changeUserInput(input, true, false, updateUrlInput: true);
    } catch (e) {
      showError(e, context);
    }
  }

  @override
  void initState() {
    super.initState();
    _urlFieldController = TextEditingController();
    _searchSomeSourcesController = TextEditingController();
    _searchResultFilterController = TextEditingController();
    _searchSomeSourcesFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _urlFieldController.dispose();
    _searchSomeSourcesController.dispose();
    _searchResultFilterController.dispose();
    _searchSomeSourcesFocusNode.dispose();
    super.dispose();
  }

  /// Lazily initialise [_searchSelectedStores] using persisted deselections.
  Set<String> _getSearchSelectedStores(SettingsProvider settingsProvider) {
    if (_searchSelectedStores == null) {
      final deselected = settingsProvider.searchDeselected.toSet();
      _searchSelectedStores = sourceProvider.sources
          .where((e) => e.canSearch && !deselected.contains(e.name))
          .map((e) => e.name)
          .toSet();
    }
    return _searchSelectedStores!;
  }

  bool _isUrlInputValid(String value) {
    if (value.trim().isEmpty) {
      return false;
    }
    try {
      sourceProvider
          .getSource(value, overrideSource: pickedSourceOverride)
          .standardizeUrl(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  void changeUserInput(
    String input,
    bool valid,
    bool isBuilding, {
    bool updateUrlInput = false,
    String? overrideSource,
  }) {
    userInput = input;
    if (!isBuilding) {
      setState(() {
        if (overrideSource != null) {
          pickedSourceOverride = overrideSource;
        }
        bool overrideChanged =
            pickedSourceOverride != previousPickedSourceOverride;
        previousPickedSourceOverride = pickedSourceOverride;
        if (updateUrlInput) {
          _urlFieldController.text = input;
        }
        var prevHost = pickedSource?.hosts.isNotEmpty == true
            ? pickedSource?.hosts[0]
            : null;
        var source = valid
            ? sourceProvider.getSource(
                userInput,
                overrideSource: pickedSourceOverride,
              )
            : null;
        if (pickedSource.runtimeType != source.runtimeType ||
            overrideChanged ||
            (prevHost != null && prevHost != source?.hosts[0])) {
          pickedSource = source;
          pickedSource?.runOnAddAppInputChange(userInput);
          final dynamic preservedOnDemandOnly =
              additionalSettings['onDemandOnly'];
          additionalSettings = source != null
              ? getDefaultValuesFromFormItems(
                  source.combinedAppSpecificSettingFormItems,
                )
              : {};
          if (preservedOnDemandOnly == true) {
            additionalSettings['onDemandOnly'] = true;
          }
          additionalSettingsValid = source != null
              ? !sourceProvider.ifRequiredAppSpecificSettingsExist(source)
              : true;
          inferAppIdIfOptional = true;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppsProvider appsProvider = context.read<AppsProvider>();
    SettingsProvider settingsProvider = context.watch<SettingsProvider>();
    NotificationsProvider notificationsProvider = context
        .read<NotificationsProvider>();

    bool doingSomething = gettingAppInfo || searching;

    // ── Track-only / release-date confirmations (URL mode) ─────────────

    Future<bool> getTrackOnlyConfirmationIfNeeded(
      bool userPickedTrackOnly, {
      bool ignoreHideSetting = false,
    }) async {
      var useTrackOnly = userPickedTrackOnly || pickedSource!.enforceTrackOnly;
      if (useTrackOnly &&
          (!settingsProvider.hideTrackOnlyWarning || ignoreHideSetting)) {
        // ignore: use_build_context_synchronously
        var values = await showDialog(
          context: context,
          builder: (BuildContext ctx) {
            return GeneratedFormModal(
              initValid: true,
              title: tr(
                'xIsTrackOnly',
                args: [
                  pickedSource!.enforceTrackOnly ? tr('source') : tr('app'),
                ],
              ),
              items: [
                [GeneratedFormSwitch('hide', label: tr('dontShowAgain'))],
              ],
              message:
                  '${pickedSource!.enforceTrackOnly ? tr('appsFromSourceAreTrackOnly') : tr('youPickedTrackOnly')}\n\n${tr('trackOnlyAppDescription')}',
            );
          },
        );
        if (values != null) {
          settingsProvider.hideTrackOnlyWarning = values['hide'] == true;
        }
        return useTrackOnly && values != null;
      } else {
        return true;
      }
    }

    getReleaseDateAsVersionConfirmationIfNeeded(
      bool userPickedTrackOnly,
    ) async {
      return (!(additionalSettings['releaseDateAsVersion'] == true &&
          // ignore: use_build_context_synchronously
          await showDialog(
                context: context,
                builder: (BuildContext ctx) {
                  return GeneratedFormModal(
                    title: tr('releaseDateAsVersion'),
                    items: const [],
                    message: tr('releaseDateAsVersionExplanation'),
                  );
                },
              ) ==
              null));
    }

    // ── Add app (URL mode) ─────────────────────────────────────────────

    addApp({bool resetUserInputAfter = false}) async {
      setState(() {
        gettingAppInfo = true;
      });
      try {
        var userPickedTrackOnly = additionalSettings['trackOnly'] == true;
        App? app;
        if ((await getTrackOnlyConfirmationIfNeeded(userPickedTrackOnly)) &&
            (await getReleaseDateAsVersionConfirmationIfNeeded(
              userPickedTrackOnly,
            ))) {
          var trackOnly = pickedSource!.enforceTrackOnly || userPickedTrackOnly;
          app = await sourceProvider.getApp(
            pickedSource!,
            userInput.trim(),
            additionalSettings,
            trackOnlyOverride: trackOnly,
            sourceIsOverriden: pickedSourceOverride != null,
            inferAppIdIfOptional: inferAppIdIfOptional,
          );
          // Only download the APK here if you need to for the package ID
          if (isTempId(app) && app.additionalSettings['trackOnly'] != true) {
            if (!context.mounted) return;
            var apkUrl = await appsProvider.confirmAppFileUrl(
              app,
              context,
              false,
            );
            if (apkUrl == null) {
              throw ObtainiumError(tr('cancelled'));
            }
            app.preferredApkIndex = app.apkUrls
                .map((e) => e.value)
                .toList()
                .indexOf(apkUrl.value);
            // ignore: use_build_context_synchronously
            var downloadedArtifact = await appsProvider.downloadApp(
              app,
              globalNavigatorKey.currentContext,
              notificationsProvider: notificationsProvider,
            );
            DownloadedApk? downloadedFile;
            DownloadedDir? downloadedDir;
            if (downloadedArtifact is DownloadedApk) {
              downloadedFile = downloadedArtifact;
            } else {
              downloadedDir = downloadedArtifact as DownloadedDir;
            }
            app.id = downloadedFile?.appId ?? downloadedDir!.appId;
          }
          if (appsProvider.apps.containsKey(app.id)) {
            throw ObtainiumError(tr('appAlreadyAdded'));
          }
          if (app.additionalSettings['trackOnly'] == true) {
            app.installedVersion = null;
            if (isTempId(app)) {
              app.additionalSettings['trackOnlyTemporaryPackageId'] = true;
              app.additionalSettings['trackOnlyUndeterminedInstalledVersion'] =
                  true;
            } else {
              app.additionalSettings['trackOnlyTemporaryPackageId'] = false;
              final installedInfo = await getInstalledInfo(
                app.id,
                printErr: false,
              );
              if (installedInfo != null) {
                app.installedVersion =
                    app.additionalSettings['useVersionCodeAsOSVersion'] == true
                    ? installedInfo.versionCode.toString()
                    : installedInfo.versionName;
                app.additionalSettings['trackOnlyUndeterminedInstalledVersion'] =
                    false;
              } else {
                app.additionalSettings['trackOnlyUndeterminedInstalledVersion'] =
                    true;
              }
            }
          } else if (app.additionalSettings['versionDetection'] != true) {
            app.installedVersion = app.latestVersion;
          }
          app.categories = pickedCategories;
          await appsProvider.saveApps([app], onlyIfExists: false);
          final liveApp = appsProvider.apps[app.id]?.app;
          if (liveApp != null) {
            await appsProvider.assignMatchingFoldersToAppIfNeeded(liveApp);
          }
        }
        if (app != null) {
          Navigator.push(
            globalNavigatorKey.currentContext ?? context,
            heroFriendlyAppPageRoute((_) => AppPage(appId: app!.id)),
          );
        }
      } catch (e) {
        if (!context.mounted) return;
        showError(e, context);
      } finally {
        setState(() {
          gettingAppInfo = false;
          if (resetUserInputAfter) {
            changeUserInput('', false, true);
          }
        });
      }
    }

    // ── URL mode widgets ───────────────────────────────────────────────

    Widget getUrlInputRow() {
      final ColorScheme colorScheme = Theme.of(context).colorScheme;
      final bool addDisabled =
          doingSomething ||
          pickedSource == null ||
          (pickedSource!.combinedAppSpecificSettingFormItems.isNotEmpty &&
              !additionalSettingsValid);
      final Widget trailingControl = gettingAppInfo
          ? SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: ExpressiveLoadingIndicator(
                  color: colorScheme.primary,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 24,
                  ),
                ),
              ),
            )
          : Material(
              color: addDisabled
                  ? colorScheme.primary.withValues(alpha: 0.38)
                  : colorScheme.primary,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: addDisabled
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        addApp();
                      },
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Icon(
                    Icons.add,
                    color: colorScheme.onPrimary,
                    size: 22,
                  ),
                ),
              ),
            );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: _urlFieldController,
              onChanged: (String text) {
                changeUserInput(text, _isUrlInputValid(text), false);
              },
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) {
                if (!addDisabled) {
                  HapticFeedback.selectionClick();
                  addApp();
                }
              },
              decoration: appPageOutlinedInputDecoration(
                context,
                labelText: tr('appSourceURL'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          trailingControl,
        ],
      );
    }

    Widget getHTMLSourceOverrideDropdown() => Column(
      children: [
        Row(
          children: [
            Expanded(
              child: GeneratedForm(
                outlinedInputFields: true,
                items: [
                  [
                    GeneratedFormDropdown(
                      'overrideSource',
                      defaultValue: pickedSourceOverride ?? '',
                      [
                        MapEntry('', tr('none')),
                        ...sourceProvider.sources
                            .where(
                              (s) =>
                                  s.allowOverride ||
                                  (pickedSource != null &&
                                      pickedSource.runtimeType ==
                                          s.runtimeType),
                            )
                            .map(
                              (s) => MapEntry(s.runtimeType.toString(), s.name),
                            ),
                      ],
                      label: tr('overrideSource'),
                    ),
                  ],
                ],
                onValueChanges: (values, valid, isBuilding) {
                  fn() {
                    pickedSourceOverride =
                        (values['overrideSource'] == null ||
                            values['overrideSource'] == '')
                        ? null
                        : values['overrideSource'];
                  }

                  if (!isBuilding) {
                    setState(() {
                      fn();
                    });
                  } else {
                    fn();
                  }
                  changeUserInput(userInput, valid, isBuilding);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );

    Widget getAdditionalOptsCol() {
      final ColorScheme colorScheme = Theme.of(context).colorScheme;
      final TextStyle? sectionIntroStyle = Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.w600, color: colorScheme.primary);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pickedSource != null && pickedSource!.appIdInferIsOptional)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GeneratedForm(
                key: const Key('inferAppIdIfOptional'),
                outlinedInputFields: true,
                prominentSectionHeaders: true,
                wrapFormSectionsInCards: true,
                items: [
                  [
                    GeneratedFormSwitch(
                      'inferAppIdIfOptional',
                      label: tr('tryInferAppIdFromCode'),
                      defaultValue: inferAppIdIfOptional,
                    ),
                  ],
                ],
                onValueChanges: (values, valid, isBuilding) {
                  if (!isBuilding) {
                    setState(() {
                      inferAppIdIfOptional = values['inferAppIdIfOptional'];
                    });
                  }
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              tr(
                'additionalOptsFor',
                args: [pickedSource?.name ?? tr('source')],
              ),
              style: sectionIntroStyle,
            ),
          ),
          GeneratedForm(
            key: Key(
              '${pickedSource.runtimeType.toString()}-${pickedSource?.hostChanged.toString()}-${pickedSource?.hostIdenticalDespiteAnyChange.toString()}',
            ),
            outlinedInputFields: true,
            prominentSectionHeaders: true,
            wrapFormSectionsInCards: true,
            items: attachRegexAssistToItems(
              cloneFormItems([
                ...pickedSource!.combinedAppSpecificSettingFormItems,
                ...(pickedSourceOverride != null
                    ? pickedSource!.sourceConfigSettingFormItems.map((e) => [e])
                    : []),
              ]),
              rawLatestVersionFromSource: null,
              rawApkNamesFromSource: null,
              rawReleaseTitlesFromSource: null,
            ),
            onValueChanges: (values, valid, isBuilding) {
              if (!isBuilding) {
                setState(() {
                  additionalSettings = values;
                  additionalSettingsValid = valid;
                });
              }
            },
          ),
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 8),
            decoration: appPageSectionCardDecoration(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 6),
                    child: appPageCardSectionHeaderLabel(
                      context,
                      tr('categories'),
                    ),
                  ),
                  CategoryEditorSelector(
                    alignment: WrapAlignment.start,
                    showLabelWhenNotEmpty: false,
                    onSelected: (categories) {
                      pickedCategories = categories;
                    },
                  ),
                ],
              ),
            ),
          ),
          if (pickedSource != null && pickedSource!.enforceTrackOnly)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: GeneratedForm(
                key: Key(
                  '${pickedSource.runtimeType.toString()}-${pickedSource?.hostChanged.toString()}-${pickedSource?.hostIdenticalDespiteAnyChange.toString()}-appId',
                ),
                outlinedInputFields: true,
                prominentSectionHeaders: true,
                wrapFormSectionsInCards: true,
                items: [
                  [
                    GeneratedFormTextField(
                      'appId',
                      label: '${tr('appId')} - ${tr('custom')}',
                      required: false,
                      additionalValidators: [
                        (value) {
                          if (value == null || value.isEmpty) {
                            return null;
                          }
                          final isValid = RegExp(
                            r'^([A-Za-z]{1}[A-Za-z\d_]*\.)+[A-Za-z][A-Za-z\d_]*$',
                          ).hasMatch(value);
                          if (!isValid) {
                            return tr('invalidInput');
                          }
                          return null;
                        },
                      ],
                    ),
                  ],
                ],
                onValueChanges: (values, valid, isBuilding) {
                  if (!isBuilding) {
                    setState(() {
                      additionalSettings['appId'] = values['appId'];
                    });
                  }
                },
              ),
            ),
        ],
      );
    }

    Widget getSourcesListWidget() => Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        direction: Axis.horizontal,
        alignment: WrapAlignment.spaceBetween,
        spacing: 12,
        children: [
          InkWell(
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return GeneratedFormModal(
                    singleNullReturnButton: tr('ok'),
                    title: tr('supportedSources'),
                    items: const [],
                    additionalWidgets: [
                      ...sourceProvider.sources.map(
                        (e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: InkWell(
                            onTap: e.hosts.isNotEmpty
                                ? () {
                                    launchUrlString(
                                      'https://${e.hosts[0]}',
                                      mode: LaunchMode.externalApplication,
                                    );
                                  }
                                : null,
                            child: Text(
                              '${e.name}${e.enforceTrackOnly ? ' ${tr('trackOnlyInBrackets')}' : ''}${e.canSearch ? ' ${tr('searchableInBrackets')}' : ''}',
                              style: TextStyle(
                                decoration: e.hosts.isNotEmpty
                                    ? TextDecoration.underline
                                    : TextDecoration.none,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${tr('note')}:',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(tr('selfHostedNote', args: [tr('overrideSource')])),
                    ],
                  );
                },
              );
            },
            child: Text(
              tr('supportedSources'),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.underline,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          InkWell(
            onTap: () {
              launchUrlString(
                'https://apps.obtainium.imranr.dev/',
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text(
              tr('crowdsourcedConfigsShort'),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.underline,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );

    // ── Search mode widgets ────────────────────────────────────────────

    final Set<String> searchSelectedStores = _getSearchSelectedStores(
      settingsProvider,
    );

    // ── Inline search runner ───────────────────────────────────────────

    runInlineSearch({
      required AppsProvider appsProvider,
      required SettingsProvider settingsProvider,
    }) async {
      _searchSomeSourcesFocusNode.unfocus();
      FocusManager.instance.primaryFocus?.unfocus();
      _searchResultFilterController.clear();
      setState(() {
        searching = true;
        _byUrlOpenedFromSearchPick = false;
        _searchHasSearched = false;
        _searchResults = {};
        _searchResultFilter = '';
      });

      try {
        final List<String> selectedSourceNames = searchSelectedStores.toList();
        if (selectedSourceNames.isEmpty) {
          throw ObtainiumError(tr('noResults'));
        }

        List<MapEntry<String, Map<String, List<String>>>?>
        results = (await Future.wait(
          sourceProvider.sources
              .where((e) => selectedSourceNames.contains(e.name))
              .map((e) async {
                try {
                  Map<String, dynamic>? querySettings = {};
                  if (e.includeAdditionalOptsInMainSearch) {
                    querySettings = await showDialog<Map<String, dynamic>?>(
                      context: context,
                      builder: (BuildContext ctx) {
                        return GeneratedFormModal(
                          title: tr('searchX', args: [e.name]),
                          items: [
                            ...e.searchQuerySettingFormItems.map((e) => [e]),
                            [
                              GeneratedFormTextField(
                                'url',
                                label: e.hosts.isNotEmpty
                                    ? tr('overrideSource')
                                    : plural('url', 1).substring(2),
                                autoCompleteOptions: [
                                  ...(e.hosts.isNotEmpty ? [e.hosts[0]] : []),
                                  ...appsProvider.apps.values
                                      .where(
                                        (a) =>
                                            sourceProvider
                                                .getSource(
                                                  a.app.url,
                                                  overrideSource:
                                                      a.app.overrideSource,
                                                )
                                                .runtimeType ==
                                            e.runtimeType,
                                      )
                                      .map((a) {
                                        var uri = Uri.parse(a.app.url);
                                        return '${uri.origin}${uri.path}';
                                      }),
                                ],
                                defaultValue: e.hosts.isNotEmpty
                                    ? e.hosts[0]
                                    : '',
                                required: true,
                              ),
                            ],
                          ],
                        );
                      },
                    );
                    if (querySettings == null) {
                      return null;
                    }
                  }
                  return MapEntry(
                    e.runtimeType.toString(),
                    await e.search(searchQuery, querySettings: querySettings),
                  );
                } catch (err) {
                  if (err is! CredsNeededError) {
                    rethrow;
                  } else {
                    err.unexpected = true;
                    if (!context.mounted) return null;
                    showError(err, context);
                    return null;
                  }
                }
              }),
        )).where((a) => a != null).toList();

        // Interleave results from multiple sources
        Map<String, MapEntry<String, List<String>>> res = {};
        var si = 0;
        var done = false;
        while (!done) {
          done = true;
          for (var r in results) {
            var sourceName = r!.key;
            if (r.value.length > si) {
              done = false;
              var singleRes = r.value.entries.elementAt(si);
              res[singleRes.key] = MapEntry(sourceName, singleRes.value);
            }
          }
          si++;
        }

        if (!context.mounted) return;
        setState(() {
          _searchResults = res;
          _searchHasSearched = true;
        });
      } catch (e) {
        if (!context.mounted) return;
        showError(e, context);
      } finally {
        if (mounted) {
          setState(() {
            searching = false;
          });
        }
      }
    }

    // ── Search mode widgets ────────────────────────────────────────────

    Widget getSearchBarRow() {
      final ColorScheme colorScheme = Theme.of(context).colorScheme;
      final bool searchDisabled = searchQuery.isEmpty || doingSomething;
      final Widget trailingSearch = searching
          ? SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: ExpressiveLoadingIndicator(
                  color: colorScheme.primary,
                  constraints: const BoxConstraints.tightFor(
                    width: 22,
                    height: 22,
                  ),
                ),
              ),
            )
          : Material(
              color: searchDisabled
                  ? colorScheme.primary.withValues(alpha: 0.38)
                  : colorScheme.primary,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: searchDisabled
                    ? null
                    : () {
                        _searchSomeSourcesFocusNode.unfocus();
                        FocusManager.instance.primaryFocus?.unfocus();
                        HapticFeedback.selectionClick();
                        runInlineSearch(
                          appsProvider: appsProvider,
                          settingsProvider: settingsProvider,
                        );
                      },
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(
                    Icons.search,
                    color: colorScheme.onPrimary,
                    size: 22,
                  ),
                ),
              ),
            );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              focusNode: _searchSomeSourcesFocusNode,
              controller: _searchSomeSourcesController,
              onChanged: (String text) {
                setState(() {
                  searchQuery = text.trim();
                });
              },
              textInputAction: TextInputAction.search,
              onSubmitted: (_) {
                if (!(searchQuery.isEmpty || doingSomething)) {
                  _searchSomeSourcesFocusNode.unfocus();
                  HapticFeedback.selectionClick();
                  runInlineSearch(
                    appsProvider: appsProvider,
                    settingsProvider: settingsProvider,
                  );
                }
              },
              decoration: InputDecoration(
                hintText: tr('searchSomeSourcesLabel'),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.55),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          trailingSearch,
        ],
      );
    }

    Widget getSearchStoreChips() {
      final searchableSources = sourceProvider.sources
          .where((e) => e.canSearch)
          .toList();
      if (searchableSources.isEmpty) return const SizedBox.shrink();
      return Wrap(
        spacing: 8,
        runSpacing: 4,
        children: searchableSources.map((source) {
          final selected = searchSelectedStores.contains(source.name);
          return FilterChip(
            avatar: source.hosts.isNotEmpty
                ? StoreSourceChipAvatar(host: source.hosts.first, size: 16)
                : null,
            showCheckmark: false,
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(source.name),
                if (selected) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.check_rounded, size: 14),
                ],
              ],
            ),
            selected: selected,
            onSelected: (value) {
              setState(() {
                if (value) {
                  searchSelectedStores.add(source.name);
                } else {
                  searchSelectedStores.remove(source.name);
                }
                settingsProvider.searchDeselected = searchableSources
                    .map((s) => s.name)
                    .where((n) => !searchSelectedStores.contains(n))
                    .toList();
              });
            },
          );
        }).toList(),
      );
    }

    Widget getSearchResultsList() {
      if (!_searchHasSearched && _searchResults.isEmpty) {
        return const SizedBox.shrink();
      }
      if (_searchResults.isEmpty) {
        return Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Center(child: Text(tr('noResults'))),
        );
      }
      // Apply filter if the user typed one.
      final String filterQ = _searchResultFilter.trim().toLowerCase();
      final entries = _searchResults.entries.where((e) {
        if (filterQ.isEmpty) return true;
        final title = e.key.toLowerCase();
        final subtitle = e.value.value.join(' ').toLowerCase();
        return title.contains(filterQ) || subtitle.contains(filterQ);
      }).toList();

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              tr('addAppSearchResultsTitle'),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextField(
            controller: _searchResultFilterController,
            onChanged: (v) => setState(() => _searchResultFilter = v),
            decoration: InputDecoration(
              hintText: tr('filter'),
              prefixIcon: const Icon(Icons.filter_list_rounded, size: 20),
              suffixIcon: _searchResultFilter.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchResultFilterController.clear();
                        setState(() => _searchResultFilter = '');
                      },
                    )
                  : null,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
            ),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(child: Text(tr('noResults'))),
            ),
          const SizedBox(height: 8),
          ...entries.map((entry) {
            final displayTitle = entry.key;
            final sourceName = entry.value.key;
            final subtitleLines = entry.value.value;
            return Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                leading: SizedBox(
                  width: 32,
                  child: Center(child: _searchSourceIcon(sourceName)),
                ),
                title: subtitleLines.isNotEmpty
                    ? Text(
                        subtitleLines.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Text(
                        displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                subtitle: subtitleLines.isNotEmpty
                    ? Text(
                        displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    : null,
                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                onTap: () {
                  // Fill URL mode with selected result and switch to it
                  changeUserInput(
                    displayTitle,
                    true,
                    false,
                    updateUrlInput: true,
                    overrideSource: sourceName,
                  );
                  setState(() {
                    _byUrlOpenedFromSearchPick = true;
                    _mode = _AddMode.byUrl;
                  });
                },
              ),
            );
          }),
        ],
      );
    }

    // ── Mode selector ──────────────────────────────────────────────────

    Widget buildModeSelector() {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: SegmentedButton<_AddMode>(
          segments: [
            ButtonSegment(
              value: _AddMode.byUrl,
              label: Text(tr('addByUrl')),
              icon: const Icon(Icons.link_rounded),
            ),
            ButtonSegment(
              value: _AddMode.search,
              label: Text(tr('addBySearch')),
              icon: const Icon(Icons.search_rounded),
            ),
            ButtonSegment(
              value: _AddMode.fromDevice,
              label: Text(tr('addFromDevice')),
              icon: const Icon(Icons.phone_android_rounded),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (Set<_AddMode> selection) {
            setState(() {
              _byUrlOpenedFromSearchPick = false;
              _mode = selection.first;
            });
          },
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
      );
    }

    // ── Layout ─────────────────────────────────────────────────────────

    // Device mode uses a plain Column so the BulkAddWidget always gets a clean
    // bounded height via Expanded, with no outer CustomScrollView that could
    // steal scroll gestures or push content off-screen.
    if (_mode == _AddMode.fromDevice) {
      final ColorScheme deviceScheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: deviceScheme.surface,
        appBar: AppBar(
          title: Text(tr('addApp')),
          automaticallyImplyLeading: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: deviceScheme.surface,
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            buildModeSelector(),
            Expanded(
              child: BulkAddWidget(
                key: _bulkWidgetKey,
                onComplete: () => setState(() {
                  _byUrlOpenedFromSearchPick = false;
                  _mode = _AddMode.byUrl;
                }),
              ),
            ),
          ],
        ),
      );
    }

    final ColorScheme addScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: addScheme.surface,
      // Show supported-sources footer only for URL mode when no source is detected
      bottomNavigationBar: (_mode == _AddMode.byUrl && pickedSource == null)
          ? getSourcesListWidget()
          : null,
      body: Stack(
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
                      addScheme.schemePageGradientTopColor,
                      addScheme.schemePageGradientMidColor,
                      addScheme.surface,
                      addScheme.surface,
                    ],
                  ),
                ),
              ),
            ),
          CustomScrollView(
            key: const PageStorageKey<String>('add-app-tab-scroll'),
            cacheExtent: 1600,
            slivers: <Widget>[
              CustomAppBar(title: tr('addApp')),
              // Mode selector pinned just below the app bar
              SliverPersistentHeader(
                pinned: false,
                delegate: _PaddedWidgetDelegate(
                  child: buildModeSelector(),
                  height: 60,
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(
                      key: ValueKey(_mode),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // ── By URL ─────────────────────────────────────
                          if (_mode == _AddMode.byUrl) ...[
                            const SizedBox(height: 8),
                            getUrlInputRow(),
                            const SizedBox(height: 16),
                            if (pickedSource != null)
                              getHTMLSourceOverrideDropdown(),
                            if (pickedSource != null)
                              FutureBuilder(
                                builder: (ctx, val) {
                                  return val.data != null &&
                                          val.data!.isNotEmpty
                                      ? Text(
                                          val.data!,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        )
                                      : const SizedBox();
                                },
                                future: pickedSource?.getSourceNote(),
                              ),
                            if (pickedSource != null) getAdditionalOptsCol(),
                          ],

                          // ── Search ─────────────────────────────────────
                          if (_mode == _AddMode.search) ...[
                            const SizedBox(height: 8),
                            getSearchBarRow(),
                            const SizedBox(height: 12),
                            Text(
                              tr('storesToSearch'),
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            getSearchStoreChips(),
                            getSearchResultsList(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (settingsProvider.progressiveBlurEnabled)
                SliverToBoxAdapter(
                  child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Small icon to indicate which source a search result came from.
  Widget _searchSourceIcon(String sourceName) {
    final String? assetPath = storeSourceAssetPathForClassName(sourceName);
    if (assetPath == null) return const Icon(Icons.store_rounded, size: 20);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    Widget img = StoreSourceIconImage(assetPath: assetPath, size: 20);
    if (iconNeedsInversion(assetPath, isDark)) {
      img = ColorFiltered(colorFilter: invertColorFilter, child: img);
    }
    return img;
  }
}

/// Minimal [SliverPersistentHeaderDelegate] for a fixed-height widget.
class _PaddedWidgetDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;

  const _PaddedWidgetDelegate({required this.child, required this.height});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(color: Theme.of(context).colorScheme.surface, child: child);
  }

  @override
  bool shouldRebuild(_PaddedWidgetDelegate oldDelegate) =>
      oldDelegate.child != child || oldDelegate.height != height;
}
