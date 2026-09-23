import 'dart:ui' show Brightness, PlatformDispatcher;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:obtainium/app_distribution.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/virustotal_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android density bucket for [devicePixelRatio], matching the usual dpi
/// buckets (ldpi 0.75, mdpi 1, hdpi 1.5, xhdpi 2, xxhdpi 3, xxxhdpi 4).
String androidDensityBucket(double devicePixelRatio) {
  if (devicePixelRatio < 1.0) return 'ldpi';
  if (devicePixelRatio < 1.5) return 'mdpi';
  if (devicePixelRatio < 2.0) return 'hdpi';
  if (devicePixelRatio < 3.0) return 'xhdpi';
  if (devicePixelRatio < 4.0) return 'xxhdpi';
  return 'xxxhdpi';
}

String formatSavedSecretStatus({required bool saved, bool? validated}) {
  if (!saved) return 'Not Saved';
  if (validated == null) return 'Saved';
  return 'Saved (Validated: $validated)';
}

/// The window metrics a layout report can't be reproduced without.
///
/// Android's Display size setting moves [logicalSize] (and often
/// [devicePixelRatio]) while its Font size setting moves [textScale], so the two
/// are captured separately - a clipped or overflowing widget is usually one or
/// the other. [boldText] belongs with them because it changes text metrics too.
class DiagnosticDisplayInfo {
  DiagnosticDisplayInfo({
    required this.logicalSize,
    required this.devicePixelRatio,
    required this.textScale,
    required this.boldText,
    required this.platformBrightness,
  });

  factory DiagnosticDisplayInfo.fromContext(BuildContext context) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    return DiagnosticDisplayInfo(
      logicalSize: mediaQuery.size,
      devicePixelRatio: mediaQuery.devicePixelRatio,
      textScale: mediaQuery.textScaler.scale(14) / 14,
      boldText: mediaQuery.boldText,
      platformBrightness: mediaQuery.platformBrightness,
    );
  }

  final Size logicalSize;
  final double devicePixelRatio;
  final double textScale;
  final bool boldText;
  final Brightness platformBrightness;

  void writeTo(StringBuffer buffer) {
    buffer.writeln(
      'Screen: ${_formatDouble(logicalSize.width)} x ${_formatDouble(logicalSize.height)} dp '
      '@ ${_formatDouble(devicePixelRatio)} (${androidDensityBucket(devicePixelRatio)})',
    );
    buffer.writeln(
      'Text scale: ${_formatDouble(textScale)}${boldText ? ' (bold text on)' : ''}',
    );
  }
}

/// The user's Display size setting, as `Display size: ...` log text.
///
/// Returns null when the platform did not answer (non-Android, background
/// engine, or a build without the diagnostics channel).
///
/// The pixel resolution is deliberately not reported: it is just the logged
/// dp size times the density. What that arithmetic cannot show is whether the
/// density itself is the stock one, the one the user picked, or the one
/// MainActivity's scale cap forced - which is what this line answers.
String? formatDisplayScale(Map<String, Object?>? platformDisplayDiagnostics) {
  if (platformDisplayDiagnostics == null) return null;
  final int? stableDensityDpi =
      platformDisplayDiagnostics['stableDensityDpi'] as int?;
  final int? systemDensityDpi =
      platformDisplayDiagnostics['systemDensityDpi'] as int?;
  final int? effectiveDensityDpi =
      platformDisplayDiagnostics['effectiveDensityDpi'] as int?;
  if (stableDensityDpi == null ||
      systemDensityDpi == null ||
      effectiveDensityDpi == null ||
      stableDensityDpi <= 0) {
    return null;
  }

  final double systemScale =
      (systemDensityDpi / stableDensityDpi * 100).roundToDouble() / 100;
  final double effectiveScale =
      (effectiveDensityDpi / stableDensityDpi * 100).roundToDouble() / 100;
  if (systemDensityDpi == effectiveDensityDpi) {
    if (systemDensityDpi == stableDensityDpi) {
      return 'stock ($stableDensityDpi dpi)';
    }
    return '${_formatDouble(systemScale)}x of stock '
        '($systemDensityDpi dpi, stock $stableDensityDpi dpi)';
  }
  return '${_formatDouble(systemScale)}x of stock, '
      'capped by the app to ${_formatDouble(effectiveScale)}x '
      '(system $systemDensityDpi dpi, app $effectiveDensityDpi dpi, stock $stableDensityDpi dpi)';
}

String _formatDouble(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(3)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

void _writeLine(StringBuffer buffer, String label, Object? value) {
  buffer.writeln('$label: ${value ?? '<unset>'}');
}

Future<String> _permissionStatusLabel(Permission permission) async {
  try {
    return (await permission.status).name;
  } catch (error) {
    return 'Unknown ($error)';
  }
}

/// Header prepended to shared app logs.
///
/// Deliberately limited to state that changes how the app behaves, so a report
/// can be reproduced or explained from it. Cosmetic preferences (badges, sort
/// order, swipe actions, accent colours) and inert device trivia are left out,
/// as is the value of any credential.
///
/// [probeNativePlatform] is true in production. Tests turn it off so package
/// lookups, device_info, and permission_handler do not hang on a missing
/// plugin channel.
Future<String> buildObtainxDiagnosticLog({
  required SettingsProvider settings,
  required int trackedAppCount,
  required DiagnosticDisplayInfo display,
  required String appLocale,
  String? deviceLocale,
  String performanceReport = '',
  bool probeNativePlatform = true,
}) async {
  final StringBuffer buffer = StringBuffer();
  buffer.writeln('=== ObtainX Diagnostic Log ===');
  if (performanceReport.isNotEmpty) {
    buffer.write(performanceReport);
    if (!performanceReport.endsWith('\n')) buffer.writeln();
  }

  if (probeNativePlatform) {
    try {
      final packageInfo = await getInstalledInfo(
        obtainiumId,
        printErr: false,
        includeOwnDebugBuild: true,
      );
      _writeLine(
        buffer,
        'App Version',
        '${packageInfo?.versionName ?? 'Unknown'} (code ${packageInfo?.versionCode ?? 'unknown'})',
      );
      _writeLine(buffer, 'Package ID', packageInfo?.packageName ?? obtainiumId);
    } catch (error) {
      _writeLine(buffer, 'App Version', 'Unknown ($error)');
    }
  }
  if (AppDistribution.fdroid) {
    _writeLine(buffer, 'Build flavor', 'F-Droid');
  }
  _writeLine(buffer, 'Tracked apps', trackedAppCount);
  _writeLine(
    buffer,
    'Locale',
    '$appLocale (device ${deviceLocale ?? PlatformDispatcher.instance.locale.toLanguageTag()}, '
        'forced ${settings.forcedLocale?.toLanguageTag() ?? 'no'})',
  );

  if (probeNativePlatform) {
    try {
      final AndroidDeviceInfo androidInfo =
          await DeviceInfoPlugin().androidInfo;
      _writeLine(
        buffer,
        'Device',
        '${androidInfo.manufacturer} ${androidInfo.model}, Android ${androidInfo.version.release} (SDK ${androidInfo.version.sdkInt})',
      );
      _writeLine(buffer, 'ABIs', androidInfo.supportedAbis.join(', '));
    } catch (error) {
      _writeLine(buffer, 'Device', 'Unknown ($error)');
    }
  }
  if (settings.isTV) {
    _writeLine(buffer, 'Device type', 'TV');
  }

  display.writeTo(buffer);
  if (probeNativePlatform) {
    final Map<String, Object?>? platformDisplayDiagnostics =
        await NativeFeatures.getDisplayDiagnostics();
    final String? displayScale = formatDisplayScale(platformDisplayDiagnostics);
    if (displayScale != null) {
      _writeLine(buffer, 'Display size', displayScale);
    }
    if (platformDisplayDiagnostics?['isInMultiWindowMode'] == true) {
      _writeLine(buffer, 'Multi-window', true);
    }
    _writeLine(
      buffer,
      'Permissions',
      'notifications ${await _permissionStatusLabel(Permission.notification)}, '
          'install unknown apps ${await _permissionStatusLabel(Permission.requestInstallPackages)}, '
          'unrestricted battery ${await _permissionStatusLabel(Permission.ignoreBatteryOptimizations)}',
    );
  }

  final String? githubPat = settings.getSettingString(GitHub.githubCredsKey);
  final bool hasGithubPat = githubPat != null && githubPat.isNotEmpty;
  _writeLine(
    buffer,
    'GitHub PAT',
    formatSavedSecretStatus(
      saved: hasGithubPat,
      validated: hasGithubPat
          ? GitHub.hasValidatedPAT(githubPat, settings)
          : null,
    ),
  );
  final String? githubProxy = settings.getSettingString(
    GitHub.githubReqPrefixKey,
  );
  if (githubProxy != null && githubProxy.isNotEmpty) {
    _writeLine(
      buffer,
      'GitHub request prefix',
      '$githubProxy (sends token: ${settings.getSettingBool(GitHub.githubReqPrefixUseTokenKey)})',
    );
  }
  final String? gitlabPat = settings.getSettingString('gitlab-creds');
  final bool hasGitlabPat = gitlabPat != null && gitlabPat.isNotEmpty;
  _writeLine(
    buffer,
    'GitLab PAT',
    formatSavedSecretStatus(
      saved: hasGitlabPat,
      validated: hasGitlabPat
          ? GitLab.hasValidatedPAT(gitlabPat, settings)
          : null,
    ),
  );

  final String installerMode = settings.installerMode;
  _writeLine(
    buffer,
    'Installer',
    installerMode == InstallerMode.external.name
        ? '$installerMode (${settings.externalInstallerPackage ?? 'no target set'})'
        : installerMode == InstallerMode.shizuku.name
        ? '$installerMode (pretends to be Play: ${settings.shizukuPretendToBeGooglePlay})'
        : installerMode,
  );
  _writeLine(
    buffer,
    'Update checks',
    'background ${settings.enableBackgroundUpdates}, every ${settings.updateInterval} min, '
        'on start ${settings.checkOnStart}, installed/track-only only ${settings.onlyCheckInstalledOrTrackOnlyApps}, '
        'prereleases ${settings.includePrereleasesByDefault}',
  );
  if (settings.enableBackgroundUpdates) {
    _writeLine(
      buffer,
      'Background conditions',
      'Wi-Fi only ${settings.bgUpdatesOnWiFiOnly}, charging only ${settings.bgUpdatesWhileChargingOnly}, '
          'foreground service ${settings.useFGService}',
    );
  }
  _writeLine(
    buffer,
    'Downloads',
    'parallel ${settings.parallelDownloads}, VirusTotal scan ${settings.enableVirusTotalScanning}, '
        'save APK copies ${settings.saveDownloadedApkCopies}',
  );
  if (settings.enableVirusTotalScanning) {
    final String? virusTotalApiKey = settings.getSettingString(
      virusTotalApiKeyKey,
    );
    final bool hasVirusTotalApiKey =
        virusTotalApiKey != null && virusTotalApiKey.isNotEmpty;
    _writeLine(
      buffer,
      'VirusTotal API Key',
      formatSavedSecretStatus(
        saved: hasVirusTotalApiKey,
        validated: hasVirusTotalApiKey
            ? hasValidatedApiKey(virusTotalApiKey, settings)
            : null,
      ),
    );
  }
  _writeLine(
    buffer,
    'Remove on external uninstall',
    settings.removeOnExternalUninstall,
  );
  _writeLine(
    buffer,
    'List',
    'group by ${settings.appsListGroupBy.name}, folders ${settings.appFolders.length}, '
        'foldered apps on main page ${settings.showFolderedAppsOnMainPage}',
  );
  _writeLine(
    buffer,
    'UI',
    'theme ${settings.theme.name} (platform ${display.platformBrightness.name}, black ${settings.blackThemeActive}), '
        'scale ${settings.appUiScale}, phone layout ${settings.alwaysUsePhoneLayout}, '
        'blur ${settings.progressiveBlurEnabled}, reduced effects ${settings.reduceVisualEffects}, '
        'in-app web ${settings.showAppWebpage}',
  );
  if (settings.customFontName != null) {
    _writeLine(buffer, 'Custom font', settings.customFontName);
  }

  _writeLine(buffer, 'Auto-export on changes', settings.autoExportOnChanges);
  if (probeNativePlatform) {
    if (settings.autoExportOnChanges) {
      try {
        final exportDir = await settings.getExportDir(requireAccess: false);
        _writeLine(
          buffer,
          'Export directory',
          exportDir == null
              ? 'Not configured'
              : 'Configured (access ${await settings.getExportDir(warnIfInaccessible: false) != null})',
        );
      } catch (error) {
        _writeLine(buffer, 'Export directory', 'Unknown ($error)');
      }
    }
    if (settings.saveDownloadedApkCopies) {
      try {
        final apkSaveDir = await settings.getApkSaveDir(requireAccess: false);
        _writeLine(
          buffer,
          'APK save directory',
          apkSaveDir == null
              ? 'Not configured'
              : 'Configured (access ${await settings.getApkSaveDir(warnIfInaccessible: false) != null})',
        );
      } catch (error) {
        _writeLine(buffer, 'APK save directory', 'Unknown ($error)');
      }
    }
  }

  buffer.writeln('===============================\n');
  return buffer.toString();
}
