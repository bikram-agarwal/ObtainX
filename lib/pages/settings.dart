import 'package:device_info_plus/device_info_plus.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/custom_app_bar.dart';
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
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shizuku_apk_installer/shizuku_apk_installer.dart';
import 'package:url_launcher/url_launcher_string.dart';


IconData _swipeActionIcon(SwipeAction action) => switch (action) {
  SwipeAction.update   => Icons.system_update_alt_rounded,
  SwipeAction.pin      => Icons.push_pin_rounded,
  SwipeAction.appOptions => Icons.tune_rounded,
  SwipeAction.delete   => Icons.delete_rounded,
  SwipeAction.open     => Icons.open_in_new_rounded,
  SwipeAction.appInfo  => Icons.info_rounded,
  SwipeAction.edit     => Icons.edit_rounded,
  SwipeAction.none     => Icons.block_rounded,
};

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
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

  final Map<ColorSwatch<Object>, String> colorsNameMap =
      <ColorSwatch<Object>, String>{
        ColorTools.createPrimarySwatch(obtainiumThemeColor): 'Obtainium',
      };

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

  @override
  Widget build(BuildContext context) {
    SettingsProvider settingsProvider = context.watch<SettingsProvider>();
    SourceProvider sourceProvider = SourceProvider();
    if (settingsProvider.prefs == null) settingsProvider.initializeSettings();
    processIntervalSliderValue(settingsProvider.updateIntervalSliderVal);

    Future<bool> colorPickerDialog() async {
      return ColorPicker(
        color: settingsProvider.themeColor,
        onColorChanged: (Color color) =>
            setState(() => settingsProvider.themeColor = color),
        actionButtons: const ColorPickerActionButtons(
          okButton: true,
          closeButton: true,
          dialogActionButtons: false,
        ),
        pickersEnabled: const <ColorPickerType, bool>{
          ColorPickerType.both: false,
          ColorPickerType.primary: false,
          ColorPickerType.accent: false,
          ColorPickerType.bw: false,
          ColorPickerType.custom: true,
          ColorPickerType.wheel: true,
        },
        pickerTypeLabels: <ColorPickerType, String>{
          ColorPickerType.custom: tr('standard'),
          ColorPickerType.wheel: tr('custom'),
        },
        title: Text(
          tr('selectX', args: [tr('colour').toLowerCase()]),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        wheelDiameter: 192,
        wheelSquareBorderRadius: 32,
        width: 48,
        height: 48,
        borderRadius: 24,
        spacing: 8,
        runSpacing: 8,
        enableShadesSelection: false,
        customColorSwatchesAndNames: colorsNameMap,
        showMaterialName: true,
        showColorName: true,
        materialNameTextStyle: Theme.of(context).textTheme.bodySmall,
        colorNameTextStyle: Theme.of(context).textTheme.bodySmall,
        copyPasteBehavior: const ColorPickerCopyPasteBehavior(
          longPressMenu: true,
        ),
      ).showPickerDialog(
        context,
        transitionBuilder:
            (
              BuildContext context,
              Animation<double> a1,
              Animation<double> a2,
              Widget widget,
            ) {
              final double curvedValue = Curves.easeInCubic.transform(a1.value);
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(curvedValue, curvedValue, 1),
                child: Opacity(opacity: curvedValue, child: widget),
              );
            },
        transitionDuration: const Duration(milliseconds: 250),
      );
    }

    var colorPicker = ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(tr('selectX', args: [tr('colour').toLowerCase()])),
      subtitle: Text(
        "${ColorTools.nameThatColor(settingsProvider.themeColor)} "
        "(${ColorTools.materialNameAndCode(settingsProvider.themeColor, colorSwatchNameMap: colorsNameMap)})",
      ),
      trailing: ColorIndicator(
        width: 40,
        height: 40,
        borderRadius: 20,
        color: settingsProvider.themeColor,
        onSelectFocus: false,
        onSelect: () async {
          final Color colorBeforeDialog = settingsProvider.themeColor;
          if (!(await colorPickerDialog())) {
            setState(() {
              settingsProvider.themeColor = colorBeforeDialog;
            });
          }
        },
      ),
    );

    var localeDropdown = DropdownButtonFormField(
      decoration: InputDecoration(labelText: tr('language')),
      initialValue: settingsProvider.forcedLocale,
      items: [
        DropdownMenuItem(value: null, child: Text(tr('followSystem'))),
        ...supportedLocales.map(
          (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
        ),
      ],
      onChanged: (value) {
        settingsProvider.forcedLocale = value;
        if (value != null) {
          context.setLocale(value);
        } else {
          settingsProvider.resetLocaleSafe(context);
        }
      },
    );

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
        value: settingsProvider.updateIntervalSliderVal
            .roundToDouble()
            .clamp(0, updateIntervalNodes.length.toDouble()),
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

    var sourceSpecificFields = sourceProvider.sources.map((e) {
      if (e.sourceConfigSettingFormItems.isNotEmpty) {
        return GeneratedForm(
          items: e.sourceConfigSettingFormItems.map((e) {
            if (e is GeneratedFormSwitch) {
              e.defaultValue = settingsProvider.getSettingBool(e.key);
            } else {
              e.defaultValue = settingsProvider.getSettingString(e.key);
            }
            return [e];
          }).toList(),
          onValueChanges: (values, valid, isBuilding) {
            if (valid && !isBuilding) {
              values.forEach((key, value) {
                var formItem = e.sourceConfigSettingFormItems
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
      } else {
        return Container();
      }
    });

    const height8 = SizedBox(height: 8);

    final cs = Theme.of(context).colorScheme;

    Widget sectionHeader(String title, IconData icon) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          Icon(icon, color: cs.primary, size: 16),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: cs.primary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );

    Widget settingsCard(List<Widget> children) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final double deepen = isDark ? 0.055 : 0.045;
      final Color fill = isDark ? cs.surfaceContainerHighest : cs.surfaceContainer;
      return Container(
        decoration: BoxDecoration(
          color: Color.lerp(fill, Colors.black, deepen) ?? fill,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.outlineVariant, width: 1),
          boxShadow: [
            if (isDark)
              BoxShadow(
                color: cs.shadow.withAlpha(180),
                blurRadius: 16,
                spreadRadius: 0,
                offset: const Offset(0, 4),
              )
            else
              BoxShadow(
                color: cs.shadow.withAlpha(40),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: CustomScrollView(
        slivers: <Widget>[
          CustomAppBar(title: tr('settings')),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: settingsProvider.prefs == null
                  ? const SizedBox()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── Updates ──────────────────────────────────────────
                        sectionHeader(tr('updates'), Icons.update_rounded),
                        settingsCard([
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.update_rounded,
                                  color: cs.onSurfaceVariant,
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
                                                tr('bgUpdateCheckInterval'),
                                              ),
                                            ),
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
                          ),
                          FutureBuilder(
                            builder: (ctx, val) {
                              return (settingsProvider.updateInterval > 0) &&
                                      (((val.data?.version.sdkInt ?? 0) >= 30) ||
                                          settingsProvider.useShizuku)
                                  ? Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        SwitchListTile(
                                          title: Text(tr('foregroundServiceExplanation')),
                                          value: settingsProvider.useFGService,
                                          onChanged: (value) {
                                            settingsProvider.useFGService = value;
                                          },
                                        ),
                                        SwitchListTile(
                                          title: Text(tr('enableBackgroundUpdates')),
                                          value: settingsProvider.enableBackgroundUpdates,
                                          onChanged: (value) {
                                            settingsProvider.enableBackgroundUpdates = value;
                                          },
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                tr('backgroundUpdateReqsExplanation'),
                                                style: Theme.of(context).textTheme.labelSmall,
                                              ),
                                              Text(
                                                tr('backgroundUpdateLimitsExplanation'),
                                                style: Theme.of(context).textTheme.labelSmall,
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (settingsProvider.enableBackgroundUpdates) ...[
                                          SwitchListTile(
                                            title: Text(tr('bgUpdatesOnWiFiOnly')),
                                            value: settingsProvider.bgUpdatesOnWiFiOnly,
                                            onChanged: (value) {
                                              settingsProvider.bgUpdatesOnWiFiOnly = value;
                                            },
                                          ),
                                          SwitchListTile(
                                            title: Text(tr('bgUpdatesWhileChargingOnly')),
                                            value: settingsProvider.bgUpdatesWhileChargingOnly,
                                            onChanged: (value) {
                                              settingsProvider.bgUpdatesWhileChargingOnly = value;
                                            },
                                          ),
                                        ],
                                      ],
                                    )
                                  : const SizedBox.shrink();
                            },
                            future: DeviceInfoPlugin().androidInfo,
                          ),
                          SwitchListTile(
                            title: Text(tr('checkOnStart')),
                            value: settingsProvider.checkOnStart,
                            onChanged: (value) {
                              settingsProvider.checkOnStart = value;
                            },
                          ),
                          SwitchListTile(
                            title: Text(tr('checkUpdateOnDetailPage')),
                            value: settingsProvider.checkUpdateOnDetailPage,
                            onChanged: (value) {
                              settingsProvider.checkUpdateOnDetailPage = value;
                            },
                          ),
                          SwitchListTile(
                            title: Text(tr('onlyCheckInstalledOrTrackOnlyApps')),
                            value: settingsProvider.onlyCheckInstalledOrTrackOnlyApps,
                            onChanged: (value) {
                              settingsProvider.onlyCheckInstalledOrTrackOnlyApps = value;
                            },
                          ),
                          SwitchListTile(
                            title: Text(tr('removeOnExternalUninstall')),
                            value: settingsProvider.removeOnExternalUninstall,
                            onChanged: (value) {
                              settingsProvider.removeOnExternalUninstall = value;
                            },
                          ),
                          SwitchListTile(
                            title: Text(tr('parallelDownloads')),
                            value: settingsProvider.parallelDownloads,
                            onChanged: (value) {
                              settingsProvider.parallelDownloads = value;
                            },
                          ),
                          ListTile(
                            title: Text(tr('beforeNewInstallsShareToAppVerifier')),
                            subtitle: GestureDetector(
                              onTap: () {
                                launchUrlString(
                                  'https://github.com/soupslurpr/AppVerifier',
                                  mode: LaunchMode.externalApplication,
                                );
                              },
                              child: Text(
                                tr('about'),
                                style: const TextStyle(
                                  decoration: TextDecoration.underline,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            trailing: Switch(
                              value: settingsProvider.beforeNewInstallsShareToAppVerifier,
                              onChanged: (value) {
                                settingsProvider.beforeNewInstallsShareToAppVerifier = value;
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr('installerMode')),
                                height8,
                                SizedBox(
                                  width: double.infinity,
                                  child: SegmentedButton<String>(
                                    segments: [
                                      ButtonSegment(
                                        value: 'stock',
                                        label: Text(tr('installerModeStock')),
                                      ),
                                      ButtonSegment(
                                        value: 'shizuku',
                                        label: Text(tr('installerModeShizuku')),
                                      ),
                                      ButtonSegment(
                                        value: 'legacy',
                                        label: Text(tr('installerModeThirdParty')),
                                      ),
                                    ],
                                    selected: {settingsProvider.installerMode},
                                    onSelectionChanged: (selected) {
                                      final mode = selected.first;
                                      if (mode == 'shizuku') {
                                        ShizukuApkInstaller().checkPermission().then((
                                          resCode,
                                        ) {
                                          if (!context.mounted) return;
                                          if (resCode!.startsWith('granted')) {
                                            settingsProvider.installerMode = 'shizuku';
                                          } else {
                                            switch (resCode) {
                                              case 'services_not_found':
                                                showError(
                                                  ObtainiumError(
                                                    tr('shizukuBinderNotFound'),
                                                  ),
                                                  context,
                                                );
                                              case 'old_shizuku':
                                                showError(
                                                  ObtainiumError(tr('shizukuOld')),
                                                  context,
                                                );
                                              case 'old_android_with_adb':
                                                showError(
                                                  ObtainiumError(
                                                    tr('shizukuOldAndroidWithADB'),
                                                  ),
                                                  context,
                                                );
                                              case 'denied':
                                                showError(
                                                  ObtainiumError(tr('cancelled')),
                                                  context,
                                                );
                                            }
                                          }
                                        });
                                      } else {
                                        settingsProvider.installerMode = mode;
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (settingsProvider.installerMode == 'shizuku')
                            SwitchListTile(
                              title: Text(tr('shizukuPretendToBeGooglePlay')),
                              value: settingsProvider.shizukuPretendToBeGooglePlay,
                              onChanged: (value) {
                                settingsProvider.shizukuPretendToBeGooglePlay = value;
                              },
                            ),
                          if (settingsProvider.installerMode == 'legacy')
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: _ThirdPartyInstallerSelector(
                                settingsProvider: settingsProvider,
                              ),
                            ),
                        ]),
                        // ── Source-specific ──────────────────────────────────
                        if (sourceProvider.sources.any(
                          (s) => s.sourceConfigSettingFormItems.isNotEmpty,
                        )) ...[
                          sectionHeader(tr('sourceSpecific'), Icons.dns_rounded),
                          settingsCard([
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [...sourceSpecificFields],
                              ),
                            ),
                          ]),
                        ],
                        // ── Appearance ────────────────────────────────────────
                        sectionHeader(tr('appearance'), Icons.palette_rounded),
                        settingsCard([
                          if (!settingsProvider.useMaterialYou)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: colorPicker,
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                            child: localeDropdown,
                          ),
                          FutureBuilder(
                            builder: (ctx, val) {
                              return (val.data?.version.sdkInt ?? 0) >= 29
                                  ? SwitchListTile(
                                      title: Text(tr('useSystemFont')),
                                      value: settingsProvider.useSystemFont,
                                      onChanged: (useSystemFont) {
                                        if (useSystemFont) {
                                          NativeFeatures.loadSystemFont().then((val) {
                                            settingsProvider.useSystemFont = true;
                                          });
                                        } else {
                                          settingsProvider.useSystemFont = false;
                                        }
                                      },
                                    )
                                  : const SizedBox.shrink();
                            },
                            future: DeviceInfoPlugin().androidInfo,
                          ),
                          SwitchListTile(
                            title: Text(tr('showWebInAppView')),
                            value: settingsProvider.showAppWebpage,
                            onChanged: (value) {
                              settingsProvider.showAppWebpage = value;
                            },
                          ),
                          SwitchListTile(
                            title: Text(tr('showFolderedAppsOnMainPage')),
                            value: settingsProvider.showFolderedAppsOnMainPage,
                            onChanged: (value) {
                              settingsProvider.showFolderedAppsOnMainPage =
                                  value;
                            },
                          ),
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
                              settingsProvider.disablePageTransitions = value;
                            },
                          ),
                          SwitchListTile(
                            title: Text(tr('reversePageTransitions')),
                            value: settingsProvider.reversePageTransitions,
                            onChanged: settingsProvider.disablePageTransitions
                                ? null
                                : (value) {
                                    settingsProvider.reversePageTransitions = value;
                                  },
                          ),
                          SwitchListTile(
                            title: Text(tr('highlightTouchTargets')),
                            value: settingsProvider.highlightTouchTargets,
                            onChanged: (value) {
                              settingsProvider.highlightTouchTargets = value;
                            },
                          ),
                        ]),
                        // ── Gestures ──────────────────────────────────────────
                        sectionHeader(
                          '${tr('gestures')} · ${SwipeAction.values.length}',
                          Icons.swipe_rounded,
                        ),
                        settingsCard([
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                DropdownMenu<SwipeAction>(
                                  key: ValueKey(settingsProvider.rightSwipeAction),
                                  initialSelection: settingsProvider.rightSwipeAction,
                                  label: Text(tr('rightSwipeAction')),
                                  expandedInsets: EdgeInsets.zero,
                                  onSelected: (value) {
                                    if (value != null) {
                                      settingsProvider.rightSwipeAction = value;
                                    }
                                  },
                                  dropdownMenuEntries: swipeActionsSortedByLocalizedLabel()
                                      .map((action) => DropdownMenuEntry(
                                            value: action,
                                            label: tr('swipeAction_${action.name}'),
                                            leadingIcon: Icon(_swipeActionIcon(action), size: 18),
                                          ))
                                      .toList(),
                                ),
                                const SizedBox(height: 16),
                                DropdownMenu<SwipeAction>(
                                  key: ValueKey(settingsProvider.leftSwipeAction),
                                  initialSelection: settingsProvider.leftSwipeAction,
                                  label: Text(tr('leftSwipeAction')),
                                  expandedInsets: EdgeInsets.zero,
                                  onSelected: (value) {
                                    if (value != null) {
                                      settingsProvider.leftSwipeAction = value;
                                    }
                                  },
                                  dropdownMenuEntries: swipeActionsSortedByLocalizedLabel()
                                      .map((action) => DropdownMenuEntry(
                                            value: action,
                                            label: tr('swipeAction_${action.name}'),
                                            leadingIcon: Icon(_swipeActionIcon(action), size: 18),
                                          ))
                                      .toList(),
                                ),
                              ],
                            ),
                          ),
                        ]),
                        // ── Categories ────────────────────────────────────────
                        sectionHeader(tr('categories'), Icons.label_rounded),
                        settingsCard([
                          Padding(
                            padding: const EdgeInsets.all(16),
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
                      icon: const Icon(Icons.help_outline_rounded),
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
                            showMessage(ObtainiumError(tr('noLogs')), context);
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
        ],
      ),
    );
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
            SharePlus.instance.share(ShareParams(text: logString ?? '', subject: tr('appLogs')));
            Navigator.of(context).pop();
          },
          child: Text(tr('share')),
        ),
      ],
    );
  }
}

class CategoryEditorSelector extends StatefulWidget {
  final void Function(List<String> categories)? onSelected;
  final bool singleSelect;
  final Set<String> preselected;
  final WrapAlignment alignment;
  final bool showLabelWhenNotEmpty;
  const CategoryEditorSelector({
    super.key,
    this.onSelected,
    this.singleSelect = false,
    this.preselected = const {},
    this.alignment = WrapAlignment.start,
    this.showLabelWhenNotEmpty = true,
  });

  @override
  State<CategoryEditorSelector> createState() => _CategoryEditorSelectorState();
}

class _CategoryEditorSelectorState extends State<CategoryEditorSelector> {
  Map<String, MapEntry<int, bool>> storedValues = {};

  @override
  Widget build(BuildContext context) {
    var settingsProvider = context.watch<SettingsProvider>();
    var appsProvider = context.watch<AppsProvider>();
    storedValues = settingsProvider.categories.map(
      (key, value) => MapEntry(
        key,
        MapEntry(
          value,
          storedValues[key]?.value ?? widget.preselected.contains(key),
        ),
      ),
    );
    return GeneratedForm(
      items: [
        [
          GeneratedFormTagInput(
            'categories',
            label: tr('categories'),
            emptyMessage: tr('noCategories'),
            defaultValue: storedValues,
            alignment: widget.alignment,
            deleteConfirmationMessage: MapEntry(
              tr('deleteCategoriesQuestion'),
              tr('categoryDeleteWarning'),
            ),
            singleSelect: widget.singleSelect,
            showLabelWhenNotEmpty: widget.showLabelWhenNotEmpty,
          ),
        ],
      ],
      onValueChanges: ((values, valid, isBuilding) {
        if (!isBuilding) {
          storedValues =
              values['categories'] as Map<String, MapEntry<int, bool>>;
          settingsProvider.setCategories(
            storedValues.map((key, value) => MapEntry(key, value.key)),
            appsProvider: appsProvider,
          );
          if (widget.onSelected != null) {
            widget.onSelected!(
              storedValues.keys.where((k) => storedValues[k]!.value).toList(),
            );
          }
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

class _ThirdPartyInstallerSelectorState extends State<_ThirdPartyInstallerSelector> {
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
    final currentValue =
        (currentPkg != null && currentAct != null) ? '$currentPkg|$currentAct' : null;

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
                              secondary: app.icon != null && app.icon!.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.memory(
                                        app.icon!,
                                        width: 40,
                                        height: 40,
                                        fit: BoxFit.contain,
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

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: selectedApp?.icon != null && selectedApp!.icon!.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        selectedApp.icon!,
                        width: 36,
                        height: 36,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.android, size: 36),
                      ),
                    )
                  : null,
              title: Text(tr('thirdPartyInstallerSelect')),
              subtitle: Text(
                selectedApp?.label ?? selectedPkg ?? tr('thirdPartyInstallerNoneSelected'),
              ),
              trailing: const Icon(Icons.arrow_drop_down),
              onTap: _showInstallerPicker,
            ),
        ],
      ),
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
    final canvas = context.canvas;
    final paint = Paint()
      ..color = sliderTheme.thumbColor ?? Colors.white
      ..style = PaintingStyle.fill;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: _width, height: _height),
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

    final activePaint = Paint()
      ..color = (sliderTheme.activeTrackColor ?? Colors.blue);
    final inactivePaint = Paint()
      ..color = (sliderTheme.inactiveTrackColor ?? Colors.grey);

    // Active (left) track — up to thumb minus gap
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
            trackRect.left, trackRect.top, thumbCenter.dx - _gap, trackRect.bottom),
        topLeft: const Radius.circular(_radius),
        bottomLeft: const Radius.circular(_radius),
      ),
      activePaint,
    );

    // Inactive (right) track — from thumb plus gap
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
            thumbCenter.dx + _gap, trackRect.top, trackRect.right, trackRect.bottom),
        topRight: const Radius.circular(_radius),
        bottomRight: const Radius.circular(_radius),
      ),
      inactivePaint,
    );
  }
}
