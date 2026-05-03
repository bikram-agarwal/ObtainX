import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:progress_indicator_m3e/progress_indicator_m3e.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Human-readable label for a SAF tree [Uri] (Android document tree).
String apkSaveTreeUriDisplayLabel(Uri uri) {
  final String path = uri.path;
  if (path.startsWith('/tree/')) {
    return Uri.decodeComponent(path.substring('/tree/'.length));
  }
  if (path.isNotEmpty) {
    final String withoutLeadingSlash = path.startsWith('/')
        ? path.substring(1)
        : path;
    return Uri.decodeComponent(withoutLeadingSlash);
  }
  return uri.toString();
}

/// Display path for SAF tree URIs, with `primary:` storage prefix removed.
String folderDisplayPathFromTreeUri(Uri uri) {
  String label = apkSaveTreeUriDisplayLabel(uri);
  const String primaryPrefix = 'primary:';
  if (label.startsWith(primaryPrefix)) {
    return label.substring(primaryPrefix.length);
  }
  return label;
}

class ImportExportPage extends StatefulWidget {
  const ImportExportPage({super.key});

  @override
  State<ImportExportPage> createState() => _ImportExportPageState();
}

class _ImportExportPageState extends State<ImportExportPage> {
  bool importInProgress = false;

  @override
  Widget build(BuildContext context) {
    SourceProvider sourceProvider = SourceProvider();
    // [appsProvider] is intentionally a broad watch — this page lists
    // every tracked app to drive the export selection, and any add /
    // remove / rename should refresh the list. The expensive cost is
    // [settingsProvider] which used to broad-watch and rebuild this
    // long page on every unrelated settings change. Narrow it to only
    // the four fields actually read in build.
    var appsProvider = context.watch<AppsProvider>();
    context.select<SettingsProvider, int>(
      (s) => Object.hash(
        s.useGradientBackground,
        s.saveDownloadedApkCopies,
        s.exportSettings,
        s.autoExportOnChanges,
      ),
    );
    var settingsProvider = context.read<SettingsProvider>();

    var outlineButtonStyle = ButtonStyle(
      shape: WidgetStateProperty.all(
        StadiumBorder(
          side: BorderSide(
            width: 1,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );

    urlListImport({String? initValue, bool overrideInitValid = false}) {
      showDialog<Map<String, dynamic>?>(
        context: context,
        builder: (BuildContext ctx) {
          return GeneratedFormModal(
            initValid: overrideInitValid,
            title: tr('importFromURLList'),
            items: [
              [
                GeneratedFormTextField(
                  'appURLList',
                  defaultValue: initValue ?? '',
                  label: tr('appURLList'),
                  max: 7,
                  additionalValidators: [
                    (dynamic value) {
                      if (value != null && value.isNotEmpty) {
                        var lines = value.trim().split('\n');
                        for (int i = 0; i < lines.length; i++) {
                          try {
                            sourceProvider.getSource(lines[i]);
                          } catch (e) {
                            return '${tr('line')} ${i + 1}: $e';
                          }
                        }
                      }
                      return null;
                    },
                  ],
                ),
              ],
            ],
          );
        },
      ).then((values) {
        if (values != null) {
          var urls = (values['appURLList'] as String).split('\n');
          setState(() {
            importInProgress = true;
          });
          appsProvider
              .addAppsByURL(urls)
              .then((errors) {
                if (!context.mounted) return;
                if (errors.isEmpty) {
                  showMessage(
                    tr(
                      'importedX',
                      args: [plural('apps', urls.length).toLowerCase()],
                    ),
                    context,
                  );
                } else {
                  showDialog(
                    context: context,
                    builder: (BuildContext ctx) {
                      return ImportErrorDialog(
                        urlsLength: urls.length,
                        errors: errors,
                      );
                    },
                  );
                }
              })
              .catchError((e) {
                if (!context.mounted) return;
                showError(e, context);
              })
              .whenComplete(() {
                setState(() {
                  importInProgress = false;
                });
              });
        }
      });
    }

    runObtainiumExport({bool pickOnly = false}) async {
      HapticFeedback.selectionClick();
      appsProvider
          .export(
            pickOnly:
                pickOnly || (await settingsProvider.getExportDir()) == null,
            sp: settingsProvider,
          )
          .then((String? result) {
            if (!context.mounted) return;
            if (result != null) {
              showMessage(tr('exportedTo', args: [result]), context);
            }
            setState(() {});
          })
          .catchError((e) {
            if (!context.mounted) return;
            showError(e, context);
          });
    }

    runObtainiumImport() {
      HapticFeedback.selectionClick();
      FilePicker.pickFiles()
          .then((result) async {
            setState(() {
              importInProgress = true;
            });
            if (result != null) {
              // [readAsString] (async) instead of [readAsStringSync] so a
              // multi-megabyte backup file doesn't freeze the UI thread
              // while it's being slurped in.
              String data = await File(
                result.files.single.path!,
              ).readAsString();
              try {
                jsonDecode(data);
              } catch (e) {
                throw ObtainiumError(tr('invalidInput'));
              }
              appsProvider.import(data).then((value) {
                if (!context.mounted) return;
                var cats = settingsProvider.categories;
                appsProvider.apps.forEach((key, value) {
                  for (var c in value.app.categories) {
                    if (!cats.containsKey(c)) {
                      cats[c] = generateRandomLightColor().toARGB32();
                    }
                  }
                });
                appsProvider.addMissingCategories(settingsProvider);
                showMessage(
                  '${tr('importedX', args: [plural('apps', value.key.length).toLowerCase()])}${value.value ? ' + ${tr('settings').toLowerCase()}' : ''}',
                  context,
                );
              });
            } else {
              // User canceled the picker
            }
          })
          .catchError((e) {
            if (!context.mounted) return;
            showError(e, context);
          })
          .whenComplete(() {
            setState(() {
              importInProgress = false;
            });
          });
    }

    runUrlImport() {
      FilePicker.pickFiles().then((result) async {
        if (result != null) {
          // Async read so picking a large URL-list dump doesn't freeze the UI.
          final String fileContents = await File(
            result.files.single.path!,
          ).readAsString();
          if (!context.mounted) return;
          urlListImport(
            overrideInitValid: true,
            initValue: RegExp('https?://[^"]+')
                .allMatches(fileContents)
                .map((e) => e.input.substring(e.start, e.end))
                .toSet()
                .toList()
                .where((url) {
                  try {
                    sourceProvider.getSource(url);
                    return true;
                  } catch (e) {
                    return false;
                  }
                })
                .join('\n'),
          );
        }
      });
    }

    runSourceSearch(AppSource source) {
      () async {
            var values = await showDialog<Map<String, dynamic>?>(
              context: context,
              builder: (BuildContext ctx) {
                return GeneratedFormModal(
                  title: tr('searchX', args: [source.name]),
                  items: [
                    [
                      GeneratedFormTextField(
                        'searchQuery',
                        label: tr('searchQuery'),
                        required: source.name != FDroidRepo().name,
                      ),
                    ],
                    ...source.searchQuerySettingFormItems.map((e) => [e]),
                    [
                      GeneratedFormTextField(
                        'url',
                        label: source.hosts.isNotEmpty
                            ? tr('overrideSource')
                            : plural('url', 1).substring(2),
                        defaultValue: source.hosts.isNotEmpty
                            ? source.hosts[0]
                            : '',
                        required: true,
                      ),
                    ],
                  ],
                );
              },
            );
            if (values != null) {
              setState(() {
                importInProgress = true;
              });
              if (source.hosts.isEmpty || values['url'] != source.hosts[0]) {
                source = sourceProvider.getSource(
                  values['url'],
                  overrideSource: source.runtimeType.toString(),
                );
              }
              var urlsWithDescriptions = await source.search(
                values['searchQuery'] as String,
                querySettings: values,
              );
              if (urlsWithDescriptions.isNotEmpty) {
                if (!context.mounted) return;
                var selectedUrls = await showDialog<List<String>?>(
                  context: context,
                  builder: (BuildContext ctx) {
                    return SelectionModal(
                      entries: urlsWithDescriptions,
                      selectedByDefault: false,
                    );
                  },
                );
                if (selectedUrls != null && selectedUrls.isNotEmpty) {
                  var errors = await appsProvider.addAppsByURL(
                    selectedUrls,
                    sourceOverride: source,
                  );
                  if (!context.mounted) return;
                  if (errors.isEmpty) {
                    showMessage(
                      tr(
                        'importedX',
                        args: [
                          plural('apps', selectedUrls.length).toLowerCase(),
                        ],
                      ),
                      context,
                    );
                  } else {
                    showDialog(
                      context: context,
                      builder: (BuildContext ctx) {
                        return ImportErrorDialog(
                          urlsLength: selectedUrls.length,
                          errors: errors,
                        );
                      },
                    );
                  }
                }
              } else {
                throw ObtainiumError(tr('noResults'));
              }
            }
          }()
          .catchError((e) {
            if (!context.mounted) return;
            showError(e, context);
          })
          .whenComplete(() {
            setState(() {
              importInProgress = false;
            });
          });
    }

    runMassSourceImport(MassAppUrlSource source) {
      () async {
            var values = await showDialog<Map<String, dynamic>?>(
              context: context,
              builder: (BuildContext ctx) {
                return GeneratedFormModal(
                  title: tr('importX', args: [source.name]),
                  items: source.requiredArgs
                      .map((e) => [GeneratedFormTextField(e, label: e)])
                      .toList(),
                );
              },
            );
            if (values != null) {
              setState(() {
                importInProgress = true;
              });
              var urlsWithDescriptions = await source.getUrlsWithDescriptions(
                values.values.map((e) => e.toString()).toList(),
              );
              if (!context.mounted) return;
              var selectedUrls = await showDialog<List<String>?>(
                context: context,
                builder: (BuildContext ctx) {
                  return SelectionModal(entries: urlsWithDescriptions);
                },
              );
              if (selectedUrls != null) {
                var errors = await appsProvider.addAppsByURL(selectedUrls);
                if (!context.mounted) return;
                if (errors.isEmpty) {
                  showMessage(
                    tr(
                      'importedX',
                      args: [plural('apps', selectedUrls.length).toLowerCase()],
                    ),
                    context,
                  );
                } else {
                  showDialog(
                    context: context,
                    builder: (BuildContext ctx) {
                      return ImportErrorDialog(
                        urlsLength: selectedUrls.length,
                        errors: errors,
                      );
                    },
                  );
                }
              }
            }
          }()
          .catchError((e) {
            if (!context.mounted) return;
            showError(e, context);
          })
          .whenComplete(() {
            setState(() {
              importInProgress = false;
            });
          });
    }

    var sourceStrings = <String, List<String>>{};
    sourceProvider.sources.where((e) => e.canSearch).forEach((s) {
      sourceStrings[s.name] = [s.name];
    });

    final ColorScheme impScheme = Theme.of(context).colorScheme;

    /// Folder picker rows with a title + subtitle (more vertical air).
    const EdgeInsets importPageCardFolderRowPadding = EdgeInsets.fromLTRB(
      16,
      12,
      16,
      12,
    );

    /// Other padded rows inside [importPageCard] (dropdowns, buttons, batch grid).
    const EdgeInsets importPageCardRowPadding = EdgeInsets.fromLTRB(
      16,
      8,
      16,
      8,
    );
    const EdgeInsets importPageCardSwitchTilePadding = EdgeInsets.fromLTRB(
      16,
      0,
      16,
      4,
    );
    const double importPageCardRowItemGap = 12;
    const double importPageBatchCellGap = 4;

    Widget importPageCard(List<Widget> cardItems) {
      return m3eExpressiveSettingsCard(
        context: context,
        colorScheme: impScheme,
        items: cardItems,
      );
    }

    Widget importPageSectionTitle(
      String title,
      IconData icon, {
      double topPadding = 20,
      double bottomPadding = 8,
    }) {
      return Padding(
        padding: EdgeInsets.fromLTRB(4, topPadding, 4, bottomPadding),
        child: Row(
          children: [
            Icon(icon, color: impScheme.primary, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: impScheme.primary,
                  fontSize: 13,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget resettableImportPageRow({
      required Widget child,
      required VoidCallback? onReset,
    }) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onReset == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onReset();
              },
        child: child,
      );
    }

    final ButtonStyle folderPickOutlineStyle = outlineButtonStyle.merge(
      ButtonStyle(
        padding: WidgetStateProperty.all(const EdgeInsets.all(10)),
        minimumSize: WidgetStateProperty.all(Size.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );

    Widget folderOutlineIconButton({
      required String tooltipMessage,
      required VoidCallback? onPressed,
    }) {
      return Tooltip(
        message: tooltipMessage,
        child: TextButton(
          style: folderPickOutlineStyle,
          onPressed: onPressed,
          child: Icon(Icons.folder_open_rounded, color: impScheme.primary),
        ),
      );
    }

    final List<Widget> batchImportCells = [
      TextButton(
        style: outlineButtonStyle,
        onPressed: importInProgress
            ? null
            : () async {
                var searchSourceName =
                    await showDialog<List<String>?>(
                      context: context,
                      builder: (BuildContext ctx) {
                        return SelectionModal(
                          title: tr(
                            'selectX',
                            args: [tr('source').toLowerCase()],
                          ),
                          entries: sourceStrings,
                          selectedByDefault: false,
                          onlyOneSelectionAllowed: true,
                          titlesAreLinks: false,
                        );
                      },
                    ) ??
                    [];
                var searchSource = sourceProvider.sources
                    .where((e) => searchSourceName.contains(e.name))
                    .toList();
                if (searchSource.isNotEmpty) {
                  runSourceSearch(searchSource[0]);
                }
              },
        child: Text(
          tr('searchX', args: [lowerCaseIfEnglish(tr('source'))]),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
        ),
      ),
      TextButton(
        style: outlineButtonStyle,
        onPressed: importInProgress ? null : urlListImport,
        child: Text(
          tr('importFromURLList'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
        ),
      ),
      TextButton(
        style: outlineButtonStyle,
        onPressed: importInProgress ? null : runUrlImport,
        child: Text(
          tr('importFromURLsInFile'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
        ),
      ),
      ...sourceProvider.massUrlSources.map(
        (source) => TextButton(
          style: outlineButtonStyle,
          onPressed: importInProgress
              ? null
              : () {
                  runMassSourceImport(source);
                },
          child: Text(
            tr('importX', args: [source.name]),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontSize: 13),
          ),
        ),
      ),
    ];

    return Scaffold(
      backgroundColor: impScheme.surface,
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
                      impScheme.schemePageGradientTopColor,
                      impScheme.schemePageGradientMidColor,
                      impScheme.surface,
                      impScheme.surface,
                    ],
                  ),
                ),
              ),
            ),
          CustomScrollView(
            key: const PageStorageKey<String>('import-export-tab-scroll'),
            cacheExtent: 1600,
            slivers: <Widget>[
              CustomAppBar(title: tr('importExport')),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  8 + MediaQuery.paddingOf(context).bottom,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (Platform.isAndroid) ...[
                        importPageSectionTitle(
                          tr('importExportCardUpdateAssets'),
                          Icons.system_update_rounded,
                        ),
                        FutureBuilder<Uri?>(
                          future: settingsProvider.getApkSaveDir(),
                          builder: (context, apkSaveSnapshot) {
                            final String apkFolderTitle =
                                apkSaveSnapshot.data == null
                                ? tr('pickApkSaveDir')
                                : folderDisplayPathFromTreeUri(
                                    apkSaveSnapshot.data!,
                                  );
                            return importPageCard([
                              resettableImportPageRow(
                                onReset:
                                    importInProgress ||
                                        apkSaveSnapshot.data == null
                                    ? null
                                    : () async {
                                        await settingsProvider.pickApkSaveDir(
                                          remove: true,
                                        );
                                        if (context.mounted) {
                                          setState(() {});
                                        }
                                      },
                                child: Padding(
                                  padding: importPageCardFolderRowPadding,
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              apkFolderTitle,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              tr('apkSaveFolderDescription'),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: impScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      folderOutlineIconButton(
                                        tooltipMessage: tr('pickApkSaveDir'),
                                        onPressed: importInProgress
                                            ? null
                                            : () async {
                                                await settingsProvider
                                                    .pickApkSaveDir();
                                                if (context.mounted) {
                                                  setState(() {});
                                                }
                                              },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              SwitchListTile(
                                visualDensity: VisualDensity.compact,
                                contentPadding: importPageCardSwitchTilePadding,
                                title: Text(tr('saveDownloadedApkCopies')),
                                value: settingsProvider.saveDownloadedApkCopies,
                                onChanged: importInProgress
                                    ? null
                                    : (bool enabled) {
                                        settingsProvider
                                                .saveDownloadedApkCopies =
                                            enabled;
                                      },
                              ),
                            ]);
                          },
                        ),
                      ],
                      importPageSectionTitle(
                        tr('importExportCardObtainxBackup'),
                        Icons.save_as_rounded,
                      ),
                      FutureBuilder<Uri?>(
                        future: settingsProvider.getExportDir(),
                        builder: (context, exportSnapshot) {
                          return importPageCard([
                            resettableImportPageRow(
                              onReset:
                                  importInProgress ||
                                      exportSnapshot.data == null
                                  ? null
                                  : () async {
                                      await settingsProvider.pickExportDir(
                                        remove: true,
                                      );
                                      if (context.mounted) {
                                        setState(() {});
                                      }
                                    },
                              child: Padding(
                                padding: importPageCardFolderRowPadding,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            exportSnapshot.data == null
                                                ? tr('pickConfigExportFolder')
                                                : folderDisplayPathFromTreeUri(
                                                    exportSnapshot.data!,
                                                  ),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleSmall,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            tr('configExportFolderDescription'),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: impScheme
                                                      .onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    folderOutlineIconButton(
                                      tooltipMessage: tr('pickExportDir'),
                                      onPressed: importInProgress
                                          ? null
                                          : () {
                                              runObtainiumExport(
                                                pickOnly: true,
                                              );
                                            },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: importPageCardRowPadding,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      right: importPageCardRowItemGap,
                                    ),
                                    child: Text(
                                      tr('importExportIncludeInBackup'),
                                    ),
                                  ),
                                  Expanded(
                                    child: m3eCompactDropdownScope(
                                      context: context,
                                      child: DropdownMenu<int>(
                                        key: ValueKey(
                                          settingsProvider.exportSettings,
                                        ),
                                        initialSelection:
                                            settingsProvider.exportSettings,
                                        expandedInsets: EdgeInsets.zero,
                                        onSelected: (int? selected) {
                                          if (selected != null) {
                                            settingsProvider.exportSettings =
                                                selected;
                                          }
                                        },
                                        dropdownMenuEntries: [
                                          DropdownMenuEntry<int>(
                                            value: 0,
                                            label: tr(
                                              'importExportBackupScopeOnlyApps',
                                            ),
                                          ),
                                          DropdownMenuEntry<int>(
                                            value: 1,
                                            label: tr(
                                              'importExportBackupScopeAppsSettingsNoSecrets',
                                            ),
                                          ),
                                          DropdownMenuEntry<int>(
                                            value: 2,
                                            label: tr(
                                              'importExportBackupScopeAllAppsAndSettings',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SwitchListTile(
                              visualDensity: VisualDensity.compact,
                              contentPadding: importPageCardSwitchTilePadding,
                              title: Text(tr('autoExportOnChanges')),
                              value: settingsProvider.autoExportOnChanges,
                              onChanged: importInProgress
                                  ? null
                                  : (bool value) {
                                      settingsProvider.autoExportOnChanges =
                                          value;
                                    },
                            ),
                            Padding(
                              padding: importPageCardRowPadding,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextButton(
                                      style: outlineButtonStyle,
                                      onPressed: importInProgress
                                          ? null
                                          : runObtainiumImport,
                                      child: Text(tr('obtainiumImport')),
                                    ),
                                  ),
                                  const SizedBox(
                                    width: importPageCardRowItemGap,
                                  ),
                                  Expanded(
                                    child: TextButton(
                                      style: outlineButtonStyle,
                                      onPressed:
                                          importInProgress ||
                                              exportSnapshot.data == null
                                          ? null
                                          : runObtainiumExport,
                                      child: Text(tr('obtainiumExport')),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ]);
                        },
                      ),
                      if (importInProgress) ...[
                        const SizedBox(height: 14),
                        const LinearProgressIndicatorM3E(),
                        const SizedBox(height: 14),
                      ],
                      importPageSectionTitle(
                        tr('importExportCardBatchImports'),
                        Icons.playlist_add_rounded,
                      ),
                      importPageCard([
                        Padding(
                          padding: importPageCardRowPadding,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (
                                int rowStart = 0;
                                rowStart < batchImportCells.length;
                                rowStart += 2
                              ) ...[
                                if (rowStart > 0)
                                  const SizedBox(
                                    height: importPageBatchCellGap,
                                  ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: batchImportCells[rowStart]),
                                    const SizedBox(width: importPageBatchCellGap),
                                    Expanded(
                                      child:
                                          rowStart + 1 < batchImportCells.length
                                          ? batchImportCells[rowStart + 1]
                                          : const SizedBox.shrink(),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Text(
                        tr('importedAppsIdDisclaimer'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontStyle: FontStyle.italic,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ImportErrorDialog extends StatefulWidget {
  const ImportErrorDialog({
    super.key,
    required this.urlsLength,
    required this.errors,
  });

  final int urlsLength;
  final List<List<String>> errors;

  @override
  State<ImportErrorDialog> createState() => _ImportErrorDialogState();
}

class _ImportErrorDialogState extends State<ImportErrorDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(tr('importErrors')),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              'importedXOfYApps',
              args: [
                (widget.urlsLength - widget.errors.length).toString(),
                widget.urlsLength.toString(),
              ],
            ),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          Text(
            tr('followingURLsHadErrors'),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          ...widget.errors.map((e) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                Text(e[0]),
                Text(e[1], style: const TextStyle(fontStyle: FontStyle.italic)),
              ],
            );
          }),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop(null);
          },
          child: Text(tr('ok')),
        ),
      ],
    );
  }
}

// ignore: must_be_immutable
class SelectionModal extends StatefulWidget {
  SelectionModal({
    super.key,
    required this.entries,
    this.selectedByDefault = true,
    this.onlyOneSelectionAllowed = false,
    this.titlesAreLinks = true,
    this.title,
    this.deselectThese = const [],
    this.presentAsBottomSheet = false,
    this.showFilterField = true,
  });

  String? title;
  Map<String, List<String>> entries;
  bool selectedByDefault;
  List<String> deselectThese;
  bool onlyOneSelectionAllowed;
  bool titlesAreLinks;

  /// When true, [build] returns sheet content for [showModalBottomSheet] (drag handle, rounded top).
  bool presentAsBottomSheet;

  /// When false, the regex filter field is hidden (for short lists such as searchable sources).
  bool showFilterField;

  @override
  State<SelectionModal> createState() => _SelectionModalState();
}

class _SelectionModalState extends State<SelectionModal> {
  Map<MapEntry<String, List<String>>, bool> entrySelections = {};
  String filterRegex = '';
  @override
  void initState() {
    super.initState();
    for (var entry in widget.entries.entries) {
      entrySelections.putIfAbsent(
        entry,
        () =>
            widget.selectedByDefault &&
            !widget.onlyOneSelectionAllowed &&
            !widget.deselectThese.contains(entry.key),
      );
    }
    if (widget.selectedByDefault && widget.onlyOneSelectionAllowed) {
      selectOnlyOne(widget.entries.entries.first.key);
    }
    if (widget.presentAsBottomSheet) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        FocusManager.instance.primaryFocus?.unfocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            FocusManager.instance.primaryFocus?.unfocus();
          }
        });
      });
    }
  }

  void selectOnlyOne(String url) {
    for (var e in entrySelections.keys) {
      entrySelections[e] = e.key == url;
    }
  }

  void selectAll({bool deselect = false}) {
    for (var e in entrySelections.keys) {
      entrySelections[e] = !deselect;
    }
  }

  @override
  Widget build(BuildContext context) {
    Map<MapEntry<String, List<String>>, bool> filteredEntrySelections = {};
    entrySelections.forEach((key, value) {
      var searchableText = key.value.isEmpty ? key.key : key.value[0];
      if (filterRegex.isEmpty || RegExp(filterRegex).hasMatch(searchableText)) {
        filteredEntrySelections.putIfAbsent(key, () => value);
      }
    });
    if (filterRegex.isNotEmpty && filteredEntrySelections.isEmpty) {
      entrySelections.forEach((key, value) {
        var searchableText = key.value.isEmpty ? key.key : key.value[0];
        if (filterRegex.isEmpty ||
            RegExp(
              filterRegex,
              caseSensitive: false,
            ).hasMatch(searchableText)) {
          filteredEntrySelections.putIfAbsent(key, () => value);
        }
      });
    }
    getSelectAllButton() {
      if (widget.onlyOneSelectionAllowed) {
        return const SizedBox.shrink();
      }
      var noneSelected = entrySelections.values.where((v) => v == true).isEmpty;
      return noneSelected
          ? TextButton(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onPressed: () {
                setState(() {
                  selectAll();
                });
              },
              child: Text(tr('selectAll')),
            )
          : TextButton(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onPressed: () {
                setState(() {
                  selectAll(deselect: true);
                });
              },
              child: Text(tr('deselectX', args: [''])),
            );
    }

    final Widget? filterFormWidget = widget.showFilterField
        ? GeneratedForm(
            outlinedInputFields: true,
            prominentSectionHeaders: false,
            wrapFormSectionsInCards: false,
            items: [
              [
                GeneratedFormTextField(
                  'filter',
                  label: tr('filter'),
                  required: false,
                  additionalValidators: [
                    (value) {
                      return regExValidator(value);
                    },
                  ],
                ),
              ],
            ],
            onValueChanges: (value, valid, isBuilding) {
              if (valid && !isBuilding) {
                if (value['filter'] != null) {
                  setState(() {
                    filterRegex = value['filter'];
                  });
                }
              }
            },
          )
        : null;

    final List<Widget> entryTileWidgets = filteredEntrySelections.keys.map((
      entry,
    ) {
      selectThis(bool? value) {
        setState(() {
          value ??= false;
          if (value! && widget.onlyOneSelectionAllowed) {
            selectOnlyOne(entry.key);
          } else {
            entrySelections[entry] = value!;
          }
        });
      }

      var urlLink = GestureDetector(
        onTap: !widget.titlesAreLinks
            ? null
            : () {
                launchUrlString(
                  entry.key,
                  mode: LaunchMode.externalApplication,
                );
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.value.isEmpty ? entry.key : entry.value[0],
              style: TextStyle(
                decoration: widget.titlesAreLinks
                    ? TextDecoration.underline
                    : null,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.start,
            ),
            if (widget.titlesAreLinks)
              Text(
                Uri.parse(entry.key).host,
                style: const TextStyle(
                  decoration: TextDecoration.underline,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      );

      var descriptionText = entry.value.length <= 1
          ? const SizedBox.shrink()
          : Text(
              entry.value[1].length > 128
                  ? '${entry.value[1].substring(0, 128)}...'
                  : entry.value[1],
              style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
            );

      var selectedEntries = entrySelections.entries
          .where((e) => e.value)
          .toList();

      var singleSelectTile = RadioGroup<String>(
        groupValue: selectedEntries.isEmpty
            ? null
            : selectedEntries.first.key.key,
        onChanged: (String? value) {
          if (value != null) {
            setState(() {
              selectOnlyOne(value);
            });
          }
        },
        child: ListTile(
          title: GestureDetector(
            onTap: widget.titlesAreLinks
                ? null
                : () {
                    selectThis(!(entrySelections[entry] ?? false));
                  },
            child: urlLink,
          ),
          subtitle: entry.value.length <= 1
              ? null
              : GestureDetector(
                  onTap: () {
                    setState(() {
                      selectOnlyOne(entry.key);
                    });
                  },
                  child: descriptionText,
                ),
          leading: Radio<String>(value: entry.key),
        ),
      );

      var multiSelectTile = SwitchListTile(
        title: GestureDetector(
          onTap: widget.titlesAreLinks
              ? null
              : () {
                  selectThis(!(entrySelections[entry] ?? false));
                },
          child: urlLink,
        ),
        subtitle: entry.value.length <= 1
            ? null
            : GestureDetector(
                onTap: () {
                  selectThis(!(entrySelections[entry] ?? false));
                },
                child: descriptionText,
              ),
        value: entrySelections[entry] ?? false,
        onChanged: (bool value) {
          selectThis(value);
        },
      );

      return widget.onlyOneSelectionAllowed
          ? singleSelectTile
          : multiSelectTile;
    }).toList();

    final List<Widget> sheetColumnChildren = [
      ?filterFormWidget,
      ...entryTileWidgets,
    ];

    final List<Widget> selectionActions = [
      getSelectAllButton(),
      TextButton(
        onPressed: () {
          Navigator.of(context).pop();
        },
        child: Text(tr('cancel')),
      ),
      TextButton(
        onPressed: entrySelections.values.where((b) => b).isEmpty
            ? null
            : () {
                Navigator.of(context).pop(
                  entrySelections.entries
                      .where((entry) => entry.value)
                      .map((e) => e.key.key)
                      .toList(),
                );
              },
        child: Text(
          widget.onlyOneSelectionAllowed
              ? tr('pick')
              : tr(
                  'selectX',
                  args: [
                    entrySelections.values.where((b) => b).length.toString(),
                  ],
                ),
        ),
      ),
    ];

    if (widget.presentAsBottomSheet) {
      final ColorScheme colorScheme = Theme.of(context).colorScheme;
      final double screenHeight = MediaQuery.sizeOf(context).height;
      final EdgeInsets viewPadding = MediaQuery.paddingOf(context);
      // Max height for the sheet column — from just below the status bar.
      final double areaBelowStatusBar = screenHeight - viewPadding.top - 16;

      void popWithSelectedKeys() {
        Navigator.of(context).pop(
          entrySelections.entries
              .where(
                (MapEntry<MapEntry<String, List<String>>, bool> e) => e.value,
              )
              .map(
                (MapEntry<MapEntry<String, List<String>>, bool> e) => e.key.key,
              )
              .toList(),
        );
      }

      final bool hasSelection = entrySelections.values.any(
        (bool selected) => selected,
      );

      final double sheetBottomInset = MediaQuery.paddingOf(context).bottom + 20;

      Widget sheetIconBar() {
        Widget slot(Widget child) => Expanded(child: Center(child: child));
        if (widget.onlyOneSelectionAllowed) {
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, sheetBottomInset),
            child: Row(
              children: [
                slot(
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 24,
                    color: colorScheme.primary,
                    tooltip: tr('cancel'),
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                ),
                slot(
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 24,
                    color: colorScheme.primary,
                    tooltip: tr('continue'),
                    icon: const Icon(Icons.check),
                    onPressed: hasSelection ? popWithSelectedKeys : null,
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, sheetBottomInset),
          child: Row(
            children: [
              slot(
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  tooltip: tr('selectAll'),
                  icon: const Icon(Icons.select_all_outlined),
                  onPressed: () {
                    setState(() {
                      selectAll();
                    });
                  },
                ),
              ),
              slot(
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  tooltip: tr('deselectAll'),
                  icon: const Icon(Icons.deselect),
                  onPressed: () {
                    setState(() {
                      selectAll(deselect: true);
                    });
                  },
                ),
              ),
              slot(
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  tooltip: tr('cancel'),
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ),
              slot(
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  color: colorScheme.primary,
                  tooltip: tr('search'),
                  icon: const Icon(Icons.search),
                  onPressed: hasSelection ? popWithSelectedKeys : null,
                ),
              ),
            ],
          ),
        );
      }

      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: areaBelowStatusBar),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      widget.title ?? tr('pick'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (filterFormWidget != null) ...[
                    filterFormWidget,
                    const SizedBox(height: 8),
                  ],
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: entryTileWidgets,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  sheetIconBar(),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      scrollable: true,
      title: Text(widget.title ?? tr('pick')),
      content: Column(children: sheetColumnChildren),
      actions: selectionActions,
    );
  }
}
