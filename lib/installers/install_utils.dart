import 'dart:async';

import 'package:obtainium/providers/apps_provider.dart' show getInstalledInfo;

/// Snapshot of a package's install state, taken before an install so that
/// [waitForPackageInstall] can later tell whether the install landed.
class InstallBaseline {
  final bool wasInstalled;
  final int? versionCode;
  final int? updateTime;
  const InstallBaseline({
    required this.wasInstalled,
    this.versionCode,
    this.updateTime,
  });
}

/// Captures the current install state of [appId] to compare against later.
Future<InstallBaseline> captureInstallBaseline(String appId) async {
  final info = await getInstalledInfo(appId);
  return InstallBaseline(
    wasInstalled: info != null,
    versionCode: info?.versionCode,
    updateTime: info?.lastUpdateTime,
  );
}

/// Polls for an install that can't report completion synchronously (a silent
/// background install, or a hand-off to an external installer). Returns true as
/// soon as the package appears (when it wasn't installed before) or its update
/// timestamp changes relative to [baseline] — a version-agnostic signal that
/// also works with pseudo-versions — or false if neither happens within
/// [attempts] × [interval]. Without a baseline timestamp the version code is
/// compared instead, so an unknown timestamp no longer reads as "installed" on
/// the first poll (upstream 65126176).
Future<bool> waitForPackageInstall(
  String appId,
  InstallBaseline baseline, {
  required int attempts,
  Duration interval = const Duration(milliseconds: 500),
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    final info = await getInstalledInfo(appId);
    if (info != null) {
      if (!baseline.wasInstalled) return true;
      if (baseline.updateTime != null) {
        final updateTimeAfter = info.lastUpdateTime;
        if (updateTimeAfter != null && updateTimeAfter != baseline.updateTime) {
          return true;
        }
      } else {
        final newCode = info.versionCode;
        if (newCode != null && newCode != baseline.versionCode) {
          return true;
        }
      }
    }
    if (attempt < attempts - 1) {
      await Future.delayed(interval);
    }
  }
  return false;
}
