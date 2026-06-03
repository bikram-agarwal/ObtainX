import 'dart:convert';

import 'package:android_package_manager/android_package_manager.dart'
    show PackageInfo;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:obtainium/widgets/help_hint_icon.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/components/themes_settings_section.dart';
import 'package:obtainium/components/generated_form.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/installer_provider.dart' as installer;
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/native_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/theme/m3e_expressive_list.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shizuku_apk_installer/shizuku_apk_installer.dart';
import 'package:url_launcher/url_launcher_string.dart';

IconData _swipeActionIcon(SwipeAction action) => switch (action) {
  SwipeAction.update => Icons.system_update_alt_rounded,
  SwipeAction.pin => Icons.push_pin_rounded,
  SwipeAction.appOptions => Icons.tune_rounded,
  SwipeAction.delete => Icons.delete_rounded,
  SwipeAction.open => Icons.open_in_new_rounded,
  SwipeAction.appInfo => Icons.info_rounded,
  SwipeAction.edit => Icons.edit_rounded,
  SwipeAction.none => Icons.block_rounded,
};

const String _aboutObtainXWebsiteUrl =
    'https://bikram-agarwal.github.io/obtainx/';
const String _aboutObtainXPrivacyUrl =
    'https://bikram-agarwal.github.io/obtainx/privacy/';
const String _aboutObtainXTermsUrl =
    'https://bikram-agarwal.github.io/obtainx/terms/';
const String _aboutRememberUrl =
    'https://github.com/bikram-agarwal/Remember/releases/latest';
const String _aboutFilePipeUrl =
    'https://github.com/bikram-agarwal/FilePipe/releases/latest';
const String _aboutAuthorUrl = 'https://github.com/bikram-agarwal';
const String _aboutWikiUrl = 'https://wiki.obtainium.imranr.dev/';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<AndroidDeviceInfo> _androidInfo =
      DeviceInfoPlugin().androidInfo;
  static const List<String> _settingsSectionKeys = [
    'updates',
    'sourceSpecific',
    'themes',
    'appearance',
    'gestures',
    'categories',
  ];

  List<int> updateIntervalNodes = [
    15,
    30,
    60,
    120,
    180,
    360,
    720,
    1440,
    4320,
    10080,
    20160,
    43200,
  ];
  int updateInterval = 0;
  String updateIntervalLabel = tr('neverManualOnly');

  void processIntervalSliderValue(double val) {
    final int index = val.round().clamp(0, updateIntervalNodes.length);
    if (index == 0) {
      updateInterval = 0;
      updateIntervalLabel = tr('neverManualOnly');
      return;
    }
    final int minutes = updateIntervalNodes[index - 1];
    updateInterval = minutes;
    if (minutes < 60) {
      updateIntervalLabel = plural('minute', minutes);
    } else if (minutes < 24 * 60) {
      updateIntervalLabel = plural('hour', minutes ~/ 60);
    } else {
      updateIntervalLabel = plural('day', minutes ~/ (24 * 60));
    }
  }

  List<Widget> _updatesCardItemList(
    BuildContext context,
    ColorScheme cs,
    SettingsProvider settingsProvider,
    AsyncSnapshot<AndroidDeviceInfo> snapshot,
    Widget updatesIntervalHead,
  ) {
    final List<Widget> rows = <Widget>[updatesIntervalHead];
    final bool showBgControls =
        (settingsProvider.updateInterval > 0) &&
        (((snapshot.data?.version.sdkInt ?? 0) >= 30) ||
            settingsProvider.useShizuku);
    if (showBgControls) {
      rows.add(
        ListTile(
          title: Text(tr('foregroundServiceForUpdateChecking')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              HelpHintIcon(
                message: tr('foregroundServiceReliabilityNote'),
                padding: EdgeInsets.zero,
              ),
              Switch(
                value: settingsProvider.useFGService,
                onChanged: (bool value) {
                  settingsProvider.useFGService = value;
                },
              ),
            ],
          ),
          onTap: () {
            settingsProvider.useFGService = !settingsProvider.useFGService;
          },
        ),
      );
      rows.add(
        ListTile(
          title: Text(tr('enableBackgroundUpdates')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              HelpHintIcon(
                message:
                    '${tr('backgroundUpdateReqsExplanation')}\n\n${tr('backgroundUpdateLimitsExplanation')}',
                padding: EdgeInsets.zero,
              ),
              Switch(
                value: settingsProvider.enableBackgroundUpdates,
                onChanged: (bool value) {
                  settingsProvider.enableBackgroundUpdates = value;
                },
              ),
            ],
          ),
          onTap: () {
            settingsProvider.enableBackgroundUpdates =
                !settingsProvider.enableBackgroundUpdates;
          },
        ),
      );
      if (settingsProvider.enableBackgroundUpdates) {
        rows.add(
          SwitchListTile(
            title: Text(tr('bgUpdatesOnWiFiOnly')),
            value: settingsProvider.bgUpdatesOnWiFiOnly,
            onChanged: (bool value) {
              settingsProvider.bgUpdatesOnWiFiOnly = value;
            },
          ),
        );
        rows.add(
          SwitchListTile(
            title: Text(tr('bgUpdatesWhileChargingOnly')),
            value: settingsProvider.bgUpdatesWhileChargingOnly,
            onChanged: (bool value) {
              settingsProvider.bgUpdatesWhileChargingOnly = value;
            },
          ),
        );
      }
    }
    rows.addAll(<Widget>[
      SwitchListTile(
        title: Text(tr('checkOnStart')),
        value: settingsProvider.checkOnStart,
        onChanged: (bool value) {
          settingsProvider.checkOnStart = value;
        },
      ),
      SwitchListTile(
        title: Text(tr('checkUpdateOnDetailPage')),
        value: settingsProvider.checkUpdateOnDetailPage,
        onChanged: (bool value) {
          settingsProvider.checkUpdateOnDetailPage = value;
        },
      ),
      SwitchListTile(
        title: Text(tr('onlyCheckInstalledOrTrackOnlyApps')),
        value: settingsProvider.onlyCheckInstalledOrTrackOnlyApps,
        onChanged: (bool value) {
          settingsProvider.onlyCheckInstalledOrTrackOnlyApps = value;
        },
      ),
      SwitchListTile(
        title: Text(tr('removeOnExternalUninstall')),
        value: settingsProvider.removeOnExternalUninstall,
        onChanged: (bool value) {
          settingsProvider.removeOnExternalUninstall = value;
        },
      ),
      SwitchListTile(
        title: Text(tr('parallelDownloads')),
        value: settingsProvider.parallelDownloads,
        onChanged: (bool value) {
          settingsProvider.parallelDownloads = value;
        },
      ),
      ListTile(
        title: Text(tr('beforeNewInstallsShareToAppVerifier')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: tr('about'),
              onPressed: () {
                launchUrlString(
                  'https://github.com/soupslurpr/AppVerifier',
                  mode: LaunchMode.externalApplication,
                );
              },
              style: IconButton.styleFrom(
                foregroundColor: cs.onSurfaceVariant,
                iconSize: 20,
                padding: const EdgeInsets.all(4),
                minimumSize: const Size(32, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.open_in_new_rounded),
            ),
            Switch(
              value: settingsProvider.beforeNewInstallsShareToAppVerifier,
              onChanged: (bool value) {
                settingsProvider.beforeNewInstallsShareToAppVerifier = value;
              },
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('installerMode')),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment<String>(
                    value: 'stock',
                    label: Text(tr('installerModeStock')),
                  ),
                  ButtonSegment<String>(
                    value: 'shizuku',
                    label: Text(tr('installerModeShizuku')),
                  ),
                  ButtonSegment<String>(
                    value: 'legacy',
                    label: Text(tr('installerModeThirdParty')),
                  ),
                ],
                selected: {settingsProvider.installerMode},
                onSelectionChanged: (Set<String> selected) {
                  final String mode = selected.first;
                  if (mode == 'shizuku') {
                    ShizukuApkInstaller().checkPermission().then((
                      String? resCode,
                    ) {
                      if (!context.mounted) return;
                      if (resCode!.startsWith('granted')) {
                        settingsProvider.installerMode = 'shizuku';
                      } else {
                        switch (resCode) {
                          case 'services_not_found':
                            showError(
                              ObtainiumError(tr('shizukuBinderNotFound')),
                              context,
                            );
                          case 'old_shizuku':
                            showError(
                              ObtainiumError(tr('shizukuOld')),
                              context,
                            );
                          case 'old_android_with_adb':
                            showError(
                              ObtainiumError(tr('shizukuOldAndroidWithADB')),
                              context,
                            );
                          case 'denied':
                            showError(ObtainiumError(tr('cancelled')), context);
                        }
                      }
                    });
                  } else {
                    settingsProvider.installerMode = mode;
                  }
                },
              ),
            ),
            if (settingsProvider.installerMode == 'shizuku')
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('shizukuPretendToBeGooglePlay')),
                value: settingsProvider.shizukuPretendToBeGooglePlay,
                onChanged: (bool value) {
                  settingsProvider.shizukuPretendToBeGooglePlay = value;
                },
              ),
            if (settingsProvider.installerMode == 'legacy')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _ThirdPartyInstallerSelector(
                  settingsProvider: settingsProvider,
                ),
              ),
          ],
        ),
      ),
    ]);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    SettingsProvider settingsProvider = context.watch<SettingsProvider>();
    SourceProvider sourceProvider = SourceProvider();
    if (settingsProvider.prefs == null) settingsProvider.initializeSettings();
    processIntervalSliderValue(settingsProvider.updateIntervalSliderVal);

    final Widget localeMenu = m3eCompactDropdownScope(
      context: context,
      child: DropdownMenu<Locale?>(
        key: ValueKey(
          settingsProvider.forcedLocale?.toLanguageTag() ?? '_system',
        ),
        initialSelection: settingsProvider.forcedLocale,
        label: Text(tr('language')),
        expandedInsets: EdgeInsets.zero,
        onSelected: (Locale? value) {
          settingsProvider.forcedLocale = value;
          if (value != null) {
            context.setLocale(value);
          } else {
            settingsProvider.resetLocaleSafe(context);
          }
        },
        dropdownMenuEntries: [
          DropdownMenuEntry<Locale?>(value: null, label: tr('followSystem')),
          ...supportedLocales.map(
            (MapEntry<Locale, String> localeEntry) =>
                DropdownMenuEntry<Locale?>(
                  value: localeEntry.key,
                  label: localeEntry.value,
                ),
          ),
        ],
      ),
    );

    // M3 Expressive slider design - thick gapped track + vertical-bar thumb.
    // Implemented via custom [SliderTrackShape] / [SliderComponentShape]
    // painters at the bottom of this file. The slider_m3e package's
    // "round" / "square" thumb variants don't match the M3E reference
    // (which is a vertical-pill thumb), so we keep our spec-correct
    // hand-built shapes.
    var intervalSlider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 16,
        trackShape: const _GappedTrackShape(),
        thumbShape: const _VerticalBarThumbShape(),
        tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 3),
        activeTickMarkColor: Theme.of(context).colorScheme.onPrimary,
        inactiveTickMarkColor: Theme.of(context).colorScheme.primary,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
      ),
      child: Slider(
        value: settingsProvider.updateIntervalSliderVal.roundToDouble().clamp(
          0,
          updateIntervalNodes.length.toDouble(),
        ),
        max: updateIntervalNodes.length.toDouble(),
        divisions: updateIntervalNodes.length,
        label: updateIntervalLabel,
        onChanged: (double value) {
          setState(() {
            settingsProvider.updateIntervalSliderVal = value;
            processIntervalSliderValue(value);
          });
        },
        onChangeEnd: (double value) {
          setState(() {
            settingsProvider.updateInterval = updateInterval;
          });
        },
      ),
    );

    final List<Widget> sourceSpecificForms = sourceProvider.sources
        .where((s) => s.sourceConfigSettingFormItems.isNotEmpty)
        .map((source) {
          return GeneratedForm(
            outlinedInputFields: true,
            items: source.sourceConfigSettingFormItems.map((item) {
              if (item is GeneratedFormSwitch) {
                item.defaultValue = settingsProvider.getSettingBool(item.key);
              } else {
                item.defaultValue = settingsProvider.getSettingString(item.key);
              }
              return [item];
            }).toList(),
            onValueChanges: (values, valid, isBuilding) {
              if (valid && !isBuilding) {
                values.forEach((key, value) {
                  final formItem = source.sourceConfigSettingFormItems
                      .where((i) => i.key == key)
                      .firstOrNull;
                  if (formItem is GeneratedFormSwitch) {
                    settingsProvider.setSettingBool(key, value == true);
                  } else {
                    settingsProvider.setSettingString(key, value ?? '');
                  }
                });
              }
            },
          );
        })
        .toList();

    final cs = Theme.of(context).colorScheme;

    final Widget updatesIntervalHead = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.update_rounded, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(tr('bgUpdateCheckInterval'))),
                      Text(updateIntervalLabel),
                    ],
                  ),
                ),
                intervalSlider,
              ],
            ),
          ),
        ],
      ),
    );

    Widget sectionHeader(String title, IconData icon, String key) {
      final bool expanded =
          settingsProvider.prefs?.getBool('settingsSection_$key') ?? true;
      const Duration headerTransitionDuration = Duration(milliseconds: 300);
      const Curve headerTransitionCurve = Curves.easeInOutCubicEmphasized;
      final Color collapsedHeaderColor = Color.lerp(
        cs.secondaryContainer,
        cs.primaryContainer,
        0.30,
      )!;
      final Color collapsedHeaderContentColor = cs.onSecondaryContainer;
      final Color headerContentColor = expanded
          ? cs.primary
          : collapsedHeaderContentColor;
      final BorderSide outlineSide = expanded
          ? BorderSide.none
          : m3ePureBlackOutlineSide(cs, alpha: 0.16);

      return AnimatedPadding(
        duration: headerTransitionDuration,
        curve: headerTransitionCurve,
        padding: EdgeInsets.fromLTRB(0, expanded ? 20 : 16, 0, 8),
        child: AnimatedContainer(
          duration: headerTransitionDuration,
          curve: headerTransitionCurve,
          decoration: BoxDecoration(
            color: expanded ? Colors.transparent : collapsedHeaderColor,
            borderRadius: BorderRadius.circular(expanded ? 8 : 28),
            border: outlineSide == BorderSide.none
                ? null
                : Border.fromBorderSide(outlineSide),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => settingsProvider.setSettingBool(
                'settingsSection_$key',
                !expanded,
              ),
              borderRadius: BorderRadius.circular(expanded ? 8 : 28),
              splashFactory: NoSplash.splashFactory,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              child: AnimatedPadding(
                duration: headerTransitionDuration,
                curve: headerTransitionCurve,
                padding: EdgeInsets.symmetric(
                  horizontal: expanded ? 4 : 12,
                  vertical: expanded ? 4 : 8,
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: headerTransitionDuration,
                      curve: headerTransitionCurve,
                      width: expanded ? 20 : 30,
                      height: expanded ? 20 : 30,
                      decoration: BoxDecoration(
                        color: expanded
                            ? Colors.transparent
                            : cs.primary.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        color: headerContentColor,
                        size: expanded ? 16 : 17,
                      ),
                    ),
                    SizedBox(width: expanded ? 8 : 10),
                    Expanded(
                      child: AnimatedDefaultTextStyle(
                        duration: headerTransitionDuration,
                        curve: headerTransitionCurve,
                        style: TextStyle(
                          fontWeight: expanded
                              ? FontWeight.w600
                              : FontWeight.w700,
                          color: headerContentColor,
                          fontSize: 13,
                          letterSpacing: expanded ? 0 : 0.1,
                          decoration: TextDecoration.none,
                        ),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    AnimatedContainer(
                      duration: headerTransitionDuration,
                      curve: headerTransitionCurve,
                      width: expanded ? 20 : 32,
                      height: expanded ? 20 : 32,
                      decoration: BoxDecoration(
                        color: expanded
                            ? Colors.transparent
                            : cs.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: AnimatedRotation(
                        turns: expanded ? 0.25 : 0,
                        duration: headerTransitionDuration,
                        curve: headerTransitionCurve,
                        child: Icon(
                          Icons.chevron_right_rounded,
                          color: expanded ? cs.primary : cs.onSurfaceVariant,
                          size: expanded ? 18 : 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget aboutSectionHeader() {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 4),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
          child: Row(
            children: [
              Icon(Icons.info_rounded, color: cs.primary, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('about'),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                    fontSize: 13,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _openLogsDialog(context),
                icon: const Icon(Icons.bug_report_outlined),
                tooltip: tr('appLogs'),
                color: cs.primary,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget settingsCard(List<Widget> children) {
      return m3eExpressiveSettingsCard(
        context: context,
        colorScheme: cs,
        items: children,
      );
    }

    Widget collapsibleCard(String key, List<Widget> children) {
      final bool expanded =
          settingsProvider.prefs?.getBool('settingsSection_$key') ?? true;
      return ClipRect(
        clipper: _SettingsSectionShadowClipper(expanded: expanded),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeInOutCubicEmphasized,
          alignment: Alignment.topCenter,
          heightFactor: expanded ? 1.0 : 0.0,
          child: AnimatedOpacity(
            duration: Duration(milliseconds: expanded ? 260 : 140),
            curve: expanded ? Curves.easeOutCubic : Curves.easeInCubic,
            opacity: expanded ? 1.0 : 0.0,
            child: settingsCard(children),
          ),
        ),
      );
    }

    final List<String> visibleSettingsSectionKeys = [
      'updates',
      if (sourceProvider.sources.any(
        (source) => source.sourceConfigSettingFormItems.isNotEmpty,
      ))
        'sourceSpecific',
      'themes',
      'appearance',
      'gestures',
      'categories',
    ];
    final bool allSettingsSectionsExpanded = visibleSettingsSectionKeys.every(
      (sectionKey) =>
          settingsProvider.prefs?.getBool('settingsSection_$sectionKey') ??
          true,
    );

    void setAllSettingsSectionsExpanded(bool expanded) {
      for (final sectionKey in _settingsSectionKeys) {
        settingsProvider.setSettingBool(
          'settingsSection_$sectionKey',
          expanded,
        );
      }
    }

    return Scaffold(
      backgroundColor: cs.surface,
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
                      cs.schemePageGradientTopColor,
                      cs.schemePageGradientMidColor,
                      cs.surface,
                      cs.surface,
                    ],
                  ),
                ),
              ),
            ),
          CustomScrollView(
            key: const PageStorageKey<String>('settings-tab-scroll'),
            cacheExtent: 1600,
            slivers: <Widget>[
              CustomAppBar(
                title: tr('settings'),
                matchGradientBackground: settingsProvider.useGradientBackground,
                actions: [
                  IconButton(
                    tooltip: allSettingsSectionsExpanded
                        ? tr('collapseAll')
                        : tr('expandAll'),
                    icon: Icon(
                      allSettingsSectionsExpanded
                          ? Icons.unfold_less_rounded
                          : Icons.unfold_more_rounded,
                    ),
                    onPressed: () {
                      setAllSettingsSectionsExpanded(
                        !allSettingsSectionsExpanded,
                      );
                    },
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: settingsProvider.prefs == null
                      ? const SizedBox()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── Updates ──────────────────────────────────────────
                            sectionHeader(
                              tr('updates'),
                              Icons.update_rounded,
                              'updates',
                            ),
                            FutureBuilder<AndroidDeviceInfo>(
                              future: _androidInfo,
                              builder:
                                  (
                                    BuildContext context,
                                    AsyncSnapshot<AndroidDeviceInfo> snapshot,
                                  ) {
                                    return collapsibleCard(
                                      'updates',
                                      _updatesCardItemList(
                                        context,
                                        cs,
                                        settingsProvider,
                                        snapshot,
                                        updatesIntervalHead,
                                      ),
                                    );
                                  },
                            ),
                            // ── Source-specific ──────────────────────────────────
                            if (sourceProvider.sources.any(
                              (s) => s.sourceConfigSettingFormItems.isNotEmpty,
                            )) ...[
                              sectionHeader(
                                tr('sourceSpecific'),
                                Icons.dns_rounded,
                                'sourceSpecific',
                              ),
                              collapsibleCard('sourceSpecific', [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    8,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (
                                        int i = 0;
                                        i < sourceSpecificForms.length;
                                        i++
                                      ) ...[
                                        if (i > 0) const SizedBox(height: 12),
                                        sourceSpecificForms[i],
                                      ],
                                    ],
                                  ),
                                ),
                              ]),
                            ],
                            // ── Themes ────────────────────────────────────────────
                            sectionHeader(
                              tr('settingsThemesSection'),
                              Icons.palette_rounded,
                              'themes',
                            ),
                            collapsibleCard(
                              'themes',
                              buildThemesSettingsCardItems(
                                context,
                                _androidInfo,
                              ),
                            ),
                            // ── Appearance ────────────────────────────────────────
                            sectionHeader(
                              tr('appearance'),
                              Icons.tune_rounded,
                              'appearance',
                            ),
                            collapsibleCard('appearance', [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  4,
                                ),
                                child: localeMenu,
                              ),
                              FutureBuilder(
                                builder: (ctx, val) {
                                  return (val.data?.version.sdkInt ?? 0) >= 29
                                      ? SwitchListTile(
                                          title: Text(tr('useSystemFont')),
                                          value: settingsProvider.useSystemFont,
                                          onChanged: (useSystemFont) {
                                            if (useSystemFont) {
                                              NativeFeatures.loadSystemFont()
                                                  .then((val) {
                                                    settingsProvider
                                                            .useSystemFont =
                                                        true;
                                                  });
                                            } else {
                                              settingsProvider.useSystemFont =
                                                  false;
                                            }
                                          },
                                        )
                                      : const SizedBox.shrink();
                                },
                                future: _androidInfo,
                              ),
                              // ── UI scale slider ─────────────────────────
                              // Lets users dial the in-app text/layout size
                              // up or down. The slider is the sole knob -
                              // when it's at 1.0 the MediaQuery override in
                              // main.dart is a true no-op. Visual design
                              // mirrors the [intervalSlider] above (gapped
                              // track + vertical-bar thumb + tick marks)
                              // for consistency across the settings page.
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.format_size_rounded,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(tr('uiScale')),
                                                ),
                                                Text(
                                                  '${(settingsProvider.appUiScale * 100).round()}%',
                                                ),
                                              ],
                                            ),
                                          ),
                                          SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              trackHeight: 16,
                                              trackShape:
                                                  const _GappedTrackShape(),
                                              thumbShape:
                                                  const _VerticalBarThumbShape(),
                                              tickMarkShape:
                                                  const RoundSliderTickMarkShape(
                                                    tickMarkRadius: 3,
                                                  ),
                                              activeTickMarkColor: Theme.of(
                                                context,
                                              ).colorScheme.onPrimary,
                                              inactiveTickMarkColor: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              overlayShape:
                                                  const RoundSliderOverlayShape(
                                                    overlayRadius: 20,
                                                  ),
                                            ),
                                            child: Slider(
                                              min: SettingsProvider
                                                  .appUiScaleMin,
                                              max: SettingsProvider
                                                  .appUiScaleMax,
                                              divisions:
                                                  ((SettingsProvider
                                                                  .appUiScaleMax -
                                                              SettingsProvider
                                                                  .appUiScaleMin) /
                                                          0.05)
                                                      .round(),
                                              label:
                                                  '${(settingsProvider.appUiScale * 100).round()}%',
                                              value:
                                                  settingsProvider.appUiScale,
                                              onChanged: (double value) {
                                                settingsProvider.appUiScale =
                                                    value;
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.rounded_corner_rounded,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    tr('cardCorners'),
                                                  ),
                                                ),
                                                Text(
                                                  '${(settingsProvider.cardCornerScale * 100).round()}%',
                                                ),
                                              ],
                                            ),
                                          ),
                                          SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              trackHeight: 16,
                                              trackShape:
                                                  const _GappedTrackShape(),
                                              thumbShape:
                                                  const _VerticalBarThumbShape(),
                                              tickMarkShape:
                                                  const RoundSliderTickMarkShape(
                                                    tickMarkRadius: 3,
                                                  ),
                                              activeTickMarkColor: Theme.of(
                                                context,
                                              ).colorScheme.onPrimary,
                                              inactiveTickMarkColor: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              overlayShape:
                                                  const RoundSliderOverlayShape(
                                                    overlayRadius: 20,
                                                  ),
                                            ),
                                            child: Slider(
                                              min: SettingsProvider
                                                  .cardCornerScaleMin,
                                              max: SettingsProvider
                                                  .cardCornerScaleMax,
                                              divisions:
                                                  ((SettingsProvider
                                                                  .cardCornerScaleMax -
                                                              SettingsProvider
                                                                  .cardCornerScaleMin) /
                                                          0.10)
                                                      .round(),
                                              label:
                                                  '${(settingsProvider.cardCornerScale * 100).round()}%',
                                              value: settingsProvider
                                                  .cardCornerScale,
                                              onChanged: (double value) {
                                                settingsProvider
                                                        .cardCornerScale =
                                                    value;
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SwitchListTile(
                                title: Text(tr('showWebInAppView')),
                                value: settingsProvider.showAppWebpage,
                                onChanged: (value) {
                                  settingsProvider.showAppWebpage = value;
                                },
                              ),
                              // [showFolderedAppsOnMainPage] toggle moved
                              // to the apps-list view options sheet (open
                              // via the apps tab's filter / view-options
                              // entry point) - it's a main-tab-scoped
                              // setting and belongs alongside the other
                              // view options (sort / group / pin updates
                              // etc.) rather than in the global Settings
                              // page where it competed with truly app-wide
                              // controls. See [showAppsViewOptionsSheet].
                              SwitchListTile(
                                title: Text(tr('dontShowTrackOnlyWarnings')),
                                value: settingsProvider.hideTrackOnlyWarning,
                                onChanged: (value) {
                                  settingsProvider.hideTrackOnlyWarning = value;
                                },
                              ),
                              SwitchListTile(
                                title: Text(tr('dontShowAPKOriginWarnings')),
                                value: settingsProvider.hideAPKOriginWarning,
                                onChanged: (value) {
                                  settingsProvider.hideAPKOriginWarning = value;
                                },
                              ),
                              SwitchListTile(
                                title: Text(tr('disablePageTransitions')),
                                value: settingsProvider.disablePageTransitions,
                                onChanged: (value) {
                                  settingsProvider.disablePageTransitions =
                                      value;
                                },
                              ),
                              SwitchListTile(
                                title: Text(tr('reversePageTransitions')),
                                value: settingsProvider.reversePageTransitions,
                                onChanged:
                                    settingsProvider.disablePageTransitions
                                    ? null
                                    : (value) {
                                        settingsProvider
                                                .reversePageTransitions =
                                            value;
                                      },
                              ),
                              SwitchListTile(
                                title: Text(tr('highlightTouchTargets')),
                                value: settingsProvider.highlightTouchTargets,
                                onChanged: (value) {
                                  settingsProvider.highlightTouchTargets =
                                      value;
                                },
                              ),
                            ]),
                            // ── Gestures ──────────────────────────────────────────
                            sectionHeader(
                              tr('gestures'),
                              Icons.swipe_rounded,
                              'gestures',
                            ),
                            collapsibleCard('gestures', [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  12,
                                ),
                                child: m3eCompactDropdownScope(
                                  context: context,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      DropdownMenu<SwipeAction>(
                                        key: ValueKey(
                                          'rightSwipeAction_${settingsProvider.rightSwipeAction}',
                                        ),
                                        initialSelection:
                                            settingsProvider.rightSwipeAction,
                                        label: Text(tr('rightSwipeAction')),
                                        expandedInsets: EdgeInsets.zero,
                                        onSelected: (SwipeAction? value) {
                                          if (value != null) {
                                            settingsProvider.rightSwipeAction =
                                                value;
                                          }
                                        },
                                        dropdownMenuEntries:
                                            swipeActionsSortedByLocalizedLabel()
                                                .map(
                                                  (SwipeAction action) =>
                                                      DropdownMenuEntry<
                                                        SwipeAction
                                                      >(
                                                        value: action,
                                                        label: tr(
                                                          'swipeAction_${action.name}',
                                                        ),
                                                        leadingIcon: Icon(
                                                          _swipeActionIcon(
                                                            action,
                                                          ),
                                                          size: 18,
                                                        ),
                                                      ),
                                                )
                                                .toList(),
                                      ),
                                      const SizedBox(height: 16),
                                      DropdownMenu<SwipeAction>(
                                        key: ValueKey(
                                          'leftSwipeAction_${settingsProvider.leftSwipeAction}',
                                        ),
                                        initialSelection:
                                            settingsProvider.leftSwipeAction,
                                        label: Text(tr('leftSwipeAction')),
                                        expandedInsets: EdgeInsets.zero,
                                        onSelected: (SwipeAction? value) {
                                          if (value != null) {
                                            settingsProvider.leftSwipeAction =
                                                value;
                                          }
                                        },
                                        dropdownMenuEntries:
                                            swipeActionsSortedByLocalizedLabel()
                                                .map(
                                                  (SwipeAction action) =>
                                                      DropdownMenuEntry<
                                                        SwipeAction
                                                      >(
                                                        value: action,
                                                        label: tr(
                                                          'swipeAction_${action.name}',
                                                        ),
                                                        leadingIcon: Icon(
                                                          _swipeActionIcon(
                                                            action,
                                                          ),
                                                          size: 18,
                                                        ),
                                                      ),
                                                )
                                                .toList(),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ]),
                            // ── Categories ────────────────────────────────────────
                            sectionHeader(
                              tr('categories'),
                              Icons.label_rounded,
                              'categories',
                            ),
                            collapsibleCard('categories', [
                              const Padding(
                                padding: EdgeInsets.all(16),
                                child: CategoryEditorSelector(
                                  showLabelWhenNotEmpty: false,
                                  showSelectedCheckmark: true,
                                  showChangeIntentIcons: false,
                                ),
                              ),
                            ]),
                            aboutSectionHeader(),
                            settingsCard([
                              _AboutSectionContent(
                                colorScheme: cs,
                                settingsProvider: settingsProvider,
                              ),
                            ]),
                          ],
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
}

class _SettingsSectionShadowClipper extends CustomClipper<Rect> {
  const _SettingsSectionShadowClipper({required this.expanded});

  final bool expanded;

  static const double shadowPaintAllowance = 32;

  @override
  Rect getClip(Size size) {
    if (!expanded) {
      return Offset.zero & size;
    }
    return Rect.fromLTRB(
      -shadowPaintAllowance,
      -shadowPaintAllowance,
      size.width + shadowPaintAllowance,
      size.height + shadowPaintAllowance,
    );
  }

  @override
  bool shouldReclip(_SettingsSectionShadowClipper oldClipper) {
    return oldClipper.expanded != expanded;
  }
}

class _AboutSectionContent extends StatelessWidget {
  const _AboutSectionContent({
    required this.colorScheme,
    required this.settingsProvider,
  });

  final ColorScheme colorScheme;
  final SettingsProvider settingsProvider;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FutureBuilder<PackageInfo?>(
            future: getInstalledInfo(obtainiumId, printErr: false),
            builder: (context, snapshot) {
              final String versionName =
                  snapshot.data?.versionName ?? tr('unknown');
              return Text(
                tr('aboutAppVersion', args: [versionName]),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          Text(
            tr('aboutTagline'),
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _AboutImageTile(
                assetPath: 'assets/graphics/icon_small.png',
                borderRadius: 24,
                semanticLabel: tr('about'),
                fit: BoxFit.contain,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
              const SizedBox(width: 14),
              _AboutImageTile(
                assetPath: 'assets/graphics/me_600.webp',
                borderRadius: 18,
                semanticLabel: tr('aboutAuthorProfile'),
                onTap: () => _openAboutUrl(_aboutAuthorUrl),
                onLongPress: () => _copyAboutUrl(context, _aboutAuthorUrl),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            tr('aboutByline'),
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 18),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openAboutUrl(settingsProvider.sourceUrl),
                onLongPress: () =>
                    _copyAboutUrl(context, settingsProvider.sourceUrl),
                icon: _GitHubMarkIcon(color: colorScheme.onPrimary),
                label: Text(tr('aboutStarOnGithub')),
              ),
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: _aboutSecondaryButtonStyle(colorScheme),
                    onPressed: () => _openAboutUrl(_aboutWikiUrl),
                    onLongPress: () => _copyAboutUrl(context, _aboutWikiUrl),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(tr('aboutOpenWiki')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: _aboutSecondaryButtonStyle(colorScheme),
                    onPressed: () =>
                        _shareAboutUrl(settingsProvider.sourceUrl, 'ObtainX'),
                    onLongPress: () =>
                        _copyAboutUrl(context, settingsProvider.sourceUrl),
                    icon: const Icon(Icons.share_rounded),
                    label: Text(tr('share')),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              tr('aboutOtherApps'),
              style: textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          _AboutAppPromo(
            colorScheme: colorScheme,
            assetPath: 'assets/graphics/remember_logo.png',
            accentColor: const Color(0xFF74B84A),
            name: tr('aboutRememberName'),
            tagline: tr('aboutRememberTagline'),
            url: _aboutRememberUrl,
          ),
          const SizedBox(height: 10),
          _AboutAppPromo(
            colorScheme: colorScheme,
            assetPath: 'assets/graphics/filepipe_logo.png',
            accentColor: const Color(0xFF5967D8),
            name: tr('aboutFilePipeName'),
            tagline: tr('aboutFilePipeTagline'),
            url: _aboutFilePipeUrl,
          ),
          const SizedBox(height: 8),
          _AboutLegalLinks(colorScheme: colorScheme),
        ],
      ),
    );
  }
}

ButtonStyle _aboutSecondaryButtonStyle(ColorScheme colorScheme) {
  return FilledButton.styleFrom(
    backgroundColor: Color.alphaBlend(
      colorScheme.primary.withValues(alpha: 0.16),
      colorScheme.surfaceContainerHighest,
    ),
    foregroundColor: colorScheme.primary,
    side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.36)),
  );
}

class _GitHubMarkIcon extends StatelessWidget {
  const _GitHubMarkIcon({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(20),
      painter: _GitHubMarkPainter(color),
    );
  }
}

class _GitHubMarkPainter extends CustomPainter {
  const _GitHubMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final Path path = Path()
      ..moveTo(12, 2)
      ..arcToPoint(
        const Offset(2, 12),
        radius: const Radius.circular(10),
        clockwise: false,
      )
      ..relativeCubicTo(0, 4.42, 2.87, 8.17, 6.84, 9.5)
      ..relativeCubicTo(0.5, 0.08, 0.66, -0.23, 0.66, -0.5)
      ..relativeLineTo(0, -1.69)
      ..relativeCubicTo(-2.77, 0.6, -3.36, -1.34, -3.36, -1.34)
      ..relativeCubicTo(-0.46, -1.16, -1.11, -1.47, -1.11, -1.47)
      ..relativeCubicTo(-0.91, -0.62, 0.07, -0.6, 0.07, -0.6)
      ..relativeCubicTo(1, 0.07, 1.53, 1.03, 1.53, 1.03)
      ..relativeCubicTo(0.89, 1.52, 2.34, 1.08, 2.91, 0.83)
      ..relativeCubicTo(0.09, -0.65, 0.35, -1.09, 0.63, -1.34)
      ..relativeCubicTo(-2.22, -0.25, -4.55, -1.11, -4.55, -4.94)
      ..relativeCubicTo(0, -1.09, 0.39, -1.98, 1.03, -2.68)
      ..relativeCubicTo(-0.1, -0.25, -0.45, -1.27, 0.1, -2.65)
      ..relativeCubicTo(0, 0, 0.84, -0.27, 2.75, 1.02)
      ..relativeCubicTo(0.8, -0.22, 1.65, -0.33, 2.5, -0.33)
      ..relativeCubicTo(0.85, 0, 1.7, 0.11, 2.5, 0.33)
      ..relativeCubicTo(1.91, -1.29, 2.75, -1.02, 2.75, -1.02)
      ..relativeCubicTo(0.55, 1.38, 0.2, 2.4, 0.1, 2.65)
      ..relativeCubicTo(0.64, 0.7, 1.03, 1.59, 1.03, 2.68)
      ..relativeCubicTo(0, 3.85, -2.34, 4.68, -4.57, 4.93)
      ..relativeCubicTo(0.36, 0.31, 0.68, 0.92, 0.68, 1.85)
      ..relativeLineTo(0, 2.74)
      ..relativeCubicTo(0, 0.27, 0.16, 0.59, 0.67, 0.5)
      ..cubicTo(19.14, 20.17, 22, 16.42, 22, 12)
      ..arcToPoint(
        const Offset(12, 2),
        radius: const Radius.circular(10),
        clockwise: false,
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GitHubMarkPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _AboutImageTile extends StatelessWidget {
  const _AboutImageTile({
    required this.assetPath,
    required this.borderRadius,
    required this.semanticLabel,
    this.backgroundColor,
    this.fit = BoxFit.cover,
    this.onTap,
    this.onLongPress,
  });

  final String assetPath;
  final double borderRadius;
  final String semanticLabel;
  final Color? backgroundColor;
  final BoxFit fit;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor ?? Colors.transparent,
      borderRadius: BorderRadius.circular(borderRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Ink.image(
          image: AssetImage(assetPath),
          width: 84,
          height: 84,
          fit: fit,
          child: Semantics(
            label: semanticLabel,
            image: true,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _AboutAppPromo extends StatelessWidget {
  const _AboutAppPromo({
    required this.colorScheme,
    required this.assetPath,
    required this.accentColor,
    required this.name,
    required this.tagline,
    required this.url,
  });

  final ColorScheme colorScheme;
  final String assetPath;
  final Color accentColor;
  final String name;
  final String tagline;
  final String url;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color containerColor = Color.alphaBlend(
      accentColor.withValues(alpha: 0.24),
      colorScheme.surfaceContainerHighest,
    );
    final RoundedRectangleBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: accentColor.withValues(alpha: 0.34)),
    );
    return Material(
      color: containerColor,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openAboutUrl(url),
        onLongPress: () => _copyAboutUrl(context, url),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  assetPath,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tagline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: accentColor.withValues(alpha: 0.86),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AboutLegalLinks extends StatelessWidget {
  const _AboutLegalLinks({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AboutTextLink(
              label: tr('aboutWebsite'),
              url: _aboutObtainXWebsiteUrl,
              colorScheme: colorScheme,
            ),
            _AboutLinkSeparator(colorScheme: colorScheme),
            _AboutTextLink(
              label: tr('aboutPrivacyPolicy'),
              url: _aboutObtainXPrivacyUrl,
              colorScheme: colorScheme,
            ),
            _AboutLinkSeparator(colorScheme: colorScheme),
            _AboutTextLink(
              label: tr('aboutTerms'),
              url: _aboutObtainXTermsUrl,
              colorScheme: colorScheme,
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutTextLink extends StatelessWidget {
  const _AboutTextLink({
    required this.label,
    required this.url,
    required this.colorScheme,
  });

  final String label;
  final String url;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => _openAboutUrl(url),
      onLongPress: () => _copyAboutUrl(context, url),
      style: TextButton.styleFrom(
        foregroundColor: colorScheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, maxLines: 1),
    );
  }
}

class _AboutLinkSeparator extends StatelessWidget {
  const _AboutLinkSeparator({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Text('•', style: TextStyle(color: colorScheme.onSurfaceVariant));
  }
}

Future<void> _openAboutUrl(String url) async {
  await launchUrlString(url, mode: LaunchMode.externalApplication);
}

Future<void> _copyAboutUrl(BuildContext context, String url) async {
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  showMessage(tr('aboutLinkCopied'), context);
}

Future<void> _shareAboutUrl(String url, String subject) async {
  await SharePlus.instance.share(
    ShareParams(
      text: tr('aboutShareText', args: [url]),
      subject: subject,
    ),
  );
}

void _openLogsDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (BuildContext dialogContext) {
      return const LogsDialog(initialDays: 7);
    },
  );
}

class LogsDialog extends StatefulWidget {
  final int initialDays;
  const LogsDialog({
    super.key,
    required this.initialDays,
  });

  @override
  State<LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<LogsDialog> {
  String? logString;
  bool isLoading = true;
  late int selectedDays;
  List<int> days = [7, 5, 4, 3, 2, 1];

  @override
  void initState() {
    super.initState();
    selectedDays = widget.initialDays;
    fetchLogs(selectedDays);
  }

  void fetchLogs(int daysLimit) {
    setState(() {
      isLoading = true;
    });
    context
        .read<LogsProvider>()
        .get(
          after: DateTime.now().subtract(Duration(days: daysLimit)),
          limit: 500,
          orderBy: 'timestamp DESC',
        )
        .then((logsList) {
      if (!mounted) return;
      setState(() {
        final chronologicalLogs = logsList.reversed.toList();
        String joinedLogs = chronologicalLogs.map((logEntry) => logEntry.toString()).join('\n\n');
        logString = joinedLogs.isNotEmpty ? joinedLogs : tr('noLogs');
        isLoading = false;
      });
    }).catchError((error) {
      if (!mounted) return;
      setState(() {
        logString = tr('noLogs');
        isLoading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    var logsProvider = context.read<LogsProvider>();

    Future<String> getDiagnosticsText() async {
      final buffer = StringBuffer();
      buffer.writeln('=== ObtainX Diagnostic Log ===');
      
      try {
        final packageInfo = await getInstalledInfo(obtainiumId, printErr: false);
        buffer.writeln('App Version: ${packageInfo?.versionName ?? 'Unknown'} (code ${packageInfo?.versionCode ?? 'unknown'})');
        buffer.writeln('Package ID: ${packageInfo?.packageName ?? obtainiumId}');
      } catch (exception) {
        buffer.writeln('App Version: Unknown (Error fetching package info)');
      }

      try {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        buffer.writeln('Device: ${androidInfo.manufacturer} ${androidInfo.model} (${androidInfo.device})');
        buffer.writeln('Android Version: ${androidInfo.version.release} (SDK ${androidInfo.version.sdkInt})');
        buffer.writeln('Supported ABIs: ${androidInfo.supportedAbis.join(', ')}');
      } catch (exception) {
        buffer.writeln('Device Info: Unknown (Error fetching device info)');
      }

      final settingsProvider = context.read<SettingsProvider>();
      final appsProvider = context.read<AppsProvider>();
      buffer.writeln('Installer Mode: ${settingsProvider.installerMode}');
      buffer.writeln('Use Shizuku: ${settingsProvider.useShizuku}');
      buffer.writeln('Background Updates: ${settingsProvider.enableBackgroundUpdates}');
      buffer.writeln('Parallel Downloads: ${settingsProvider.parallelDownloads}');
      buffer.writeln('Tracked Apps: ${appsProvider.apps.length}');

      try {
        final notificationGranted = await Permission.notification.isGranted;
        buffer.writeln('Notifications Enabled: $notificationGranted');
      } catch (exception) {
        buffer.writeln('Notifications Enabled: Unknown (Error checking permission)');
      }

      final autoExportEnabled = settingsProvider.autoExportOnChanges;
      buffer.writeln('Auto-Export on Changes: $autoExportEnabled');
      if (autoExportEnabled) {
        try {
          final exportDir = await settingsProvider.getExportDir(requireAccess: false);
          if (exportDir == null) {
            buffer.writeln('Export Directory: Not configured');
          } else {
            final accessGranted = await settingsProvider.getExportDir(warnIfInaccessible: false) != null;
            buffer.writeln('Export Directory Configured: true (Access Present: $accessGranted)');
          }
        } catch (exception) {
          buffer.writeln('Export Directory: Unknown (Error checking path)');
        }
      }

      final saveApkCopies = settingsProvider.saveDownloadedApkCopies;
      buffer.writeln('Save APK Copies: $saveApkCopies');
      if (saveApkCopies) {
        try {
          final apkSaveDir = await settingsProvider.getApkSaveDir(requireAccess: false);
          if (apkSaveDir == null) {
            buffer.writeln('APK Save Directory: Not configured');
          } else {
            final accessGranted = await settingsProvider.getApkSaveDir(warnIfInaccessible: false) != null;
            buffer.writeln('APK Save Directory Configured: true (Access Present: $accessGranted)');
          }
        } catch (exception) {
          buffer.writeln('APK Save Directory: Unknown (Error checking path)');
        }
      }

      buffer.writeln('===============================\n');

      return buffer.toString();
    }

    return AlertDialog(
      title: Text(tr('appLogs')),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              initialValue: selectedDays,
              items: days
                  .map(
                    (dayValue) => DropdownMenuItem<int>(
                      value: dayValue,
                      child: Text(plural('day', dayValue)),
                    ),
                  )
                  .toList(),
              onChanged: isLoading
                  ? null
                  : (selectedVal) {
                      if (selectedVal != null) {
                        selectedDays = selectedVal;
                        fetchLogs(selectedVal);
                      }
                    },
            ),
            const SizedBox(height: 16),
            Expanded(
              child: isLoading
                  ? const Center(child: ExpressiveLoadingIndicator())
                  : Scrollbar(
                      child: SingleChildScrollView(
                        child: SelectableText(logString ?? ''),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: double.maxFinite,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () async {
                      var cont =
                          (await showDialog<Map<String, dynamic>?>(
                            context: context,
                            builder: (BuildContext modalContext) {
                              return GeneratedFormModal(
                                title: tr('appLogs'),
                                items: const [],
                                initValid: true,
                                message: tr('removeFromObtainX'),
                              );
                            },
                          )) !=
                          null;
                      if (cont) {
                        logsProvider.clear();
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                      }
                    },
                    child: Text(tr('remove')),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    child: Text(tr('close')),
                  ),
                  TextButton(
                    onPressed: () async {
                      final diagnostics = await getDiagnosticsText();
                      SharePlus.instance.share(
                        ShareParams(
                          text: '$diagnostics${logString ?? ''}',
                          subject: tr('appLogs'),
                        ),
                      );
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                    },
                    child: Text(tr('share')),
                  ),
                  TextButton(
                    onPressed: () async {
                      final diagnostics = await getDiagnosticsText();
                      final timestampForFilename = DateTime.now()
                          .toIso8601String()
                          .replaceAll(':', '-');
                      final logFileName =
                          'obtainx-logs-$timestampForFilename.txt';
                      final logFile = XFile.fromData(
                        Uint8List.fromList(utf8.encode('$diagnostics${logString ?? ''}')),
                        mimeType: 'text/plain',
                        name: logFileName,
                      );
                      await SharePlus.instance.share(
                        ShareParams(
                          files: [logFile],
                          fileNameOverrides: [logFileName],
                          subject: tr('appLogs'),
                        ),
                      );
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                    },
                    child: Text(tr('shareAsFile')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Canonical JSON for [GeneratedForm] key (prefs key order can vary).
String _stableCategoriesMapJson(Map<String, int> categories) {
  final List<MapEntry<String, int>> sorted =
      List<MapEntry<String, int>>.from(categories.entries)..sort(
        (MapEntry<String, int> left, MapEntry<String, int> right) =>
            left.key.compareTo(right.key),
      );
  return jsonEncode(Map<String, int>.fromEntries(sorted));
}

Map<String, MapEntry<int, bool>> _mergeCategoryEditorMaps(
  Map<String, int> fromPrefs,
  Map<String, MapEntry<int, bool>> previousSelections,
  Set<String> preselected,
) {
  final Map<String, MapEntry<int, bool>> merged =
      <String, MapEntry<int, bool>>{};
  for (final MapEntry<String, int> entry in fromPrefs.entries) {
    merged[entry.key] = MapEntry(
      entry.value,
      previousSelections[entry.key]?.value ?? preselected.contains(entry.key),
    );
  }
  for (final MapEntry<String, MapEntry<int, bool>> entry
      in previousSelections.entries) {
    if (!merged.containsKey(entry.key)) {
      merged[entry.key] = entry.value;
    }
  }
  return merged;
}

class CategoryEditorSelector extends StatefulWidget {
  final void Function(List<String> categories)? onSelected;
  final bool singleSelect;
  final Set<String> preselected;
  final WrapAlignment alignment;
  final bool showLabelWhenNotEmpty;
  final bool showSelectedCheckmark;
  final bool showChangeIntentIcons;

  /// When false, only chips are shown (toggle selection). Add / edit / remove
  /// controls for the global category list are hidden.
  final bool allowCategoryManagement;
  const CategoryEditorSelector({
    super.key,
    this.onSelected,
    this.singleSelect = false,
    this.preselected = const {},
    this.alignment = WrapAlignment.start,
    this.showLabelWhenNotEmpty = true,
    this.showSelectedCheckmark = false,
    this.showChangeIntentIcons = true,
    this.allowCategoryManagement = true,
  });

  @override
  State<CategoryEditorSelector> createState() => _CategoryEditorSelectorState();
}

class _CategoryEditorSelectorState extends State<CategoryEditorSelector> {
  Map<String, MapEntry<int, bool>> storedValues = {};

  @override
  Widget build(BuildContext context) {
    // Select only categories so this widget doesn't rebuild on unrelated
    // settings changes (every SettingsProvider setter calls notifyListeners).
    final Map<String, int> fromPrefs = context
        .select<SettingsProvider, Map<String, int>>((s) => s.categories);
    final appsProvider = context
        .read<AppsProvider>(); // not watch: saveApps would rebuild form
    final Map<String, MapEntry<int, bool>> merged = _mergeCategoryEditorMaps(
      fromPrefs,
      storedValues,
      widget.preselected,
    );
    return GeneratedForm(
      key: ValueKey<String>(
        'categories_${_stableCategoriesMapJson(fromPrefs)}',
      ),
      items: [
        [
          GeneratedFormTagInput(
            'categories',
            label: tr('categories'),
            emptyMessage: tr('noCategories'),
            defaultValue: merged,
            alignment: widget.alignment,
            deleteConfirmationMessage: MapEntry(
              tr('deleteCategoriesQuestion'),
              tr('categoryDeleteWarning'),
            ),
            singleSelect: widget.singleSelect,
            showLabelWhenNotEmpty: widget.showLabelWhenNotEmpty,
            allowTagManagement: widget.allowCategoryManagement,
            showSelectedCheckmark: widget.showSelectedCheckmark,
            showChangeIntentIcons: widget.showChangeIntentIcons,
          ),
        ],
      ],
      onValueChanges: ((values, valid, isBuilding) {
        if (!isBuilding) {
          final Map<String, MapEntry<int, bool>> catMap =
              values['categories'] as Map<String, MapEntry<int, bool>>;
          storedValues = cloneCategoryTagInputValueMap(catMap);
          final Map<String, int> colorsByName = catMap.map(
            (key, value) => MapEntry(key, value.key),
          );
          final List<String> selected = catMap.keys
              .where((k) => catMap[k]!.value)
              .toList();
          widget.onSelected?.call(selected);
          context.read<SettingsProvider>().setCategories(
            colorsByName,
            appsProvider: appsProvider,
          );
        }
      }),
    );
  }
}

class _ThirdPartyInstallerSelector extends StatefulWidget {
  final SettingsProvider settingsProvider;
  const _ThirdPartyInstallerSelector({required this.settingsProvider});

  @override
  State<_ThirdPartyInstallerSelector> createState() =>
      _ThirdPartyInstallerSelectorState();
}

class _ThirdPartyInstallerSelectorState
    extends State<_ThirdPartyInstallerSelector> {
  List<installer.InstallerAppInfo>? _installerApps;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadInstallers();
  }

  Future<void> _loadInstallers() async {
    final apps = await installer.getApkInstallerApps();
    if (mounted) {
      setState(() {
        _installerApps = apps;
        _loading = false;
      });
    }
  }

  void _showInstallerPicker() {
    if (_installerApps == null || _installerApps!.isEmpty) return;

    final currentPkg = widget.settingsProvider.legacyInstallerPackage;
    final currentAct = widget.settingsProvider.legacyInstallerActivity;
    final currentValue = (currentPkg != null && currentAct != null)
        ? '$currentPkg|$currentAct'
        : null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        String? selectedValue = currentValue;
        return StatefulBuilder(
          builder: (builderContext, setSheetState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.5,
              maxChildSize: 0.85,
              builder: (_, scrollController) {
                return RadioGroup<String>(
                  groupValue: selectedValue,
                  onChanged: (String? value) {
                    setSheetState(() => selectedValue = value);
                    if (value != null) {
                      final selected = _installerApps!.firstWhere(
                        (a) => '${a.packageName}|${a.activityName}' == value,
                      );
                      widget.settingsProvider.legacyInstallerPackage =
                          selected.packageName;
                      widget.settingsProvider.legacyInstallerActivity =
                          selected.activityName;
                    }
                    Navigator.pop(sheetContext);
                  },
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          tr('thirdPartyInstallerSelect'),
                          style: Theme.of(builderContext).textTheme.titleMedium,
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          controller: scrollController,
                          itemCount: _installerApps!.length,
                          itemBuilder: (_, index) {
                            final app = _installerApps![index];
                            final radioValue =
                                '${app.packageName}|${app.activityName}';
                            return RadioListTile<String>(
                              secondary:
                                  app.icon != null && app.icon!.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.memory(
                                        app.icon!,
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.contain,
                                        // Decode at the rendered size × DPR
                                        // so a 512×512 launcher icon doesn't
                                        // sit at full resolution in the
                                        // raster cache for a 40-px row.
                                        cacheWidth:
                                            (40 *
                                                    MediaQuery.devicePixelRatioOf(
                                                      context,
                                                    ))
                                                .round(),
                                        cacheHeight:
                                            (40 *
                                                    MediaQuery.devicePixelRatioOf(
                                                      context,
                                                    ))
                                                .round(),
                                        errorBuilder: (_, _, _) =>
                                            const Icon(Icons.android, size: 40),
                                      ),
                                    )
                                  : const Icon(Icons.android, size: 40),
                              title: Text(app.label),
                              subtitle: Text(
                                app.packageName,
                                style: const TextStyle(fontSize: 12),
                              ),
                              value: radioValue,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedPkg = widget.settingsProvider.legacyInstallerPackage;
    final selectedApp = (_installerApps ?? [])
        .where((app) => app.packageName == selectedPkg)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading)
          const Center(child: ExpressiveLoadingIndicator())
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: selectedApp?.icon != null && selectedApp!.icon!.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      selectedApp.icon!,
                      width: 36,
                      height: 36,
                      fit: BoxFit.contain,
                      cacheWidth: (36 * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                      cacheHeight: (36 * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.android, size: 36),
                    ),
                  )
                : null,
            title: Text(tr('thirdPartyInstallerSelect')),
            subtitle: Text(
              selectedApp?.label ??
                  selectedPkg ??
                  tr('thirdPartyInstallerNoneSelected'),
            ),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: _showInstallerPicker,
          ),
      ],
    );
  }
}

class _VerticalBarThumbShape extends SliderComponentShape {
  const _VerticalBarThumbShape();

  static const double _width = 4;
  static const double _height = 28;
  static const double _radius = 2;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size(_width, _height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    // Flutter's slider computes the framework-provided [center.dx] using
    // the FULL trackRect width:
    //   thumbX = trackRect.left + value * trackRect.width
    // ...but tick marks are inset on each side by trackHeight/2:
    //   tickX  = trackRect.left + value * (trackRect.width - trackHeight)
    //                           + trackHeight/2
    // The two only coincide at value == 0.5. Everywhere else the thumb
    // drifts off the tick proportionally to (value - 0.5) * trackHeight.
    // For a default 4dp track this drift is sub-pixel and unnoticeable;
    // for our M3E 16dp track it's a visible 8dp at the endpoints.
    //
    // Re-project the framework-provided center onto the tick-aligned
    // x-axis so the vertical bar thumb lands exactly on each dot.
    final Rect trackRect = sliderTheme.trackShape!.getPreferredRect(
      parentBox: parentBox,
      offset: Offset.zero,
      sliderTheme: sliderTheme,
      isEnabled: enableAnimation.value > 0,
      isDiscrete: isDiscrete,
    );
    final double trackHeight = trackRect.height;
    final double trackWidth = trackRect.width;
    Offset alignedCenter = center;
    if (trackWidth > trackHeight) {
      final double valueRatio = textDirection == TextDirection.rtl
          ? 1.0 - value
          : value;
      final double alignedX =
          trackRect.left +
          valueRatio * (trackWidth - trackHeight) +
          trackHeight / 2;
      alignedCenter = Offset(alignedX, center.dy);
    }
    final canvas = context.canvas;
    final paint = Paint()
      ..color = sliderTheme.thumbColor ?? Colors.white
      ..style = PaintingStyle.fill;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: alignedCenter, width: _width, height: _height),
      const Radius.circular(_radius),
    );
    canvas.drawRRect(rrect, paint);
  }
}

class _GappedTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _GappedTrackShape();

  static const double _gap = 4;
  static const double _radius = 8;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final canvas = context.canvas;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    // Re-project thumbCenter.dx onto the tick-aligned axis so the split
    // between active and inactive lanes coincides with the rendered
    // thumb position. See the long comment in [_VerticalBarThumbShape]
    // for why this re-projection is needed (Flutter's tick range is
    // inset by trackHeight/2 on each side; the framework-provided
    // thumbCenter is on the un-inset full-track axis).
    double thumbX = thumbCenter.dx;
    final double trackHeight = trackRect.height;
    final double trackWidth = trackRect.width;
    if (trackWidth > trackHeight) {
      final double valueRatio = ((thumbCenter.dx - trackRect.left) / trackWidth)
          .clamp(0.0, 1.0);
      thumbX =
          trackRect.left +
          valueRatio * (trackWidth - trackHeight) +
          trackHeight / 2;
    }

    final activePaint = Paint()
      ..color = (sliderTheme.activeTrackColor ?? Colors.blue);
    final inactivePaint = Paint()
      ..color = (sliderTheme.inactiveTrackColor ?? Colors.grey);

    // Active (left) track — up to thumb minus gap
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
          trackRect.left,
          trackRect.top,
          thumbX - _gap,
          trackRect.bottom,
        ),
        topLeft: const Radius.circular(_radius),
        bottomLeft: const Radius.circular(_radius),
      ),
      activePaint,
    );

    // Inactive (right) track — from thumb plus gap
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
          thumbX + _gap,
          trackRect.top,
          trackRect.right,
          trackRect.bottom,
        ),
        topRight: const Radius.circular(_radius),
        bottomRight: const Radius.circular(_radius),
      ),
      inactivePaint,
    );
  }
}
