import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/githubstars.dart';
import 'package:obtainium/components/app_bottom_sheet.dart';
import 'package:obtainium/components/legacy_material_bridge.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/import_export.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:obtainium/theme/app_form_field_styles.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:obtainium/utils/format_utils.dart';
import 'package:obtainium/widgets/help_hint_icon.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

const double _filterFieldRadius = 30;

Future<void> showImportGitHubStarsSheet(
  BuildContext context, {
  Future<void> Function()? onImportCompleted,
  GitHubStars? source,
  Future<void> Function(String url)? onOpenRepositoryUrl,
}) async {
  await showAppModalSheet<void>(
    context: context,
    builder: (_) => ImportGitHubStarsContent(
      onImportCompleted: onImportCompleted,
      source: source,
      onOpenRepositoryUrl: onOpenRepositoryUrl,
    ),
  );
}

class ImportGitHubStarsContent extends StatefulWidget {
  const ImportGitHubStarsContent({
    super.key,
    this.embedded = false,
    this.onImportCompleted,
    this.source,
    this.onOpenRepositoryUrl,
  });

  final bool embedded;
  final Future<void> Function()? onImportCompleted;
  final GitHubStars? source;
  final Future<void> Function(String url)? onOpenRepositoryUrl;

  @override
  State<ImportGitHubStarsContent> createState() =>
      _ImportGitHubStarsContentState();
}

class _ImportGitHubStarsContentState extends State<ImportGitHubStarsContent> {
  late final GitHubStars _source = widget.source ?? GitHubStars();
  final TextEditingController _usernameController = TextEditingController();
  bool _isLoading = false;
  String? _loadingSavedUsername;
  String? _usernameErrorText;
  String? _savedUsernameErrorText;

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _importStarredRepositories({String? savedUsername}) async {
    final bool fromSavedList = savedUsername != null;
    final String username = (savedUsername ?? _usernameController.text).trim();
    if (username.isEmpty) {
      setState(() {
        _usernameErrorText = tr('invalidInput');
        _savedUsernameErrorText = null;
      });
      return;
    }

    final AppsProvider appsProvider = context.read<AppsProvider>();
    final SettingsProvider settingsProvider = context.read<SettingsProvider>();
    final bool embedded = widget.embedded;
    final Future<void> Function()? onImportCompleted = widget.onImportCompleted;
    final Future<void> Function(String url)? onOpenRepositoryUrl =
        widget.onOpenRepositoryUrl;
    final NavigatorState navigator = Navigator.of(context);
    final Route<dynamic>? usernameSheetRoute = embedded
        ? null
        : ModalRoute.of(context);
    setState(() {
      _isLoading = true;
      _loadingSavedUsername = savedUsername;
      _usernameErrorText = null;
      _savedUsernameErrorText = null;
    });
    try {
      final GitHubStarredResult result = await _source
          .getStarredRepositoriesWithLists(username);
      if (!mounted) return;
      if (result.repositories.isEmpty) {
        throw ObtainiumError(tr('noResults'));
      }
      settingsProvider.addSavedGitHubStarUsername(username);
      setState(() {
        _isLoading = false;
        _loadingSavedUsername = null;
      });
      await showAppModalSheet<List<String>>(
        context: navigator.context,
        builder: (_) => GitHubStarsSelectionSheet(
          repositories: result.repositories,
          lists: result.lists,
          onOpenRepositoryUrl: onOpenRepositoryUrl,
          onSubmitSelection:
              (List<String> selectedUrls, VoidCallback stopLoading) async {
                try {
                  final List<List<String>> errors = await appsProvider
                      .addAppsByURL(selectedUrls);
                  stopLoading();
                  await WidgetsBinding.instance.endOfFrame;
                  if (errors.isEmpty) {
                    showMessage(
                      tr(
                        'importedX',
                        args: [
                          plural('apps', selectedUrls.length).toLowerCase(),
                        ],
                      ),
                    );
                  } else if (navigator.mounted) {
                    await showDialog<void>(
                      context: navigator.context,
                      builder: (_) => ImportErrorDialog(
                        urlsLength: selectedUrls.length,
                        errors: errors,
                      ),
                    );
                  }
                  if (onImportCompleted != null) {
                    await onImportCompleted();
                  }
                  if (usernameSheetRoute != null &&
                      usernameSheetRoute.isActive &&
                      navigator.mounted) {
                    navigator.removeRoute(usernameSheetRoute);
                  }
                  return true;
                } catch (error) {
                  stopLoading();
                  await WidgetsBinding.instance.endOfFrame;
                  showError(error);
                }
                return false;
              },
        ),
      );
    } catch (error) {
      // showError uses the root ScaffoldMessenger SnackBar for recoverable
      // ObtainiumErrors, which renders hidden behind a modal bottom sheet.
      // Surface the message inline in this sheet/pane instead, and reserve
      // showError's dialog for unexpected errors.
      final bool showInline =
          error is String || (error is ObtainiumError && !error.unexpected);
      if (showInline) {
        hapticHeavyImpact();
        unawaited(LogsProvider().add(error.toString(), level: LogLevel.error));
        final String message = error is ObtainiumError
            ? error.message
            : error.toString();
        if (mounted) {
          setState(() {
            if (fromSavedList) {
              _savedUsernameErrorText = message;
            } else {
              _usernameErrorText = message;
            }
          });
        }
      } else {
        showError(error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingSavedUsername = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final List<String> savedUsernames = context
        .select<SettingsProvider, List<String>>(
          (SettingsProvider settings) => settings.savedGitHubStarUsernames,
        );

    final List<Widget> children = [
      if (!widget.embedded) ...[
        Row(
          children: [
            const Icon(Icons.star_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr('importGitHubStarredRepositories'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
      TextField(
        controller: _usernameController,
        autofocus: !widget.embedded && savedUsernames.isEmpty,
        enabled: !_isLoading,
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_usernameErrorText != null || _savedUsernameErrorText != null) {
            setState(() {
              _usernameErrorText = null;
              _savedUsernameErrorText = null;
            });
          }
        },
        onSubmitted: (_) {
          if (!_isLoading) {
            unawaited(_importStarredRepositories());
          }
        },
        decoration: InputDecoration(
          labelText: tr('uname'),
          errorText: _usernameErrorText,
          errorMaxLines: 3,
          prefixIcon: const Icon(Icons.person_rounded),
        ),
      ),
      if (savedUsernames.isNotEmpty) ...[
        const SizedBox(height: 12),
        M3eExpressiveSettingsCard(
          items: [
            for (final String savedUsername in savedUsernames)
              ListTile(
                key: ValueKey<String>(savedUsername.toLowerCase()),
                dense: true,
                enabled: !_isLoading,
                contentPadding: kM3eSettingsListTileContentPadding,
                leading: _isLoading && _loadingSavedUsername == savedUsername
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: LegacyMaterialBridge(
                          child: ExpressiveLoadingIndicator(
                            constraints: BoxConstraints.tightFor(
                              width: 20,
                              height: 20,
                            ),
                          ),
                        ),
                      )
                    : const Icon(Icons.person_rounded, size: 20),
                title: Text(
                  savedUsername,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    foregroundColor: colorScheme.onSurfaceVariant,
                    shape: const CircleBorder(),
                    fixedSize: const Size.square(32),
                    minimumSize: const Size.square(32),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  tooltip: tr('delete'),
                  onPressed: _isLoading
                      ? null
                      : () {
                          hapticSelection();
                          context
                              .read<SettingsProvider>()
                              .removeSavedGitHubStarUsername(savedUsername);
                        },
                ),
                onTap: _isLoading
                    ? null
                    : () {
                        FocusScope.of(context).unfocus();
                        hapticSelection();
                        unawaited(
                          _importStarredRepositories(
                            savedUsername: savedUsername,
                          ),
                        );
                      },
              ),
          ],
        ),
      ],
      if (_savedUsernameErrorText != null) ...[
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
            Expanded(
              child: Text(
                _savedUsernameErrorText!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 20),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        spacing: 8,
        children: [
          if (!widget.embedded)
            TextButton(
              onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
              child: Text(tr('cancel')),
            ),
          FilledButton.icon(
            onPressed: _isLoading
                ? null
                : () => unawaited(_importStarredRepositories()),
            icon: _isLoading && _loadingSavedUsername == null
                ? const LegacyMaterialBridge(
                    child: ExpressiveLoadingIndicator(
                      constraints: BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                    ),
                  )
                : const Icon(Icons.download_rounded),
            label: Text(tr('import')),
          ),
        ],
      ),
    ];

    if (!widget.embedded) {
      return AppSheetContent(children: children);
    }

    return SafeArea(
      top: true,
      bottom: false,
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// Starred-repository picker matching the "Search source, add apps" result
/// cards: GitHub icon + compact star count on the left, `fullName · description`
/// and repo URL in the middle (tapping opens the repo in the default browser),
/// and a tinted selection rail with a checkbox on the right.
class GitHubStarsSelectionSheet extends StatefulWidget {
  const GitHubStarsSelectionSheet({
    super.key,
    required this.repositories,
    this.lists = const <GitHubStarList>[],
    required this.onSubmitSelection,
    this.onOpenRepositoryUrl,
  });

  final List<GitHubStarredRepository> repositories;
  final List<GitHubStarList> lists;
  final Future<bool> Function(
    List<String> selectedUrls,
    VoidCallback stopLoading,
  )
  onSubmitSelection;
  final Future<void> Function(String url)? onOpenRepositoryUrl;

  @override
  State<GitHubStarsSelectionSheet> createState() =>
      _GitHubStarsSelectionSheetState();
}

const String _allStarListsMenuValue = '';

class _GitHubStarsSelectionSheetState extends State<GitHubStarsSelectionSheet> {
  final TextEditingController _filterController = TextEditingController();
  final Set<String> _selectedUrls = <String>{};
  String _filterQuery = '';
  String? _selectedListId;
  bool _sortByStars = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  GitHubStarList? _selectedStarList() {
    final String? listId = _selectedListId;
    if (listId == null) return null;
    for (final GitHubStarList list in widget.lists) {
      if (list.id == listId) return list;
    }
    return null;
  }

  List<GitHubStarredRepository> _filteredRepositories() {
    final GitHubStarList? selectedList = _selectedStarList();
    final String normalizedQuery = _filterQuery.trim().toLowerCase();
    final List<GitHubStarredRepository> filtered = widget.repositories.where((
      GitHubStarredRepository repo,
    ) {
      if (selectedList != null && !selectedList.containsUrl(repo.url)) {
        return false;
      }
      if (normalizedQuery.isEmpty) return true;
      return repo.fullName.toLowerCase().contains(normalizedQuery) ||
          repo.description.toLowerCase().contains(normalizedQuery) ||
          repo.url.toLowerCase().contains(normalizedQuery);
    }).toList();

    if (!_sortByStars) {
      return filtered;
    }

    final List<({int index, GitHubStarredRepository repo})> indexed = [
      for (int index = 0; index < filtered.length; index++)
        (index: index, repo: filtered[index]),
    ];
    indexed.sort((left, right) {
      final int? leftStars = left.repo.starCount;
      final int? rightStars = right.repo.starCount;
      if (leftStars != null && rightStars != null) {
        final int comparison = rightStars.compareTo(leftStars);
        if (comparison != 0) return comparison;
        return left.index.compareTo(right.index);
      }
      if (leftStars != null) return -1;
      if (rightStars != null) return 1;
      return left.index.compareTo(right.index);
    });
    return [for (final item in indexed) item.repo];
  }

  void _toggleSelection(String url, bool selected) {
    setState(() {
      if (selected) {
        _selectedUrls.add(url);
      } else {
        _selectedUrls.remove(url);
      }
    });
  }

  void _openExternalUrl(String url) {
    if (url.isEmpty) return;
    final Future<void> Function(String)? customOpener =
        widget.onOpenRepositoryUrl;
    if (customOpener != null) {
      unawaited(customOpener(url));
    } else {
      unawaited(launchUrlString(url, mode: LaunchMode.externalApplication));
    }
  }

  Future<void> _submitSelected() async {
    if (_selectedUrls.isEmpty || _isSubmitting) return;
    final List<String> selectedUrls = <String>[
      for (final GitHubStarredRepository repo in widget.repositories)
        if (_selectedUrls.contains(repo.url)) repo.url,
    ];
    setState(() {
      _isSubmitting = true;
    });
    void stopSubmitting() {
      if (mounted && _isSubmitting) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }

    final bool closeSheet = await widget.onSubmitSelection(
      selectedUrls,
      stopSubmitting,
    );
    if (!mounted) return;
    if (closeSheet) {
      Navigator.of(context).pop(selectedUrls);
    } else {
      setState(() {
        _isSubmitting = false;
      });
    }
  }

  Widget _buildGitHubIcon() {
    final String? assetPath = storeSourceAssetPathForClassName('GitHub');
    if (assetPath == null) return const Icon(Icons.store_rounded, size: 20);
    return StoreSourceIconImage(assetPath: assetPath, size: 20);
  }

  Widget _buildRepositoryCard(
    BuildContext context,
    GitHubStarredRepository repo,
    ColorScheme colorScheme,
  ) {
    final bool selected = _selectedUrls.contains(repo.url);
    final int? starCount = repo.starCount;
    final String titleText = repo.description.isNotEmpty
        ? '${repo.fullName} · ${repo.description}'
        : repo.fullName;

    // Inside a modal bottom sheet the sheet background is itself
    // surfaceContainerLow, which is Card's default fill — step up to
    // surfaceContainerHigh so each repo clearly reads as its own card, and
    // tint the right selection rail over that card color for the same two-tone
    // split as "Search source, add apps".
    final Color cardColor = colorScheme.surfaceContainerHigh;
    final Color selectionRailColor = Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.08),
      cardColor,
    );

    return Card(
      color: cardColor,
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          ListTile(
            selected: selected,
            leading: SizedBox(
              width: 32,
              child: starCount != null
                  ? Semantics(
                      label: plural('starCountSemanticLabel', starCount),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildGitHubIcon(),
                          const SizedBox(height: 2),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: ExcludeSemantics(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.star_rounded,
                                    size: 11,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 1),
                                  Text(
                                    formatCompactStarCount(starCount),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          fontSize: 10,
                                          height: 1.1,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : Center(child: _buildGitHubIcon()),
            ),
            title: Text(
              titleText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              repo.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: const SizedBox.square(dimension: 28),
            onTap: () => _openExternalUrl(repo.url),
          ),
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: 60,
            child: Material(
              color: selectionRailColor,
              child: InkWell(
                onTap: _isSubmitting
                    ? null
                    : () => _toggleSelection(repo.url, !selected),
                child: Center(
                  child: SizedBox.square(
                    dimension: 28,
                    child: Checkbox(
                      value: selected,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      onChanged: _isSubmitting
                          ? null
                          : (bool? value) =>
                                _toggleSelection(repo.url, value ?? false),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool hasStarredResults = widget.repositories.any(
      (GitHubStarredRepository repo) => repo.starCount != null,
    );
    final List<GitHubStarredRepository> visibleRepositories =
        _filteredRepositories();
    final bool hasSelection = _selectedUrls.isNotEmpty;

    Widget footerSlot({
      required String tooltip,
      required Widget icon,
      required VoidCallback? onPressed,
      bool primary = false,
    }) {
      return Expanded(
        child: Center(
          child: primary
              ? IconButton.filled(
                  tooltip: tooltip,
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  icon: icon,
                  onPressed: onPressed,
                )
              : IconButton.filledTonal(
                  tooltip: tooltip,
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  icon: icon,
                  onPressed: onPressed,
                ),
        ),
      );
    }

    final GitHubStarList? selectedList = _selectedStarList();
    final bool hasLists = widget.lists.isNotEmpty;
    final bool hasGitHubPat = context.select<SettingsProvider, bool>(
      (SettingsProvider settings) =>
          (settings.getSettingString(GitHub.githubCredsKey) ?? '')
              .trim()
              .isNotEmpty,
    );
    final bool showPatHint = !hasLists && !hasGitHubPat;
    final bool hasTrailingAccessory = hasLists || showPatHint;

    Widget buildListDropdownChip() {
      final bool listFilterActive = selectedList != null;
      return PopupMenuButton<String>(
        initialValue: _selectedListId ?? _allStarListsMenuValue,
        onSelected: (String value) {
          hapticSelection();
          setState(() {
            _selectedListId = value == _allStarListsMenuValue ? null : value;
          });
        },
        itemBuilder: (BuildContext menuContext) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: _allStarListsMenuValue,
            child: Row(
              children: [
                Expanded(child: Text(tr('all'))),
                if (_selectedListId == null)
                  const Icon(Icons.check_rounded, size: 18),
              ],
            ),
          ),
          for (final GitHubStarList list in widget.lists)
            PopupMenuItem<String>(
              value: list.id,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      list.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_selectedListId == list.id)
                    const Icon(Icons.check_rounded, size: 18),
                ],
              ),
            ),
        ],
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: listFilterActive
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  selectedList?.name ?? tr('all'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: listFilterActive
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 16,
                color: listFilterActive
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      );
    }

    return AppSheetScaffold(
      expand: true,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                tr('selectAppsToImport'),
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (hasStarredResults)
                FilterChip(
                  avatar: Icon(
                    Icons.star_rounded,
                    size: 16,
                    color: _sortByStars
                        ? colorScheme.onSecondaryContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          tr('sortByMostStars'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_sortByStars) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.check_rounded, size: 14),
                      ],
                    ],
                  ),
                  selected: _sortByStars,
                  onSelected: (bool selected) {
                    setState(() {
                      _sortByStars = selected;
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _filterController,
            onChanged: (String value) {
              setState(() {
                _filterQuery = value;
              });
            },
            decoration:
                appPageOutlinedInputDecoration(
                  context,
                  labelText: null,
                  hintText: tr('filter'),
                  isDense: true,
                  borderRadius: _filterFieldRadius,
                ).copyWith(
                  prefixIcon: const Icon(Icons.filter_list_rounded, size: 20),
                  suffixIconConstraints: hasTrailingAccessory
                      ? const BoxConstraints(minWidth: 0, minHeight: 0)
                      : null,
                  suffixIcon: hasTrailingAccessory
                      ? Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_filterQuery.isNotEmpty)
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 32,
                                    height: 32,
                                  ),
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () {
                                    _filterController.clear();
                                    setState(() {
                                      _filterQuery = '';
                                    });
                                  },
                                ),
                              if (hasLists)
                                buildListDropdownChip()
                              else
                                MergeSemantics(
                                  child: HelpHintIcon(
                                    icon: Icons.info_outline_rounded,
                                    padding: EdgeInsets.zero,
                                    message: tr('githubStarListsPatHint'),
                                  ),
                                ),
                            ],
                          ),
                        )
                      : _filterQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _filterController.clear();
                            setState(() {
                              _filterQuery = '';
                            });
                          },
                        )
                      : null,
                ),
          ),
        ],
      ),
      body: visibleRepositories.isEmpty
          ? Center(child: Text(tr('noResults')))
          : ListView.builder(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemCount: visibleRepositories.length,
              itemBuilder: (BuildContext context, int index) {
                return _buildRepositoryCard(
                  context,
                  visibleRepositories[index],
                  colorScheme,
                );
              },
            ),
      footer: Row(
        children: [
          footerSlot(
            tooltip: tr('selectAll'),
            icon: const Icon(Icons.select_all_rounded),
            onPressed: _isSubmitting
                ? null
                : () {
                    setState(() {
                      for (final GitHubStarredRepository repo
                          in visibleRepositories) {
                        _selectedUrls.add(repo.url);
                      }
                    });
                  },
          ),
          footerSlot(
            tooltip: tr('deselectAll'),
            icon: const Icon(Icons.deselect_rounded),
            onPressed: _isSubmitting
                ? null
                : () {
                    setState(() {
                      for (final GitHubStarredRepository repo
                          in visibleRepositories) {
                        _selectedUrls.remove(repo.url);
                      }
                    });
                  },
          ),
          footerSlot(
            tooltip: tr('cancel'),
            icon: const Icon(Icons.close_rounded),
            onPressed: _isSubmitting
                ? null
                : () {
                    Navigator.of(context).pop();
                  },
          ),
          footerSlot(
            tooltip: tr('save'),
            icon: _isSubmitting
                ? LegacyMaterialBridge(
                    child: ExpressiveLoadingIndicator(
                      color: colorScheme.onSurfaceVariant,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                    ),
                  )
                : const Icon(Icons.save_rounded),
            onPressed: hasSelection && !_isSubmitting
                ? () => unawaited(_submitSelected())
                : null,
            primary: true,
          ),
        ],
      ),
    );
  }
}
