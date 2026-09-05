import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_package_manager/android_package_manager.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:path_provider/path_provider.dart';

/// App persistence (load/save/remove), icons, and version-detection helpers.
const _corruptFileSuffix = '.corrupt';
const Duration _staleSaveTempAge = Duration(hours: 1);
final RegExp _saveTempFilePattern = RegExp(r'\.json\.tmp_\d+_\d+$');

// Icons from getAppIcon() are often 192–432 px but only shown at ~40 dp, so
// 128 px is plenty at any device pixel ratio. Resize before caching so both the
// on-disk and in-memory representations stay small.
const int _iconMaxCachePx = 128;

int _saveAppsTmpNonce = 0;
Future<void> _saveAppsQueue = Future<void>.value();

final RegExp _androidApplicationIdPattern = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
);

/// Outcome of [AppsProviderLifecycle.removeAppsWithModal].
class RemoveAppsWithModalResult {
  const RemoveAppsWithModalResult._({
    required this.confirmed,
    this.deferredUndoAppIds = const <String>{},
    this.removedFromObtainiumImmediately = false,
    this.obtainiumEntryRemovedOrScheduled = false,
  });

  /// User dismissed the dialog with Cancel, or left both toggles off.
  static const RemoveAppsWithModalResult cancelled =
      RemoveAppsWithModalResult._(confirmed: false);

  final bool confirmed;

  /// When non-empty, those apps were removed from the UI and their Obtainium
  /// data is deleted after a short delay unless
  /// [AppsProviderLifecycle.undoDeferredObtainiumRemovals] runs first.
  final Set<String> deferredUndoAppIds;

  /// True when [removeApps] ran in the same step (remove + uninstall).
  final bool removedFromObtainiumImmediately;

  /// True when the app should disappear from the list (deferred or immediate).
  final bool obtainiumEntryRemovedOrScheduled;

  bool get shouldShowSnackBar =>
      deferredUndoAppIds.isNotEmpty || removedFromObtainiumImmediately;
}

extension AppsProviderLifecycle on AppsProvider {
  bool _getNaiveStandardVersionDetection(App app) {
    return app.settings.getBool('naiveStandardVersionDetection') ||
        SourceProvider().naiveStandardVersionDetectionForUrl(
          app.url,
          overrideSource: app.overrideSource,
        );
  }

  String? _getRealInstalledVersion(App app, PackageInfo? installedInfo) {
    if (installedInfo == null) return null;
    // Must use the same rule as the app page's displayed version: reading only
    // the derived `useVersionCodeAsOSVersion` boolean made this compare
    // versionName against a stored version code whenever the boolean and the
    // versionDetection dropdown fell out of sync.
    return app.usesVersionCodeAsOsVersion
        ? installedInfo.versionCode?.toString()
        : installedInfo.versionName;
  }

  Future<Directory> getAppsDir() async {
    if (cachedAppsDir != null) return cachedAppsDir!;
    final Directory appsDir = Directory(
      '${(await getAppStorageDir()).path}/app_data',
    );
    if (!appsDir.existsSync()) {
      try {
        appsDir.createSync();
      } catch (_) {
        final fallbackDir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/app_data',
        );
        if (!fallbackDir.existsSync()) {
          fallbackDir.createSync(recursive: true);
        }
        return cachedAppsDir = fallbackDir;
      }
    }
    return cachedAppsDir = appsDir;
  }

  bool isVersionDetectionPossible(AppInMemory? app) {
    if (app?.app == null) {
      return false;
    }
    final source = SourceProvider().getSourceTemplate(
      app!.app.url,
      overrideSource: app.app.overrideSource,
    );
    final naiveStandardVersionDetection = _getNaiveStandardVersionDetection(
      app.app,
    );
    final String? realInstalledVersion = _getRealInstalledVersion(
      app.app,
      app.installedInfo,
    );
    final bool isHTMLWithNoVersionDetection =
        (source is HTML &&
        app.app.settings
                .getStringOrNull('versionExtractionRegEx')
                ?.isNotEmpty !=
            true);
    // A commit-sha-like token in either the real or latest version (or the
    // explicit releaseCommitShaAsVersion setting) means detection IS possible —
    // don't auto-disable just because such versions can't be standardized
    // (parity with fork main).
    final bool hasCommitSha =
        (realInstalledVersion != null &&
            commitHashLikeTokensFromVersion(realInstalledVersion).isNotEmpty) ||
        commitHashLikeTokensFromVersion(app.app.latestVersion).isNotEmpty;
    final bool releaseCommitShaAsVersion = app.app.settings.getBool(
      'releaseCommitShaAsVersion',
    );
    final bool hasComparableNumericReleaseVersions =
        realInstalledVersion != null &&
        recognizedNumericReleaseVersionsAreComparable(
          realInstalledVersion,
          app.app.latestVersion,
        );
    return !app.app.settings.getBool('trackOnly') &&
        !app.app.settings.getBool('releaseDateAsVersion') &&
        !isHTMLWithNoVersionDetection &&
        !source.versionDetectionDisallowed &&
        realInstalledVersion != null &&
        (reconcileVersionDifferences(
                  realInstalledVersion,
                  app.app.latestVersion,
                ) !=
                null ||
            hasComparableNumericReleaseVersions ||
            naiveStandardVersionDetection ||
            hasCommitSha ||
            releaseCommitShaAsVersion);
  }

  /// Reconciles reported vs. real installed/latest versions for [app].
  /// Returns the modified app if any corrections were made, or null.
  App? getCorrectedInstallStatusAppIfPossible(
    App app,
    PackageInfo? installedInfo,
  ) {
    var modded = false;
    final trackOnly = app.settings.getBool('trackOnly');
    // Reset a stale "temporary package id" flag once a track-only app has a
    // real (non-temp) package id (parity with fork main).
    if (trackOnly &&
        !isTempId(app) &&
        app.additionalSettings['trackOnlyTemporaryPackageId'] == true) {
      app = app.copyWith(
        additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
          ..['trackOnlyTemporaryPackageId'] = false,
      );
      modded = true;
    }
    // Record the device's last package-update time so the update-check logic
    // can use release-date recency to resolve ambiguous version ordering
    // (read in apps_provider_updates.dart). Written on every reconcile and
    // removed when the app is not installed — parity with fork main.
    if (installedInfo?.lastUpdateTime != null) {
      if (app.additionalSettings['lastInstalledTime'] !=
          installedInfo!.lastUpdateTime) {
        app = app.copyWith(
          additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
            ..['lastInstalledTime'] = installedInfo.lastUpdateTime,
        );
        modded = true;
      }
    } else if (app.additionalSettings.containsKey('lastInstalledTime')) {
      app = app.copyWith(
        additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
          ..remove('lastInstalledTime'),
      );
      modded = true;
    }
    final VersionDetectionMode versionDetection = app.versionDetectionMode;
    final bool versionDetectionIsStandard = app.usesStandardVersionDetection;
    final naiveStandardVersionDetection = _getNaiveStandardVersionDetection(
      app,
    );
    final String? realInstalledVersion = _getRealInstalledVersion(
      app,
      installedInfo,
    );
    // Migrate the 2.9.7 reset sentinel. It deliberately kept installedVersion
    // null until a reinstall, which could strand an installed app indefinitely.
    if (app.additionalSettings.containsKey(installStatusResetKey)) {
      app = resetInstallStatusToDeviceVersion(app, installedInfo);
      modded = true;
    }
    // 1. Compare reported vs. real installed versions where one is null.
    // A track-only app is exempt from "absent from the device means not
    // installed" ONLY while its package id is a temporary placeholder: there
    // getInstalledInfo can never match anything, so clearing would be wrong.
    // Once the id is a real package name the device lookup is authoritative
    // (the app holds QUERY_ALL_PACKAGES), and the else-branch below already
    // trusts it in the opposite direction — it adopts the device's version the
    // moment the package appears. Exempting every track-only app instead (fork
    // main's rule) strands sources that are always track-only (APKMirror,
    // RockMods) on "installed <old version>" forever once the user uninstalls:
    // nothing else ever nulls the stored version, so neither a restart nor
    // pull-to-refresh can clear it, and the app keeps counting as installed.
    final bool trackOnlyPackageIdIsUnverifiable =
        trackOnly &&
        (isTempId(app) ||
            app.additionalSettings['trackOnlyTemporaryPackageId'] == true);
    if (installedInfo == null &&
        app.installedVersion != null &&
        !trackOnlyPackageIdIsUnverifiable) {
      final newSettings = Map<String, dynamic>.from(app.additionalSettings);
      if (trackOnly) {
        // The install state is now *determined* (not installed), so don't let
        // the app page resurface its "is your package id wrong?" error card.
        newSettings['trackOnlyUndeterminedInstalledVersion'] = false;
      }
      app = app.copyWith(
        installedVersion: null,
        additionalSettings: newSettings,
      );
      modded = true;
    } else if (realInstalledVersion != null && app.installedVersion == null) {
      // With detection disabled (non-standard), the device manifest version
      // isn't the source/release version, so mark installed = latest rather
      // than the manifest version (parity with fork main).
      final newSettings = Map<String, dynamic>.from(app.additionalSettings);
      if (trackOnly) {
        // A real installed version is now known for this track-only app.
        newSettings['trackOnlyUndeterminedInstalledVersion'] = false;
      }
      app = app.copyWith(
        installedVersion: versionDetectionIsStandard
            ? realInstalledVersion
            : app.latestVersion,
        additionalSettings: newSettings,
      );
      modded = true;
    }
    // 1b. With version detection disabled (non-standard), still reflect an
    // external install/upgrade: if the device manifest version reconciles with
    // the source latest or the previously stored installed version, adopt it;
    // only unreconcilable pairs keep the source pseudo-version (parity with
    // fork main).
    if (realInstalledVersion != null &&
        app.installedVersion != null &&
        realInstalledVersion != app.installedVersion &&
        !versionDetectionIsStandard) {
      final correctedInstalledVersion =
          reconciledInstalledVersionForDisabledVersionDetection(
            realInstalledVersion,
            app.installedVersion!,
            app.latestVersion,
          );
      if (correctedInstalledVersion != null) {
        app = app.copyWith(installedVersion: correctedInstalledVersion);
        modded = true;
      }
    }
    // 1c. Auto-heal a stored installedVersion whose format no longer matches
    // the active version-code setting (versionCode int vs versionName) — parity
    // with fork main.
    if (realInstalledVersion != null &&
        app.installedVersion != null &&
        versionDetectionIsStandard) {
      var formatMismatch = false;
      final isStoredPureInteger = RegExp(
        r'^\d+$',
      ).hasMatch(app.installedVersion!);
      final isRealPureInteger = RegExp(r'^\d+$').hasMatch(realInstalledVersion);
      if (app.usesVersionCodeAsOsVersion) {
        if (!isStoredPureInteger) {
          formatMismatch = true;
        }
      } else {
        if (isStoredPureInteger &&
            (!isRealPureInteger ||
                realInstalledVersion != app.installedVersion)) {
          formatMismatch = true;
        }
      }
      if (formatMismatch) {
        app = app.copyWith(installedVersion: realInstalledVersion);
        modded = true;
      }
    }
    // 2. Reconcile differences between reported and real installed versions.
    if (realInstalledVersion != null &&
        app.installedVersion != null &&
        realInstalledVersion != app.installedVersion &&
        versionDetectionIsStandard) {
      // App's reported version and real version don't match (and it uses standard version detection)
      // If they share a standard format (and are still different under it), update the reported version accordingly
      final correctedInstalledVersion = reconcileVersionDifferences(
        realInstalledVersion,
        app.installedVersion!,
      );
      if (correctedInstalledVersion?.areEqual == false) {
        app = app.copyWith(
          installedVersion: correctedInstalledVersion!.version,
        );
        modded = true;
      } else if (naiveStandardVersionDetection) {
        // Only sources whose version strings are known not to match the APK
        // manifest may overwrite the stored version with the device's. Doing it
        // unconditionally strands apps whose two version strings share no
        // standard format: the stored value (which matched latestVersion) gets
        // replaced by one that doesn't, and for track-only or explicitly
        // 'standard' apps step 4 below can't clean it up.
        app = app.copyWith(installedVersion: realInstalledVersion);
        modded = true;
      }
    }
    // 3. Reconcile reported installed and latest versions.
    if (app.installedVersion != null &&
        app.installedVersion != app.latestVersion &&
        versionDetectionIsStandard) {
      // App's reported installed and latest versions don't match (and it uses standard version detection)
      // If they share a standard format, make sure the App's reported installed version uses that format
      final correctedInstalledVersion = reconcileVersionDifferences(
        app.installedVersion!,
        app.latestVersion,
      );
      if (correctedInstalledVersion?.areEqual == true) {
        app = app.copyWith(
          installedVersion: correctedInstalledVersion!.version,
        );
        modded = true;
      }
    }
    final bool realInstalledVersionMatchesLatest =
        realInstalledVersion != null &&
        versionsEffectivelyEqual(realInstalledVersion, app.latestVersion);
    // 3b. The device says the source's latest release IS what's installed, but
    // the stored version still disagrees and none of the steps above could
    // relate the two strings, so nothing adopted the device's verdict (#222).
    // Steps 1b/2/3 all require the pair to share a standard format, a digit
    // shape, or a dotted-numeric parse, and all three fail when the APK
    // manifest's versionName carries text the source version lacks
    // ('2.19.1 (git 50a6b17)' vs tag 'v2.19.1') or when a 'v' prefix combines
    // with a changed segment count ('v7.1' stored vs device '7.1.1'). Without
    // this step a single unrecorded install is permanent: the app reports the
    // old version and offers the same update forever, surviving restarts and
    // pull-to-refresh. Equality here is the same test step 4 already trusts to
    // decide that detection is working, so adopting latest cannot invent a
    // version the device isn't running.
    // Version-code mode is excluded: there the device value is a version code,
    // which is not comparable with a source version string.
    if (realInstalledVersionMatchesLatest &&
        versionDetectionIsStandard &&
        !app.usesVersionCodeAsOsVersion &&
        app.installedVersion != null &&
        app.installedVersion != app.latestVersion) {
      app = app.copyWith(installedVersion: app.latestVersion);
      modded = true;
    }
    // 4. Disable version detection if versions are not standardizable.
    // Guards (parity with fork main): only auto-disable plain auto-detection
    // (not versionCode mode or an already-non-standard mode), never for
    // track-only, and NOT when the real device version is effectively equal to
    // latest (e.g. same commit hash / sha-like) — those are reconcilable, not
    // failures. The disabled value is the string enum 'pseudo', never bool false.
    final bool canAutoDisable =
        !app.usesVersionCodeAsOsVersion &&
        versionDetection == VersionDetectionMode.auto;
    if (canAutoDisable &&
        !trackOnly &&
        installedInfo != null &&
        versionDetectionIsStandard &&
        !realInstalledVersionMatchesLatest &&
        !isVersionDetectionPossible(
          AppInMemory(app, null, installedInfo, null),
        )) {
      app = app.copyWith(
        additionalSettings: Map<String, dynamic>.from(app.additionalSettings)
          ..['versionDetection'] = VersionDetectionMode.pseudo.key,
        installedVersion: app.latestVersion,
      );
      unawaited(logs.add('Could not reconcile version formats for: ${app.id}'));
      modded = true;
    }

    final App normalizedApp = normalizeSkippedLatestVersion(app);
    if (!identical(normalizedApp, app)) {
      app = normalizedApp;
      modded = true;
    }

    return modded ? app : null;
  }

  // Version reconciliation deliberately lives ONLY as the top-level
  // [reconcileVersionDifferences] in apps_provider.dart. A same-named member here
  // shadows it for every call inside this extension, which is how the two copies
  // drifted (this one was missing the shape fallback) and how genuine updates
  // ended up being discarded. Call the top-level function; don't re-add a member.

  /// When version detection is disabled, decide whether an externally-observed
  /// device version should replace the stored pseudo/installed version.
  /// Returns the corrected installed version, or null to keep the current one
  /// (parity with fork main).
  String? reconciledInstalledVersionForDisabledVersionDetection(
    String realInstalledVersion,
    String reportedInstalledVersion,
    String latestVersion,
  ) {
    final reconciledLatest = reconcileVersionDifferences(
      realInstalledVersion,
      latestVersion,
    );
    if (reconciledLatest?.areEqual == true) {
      return reconciledLatest!.version;
    }
    final reconciledInstalled = reconcileVersionDifferences(
      realInstalledVersion,
      reportedInstalledVersion,
    );
    if (reconciledInstalled?.areEqual == true) {
      return reconciledInstalled!.version;
    }
    // Detect external upgrade/downgrade only when the real device version
    // strictly shares a standard format with the compared version — the guard
    // prevents false positives where non-strict substring matching makes an
    // incompatible pair appear reconcilable.
    final realFormats = VersionService().findStandardFormatsForVersion(
      realInstalledVersion,
      true,
    );
    if (realFormats.isNotEmpty) {
      if (reconciledLatest?.areEqual == false &&
          realFormats
              .intersection(
                VersionService().findStandardFormatsForVersion(
                  latestVersion,
                  true,
                ),
              )
              .isNotEmpty) {
        return realInstalledVersion;
      }
      if (reconciledInstalled?.areEqual == false &&
          realFormats
              .intersection(
                VersionService().findStandardFormatsForVersion(
                  reportedInstalledVersion,
                  true,
                ),
              )
              .isNotEmpty) {
        return realInstalledVersion;
      }
    }
    return null;
  }

  Future<void> loadApps({String? singleId, bool silent = false}) async {
    await waitForAppsToLoad();
    appsLoadingCompleter = Completer<void>();
    if (!silent) {
      loadingApps = true;
      notify();
    }
    bool dataChanged = false;
    final appFolders = settingsProvider.appFolders;
    final shouldMigrateFolderCriteria =
        (settingsProvider.prefs?.getInt('folderCriteriaMigrationVersion') ??
            0) <
        folderCriteriaMigrationVersion;
    final folderMembershipsToPersist = <App>[];
    final correctedInstallStatusIds = <String>[];
    try {
      // Commit any deferred "remove from ObtainX" whose in-memory deferral was
      // lost (e.g. process restart) before re-reading the app JSON dir.
      await _purgeStalePendingRemovalFilesWithoutLiveDeferral();
      final sp = SourceProvider();
      final List<List<String>> errors = [];
      final installedAppsData = await getAllInstalledInfo(light: true);
      final Map<String, PackageInfo> installedAppsMap = {
        for (var i in installedAppsData)
          if (i.packageName != null) i.packageName!: i,
      };
      final List<String> removedAppIds = [];
      final DateTime? reuseWatermark = singleId == null
          ? lastFullDiskLoadAt
          : null;
      final DateTime diskLoadStartedAt = DateTime.now();
      final List<FileSystemEntity> appFiles = await (await getAppsDir())
          .list()
          .toList();
      final DateTime staleSaveTempCutoff = DateTime.now().subtract(
        _staleSaveTempAge,
      );
      const int loadChunkSize = 16;
      for (
        int chunkStart = 0;
        chunkStart < appFiles.length;
        chunkStart += loadChunkSize
      ) {
        final int chunkEnd = min(chunkStart + loadChunkSize, appFiles.length);
        await Future.wait(
          appFiles.sublist(chunkStart, chunkEnd).map((item) async {
            final String lowerPath = item.path.toLowerCase();
            final bool isSaveTempFile =
                lowerPath.endsWith('.json.tmp') ||
                _saveTempFilePattern.hasMatch(lowerPath);
            if (isSaveTempFile) {
              try {
                final FileStat tempFileStat = await item.stat();
                if (tempFileStat.modified.isBefore(staleSaveTempCutoff)) {
                  await item.delete();
                }
              } catch (error) {
                unawaited(
                  logs.add(
                    'Failed to clean stale save temp ${item.path}: $error',
                    level: LogLevel.warning,
                  ),
                );
              }
              return;
            }
            if (!lowerPath.endsWith('.json')) return;
            final String fileName = item.path.split('/').last;
            if (singleId != null &&
                fileName.toLowerCase() != '${singleId.toLowerCase()}.json') {
              return;
            }
            final String idFromFile = fileName.substring(
              0,
              fileName.length - '.json'.length,
            );
            App? app;
            bool reused = false;
            final AppInMemory? existing = apps[idFromFile];
            if (existing != null && reuseWatermark != null) {
              try {
                final FileStat stat = await item.stat();
                if (stat.modified.isBefore(reuseWatermark)) {
                  app = existing.app;
                  reused = true;
                }
              } catch (_) {
                // Fall through to reading and parsing this file.
              }
            }
            if (!reused) {
              try {
                app = App.fromJson(
                  jsonDecode(await File(item.path).readAsString()),
                );
                dataChanged = dataChanged || existing == null;
              } catch (err) {
                if (err is FormatException) {
                  // Genuinely corrupt JSON: set it aside so it stops failing.
                  unawaited(
                    logs.add(
                      'Corrupt JSON, renaming ${item.path}: $err',
                      level: LogLevel.error,
                    ),
                  );
                  await item.rename('${item.path}$_corruptFileSuffix');
                } else {
                  // Other errors (e.g. a temporarily unresolvable source):
                  // skip but keep the file so it can load once resolved.
                  unawaited(
                    logs.add(
                      'Error loading app ${item.path} (skipped, file kept): $err',
                      level: LogLevel.warning,
                    ),
                  );
                }
              }
            }
            if (app != null) {
              final String loadingAppId = app.id;
              final String loadingAppName = app.finalName;
              final AppInMemory? before = apps[app.id];
              try {
                // Source validation is read-only; avoid constructing an adapter
                // for every app during each list load.
                final src = sp.getSourceTemplate(
                  app.url,
                  overrideSource: app.overrideSource,
                );
                final String sourceType = src.sourceIdentifier;
                final PackageInfo? installedInfo = installedAppsMap[app.id];
                // Sampled before the reconcile: "externally uninstalled" is the
                // *transition* from a recorded version to none, and only step 1
                // of the reconcile can make it.
                final bool hadInstalledVersion = app.installedVersion != null;
                final App? correctedApp =
                    getCorrectedInstallStatusAppIfPossible(app, installedInfo);
                if (correctedApp != null) {
                  app = correctedApp;
                  dataChanged = true;
                  correctedInstallStatusIds.add(correctedApp.id);
                  // Absence from the device is the signal for "externally
                  // uninstalled" — not a null installedVersion, which is also
                  // the state left behind by an explicit install status reset,
                  // by an app added while it was not installed, and by a
                  // track-only app whose package id was never resolved. Keying
                  // off installedVersion alone would let
                  // removeOnExternalUninstall delete a still-installed app, and
                  // keying off it without [hadInstalledVersion] would delete
                  // apps that were simply never installed the moment any
                  // unrelated correction fired.
                  if (hadInstalledVersion &&
                      correctedApp.installedVersion == null &&
                      installedInfo == null) {
                    removedAppIds.add(correctedApp.id);
                  }
                }
                final folderMembershipChanged = reconcileAppFolderMemberships(
                  app,
                  appFolders,
                  sourceIdentifier: sourceType,
                  isUpToDate: appIsUpToDateForFiltering(app),
                  migrateLegacyRules: shouldMigrateFolderCriteria,
                );
                if (folderMembershipChanged) {
                  folderMembershipsToPersist.add(app);
                  dataChanged = true;
                }
                final bool installedInfoChanged =
                    before?.installedInfo?.packageName !=
                        installedInfo?.packageName ||
                    before?.installedInfo?.versionName !=
                        installedInfo?.versionName ||
                    before?.installedInfo?.versionCode !=
                        installedInfo?.versionCode ||
                    before?.installedInfo?.lastUpdateTime !=
                        installedInfo?.lastUpdateTime;
                if (!reused ||
                    installedInfoChanged ||
                    before?.sourceType != sourceType) {
                  dataChanged = true;
                }
                // A later install must not keep showing an APK-extracted or
                // store-fetched icon. Clearing here lets [updateAppIcon] load
                // the device launcher icon instead of early-returning.
                final Uint8List? icon =
                    installedInfo != null && before?.installedInfo == null
                    ? null
                    : before?.icon;
                apps[app.id] = AppInMemory(
                  app,
                  before?.downloadProgress,
                  installedInfo,
                  icon,
                  sourceType: sourceType,
                  download: before?.download,
                );
              } catch (e) {
                if (e is RateLimitError || e is SocketException) {
                  unawaited(
                    logs.add(
                      'Transient error loading app $loadingAppId, will retry: $e',
                    ),
                  );
                } else {
                  errors.add([loadingAppId, loadingAppName, e.toString()]);
                }
              }
            }
          }),
        );
        // No explicit per-chunk event-loop yield: the awaited file reads above
        // already yield to the event loop (so the spinner keeps animating),
        // and a forced Timer(0) between chunks only added a frame-length stall
        // that lengthened the cold-start spinner. Chunking still bounds the
        // number of file handles open at once.
      }
      if (singleId == null) {
        lastFullDiskLoadAt = diskLoadStartedAt;
      }
      if (folderMembershipsToPersist.isNotEmpty) {
        await saveApps(
          folderMembershipsToPersist,
          updateInstalledInfo: false,
          autoExportAfterSave: false,
        );
      }
      if (shouldMigrateFolderCriteria) {
        if (appFolders.any((folder) => folder.loadedFromLegacyRule)) {
          settingsProvider.appFolders = appFolders
              .map(
                (folder) => AppFolder(
                  id: folder.id,
                  name: folder.name,
                  criteria: folder.criteria,
                ),
              )
              .toList();
        }
        await settingsProvider.prefs?.setInt(
          'folderCriteriaMigrationVersion',
          folderCriteriaMigrationVersion,
        );
      }
      if (errors.isNotEmpty) {
        for (var error in errors) {
          unawaited(
            logs.add(
              'Removing app ${error[0]} (${error[1]}) due to load error: ${error[2]}',
              level: LogLevel.error,
            ),
          );
        }
        await removeApps(errors.map((e) => e[0]).toList());
        unawaited(
          NotificationsProvider().notify(
            AppsRemovedNotification(errors.map((e) => [e[1], e[2]]).toList()),
          ),
        );
        dataChanged = true;
      }
      // Delete externally uninstalled Apps if needed.
      if (removedAppIds.isNotEmpty) {
        dataChanged = true;
        if (settingsProvider.removeOnExternalUninstall) {
          await removeApps(removedAppIds);
        }
      }
    } finally {
      loadingApps = false;
      appsLoadingCompleter?.complete();
      appsLoadingCompleter = null;
      if (!silent || dataChanged) {
        markAppsChanged();
        notify();
      }
    }
    // Deliberately after the load has been reported as finished, and not awaited:
    // nothing on screen waits for these writes.
    if (correctedInstallStatusIds.isNotEmpty) {
      unawaited(persistInstallStatusCorrections(correctedInstallStatusIds));
    }
  }

  /// Writes install-status corrections that [loadApps] applied in memory back to
  /// their JSON files.
  ///
  /// Without this, the corrected version lives only in memory and is re-derived
  /// on every load, so the file on disk — and therefore any backup or auto-export
  /// taken before the app is saved for some other reason — keeps reporting the
  /// stale version (#222).
  ///
  /// Cheap in the steady state: corrections are idempotent, so once a file has
  /// been written this finds nothing to write on subsequent loads. Only a load
  /// that actually corrected something persists anything.
  ///
  /// Reads each app from the live map rather than from a snapshot taken during the
  /// load, so a change made while the load was running (e.g. an install
  /// recording its version) wins instead of being overwritten.
  Future<void> persistInstallStatusCorrections(List<String> appIds) async {
    final List<App> appsToSave = <App>[];
    for (final String appId in appIds) {
      final AppInMemory? entry = apps[appId];
      if (entry != null) {
        appsToSave.add(entry.app);
      }
    }
    if (appsToSave.isEmpty) return;
    await saveApps(
      appsToSave,
      // These apps were just corrected against install info the load already
      // read: don't re-query the package manager, don't redo the correction, and
      // don't let a routine post-load write trigger an auto-export (same reasoning
      // as the folder-membership save above).
      attemptToCorrectInstallStatus: false,
      updateInstalledInfo: false,
      autoExportAfterSave: false,
    );
  }

  bool _bytesLookLikeRasterImage(Uint8List bytes) {
    if (bytes.length < 12) return false;
    // PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }
    // WebP (RIFF....WEBP)
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    return false;
  }

  bool _bytesLookLikePng(Uint8List bytes) {
    if (bytes.length < 8) return false;
    return bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A;
  }

  /// Moves legacy user-icon overrides (`*.user.png`) out of [iconsCacheDir]
  /// (which Android "clear cache" wipes) into [userAppIconsDir].
  Future<void> migrateUserIconsFromLegacyCacheDir() async {
    // One-shot: once complete, never enumerate the (potentially large) icon
    // cache dir again on subsequent cold starts.
    const String migratedFlag = 'userIconsMigratedFromLegacyCacheDir';
    if (settingsProvider.prefs?.getBool(migratedFlag) ?? false) {
      return;
    }
    try {
      if (!await iconsCacheDir.exists()) {
        await settingsProvider.prefs?.setBool(migratedFlag, true);
        return;
      }
      for (final FileSystemEntity entity
          in await iconsCacheDir.list().toList()) {
        if (entity is! File) continue;
        final String fileName = entity.uri.pathSegments.last;
        if (!fileName.endsWith('.user.png')) continue;
        final File destination = File('${userAppIconsDir.path}/$fileName');
        if (await destination.exists()) {
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }
        try {
          await entity.copy(destination.path);
          await entity.delete();
          unawaited(
            mirrorIconToIconsDir(
              fileName.substring(0, fileName.length - '.user.png'.length),
              isUserIcon: true,
            ),
          );
        } catch (e) {
          unawaited(logs.add('User icon migrate $fileName: $e'));
        }
      }
      // Mark done only after a clean pass so an interrupted migration retries.
      await settingsProvider.prefs?.setBool(migratedFlag, true);
    } catch (e) {
      unawaited(logs.add('User icon migrate: $e'));
    }
  }

  File _userAppIconPngFile(String appId) {
    return File('${userAppIconsDir.path}/$appId.user.png');
  }

  File _deducedAppIconPngFile(String appId) {
    return File('${deducedAppIconsDir.path}/$appId.png');
  }

  /// Whether a deduced icon (APK-extracted or store-fetched) is already stored,
  /// so callers can skip the work of deducing another one.
  bool hasDeducedAppIcon(String appId) =>
      _deducedAppIconPngFile(appId).existsSync();

  Future<Uint8List> _resizeIconForStorage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _iconMaxCachePx,
        targetHeight: _iconMaxCachePx,
      );
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      codec.dispose();
      if (byteData != null) return byteData.buffer.asUint8List();
    } catch (e) {
      unawaited(logs.add('Icon resize failed, keeping original: $e'));
    }
    return bytes;
  }

  Future<Uint8List?> _fetchIconFromUrl(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) return null;
      final res = await get(uri);
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      if (!_bytesLookLikeRasterImage(bytes)) return null;
      return bytes;
    } catch (e) {
      unawaited(logs.add('Icon fetch failed for $url: $e'));
      return null;
    }
  }

  /// Fetches the installed app's launcher icon, tolerating a missing package
  /// (JNI throws `NameNotFoundException` for uninstalled/track-only apps). On
  /// failure the stale [AppInMemory.installedInfo] is cleared so the dead lookup
  /// isn't retried, and the caller can fall back to [App.iconUrl].
  Future<Uint8List?> _getInstalledAppIconSafely(String appId) async {
    final applicationInfo = apps[appId]?.installedInfo?.applicationInfo;
    if (applicationInfo == null) return null;
    try {
      return await applicationInfo.getAppIcon();
    } catch (e) {
      unawaited(
        logs.add('App icon unavailable for $appId (clearing stale info): $e'),
      );
      final AppInMemory? existing = apps[appId];
      if (existing != null && existing.installedInfo != null) {
        apps.update(
          appId,
          (value) => AppInMemory(
            value.app,
            null,
            null,
            value.icon,
            sourceType: value.sourceType,
            download: value.download,
          ),
        );
      }
      return null;
    }
  }

  /// Stores the launcher icon out of a downloaded APK, for apps whose source
  /// (a code-hosting repo) publishes no icon.
  ///
  /// The archive was already parsed for its package id, so the icon costs no
  /// extra download - only a native decode. That makes it the most trustworthy
  /// deduced icon available (it comes from the very artifact ObtainX ships), so
  /// it overwrites a previously stored store-listing icon. It is only a fallback
  /// for apps that aren't on the device: a user override and an installed app's
  /// launcher icon both outrank it.
  Future<void> storeIconFromApkArchive(
    String appId,
    String archiveFilePath,
  ) async {
    try {
      final Uint8List? archiveIcon = await NativeFeatures.getApkArchiveIcon(
        archiveFilePath,
      );
      if (archiveIcon == null || !_bytesLookLikeRasterImage(archiveIcon)) {
        return;
      }
      final Uint8List icon = await _resizeIconForStorage(archiveIcon);
      await _deducedAppIconPngFile(appId).writeAsBytes(icon);
      unawaited(mirrorIconToIconsDir(appId, isUserIcon: false));
      if (apps.containsKey(appId) &&
          apps[appId]!.installedInfo == null &&
          !_userAppIconPngFile(appId).existsSync()) {
        apps.update(appId, (value) => value.copyWith(icon: icon));
        notify();
      }
    } catch (e) {
      unawaited(logs.add('APK icon extraction failed for $appId: $e'));
    }
  }

  Future<void> updateAppIcon(String? appId, {bool ignoreCache = false}) async {
    if (appId == null || apps[appId] == null) return;

    final File userIconFile = _userAppIconPngFile(appId);
    if (userIconFile.existsSync()) {
      try {
        final Uint8List iconBytes = await userIconFile.readAsBytes();
        if (_bytesLookLikePng(iconBytes)) {
          final Uint8List? currentIcon = apps[appId]!.icon;
          if (currentIcon != null &&
              currentIcon.length == iconBytes.length &&
              listEquals(currentIcon, iconBytes)) {
            return;
          }
          apps.update(appId, (value) => value.copyWith(icon: iconBytes));
          notify();
          return;
        }
      } catch (e) {
        unawaited(logs.add('User icon load failed for $appId: $e'));
      }
    }

    final File cachedIcon = File('${iconsCacheDir.path}/$appId.png');
    final bool isInstalled = apps[appId]!.installedInfo != null;
    if (apps[appId]!.icon != null && !ignoreCache) {
      // In-memory icons for non-installed apps (APK extract, store fetch) are
      // already the right answer. After a later install, that same in-memory
      // icon would otherwise stick forever and beat the device launcher icon.
      if (!isInstalled) return;
      if (cachedIcon.existsSync()) return;
    }

    if (ignoreCache && cachedIcon.existsSync()) {
      await cachedIcon.delete();
    }
    Uint8List? icon;
    // When the app is on the device, the device supplies the icon - nothing
    // ObtainX deduces can beat it. The launcher icon is re-derivable from the OS
    // for free, so it stays in the (disposable) cache. A non-installed app has
    // no launcher icon, so both of these come up empty and we fall through.
    final bool alreadyCached = cachedIcon.existsSync() && !ignoreCache;
    if (alreadyCached) {
      icon = await cachedIcon.readAsBytes();
    } else {
      icon = await _getInstalledAppIconSafely(appId);
      if (icon != null) {
        icon = await _resizeIconForStorage(icon);
        await cachedIcon.writeAsBytes(icon);
      }
    }
    // Deduced icons are for non-installed apps only: extracted from the app's
    // own APK, or fetched from a store listing. Persisted outside the cache so
    // "clear cache" can't force that download or network fetch to happen again.
    final File deducedIcon = _deducedAppIconPngFile(appId);
    if (!isInstalled && icon == null && deducedIcon.existsSync()) {
      try {
        icon = await deducedIcon.readAsBytes();
      } catch (e) {
        unawaited(logs.add('Deduced icon load failed for $appId: $e'));
      }
    }
    if (!isInstalled && icon == null) {
      final url = apps[appId]!.app.iconUrl;
      if (url != null && url.isNotEmpty) {
        final Uint8List? fetchedIcon = await _fetchIconFromUrl(url);
        if (fetchedIcon != null) {
          icon = await _resizeIconForStorage(fetchedIcon);
          await deducedIcon.writeAsBytes(icon);
          unawaited(mirrorIconToIconsDir(appId, isUserIcon: false));
        }
      }
    }
    if (icon != null || ignoreCache) {
      final Uint8List? resolvedIcon = icon;
      // Use the constructor (not copyWith) so a null icon actually clears the
      // in-memory icon on ignoreCache resets; preserve the shared DownloadState.
      apps.update(
        apps[appId]!.app.id,
        (value) => AppInMemory(
          value.app,
          null,
          value.installedInfo,
          resolvedIcon,
          sourceType: value.sourceType,
          download: value.download,
        ),
        ifAbsent: () => AppInMemory(
          apps[appId]!.app,
          null,
          apps[appId]?.installedInfo,
          resolvedIcon,
        ),
      );
      notify();
    }
  }

  bool hasUserAppIconOverride(String appId) =>
      _userAppIconPngFile(appId).existsSync();

  bool validateUserAppIconPngBytes(Uint8List bytes) => _bytesLookLikePng(bytes);

  /// Icon bytes as shown when the per-app user PNG override is ignored
  /// (installed app or its cache, then the deduced icon, then [App.iconUrl]).
  /// Does not read [userAppIconsDir] or mutate state.
  Future<Uint8List?> loadIconPreviewExcludingUserOverride(String appId) async {
    if (apps[appId] == null) return null;
    final File cachedIcon = File('${iconsCacheDir.path}/$appId.png');
    if (cachedIcon.existsSync()) {
      try {
        return await cachedIcon.readAsBytes();
      } catch (e) {
        unawaited(logs.add('loadIconPreviewExcludingUserOverride cache: $e'));
      }
    }
    Uint8List? icon = await _getInstalledAppIconSafely(appId);
    if (apps[appId]!.installedInfo != null) {
      return icon;
    }
    final File deducedIcon = _deducedAppIconPngFile(appId);
    if (icon == null && deducedIcon.existsSync()) {
      try {
        return await deducedIcon.readAsBytes();
      } catch (e) {
        unawaited(logs.add('loadIconPreviewExcludingUserOverride deduced: $e'));
      }
    }
    if (icon == null) {
      final String? url = apps[appId]!.app.iconUrl;
      if (url != null && url.isNotEmpty) {
        icon = await _fetchIconFromUrl(url);
      }
    }
    return icon;
  }

  /// Writes validated PNG bytes to [userAppIconsDir] and updates the in-memory
  /// icon. Returns null on success, or a translated error string.
  Future<String?> applyUserAppIconPngBytes(
    String appId,
    Uint8List bytes,
  ) async {
    if (apps[appId] == null) {
      return tr('unexpectedError');
    }
    if (!_bytesLookLikePng(bytes)) {
      return tr('changeAppIconInvalidPng');
    }
    try {
      final File dest = _userAppIconPngFile(appId);
      await dest.writeAsBytes(bytes);
      apps.update(appId, (value) => value.copyWith(icon: bytes));
      notify();
      unawaited(mirrorIconToIconsDir(appId, isUserIcon: true));
      return null;
    } catch (e) {
      unawaited(logs.add('applyUserAppIconPngBytes: $e'));
      return tr('unexpectedError');
    }
  }

  /// Copies a user-selected PNG into app storage ([userAppIconsDir]) and updates
  /// memory. Returns null on success, or a translated error string.
  Future<String?> setUserAppIconFromPngPath(
    String appId,
    String filePath,
  ) async {
    try {
      final File sourceFile = File(filePath);
      if (!sourceFile.existsSync()) {
        return tr('unexpectedError');
      }
      final Uint8List bytes = await sourceFile.readAsBytes();
      return await applyUserAppIconPngBytes(appId, bytes);
    } catch (e) {
      unawaited(logs.add('setUserAppIconFromPngPath: $e'));
      return tr('unexpectedError');
    }
  }

  Future<void> resetAppIconToDefault(String appId) async {
    if (apps[appId] == null) return;
    final File userFile = _userAppIconPngFile(appId);
    if (userFile.existsSync()) {
      deleteFile(userFile);
      unawaited(removeMirroredIconFromIconsDir(appId, isUserIcon: true));
    }
    await updateAppIcon(appId, ignoreCache: true);
  }

  /// Persists a list of [App] objects to disk as JSON files and updates in-memory state.
  Future<void> saveApps(
    List<App> apps, {
    bool attemptToCorrectInstallStatus = true,
    bool onlyIfExists = true,
    // Fork params: skip the per-app getInstalledInfo() refresh (reuse cached
    // in-memory install info) and/or skip the post-save auto-export.
    bool updateInstalledInfo = true,
    bool autoExportAfterSave = true,
    Map<String, PackageInfo>? prefetchedInstalledInfo,
  }) async {
    if (apps.isEmpty) return;
    final List<App> uniqueApps = <App>[];
    final Set<String> seenIds = <String>{};
    for (int appIndex = apps.length - 1; appIndex >= 0; appIndex--) {
      if (seenIds.add(apps[appIndex].id)) {
        uniqueApps.add(apps[appIndex].deepCopy());
      }
    }
    final List<App> effectiveApps = uniqueApps.reversed.toList();

    final Future<void> pendingSaves = _saveAppsQueue;
    final Completer<void> saveCompletion = Completer<void>();
    _saveAppsQueue = saveCompletion.future;
    try {
      await pendingSaves;
      Map<String, PackageInfo>? installedInfoSnapshot = prefetchedInstalledInfo;
      if (installedInfoSnapshot == null &&
          updateInstalledInfo &&
          effectiveApps.length > 1) {
        try {
          final List<PackageInfo> installedPackages = await getAllInstalledInfo(
            light: true,
          );
          installedInfoSnapshot = {
            for (final PackageInfo info in installedPackages)
              if (info.packageName != null) info.packageName!: info,
          };
        } catch (e) {
          unawaited(
            logs.add(
              'Failed to prefetch installed package info for bulk save: $e',
              level: LogLevel.warning,
            ),
          );
        }
      }
      final Directory appsDirectory = await getAppsDir();
      final sourceProvider = SourceProvider();
      final appFolders = settingsProvider.appFolders;
      final Map<String, PackageInfo>? effectiveInstalledInfoSnapshot =
          installedInfoSnapshot;
      const int saveChunkSize = 16;
      for (
        int chunkStart = 0;
        chunkStart < effectiveApps.length;
        chunkStart += saveChunkSize
      ) {
        final int chunkEnd = min(
          chunkStart + saveChunkSize,
          effectiveApps.length,
        );
        await Future.wait(
          effectiveApps.sublist(chunkStart, chunkEnd).map((a) async {
            var app = a.copyWith();
            final AppInMemory? cached = this.apps[app.id];
            final PackageInfo? info;
            if (!updateInstalledInfo) {
              info = cached?.installedInfo;
            } else if (effectiveInstalledInfoSnapshot != null) {
              info = effectiveInstalledInfoSnapshot[app.id];
            } else {
              info = await getInstalledInfo(app.id);
            }
            Uint8List? icon = cached?.icon;
            String? installedAppName;
            if (!updateInstalledInfo) {
              installedAppName = cached?.installedInfo == null
                  ? null
                  : cached?.app.name;
            } else {
              final bool installedPackageUnchanged =
                  cached != null &&
                  cached.installedInfo?.packageName == info?.packageName &&
                  cached.installedInfo?.versionName == info?.versionName &&
                  cached.installedInfo?.versionCode == info?.versionCode &&
                  cached.installedInfo?.lastUpdateTime == info?.lastUpdateTime;
              if (installedPackageUnchanged) {
                installedAppName = info == null ? null : cached.app.name;
              } else {
                icon = null;
                final applicationInfo = info?.applicationInfo;
                if (applicationInfo != null) {
                  try {
                    icon = await applicationInfo.getAppIcon();
                    installedAppName = await applicationInfo.getAppLabel();
                  } catch (e) {
                    unawaited(
                      logs.add(
                        'Installed package details unavailable for ${app.id}: $e',
                      ),
                    );
                  }
                }
              }
            }
            app = app.copyWith(name: installedAppName ?? app.name);
            if (attemptToCorrectInstallStatus) {
              app = getCorrectedInstallStatusAppIfPossible(app, info) ?? app;
            }
            app = normalizeSkippedLatestVersion(app);
            final sourceIdentifier =
                cached?.sourceType ??
                sourceProvider
                    .getSourceTemplate(
                      app.url,
                      overrideSource: app.overrideSource,
                    )
                    .sourceIdentifier;
            reconcileAppFolderMemberships(
              app,
              appFolders,
              sourceIdentifier: sourceIdentifier,
              isUpToDate: appIsUpToDateForFiltering(app),
            );
            if (!onlyIfExists || this.apps.containsKey(app.id)) {
              final String filePath = '${appsDirectory.path}/${app.id}.json';
              final String tmpPath =
                  '$filePath.tmp_${DateTime.now().microsecondsSinceEpoch}_${_saveAppsTmpNonce++}';
              final File tmpFile = File(tmpPath);
              try {
                await tmpFile.writeAsString(
                  jsonEncode(app.toJson()),
                  flush: true,
                ); // #2089
                await tmpFile.rename(filePath);
              } finally {
                try {
                  if (await tmpFile.exists()) {
                    await tmpFile.delete();
                  }
                } catch (cleanupError) {
                  unawaited(
                    logs.add(
                      'Failed to clean save temp for ${app.id}: $cleanupError',
                      level: LogLevel.warning,
                    ),
                  );
                }
              }
            }
            if (cached != null) {
              this.apps[app.id] = AppInMemory(
                app,
                cached.downloadProgress,
                info,
                icon,
                sourceType: cached.sourceType,
                download: cached.download,
              );
            } else if (!onlyIfExists) {
              this.apps[app.id] = AppInMemory(app, null, info, icon);
            }
          }),
        );
        if (chunkEnd < effectiveApps.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      markAppsChanged();
      notify();
      if (autoExportAfterSave) {
        scheduleAutoExport();
      }
    } finally {
      saveCompletion.complete();
    }
  }

  /// Deletes app JSON files, cached APKs, and icons for the given app IDs, then updates state.
  Future<void> removeApps(List<String> appIds) async {
    final apkFiles = apkDir.listSync();
    await Future.wait(
      appIds.map((appId) async {
        final File file = File('${(await getAppsDir()).path}/$appId.json');
        if (file.existsSync()) {
          deleteFile(file);
        }
        await Future.wait(
          apkFiles
              .where(
                (element) => element.path.split('/').last.startsWith('$appId-'),
              )
              .map((element) => element.delete(recursive: true)),
        );
        final cachedIcon = File('${iconsCacheDir.path}/$appId.png');
        if (cachedIcon.existsSync()) cachedIcon.deleteSync();
        final File deducedIcon = _deducedAppIconPngFile(appId);
        if (deducedIcon.existsSync()) {
          deducedIcon.deleteSync();
          unawaited(removeMirroredIconFromIconsDir(appId, isUserIcon: false));
        }
        if (apps.containsKey(appId)) {
          apps.remove(appId);
        }
      }),
    );
    if (appIds.isNotEmpty) {
      markAppsChanged();
      notify();
      scheduleAutoExport();
    }
  }

  /// Persists [updatedApp] under its new package ID and removes the entry
  /// stored under [previousPackageId].
  Future<void> renameAppPackageId(
    String previousPackageId,
    App updatedApp,
  ) async {
    final String newPackageId = updatedApp.id.trim();
    final AppInMemory? previousEntry = apps[previousPackageId];
    if (newPackageId.isEmpty) {
      throw ObtainiumError(tr('invalidAndroidPackageId'));
    }
    if (previousEntry == null) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    if (newPackageId == previousPackageId) {
      await saveApps([updatedApp], updateInstalledInfo: false);
      return;
    }
    if (apps.containsKey(newPackageId)) {
      throw ObtainiumError(tr('appAlreadyAdded'));
    }
    if (previousEntry.downloadProgress != null) {
      throw ObtainiumError(tr('unexpectedError'));
    }

    final File previousUserIcon = _userAppIconPngFile(previousPackageId);
    final File newUserIcon = _userAppIconPngFile(newPackageId);
    if (newUserIcon.existsSync()) {
      deleteFile(newUserIcon);
    }
    if (previousUserIcon.existsSync()) {
      previousUserIcon.renameSync(newUserIcon.path);
    }
    final File previousDeducedIcon = _deducedAppIconPngFile(previousPackageId);
    final File newDeducedIcon = _deducedAppIconPngFile(newPackageId);
    if (newDeducedIcon.existsSync()) {
      deleteFile(newDeducedIcon);
    }
    if (previousDeducedIcon.existsSync()) {
      previousDeducedIcon.renameSync(newDeducedIcon.path);
    }

    try {
      await saveApps(
        [updatedApp.copyWith(id: newPackageId)],
        onlyIfExists: false,
        autoExportAfterSave: false,
      );
    } catch (_) {
      if (newUserIcon.existsSync() && !previousUserIcon.existsSync()) {
        newUserIcon.renameSync(previousUserIcon.path);
      }
      if (newDeducedIcon.existsSync() && !previousDeducedIcon.existsSync()) {
        newDeducedIcon.renameSync(previousDeducedIcon.path);
      }
      rethrow;
    }

    unawaited(
      removeMirroredIconFromIconsDir(previousPackageId, isUserIcon: true),
    );
    unawaited(
      removeMirroredIconFromIconsDir(previousPackageId, isUserIcon: false),
    );
    if (newUserIcon.existsSync()) {
      unawaited(mirrorIconToIconsDir(newPackageId, isUserIcon: true));
    }
    if (newDeducedIcon.existsSync()) {
      unawaited(mirrorIconToIconsDir(newPackageId, isUserIcon: false));
    }

    final AppInMemory? newEntry = apps[newPackageId];
    if (newEntry != null) {
      apps[newPackageId] = AppInMemory(
        newEntry.app,
        previousEntry.downloadProgress,
        newEntry.installedInfo,
        previousEntry.icon,
        sourceType: previousEntry.sourceType,
        download: previousEntry.download,
      );
    }

    final ({String? title, String message})? pageError = appPageErrors.remove(
      previousPackageId,
    );
    if (pageError != null) {
      appPageErrors[newPackageId] = pageError;
    }
    detailPageAutoChecksInFlight.remove(previousPackageId);
    lastDetailPageAutoCheckStartedAt.remove(previousPackageId);

    await removeApps([previousPackageId]);
  }

  Future<RemoveAppsWithModalResult> removeAppsWithModal(
    BuildContext context,
    List<App> appsToAffect,
  ) async {
    final bool showUninstallOption = appsToAffect
        .where(
          (a) => a.installedVersion != null && !a.settings.getBool('trackOnly'),
        )
        .isNotEmpty;
    final Map<String, dynamic>? values = await showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return GeneratedFormModal(
          primaryActionColour: Theme.of(context).colorScheme.error,
          title: plural('removeAppQuestion', appsToAffect.length),
          items: !showUninstallOption
              ? []
              : [
                  [
                    GeneratedFormSwitch(
                      'rmAppEntry',
                      label: tr('removeFromObtainX'),
                      value: true,
                    ),
                  ],
                  [
                    GeneratedFormSwitch(
                      'uninstallApp',
                      label: tr('uninstallFromDevice'),
                    ),
                  ],
                ],
          initValid: true,
        );
      },
    );
    if (values == null) {
      return RemoveAppsWithModalResult.cancelled;
    }
    final bool uninstall =
        values['uninstallApp'] == true && showUninstallOption;
    final bool removeFromObtainium =
        !showUninstallOption || values['rmAppEntry'] == true;
    if (!removeFromObtainium && !uninstall) {
      return RemoveAppsWithModalResult.cancelled;
    }
    final List<AppInMemory> rowSnapshots = appsToAffect
        .where((App a) => apps[a.id] != null)
        .map((App a) => apps[a.id]!.deepCopy())
        .toList();
    if (uninstall) {
      for (final App appEntry in appsToAffect) {
        if (appEntry.installedVersion != null) {
          await uninstallApp(appEntry.id);
        }
      }
    }
    if (removeFromObtainium) {
      if (uninstall) {
        await removeApps(appsToAffect.map((e) => e.id).toList());
        return const RemoveAppsWithModalResult._(
          confirmed: true,
          removedFromObtainiumImmediately: true,
          obtainiumEntryRemovedOrScheduled: true,
        );
      } else {
        await scheduleDeferredObtainiumRemovals(rowSnapshots);
        return RemoveAppsWithModalResult._(
          confirmed: true,
          deferredUndoAppIds: appsToAffect.map((App e) => e.id).toSet(),
          obtainiumEntryRemovedOrScheduled: true,
        );
      }
    }
    if (uninstall) {
      // Uninstall-only: clear the recorded installed version so the row updates
      // immediately (the real uninstall is reconciled on the next load too).
      final List<App> cleared = appsToAffect
          .map((a) => a.copyWith(installedVersion: null))
          .toList();
      await saveApps(cleared, attemptToCorrectInstallStatus: false);
      return const RemoveAppsWithModalResult._(confirmed: true);
    }
    return RemoveAppsWithModalResult.cancelled;
  }

  Future<void> openAppSettings(String appId) async {
    // When enabled, open the app's info in the App Manager app instead of the
    // system settings screen (parity with fork main). Falls back to system
    // settings if App Manager isn't installed or the launch fails.
    if (settingsProvider.openAppInfoInAppManager) {
      try {
        final AndroidIntent intent = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: 'app-manager://details?id=$appId',
        );
        await intent.launch();
        return;
      } catch (_) {
        // Fall through to standard settings below.
      }
    }
    final AndroidIntent intent = AndroidIntent(
      action: 'action_application_details_settings',
      data: 'package:$appId',
    );
    await intent.launch();
  }

  void addMissingCategories(SettingsProvider settingsProvider) {
    final cats = Map<String, int>.from(settingsProvider.categories);
    apps.forEach((key, value) {
      for (var c in value.app.categories) {
        if (!cats.containsKey(c)) {
          cats[c] = generateRandomLightColor().toARGB32();
        }
      }
    });
    settingsProvider.setCategories(cats, appsProvider: this);
  }

  String _fileBasename(String rawPath) {
    final int unix = rawPath.lastIndexOf('/');
    final int win = rawPath.lastIndexOf('\\');
    final int index = unix > win ? unix : win;
    return index < 0 ? rawPath : rawPath.substring(index + 1);
  }

  /// Deletes APK cache, icon files, and optionally the main app JSON under
  /// [getAppsDir] for the given app IDs.
  Future<void> deleteObtainiumAppDiskData(
    List<String> appIds, {
    bool deleteMainJson = true,
  }) async {
    final List<FileSystemEntity> apkFiles = apkDir.listSync();
    final Directory appsDirectory = await getAppsDir();
    await Future.wait(
      appIds.map((String appId) async {
        if (deleteMainJson) {
          final File mainJson = File('${appsDirectory.path}/$appId.json');
          if (mainJson.existsSync()) {
            deleteFile(mainJson);
          }
        }
        for (final FileSystemEntity element in apkFiles) {
          if (_fileBasename(element.path).startsWith('$appId-')) {
            element.deleteSync(recursive: true);
          }
        }
        final File standardIconCache = File('${iconsCacheDir.path}/$appId.png');
        if (standardIconCache.existsSync()) {
          deleteFile(standardIconCache);
        }
        final File deducedIconStored = _deducedAppIconPngFile(appId);
        if (deducedIconStored.existsSync()) {
          deleteFile(deducedIconStored);
          unawaited(removeMirroredIconFromIconsDir(appId, isUserIcon: false));
        }
        final File userIconStored = _userAppIconPngFile(appId);
        if (userIconStored.existsSync()) {
          deleteFile(userIconStored);
          unawaited(removeMirroredIconFromIconsDir(appId, isUserIcon: true));
        }
        final File legacyUserIconInCache = File(
          '${iconsCacheDir.path}/$appId.user.png',
        );
        if (legacyUserIconInCache.existsSync()) {
          deleteFile(legacyUserIconInCache);
        }
      }),
    );
  }

  Future<void> _moveAppJsonToPendingRemoval(String appId) async {
    final Directory appsDirectory = await getAppsDir();
    final Directory pendingDir = Directory(
      '${appsDirectory.path}/pending_removal',
    );
    if (!pendingDir.existsSync()) {
      pendingDir.createSync(recursive: true);
    }
    final File sourceJson = File('${appsDirectory.path}/$appId.json');
    if (!sourceJson.existsSync()) {
      return;
    }
    final File destinationJson = File('${pendingDir.path}/$appId.json');
    if (destinationJson.existsSync()) {
      deleteFile(destinationJson);
    }
    sourceJson.renameSync(destinationJson.path);
  }

  Future<void> _restoreAppJsonFromPendingRemoval(String appId) async {
    final Directory appsDirectory = await getAppsDir();
    final File pendingJson = File(
      '${appsDirectory.path}/pending_removal/$appId.json',
    );
    final File mainJson = File('${appsDirectory.path}/$appId.json');
    if (!pendingJson.existsSync()) {
      return;
    }
    if (mainJson.existsSync()) {
      deleteFile(pendingJson);
      return;
    }
    pendingJson.renameSync(mainJson.path);
  }

  /// Drops pending-removal JSON that no longer has an in-memory deferral (e.g.
  /// after a process restart).
  Future<void> _purgeStalePendingRemovalFilesWithoutLiveDeferral() async {
    final Directory appsDirectory = await getAppsDir();
    final Directory pendingDir = Directory(
      '${appsDirectory.path}/pending_removal',
    );
    if (!pendingDir.existsSync()) {
      return;
    }
    for (final FileSystemEntity entity in pendingDir.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.json')) continue;
      final String fileName = _fileBasename(entity.path);
      final String appId = fileName.substring(0, fileName.length - 5);
      if (deferredObtainiumSnapshots.containsKey(appId)) {
        continue;
      }
      deleteFile(entity);
      await deleteObtainiumAppDiskData([appId], deleteMainJson: false);
    }
  }

  /// Removes [rowSnapshots] from the UI immediately (stashing their JSON) and
  /// schedules a disk purge after a short delay unless the user undoes it.
  Future<void> scheduleDeferredObtainiumRemovals(
    List<AppInMemory> rowSnapshots,
  ) async {
    for (final AppInMemory row in rowSnapshots) {
      final String appId = row.app.id;
      deferredObtainiumSnapshots[appId] = row.deepCopy();
      await _moveAppJsonToPendingRemoval(appId);
      apps.remove(appId);
      deferredObtainiumTimers[appId]?.cancel();
      deferredObtainiumTimers[appId] = Timer(const Duration(seconds: 5), () {
        _finalizeDeferredObtainiumRemoval(appId);
      });
    }
    markAppsChanged();
    notify();
    unawaited(export(isAuto: true));
  }

  /// Restores apps previously staged by [scheduleDeferredObtainiumRemovals].
  Future<void> undoDeferredObtainiumRemovals(Set<String> appIds) async {
    for (final String appId in appIds) {
      deferredObtainiumTimers[appId]?.cancel();
      deferredObtainiumTimers.remove(appId);
      final AppInMemory? snapshot = deferredObtainiumSnapshots.remove(appId);
      if (snapshot == null) continue;
      await _restoreAppJsonFromPendingRemoval(appId);
      final File mainJson = File('${(await getAppsDir()).path}/$appId.json');
      if (!mainJson.existsSync()) {
        await saveApps([snapshot.app], onlyIfExists: false);
      }
      apps[appId] = snapshot.deepCopy();
    }
    markAppsChanged();
    notify();
    unawaited(export(isAuto: true));
  }

  Future<void> _finalizeDeferredObtainiumRemoval(String appId) async {
    deferredObtainiumTimers.remove(appId)?.cancel();
    deferredObtainiumSnapshots.remove(appId);
    final Directory appsDirectory = await getAppsDir();
    final File mainJson = File('${appsDirectory.path}/$appId.json');
    if (mainJson.existsSync()) {
      final File stalePending = File(
        '${appsDirectory.path}/pending_removal/$appId.json',
      );
      if (stalePending.existsSync()) {
        deleteFile(stalePending);
      }
      return;
    }
    final File pendingJson = File(
      '${appsDirectory.path}/pending_removal/$appId.json',
    );
    if (pendingJson.existsSync()) {
      deleteFile(pendingJson);
    }
    await deleteObtainiumAppDiskData([appId], deleteMainJson: false);
    unawaited(export(isAuto: true));
    notify();
  }

  /// Renames a track-only app's package ID (used when the user learns the real
  /// package name for a track-only entry that was added with a placeholder).
  Future<void> changeTrackOnlyAppPackageId(
    String previousPackageId,
    String newPackageId,
  ) async {
    final trimmed = newPackageId.trim();
    if (!_androidApplicationIdPattern.hasMatch(trimmed)) {
      throw ObtainiumError(tr('invalidAndroidPackageId'));
    }
    if (trimmed == previousPackageId) {
      return;
    }
    if (!apps.containsKey(previousPackageId)) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    final existingApp = apps[previousPackageId]!.app;
    if (!existingApp.settings.getBool('trackOnly')) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    if (apps.containsKey(trimmed)) {
      throw ObtainiumError(tr('appAlreadyAdded'));
    }
    final App renamed = existingApp.copyWith(id: trimmed);
    final App updatedApp = renamed.copyWith(
      additionalSettings: {
        ...renamed.additionalSettings,
        'trackOnlyTemporaryPackageId': isTempId(renamed),
      },
    );
    await renameAppPackageId(previousPackageId, updatedApp);
  }

  /// Reconciles a newly added app with all smart folders. Prefer the live [App]
  /// from [apps] so post-save corrections apply to criteria matching.
  Future<void> assignMatchingFoldersToAppIfNeeded(App app) async {
    final sourceProvider = SourceProvider();
    final sourceIdentifier = sourceProvider
        .getSourceTemplate(app.url, overrideSource: app.overrideSource)
        .sourceIdentifier;
    final changed = reconcileAppFolderMemberships(
      app,
      settingsProvider.appFolders,
      sourceIdentifier: sourceIdentifier,
      isUpToDate: appIsUpToDateForFiltering(app),
    );
    if (changed) await saveApps([app]);
  }
}
