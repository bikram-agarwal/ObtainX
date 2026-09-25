import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/backup_import_sheet.dart';
import 'package:obtainium/components/ui_widgets.dart' show ExplainedWhenOff;
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/app.dart' show loadIconsAndScanStoresFor;
import 'package:obtainium/pages/home.dart'
    show linkImportIn, linkJson, linkPayload;
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/pick_file.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:provider/provider.dart';

/// The apps an `obtainium://app/` or `apps/` [link] carries, as entries that
/// keep what it says about them ([UrlImportEntry.seed]). Throws on apps that
/// can't be read.
List<UrlImportEntry> urlImportEntriesFromLink(
  Uri link,
  AppsProvider appsProvider,
) => [
  for (final App app in appsProvider.parseBackupContent(linkPayload(link)).apps)
    UrlImportEntry(app.url, seed: app),
];

/// What the Import from URL list box holds, as the apps to add.
///
/// The whole text can be app links, a shared link, or app JSON
/// ([linkImportIn]). Otherwise each line is a URL, or an app link of its own.
/// Every entry is then fetched and saved alike. Throws on JSON whose apps
/// can't be read.
List<UrlImportEntry> urlImportEntriesIn(
  String text,
  AppsProvider appsProvider,
) {
  final Uri? whole = linkImportIn(text);
  if (whole != null) return urlImportEntriesFromLink(whole, appsProvider);
  return [
    for (final String line in text.trim().split('\n'))
      if (line.trim().isNotEmpty)
        if (linkImportIn(line) case final Uri link)
          ...urlImportEntriesFromLink(link, appsProvider)
        else
          UrlImportEntry(line.trim()),
  ];
}

/// The apps a picked file with [contents] holds, as text the box could hold
/// ([urlImportEntriesIn]), or '' when it holds none.
///
/// A file that could have been typed into the box is taken as it is: app
/// links or app JSON, or a list with a URL or link on each line. Anything
/// else (an OPML list of feeds, say) is searched for app links, and for web
/// addresses that a site's own source takes, such as GitHub's or F-Droid's.
/// The HTML source takes any address at all, so one that only it would take
/// is left out: in a feed list, those are feeds and websites, not apps.
String urlListTextInFile(
  String contents,
  AppsProvider appsProvider,
  SourceProvider sourceProvider,
) {
  final String trimmed = contents.trim();
  final Uri? whole = linkImportIn(trimmed);
  if (whole != null) {
    try {
      // Reading JSON as apps leaves out what isn't there, so JSON that isn't
      // apps reads as apps with no URL.
      final List<UrlImportEntry> entries = urlImportEntriesFromLink(
        whole,
        appsProvider,
      );
      if (entries.isNotEmpty &&
          entries.every((UrlImportEntry entry) => entry.url.isNotEmpty)) {
        return trimmed;
      }
    } catch (_) {
      // Not apps either.
    }
    // JSON that isn't apps is searched like any other file.
  }
  final List<String> lines = [
    for (final String line in trimmed.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  final RegExp webAddress = RegExp(r'^https?://\S+$');
  if (lines.isNotEmpty &&
      lines.every(
        (String line) =>
            webAddress.hasMatch(line) ||
            (line.startsWith('obtainium://') && linkImportIn(line) != null),
      )) {
    return lines.join('\n');
  }
  final Set<String> found = {};
  // Stops where an address in a web page, XML or JSON would end. Not at an
  // apostrophe or a bracket: a link's JSON can hold those unencoded.
  for (final RegExpMatch match in RegExp(
    r'(?:https?|obtainium)://[^\s"<>]+',
  ).allMatches(contents)) {
    final String address = match[0]!;
    // Without what closes a sentence or a Markdown link around it.
    final String bare = address.replaceFirst(RegExp(r'[.,;:!?)\]}\\]+$'), '');
    if (linkImportIn(address) != null) {
      found.add(address);
    } else if (linkImportIn(bare) != null) {
      found.add(bare);
    } else {
      try {
        final AppSource source = sourceProvider.getSource(bare);
        if (source.hosts.isNotEmpty) found.add(source.standardizeUrl(bare));
      } catch (_) {
        // Not an address any source takes.
      }
    }
  }
  return found.join('\n');
}

/// Adds [entries], whether typed, pasted or sent by another app's link, all
/// the same way.
///
/// The picker sheet opens with tracked apps listed at once, and the rest
/// fetched while it's open ([fetchUrlImportEntry]). An app that can't be
/// fetched shows why and can't be ticked. The ticked ones are saved as Add
/// app saves them ([AppsProvider.addFetchedApps]), and a message says how
/// many. [rawJson] is a link's or pasted JSON, shown collapsed. [onSaving]
/// runs once the sheet closes with apps to save.
///
/// Returns the apps added, or null if the sheet was cancelled or nothing was
/// ticked. Their icons and store scans are left to the caller: a single app's
/// page does both when it opens ([loadIconsAndScanStoresFor] otherwise).
Future<List<App>?> importUrlListEntries(
  BuildContext context,
  List<UrlImportEntry> entries, {
  String? rawJson,
  VoidCallback? onSaving,
}) async {
  final AppsProvider appsProvider = context.read<AppsProvider>();
  final bool includePrereleases = context
      .read<SettingsProvider>()
      .includePrereleasesByDefault;
  final SourceProvider sourceProvider = SourceProvider();
  final UrlImportPlan plan = planUrlImport(
    appsProvider.apps,
    entries,
    sourceProvider,
  );
  // A row per entry, keyed by its URL. Two links can share one (a repo's
  // `.gh` and `.offline` builds), so a repeat gets a key of its own.
  final Map<String, UrlImportEntry> entriesByKey = {};
  for (final UrlImportEntry entry in plan.toFetch) {
    String key = entry.url;
    for (int repeat = 2; entriesByKey.containsKey(key); repeat++) {
      key = '${entry.url}#$repeat';
    }
    entriesByKey[key] = entry;
  }
  final BackupImportSelection? selection = await showUrlListImportPickerSheet(
    context: context,
    urls: entriesByKey.keys.toList(),
    urlFor: (String key) => entriesByKey[key]!.url,
    alreadyTracked: plan.alreadyTracked
        .map((AppInMemory listing) => listing.app)
        .toList(),
    existingApps: appsProvider.apps,
    // Fetched as the Add app page fetches: with its prerelease default, and
    // looking up each app's real package ID (with a temporary one, an
    // installed app shows as not installed). A lookup that gets no answer (a
    // rate limit, say) still falls back to one.
    fetchApp: (String key) => fetchUrlImportEntry(
      sourceProvider,
      entriesByKey[key]!,
      includePrereleases: includePrereleases,
    ),
    trackedListingFor: (App app) => sameStoreListingIn(appsProvider.apps, app),
    // Named and drawn as the apps list will show them once added.
    lookFor: appsProvider.newAppLook,
    rawJson: rawJson,
  );
  final List<App>? chosen = selection?.fetchedApps;
  if (chosen == null || chosen.isEmpty) return null;
  onSaving?.call();
  // Keeping the icons the sheet downloaded.
  final List<App> added = await appsProvider.addFetchedApps(
    chosen,
    downloadedIcons: selection!.downloadedIcons,
  );
  showMessage(
    added.length < chosen.length
        ? tr(
            'importedXOfYApps',
            args: [added.length.toString(), chosen.length.toString()],
          )
        : tr('importedX', args: [plural('apps', added.length).toLowerCase()]),
  );
  return added;
}

/// Obtainium-style URL-list import page, kept as a dedicated route from Add App.
class ImportFromUrlListPage extends StatefulWidget {
  const ImportFromUrlListPage({
    super.key,
    this.embedded = false,
    this.onImportCompleted,
  });

  final bool embedded;
  final Future<void> Function()? onImportCompleted;

  @override
  State<ImportFromUrlListPage> createState() => _ImportFromUrlListPageState();
}

class _ImportFromUrlListPageState extends State<ImportFromUrlListPage> {
  final SourceProvider _sourceProvider = SourceProvider();
  final TextEditingController _urlController = TextEditingController();
  bool _isImporting = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String? _validateUrls(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    if (linkImportIn(value) != null) return null;
    final List<String> lines = value.trim().split('\n');
    for (int lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      if (lines[lineIndex].trim().isEmpty) continue;
      if (linkImportIn(lines[lineIndex]) != null) continue;
      try {
        _sourceProvider.getSource(lines[lineIndex].trim());
      } catch (error) {
        return '${tr('line')} ${lineIndex + 1}: $error';
      }
    }
    return null;
  }

  // What the box holds is imported, or a picked file's apps, never the two
  // together.
  Future<void> _import() async {
    if (_validateUrls(_urlController.text) != null) return;
    await _importText(_urlController.text);
  }

  // Opens the sheet straight away with the file's apps
  // ([urlListTextInFile]). The box isn't touched.
  Future<void> _importFromFile() async {
    final AppsProvider appsProvider = context.read<AppsProvider>();
    final SettingsProvider settingsProvider = context.read<SettingsProvider>();
    final String found;
    try {
      // Any file: an OPML feed list, say, as well as JSON. One that isn't
      // text finds nothing.
      final String? contents = await pickTextFile(settingsProvider);
      if (contents == null) return;
      found = urlListTextInFile(contents, appsProvider, _sourceProvider);
    } catch (error) {
      if (mounted) showError(error);
      return;
    }
    if (!mounted) return;
    if (found.isEmpty) {
      showMessage(tr('noAppsFound'));
      return;
    }
    await _importText(found);
  }

  // URLs, app links and app JSON all go the same way ([importUrlListEntries]),
  // typed or from a file. Cancelling the sheet leaves the page as it was.
  Future<void> _importText(String text) async {
    final AppsProvider appsProvider = context.read<AppsProvider>();
    final List<UrlImportEntry> entries;
    try {
      entries = urlImportEntriesIn(text, appsProvider);
    } catch (error) {
      showError(error);
      return;
    }
    if (entries.isEmpty) return;
    final bool embedded = widget.embedded;
    final Future<void> Function()? onImportCompleted = widget.onImportCompleted;
    final NavigatorState navigator = Navigator.of(context);
    final ModalRoute<dynamic>? hostRoute = ModalRoute.of(context);
    final Uri? wholeLink = linkImportIn(text);
    try {
      final List<App>? added = await importUrlListEntries(
        context,
        entries,
        rawJson: wholeLink == null
            ? null
            : readableLinkPayload(linkJson(wholeLink)),
        onSaving: () {
          if (mounted) setState(() => _isImporting = true);
        },
      );
      if (added == null) return;
      // What Add app gets by opening the new app's page: its icon where
      // there's none yet, and a store scan.
      unawaited(
        loadIconsAndScanStoresFor(
          appsProvider,
          added.map((App app) => app.listingKey).toList(),
        ),
      );
      if (embedded) {
        await onImportCompleted?.call();
      } else if (navigator.mounted && hostRoute?.isCurrent == true) {
        navigator.pop();
      }
    } catch (error) {
      showError(error);
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool useGradientBackground = context.select<SettingsProvider, bool>(
      (settingsProvider) => settingsProvider.useGradientBackground,
    );
    final double topContentInset = !widget.embedded && useGradientBackground
        ? MediaQuery.paddingOf(context).top + kToolbarHeight
        : 0;

    return Scaffold(
      extendBodyBehindAppBar: !widget.embedded && useGradientBackground,
      backgroundColor: widget.embedded && useGradientBackground
          ? Colors.transparent
          : colorScheme.surface,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(tr('importFromURLList')),
              backgroundColor: useGradientBackground
                  ? Colors.transparent
                  : colorScheme.surface,
              surfaceTintColor: Colors.transparent,
              forceMaterialTransparency: useGradientBackground,
            ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (useGradientBackground)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: colorScheme.schemePageBackgroundGradient,
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: topContentInset),
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverSafeArea(
                  top: widget.embedded,
                  sliver: SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    sliver: SliverToBoxAdapter(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 16,
                            children: [
                              const _ImportFromUrlListHelp(),
                              TextFormField(
                                controller: _urlController,
                                maxLines: null,
                                minLines: 8,
                                enabled: !_isImporting,
                                decoration: InputDecoration(
                                  labelText: tr('appURLList'),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                                validator: _validateUrls,
                                autovalidateMode:
                                    AutovalidateMode.onUserInteraction,
                              ),
                              // Off while there's nothing it could import:
                              // the box is empty, or a line can't be read.
                              // Tapped then, it says which.
                              ValueListenableBuilder<TextEditingValue>(
                                valueListenable: _urlController,
                                builder: (context, value, child) {
                                  final String? off = _isImporting
                                      ? tr('waitForImportToFinish')
                                      : value.text.trim().isEmpty
                                      ? tr('enterAppsToImportFirst')
                                      : _validateUrls(value.text);
                                  return ExplainedWhenOff(
                                    reason: off,
                                    child: FilledButton(
                                      onPressed: off == null ? _import : null,
                                      child: child,
                                    ),
                                  );
                                },
                                child: _isImporting
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        spacing: 8,
                                        children: [
                                          const ExpressiveLoadingIndicator(
                                            constraints:
                                                BoxConstraints.tightFor(
                                                  width: 24,
                                                  height: 24,
                                                ),
                                          ),
                                          Text(tr('import')),
                                        ],
                                      )
                                    : Text(tr('import')),
                              ),
                              ExplainedWhenOff(
                                reason: _isImporting
                                    ? tr('waitForImportToFinish')
                                    : null,
                                child: OutlinedButton.icon(
                                  onPressed: _isImporting
                                      ? null
                                      : _importFromFile,
                                  icon: const Icon(Icons.upload_file_rounded),
                                  label: Text(tr('importFromURLsInFile')),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
}

/// What the box and a picked file can hold, and why an imported app can show
/// as not installed, together in one card at the top of the page.
class _ImportFromUrlListHelp extends StatelessWidget {
  const _ImportFromUrlListHelp();

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text(tr('appURLListAccepts'), style: style),
            for (final String key in const [
              'appURLListAcceptsUrls',
              'appURLListAcceptsLinks',
              'appURLListAcceptsJson',
            ])
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text('•', style: style),
                  Expanded(child: Text(tr(key), style: style)),
                ],
              ),
            const SizedBox(height: 8),
            Text(tr('importedAppsIdDisclaimer'), style: style),
          ],
        ),
      ),
    );
  }
}
