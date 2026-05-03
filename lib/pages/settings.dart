import 'dart:convert';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:flutter/material.dart';
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
      return InkWell(
        onTap: () =>
            settingsProvider.setSettingBool('settingsSection_$key', !expanded),
        borderRadius: BorderRadius.circular(8),
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Row(
            children: [
              Icon(icon, color: cs.primary, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                    fontSize: 13,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              AnimatedRotation(
                turns: expanded ? 0 : -0.25,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: cs.primary,
                  size: 18,
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
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          heightFactor: expanded ? 1.0 : 0.0,
          child: settingsCard(children),
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
                                          settingsProvider.rightSwipeAction,
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
                                          settingsProvider.leftSwipeAction,
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
                                ),
                              ),
                            ]),
                          ],
                        ),
                ),
              ),
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    const Divider(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        IconButton(
                          onPressed: () {
                            launchUrlString(
                              settingsProvider.sourceUrl,
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          icon: const Icon(Icons.code),
                          tooltip: tr('appSource'),
                        ),
                        IconButton(
                          onPressed: () {
                            launchUrlString(
                              'https://wiki.obtainium.imranr.dev/',
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          icon: const Icon(Icons.open_in_new_rounded),
                          tooltip: tr('wiki'),
                        ),
                        IconButton(
                          onPressed: () {
                            launchUrlString(
                              'https://apps.obtainium.imranr.dev/',
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          icon: const Icon(Icons.apps_rounded),
                          tooltip: tr('crowdsourcedConfigsLabel'),
                        ),
                        IconButton(
                          onPressed: () {
                            context.read<LogsProvider>().get().then((logs) {
                              if (!context.mounted) return;
                              if (logs.isEmpty) {
                                showMessage(
                                  ObtainiumError(tr('noLogs')),
                                  context,
                                );
                              } else {
                                showDialog(
                                  context: context,
                                  builder: (BuildContext ctx) {
                                    return const LogsDialog();
                                  },
                                );
                              }
                            });
                          },
                          icon: const Icon(Icons.bug_report_outlined),
                          tooltip: tr('appLogs'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
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

class LogsDialog extends StatefulWidget {
  const LogsDialog({super.key});

  @override
  State<LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<LogsDialog> {
  String? logString;
  List<int> days = [7, 5, 4, 3, 2, 1];

  @override
  Widget build(BuildContext context) {
    var logsProvider = context.read<LogsProvider>();
    void filterLogs(int days) {
      logsProvider
          .get(after: DateTime.now().subtract(Duration(days: days)))
          .then((value) {
            setState(() {
              String l = value.map((e) => e.toString()).join('\n\n');
              logString = l.isNotEmpty ? l : tr('noLogs');
            });
          });
    }

    if (logString == null) {
      filterLogs(days.first);
    }

    return AlertDialog(
      scrollable: true,
      title: Text(tr('appLogs')),
      content: Column(
        children: [
          DropdownButtonFormField(
            initialValue: days.first,
            items: days
                .map(
                  (e) =>
                      DropdownMenuItem(value: e, child: Text(plural('day', e))),
                )
                .toList(),
            onChanged: (d) {
              filterLogs(d ?? 7);
            },
          ),
          const SizedBox(height: 32),
          Text(logString ?? ''),
        ],
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
                            builder: (BuildContext ctx) {
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
                    onPressed: () {
                      SharePlus.instance.share(
                        ShareParams(
                          text: logString ?? '',
                          subject: tr('appLogs'),
                        ),
                      );
                      Navigator.of(context).pop();
                    },
                    child: Text(tr('share')),
                  ),
                  TextButton(
                    onPressed: () async {
                      final timestampForFilename = DateTime.now()
                          .toIso8601String()
                          .replaceAll(':', '-');
                      final logFileName =
                          'obtainx-logs-$timestampForFilename.txt';
                      final logFile = XFile.fromData(
                        Uint8List.fromList(utf8.encode(logString ?? '')),
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
    this.allowCategoryManagement = true,
  });

  @override
  State<CategoryEditorSelector> createState() => _CategoryEditorSelectorState();
}

class _CategoryEditorSelectorState extends State<CategoryEditorSelector> {
  Map<String, MapEntry<int, bool>> storedValues = {};

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final appsProvider = context
        .read<AppsProvider>(); // not watch: saveApps would rebuild form
    final Map<String, int> fromPrefs = settingsProvider.categories;
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
          settingsProvider.setCategories(
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
