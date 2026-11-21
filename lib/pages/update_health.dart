// Update health (upstream #1753): the apps whose setup may be keeping updates
// from arriving, and the ones the user chose to ignore.
//
// Adopted fork-shaped in the v1.7.4 sync (D8). Upstream's page is not used:
// it keys rows by `app.id` and saves the `App` it was built with, so a check
// that finished while it was open got overwritten (sync guide §1.8). Here:
// - rows and actions are keyed by listing key (a package tracked from two
//   stores has two listings, each with its own health);
// - every action re-reads the live listing right before it saves;
// - the thresholds live in Settings → Updates, not on this page;
// - tapping an app opens its options at the Update-health card, as the app
//   page's Update health line does.
// The engine is utils/update_health.dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/components/empty_state_illustration.dart';
import 'package:obtainium/components/ui_widgets.dart' show AppIcon;
import 'package:obtainium/layout_breakpoints.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/page_route_slide_up.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:obtainium/utils/update_health.dart';
import 'package:provider/provider.dart';

/// A hash of the settings update health reads, for the rebuild tokens of the
/// pages that show it (sync guide §3.11).
int updateHealthSettingsToken(SettingsProvider settings) => Object.hash(
  settings.showUpdateHealthIndicator,
  settings.updateHealthStaleReleaseDays,
  settings.updateHealthStaleVersionDays,
  settings.updateHealthFailedChecksCount,
  settings.updateHealthArchivedEnabled,
  settings.updateHealthFilteredReleasesCount,
);

/// Why [app] is flagged, one line per reason; empty when it isn't (or it's
/// ignored).
List<String> updateHealthReasonLabelsFor(App app, SettingsProvider settings) {
  if (!hasUpdateHealthIssues(app, settings)) return const <String>[];
  final UpdateHealthConfig config = resolveUpdateHealthConfig(
    app.additionalSettings,
    settings,
  );
  return evaluateUpdateHealthReasons(app, config)
      .map(
        (UpdateHealthReason reason) =>
            updateHealthReasonLabel(reason, app, config),
      )
      .toList();
}

/// [live] with its update health ignored until a new version comes out.
/// The version it has now, not one a page was built with.
App ignoreUpdateHealthForCurrentVersion(App live) =>
    live.copyWith(updateHealthDismissedVersion: live.latestVersion);

/// [live] with its update health ignored for good.
App ignoreUpdateHealthPermanently(App live) => live.copyWith(
  updateHealthEnabled: false,
  updateHealthDismissedVersion: null,
);

/// [live] with its update health checked again.
App restoreUpdateHealth(App live) => live.copyWith(
  updateHealthEnabled: true,
  updateHealthDismissedVersion: null,
);

enum _IgnoreChoice { currentVersion, permanently }

/// Saves [change] applied to the live listing [listingKey], read right before
/// the save, so nothing that changed since the page was built is lost.
Future<void> _saveUpdateHealthChoice(
  AppsProvider appsProvider,
  String listingKey,
  App Function(App live) change,
) async {
  final App? live = appsProvider.apps[listingKey]?.app;
  if (live == null) return;
  await appsProvider.saveApps(
    [change(live)],
    attemptToCorrectInstallStatus: false,
    updateInstalledInfo: false,
  );
}

class UpdateHealthPage extends StatelessWidget {
  const UpdateHealthPage({super.key});

  static int _byName(AppInMemory a, AppInMemory b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  @override
  Widget build(BuildContext context) {
    // Rebuilds when a listing is saved or removed, not on download ticks.
    context.select<AppsProvider, int>(
      (AppsProvider p) => Object.hash(p.appsListRevision, p.apps.length),
    );
    context.select<SettingsProvider, int>(
      (SettingsProvider s) => Object.hash(
        updateHealthSettingsToken(s),
        s.useGradientBackground,
        s.alwaysUsePhoneLayout,
      ),
    );
    final AppsProvider appsProvider = context.read<AppsProvider>();
    final SettingsProvider settingsProvider = context.read<SettingsProvider>();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isLargeScreen =
        MediaQuery.sizeOf(context).width >= kLargeScreenWidthBreakpoint &&
        !settingsProvider.alwaysUsePhoneLayout;

    final List<AppInMemory> flagged =
        appsProvider.apps.values
            .where(
              (AppInMemory listing) =>
                  hasUpdateHealthIssues(listing.app, settingsProvider),
            )
            .toList()
          ..sort(_byName);
    final List<AppInMemory> ignored =
        appsProvider.apps.values
            .where((AppInMemory listing) => isUpdateHealthIgnored(listing.app))
            .toList()
          ..sort(_byName);

    Widget sectionTitle(String title, IconData icon) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Row(
          children: [
            Icon(icon, color: scheme.primary, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final List<Widget> content = [
      if (flagged.isEmpty && ignored.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Center(
            child: AppEmptyState(
              illustration: const AppFilterEmptyIllustration(),
              title: tr('updateHealthNoApps'),
            ),
          ),
        ),
      if (flagged.isNotEmpty) ...[
        sectionTitle(
          tr('updateHealthDetectedApps'),
          Icons.warning_amber_rounded,
        ),
        M3eExpressiveSettingsCard(
          colorScheme: scheme,
          items: [
            for (final AppInMemory listing in flagged)
              _UpdateHealthAppRow(
                key: ValueKey<String>('flagged-${listing.listingKey}'),
                listing: listing,
                ignored: false,
              ),
          ],
        ),
      ],
      if (ignored.isNotEmpty) ...[
        sectionTitle(
          tr('updateHealthIgnoredApps'),
          Icons.visibility_off_outlined,
        ),
        M3eExpressiveSettingsCard(
          colorScheme: scheme,
          items: [
            for (final AppInMemory listing in ignored)
              _UpdateHealthAppRow(
                key: ValueKey<String>('ignored-${listing.listingKey}'),
                listing: listing,
                ignored: true,
              ),
          ],
        ),
      ],
    ];

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (settingsProvider.useGradientBackground)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: scheme.schemePageBackgroundGradient,
                ),
              ),
            ),
          CustomScrollView(
            slivers: [
              CustomAppBar(
                title: tr('updateHealth'),
                matchGradientBackground: settingsProvider.useGradientBackground,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              // Clear of the navigation bar and of side insets in landscape
              // (edge-to-edge).
              SliverSafeArea(
                top: false,
                sliver: SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isLargeScreen ? 840 : double.infinity,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: content,
                        ),
                      ),
                    ),
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

class _UpdateHealthAppRow extends StatelessWidget {
  const _UpdateHealthAppRow({
    super.key,
    required this.listing,
    required this.ignored,
  });

  final AppInMemory listing;
  final bool ignored;

  @override
  Widget build(BuildContext context) {
    final AppsProvider appsProvider = context.read<AppsProvider>();
    final SettingsProvider settingsProvider = context.read<SettingsProvider>();
    final String listingKey = listing.listingKey;
    final String subtitle = ignored
        ? (listing.app.updateHealthEnabled
              ? tr('updateHealthIgnoredForVersion')
              : tr('updateHealthIgnoredPermanently'))
        : updateHealthReasonLabelsFor(listing.app, settingsProvider).join('\n');

    final Widget trailing = ignored
        ? IconButton(
            tooltip: tr('restore'),
            icon: const Icon(Icons.settings_backup_restore_rounded),
            onPressed: () => unawaited(
              _saveUpdateHealthChoice(
                appsProvider,
                listingKey,
                restoreUpdateHealth,
              ),
            ),
          )
        : PopupMenuButton<_IgnoreChoice>(
            tooltip: tr('more'),
            onSelected: (_IgnoreChoice choice) => unawaited(
              _saveUpdateHealthChoice(
                appsProvider,
                listingKey,
                choice == _IgnoreChoice.permanently
                    ? ignoreUpdateHealthPermanently
                    : ignoreUpdateHealthForCurrentVersion,
              ),
            ),
            itemBuilder: (BuildContext menuContext) => [
              PopupMenuItem<_IgnoreChoice>(
                value: _IgnoreChoice.currentVersion,
                child: Text(tr('ignoreForThisVersion')),
              ),
              PopupMenuItem<_IgnoreChoice>(
                value: _IgnoreChoice.permanently,
                child: Text(tr('ignorePermanently')),
              ),
            ],
          );

    return ListTile(
      contentPadding: kM3eSettingsListTileContentPadding,
      leading: _UpdateHealthAppIcon(listingKey: listingKey),
      title: Text(listing.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
      trailing: trailing,
      onTap: () => unawaited(
        Navigator.push<bool>(
          context,
          slideUpPageRoute(
            (_) => AdditionalOptionsPage(
              appId: listingKey,
              scrollToSection: updateHealthSectionKey,
            ),
          ),
        ),
      ),
    );
  }
}

/// The listing's icon, watching only its own bytes, and asking for them once
/// when they aren't loaded yet.
class _UpdateHealthAppIcon extends StatefulWidget {
  const _UpdateHealthAppIcon({required this.listingKey});

  final String listingKey;

  @override
  State<_UpdateHealthAppIcon> createState() => _UpdateHealthAppIconState();
}

class _UpdateHealthAppIconState extends State<_UpdateHealthAppIcon> {
  bool _requestedIcon = false;

  @override
  Widget build(BuildContext context) {
    final (Uint8List? icon, bool known) = context
        .select<AppsProvider, (Uint8List?, bool)>((AppsProvider p) {
          final AppInMemory? listing = p.apps[widget.listingKey];
          return (listing?.icon, listing != null);
        });
    if (icon == null && known && !_requestedIcon) {
      _requestedIcon = true;
      final AppsProvider appsProvider = context.read<AppsProvider>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(appsProvider.updateAppIcon(widget.listingKey));
      });
    }
    return AppIcon(bytes: icon, size: 40, radius: 10);
  }
}
