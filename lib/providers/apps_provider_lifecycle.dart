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
import 'package:obtainium/components/generated_form_renderer.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:obtainium/services/app_check_store.dart';

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
    if (app == null ||
        app.app.settings.getBool('trackOnly') ||
        app.installedInfo == null) {
      return false;
    }
    final observed = app.app.copyWith(
      installedVersion: _getRealInstalledVersion(app.app, app.installedInfo),
      additionalSettings: {
        ...app.app.additionalSettings,
        'versionDetection': app.app.usesVersionCodeAsOsVersion
            ? 'versionCode'
            : 'standard',
        observedPackageIdKey: app.installedInfo!.packageName,
        observedVersionNameKey: app.installedInfo!.versionName,
        observedVersionCodeKey: app.installedInfo!.versionCode,
      },
    );
    return versionDecisionForApp(observed).relation != VersionRelation.unknown;
  }

  /// Refresh observations without replacing device versions with source labels.
  App? getCorrectedInstallStatusAppIfPossible(
    App app,
    PackageInfo? installedInfo,
  ) {
    final originalApp = app;
    app = normalizeSelectedSourceVersion(app);
    final resetToDevice = app.additionalSettings.containsKey(
      installStatusResetKey,
    );
    final settings = Map<String, dynamic>.from(app.additionalSettings)
      ..remove(unreconciledVersionComparisonKey)
      ..remove(installStatusResetKey);
    final trackOnly = app.settings.getBool('trackOnly');
    if (trackOnly && !isTempId(app)) {
      settings['trackOnlyTemporaryPackageId'] = false;
    }
    var installed = app.installedVersion;
    if (installedInfo == null) {
      settings.remove(observedVersionNameKey);
      settings.remove(observedVersionCodeKey);
      settings.remove(observedPackageIdKey);
      settings.remove('lastInstalledTime');
      settings.remove(confirmedInstallReleaseKey);
      final unverifiable =
          trackOnly &&
          (isTempId(app) ||
              settings['trackOnlyTemporaryPackageId'] == true ||
              app.additionalSettings[trackOnlyUserMarkedInstalledKey] == true);
      if (!unverifiable) {
        installed = null;
        if (trackOnly) {
          settings['trackOnlyUndeterminedInstalledVersion'] = false;
        }
      }
    } else {
      settings[observedVersionNameKey] = installedInfo.versionName;
      settings[observedVersionCodeKey] = installedInfo.versionCode;
      settings[observedPackageIdKey] = installedInfo.packageName;
      if (installedInfo.lastUpdateTime == null) {
        settings.remove('lastInstalledTime');
      } else {
        settings['lastInstalledTime'] = installedInfo.lastUpdateTime;
      }
      final real = _getRealInstalledVersion(app, installedInfo);
      if (trackOnly &&
          app.usesStandardVersionDetection &&
          !app.usesVersionCodeAsOsVersion &&
          settings[trackedDeviceStateVersionKey] != 1) {
        // Migrate a legacy source alias once, retaining its acknowledgement
        // separately before adopting the actual package version.
        if (!resetToDevice &&
            installed != null &&
            installed != real &&
            settings[acknowledgedSourceReleaseKey] == null) {
          settings[acknowledgedSourceReleaseKey] = acknowledgeSourceRelease(
            app.copyWith(
              latestVersion: installed,
              additionalSettings: settings,
            ),
          ).additionalSettings[acknowledgedSourceReleaseKey];
        }
        settings[trackedDeviceStateVersionKey] = 1;
      }
      if (resetToDevice ||
          app.usesStandardVersionDetection ||
          app.usesVersionCodeAsOsVersion) {
        installed = real;
      } else if (installed == null) {
        installed = app.usesStandardVersionDetection ? real : app.latestVersion;
      } else if (real != null &&
          compareVersionStrings(real, app.latestVersion).relation ==
              VersionRelation.same) {
        installed = app.latestVersion;
      }
      if (trackOnly) {
        settings['trackOnlyUndeterminedInstalledVersion'] = false;
        settings.remove(trackOnlyUserMarkedInstalledKey);
      }
      final receipt = InstallReleaseSnapshot.fromJson(
        settings[confirmedInstallReleaseKey],
      );
      if (receipt == null ||
          !receipt.belongsTo(app) ||
          !receipt.matchesPackage(installedInfo)) {
        settings.remove(confirmedInstallReleaseKey);
      }
      final pending = InstallReleaseSnapshot.fromJson(
        settings[pendingInstallReleaseKey],
      );
      if (pending == null || !pending.belongsTo(app)) {
        settings.remove(pendingInstallReleaseKey);
      }
      if (pending != null &&
          pending.belongsTo(app) &&
          pending.matchesPackage(installedInfo)) {
        settings[confirmedInstallReleaseKey] = pending.toJson();
        settings.remove(pendingInstallReleaseKey);
        if (!app.usesStandardVersionDetection &&
            !app.usesVersionCodeAsOsVersion) {
          installed = pending.version;
        }
      }
    }
    var corrected =
        installed == app.installedVersion &&
            mapEquals(settings, app.additionalSettings)
        ? app
        : app.copyWith(
            installedVersion: installed,
            additionalSettings: settings,
          );
    corrected = normalizeSkippedLatestVersion(corrected);
    return identical(corrected, originalApp) ? null : corrected;
  }

  Future<void> loadApps({
    String? singleId,
    bool silent = false,
    Duration installedInfoTimeout = const Duration(seconds: 20),
  }) async {
    // Reserve the queue slot before yielding. Waiting first lets two callers
    // both see an idle loader and overwrite each other's completion signal.
    final previousLoad = appsLoadingCompleter;
    final loadCompletion = Completer<void>();
    appsLoadingCompleter = loadCompletion;
    bool dataChanged = false;
    final correctedInstallStatusIds = <String>[];
    var stage = 'waiting for an earlier load';
    var wasSlow = false;
    final slowLoad = Timer(const Duration(seconds: 15), () {
      wasSlow = true;
      unawaited(
        logs.add(
          'App load still waiting after 15s (${singleId ?? "all apps"}): $stage',
          level: LogLevel.warning,
        ),
      );
    });
    try {
      await previousLoad?.future;
      if (!silent) {
        loadingApps = true;
        notify();
      }
      stage = 'reading folder settings';
      final appFolders = settingsProvider.appFolders;
      final shouldMigrateFolderCriteria =
          (settingsProvider.prefs?.getInt('folderCriteriaMigrationVersion') ??
              0) <
          folderCriteriaMigrationVersion;
      final folderMembershipsToPersist = <App>[];
      // Commit any deferred "remove from ObtainX" whose in-memory deferral was
      // lost (e.g. process restart) before re-reading the app JSON dir.
      if (singleId == null) {
        stage = 'cleaning pending removals';
        await _purgeStalePendingRemovalFilesWithoutLiveDeferral();
      }
      final sp = SourceProvider();
      final List<List<String>> errors = [];
      stage = 'reading installed packages';
      var installedInfoAvailable = true;
      List<PackageInfo> installedAppsData = [];
      try {
        installedAppsData = singleId == null
            ? await getAllInstalledInfo(
                light: true,
              ).timeout(installedInfoTimeout)
            : [
                await getInstalledInfo(
                  singleId,
                  throwOnError: true,
                ).timeout(installedInfoTimeout),
              ].nonNulls.toList();
      } catch (error) {
        if (singleId != null) rethrow;
        // Missing observations are not evidence of an uninstall. The saved
        // library remains useful while Android's package service is unavailable.
        installedInfoAvailable = false;
        unawaited(
          logs.add(
            'Installed package snapshot unavailable; loading saved apps without '
            'changing install state: $error',
            level: LogLevel.warning,
          ),
        );
      }
      final Map<String, PackageInfo> installedAppsMap = {
        for (var i in installedAppsData)
          if (i.packageName != null) i.packageName!: i,
      };
      final List<String> removedAppIds = [];
      final DateTime? reuseWatermark = singleId == null
          ? lastFullDiskLoadAt
          : null;
      final DateTime diskLoadStartedAt = DateTime.now();
      final appsDirectory = await getAppsDir();
      final directoryModifiedAtStart = (await appsDirectory.stat()).modified;
      // A relative sqflite path uses Android's internal database directory.
      // App JSON may live on external storage, which is unsuitable for SQLite.
      final checks = appCheckStore ??= AppCheckStore('app_checks.db');
      stage = 'reading check timestamp database';
      // Both reads are optional (JSON records are durable) and independent, so
      // they run concurrently on the store's short read budget. Awaiting them
      // one after the other put two lock waits in series, directly in front of
      // the app list's first paint.
      final Future<DateTime?> checkStoreModifiedRead = checks.modified();
      final Future<Map<String, Map<String, Object?>>>
      checkTimesRead = checks.read(singleId: singleId).catchError((
        Object error,
      ) {
        // Timestamp storage is optional for loading the durable app records.
        unawaited(
          logs.add(
            'Could not load check timestamps: $error',
            level: LogLevel.warning,
          ),
        );
        return <String, Map<String, Object?>>{};
      });
      final checkStoreModifiedAtStart = await checkStoreModifiedRead;
      final Map<String, Map<String, Object?>> checkTimes = await checkTimesRead;
      // A single-ID load is by Android package, which can have a record per
      // store it is tracked from. Naming the known records keeps this off a
      // full directory listing.
      final List<FileSystemEntity> appFiles = singleId == null
          ? await appsDirectory.list().toList()
          : <FileSystemEntity>[
              for (final String recordName in <String>{
                singleId,
                for (final AppInMemory listing in apps.listingsForPackage(
                  singleId,
                ))
                  listing.listingKey,
              })
                File('${appsDirectory.path}/$recordName.json'),
            ];
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
            stage =
                'reading app records (${chunkStart + 1}-$chunkEnd/${appFiles.length})';
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
            final String fileName = _fileBasename(item.path);
            if (singleId != null &&
                !_appRecordFileMatchesPackageOrListing(fileName, singleId)) {
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
                  final checkpointJson = <String, dynamic>{
                    'id': app.id,
                    'listingId': app.listingId,
                    appRecordRevisionKey: checks.revisions[app.listingKey],
                    'lastUpdateCheck':
                        app.lastUpdateCheck?.microsecondsSinceEpoch,
                  };
                  checks.apply(checkpointJson, checkTimes);
                  final checked = dateTimeFromJsonValue(
                    checkpointJson['lastUpdateCheck'],
                  );
                  if (checked != app.lastUpdateCheck) {
                    app = app.copyWith(lastUpdateCheck: checked);
                    dataChanged = true;
                  }
                  reused = true;
                }
              } catch (_) {
                // Fall through to reading and parsing this file.
              }
            }
            if (!reused) {
              try {
                final json =
                    jsonDecode(await File(item.path).readAsString())
                        as Map<String, dynamic>;
                checks.apply(json, checkTimes);
                app = App.fromJson(json);
                // The file name is the record's identity, so a record whose
                // stored listing ID disagrees with it adopts the file name.
                // This also reclaims records written by builds that derived the
                // name from the tracked source.
                if (idFromFile != app.listingKey) {
                  app = app.copyWith(
                    listingId: idFromFile == app.id ? null : idFromFile,
                  );
                  dataChanged = true;
                }
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
              final AppInMemory? before = apps[app.listingKey];
              try {
                // Source validation is read-only; avoid constructing an adapter
                // for every app during each list load.
                final src = sp.getSourceTemplate(
                  app.url,
                  overrideSource: app.overrideSource,
                );
                final String sourceType = src.sourceIdentifier;
                final PackageInfo? installedInfo = installedInfoAvailable
                    ? installedAppsMap[app.id]
                    : before?.installedInfo;
                // Sampled before the reconcile: "externally uninstalled" is the
                // *transition* from a recorded version to none, and only step 1
                // of the reconcile can make it.
                final bool hadInstalledVersion = app.installedVersion != null;
                final App? correctedApp = installedInfoAvailable
                    ? getCorrectedInstallStatusAppIfPossible(app, installedInfo)
                    : null;
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
                if (!identical(before?.app, app) ||
                    installedInfoChanged ||
                    before?.sourceType != sourceType ||
                    before?.icon != icon) {
                  apps[app.listingKey] = AppInMemory(
                    app,
                    before?.downloadProgress,
                    installedInfo,
                    icon,
                    sourceType: sourceType,
                    download: before?.download,
                  );
                }
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
        lastFullDiskLoadAt = installedInfoAvailable ? diskLoadStartedAt : null;
        appDirectoryModifiedAt = directoryModifiedAtStart;
        appCheckStoreModifiedAt = checkStoreModifiedAtStart;
      }
      if (folderMembershipsToPersist.isNotEmpty) {
        stage = 'saving folder membership changes';
        await saveApps(
          folderMembershipsToPersist,
          attemptToCorrectInstallStatus: installedInfoAvailable,
          updateInstalledInfo: false,
          autoExportAfterSave: false,
        );
      }
      if (shouldMigrateFolderCriteria && singleId == null) {
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
        stage = 'processing invalid app records';
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
      slowLoad.cancel();
      if (identical(appsLoadingCompleter, loadCompletion)) {
        loadingApps = false;
        appsLoadingCompleter = null;
      }
      loadCompletion.complete();
      if (wasSlow) {
        unawaited(logs.add('App load finished (${singleId ?? "all apps"})'));
      }
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

  // Icons belong to the Android package and are shared by every store listing
  // of it, while callers hold a listing key as often as a package ID. Both
  // resolvers accept either.
  File _userAppIconPngFile(String appId) {
    final String packageId = apps[appId]?.app.id ?? appId;
    return File('${userAppIconsDir.path}/$packageId.user.png');
  }

  File _deducedAppIconPngFile(String appId) {
    final String packageId = apps[appId]?.app.id ?? appId;
    return File('${deducedAppIconsDir.path}/$packageId.png');
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
      // Install state is per package, so clear it on every listing of it.
      for (final AppInMemory listing
          in apps.listingsForPackage(appId).toList()) {
        if (listing.installedInfo == null) continue;
        apps[listing.listingKey] = AppInMemory(
          listing.app,
          null,
          null,
          listing.icon,
          sourceType: listing.sourceType,
          download: listing.download,
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
      if (!_userAppIconPngFile(appId).existsSync()) {
        bool iconApplied = false;
        for (final AppInMemory listing
            in apps.listingsForPackage(appId).toList()) {
          if (listing.installedInfo != null) continue;
          apps[listing.listingKey] = listing.copyWith(icon: icon);
          iconApplied = true;
        }
        if (iconApplied) notify();
      }
    } catch (e) {
      unawaited(logs.add('APK icon extraction failed for $appId: $e'));
    }
  }

  Future<void> updateAppIcon(String? appId, {bool ignoreCache = false}) async {
    if (appId == null) return;
    final AppInMemory? listing = apps[appId];
    if (listing == null) return;
    final String packageId = listing.app.id;

    final File userIconFile = _userAppIconPngFile(packageId);
    if (userIconFile.existsSync()) {
      try {
        final Uint8List iconBytes = await userIconFile.readAsBytes();
        if (_bytesLookLikePng(iconBytes)) {
          final Uint8List? currentIcon = listing.icon;
          if (currentIcon != null &&
              currentIcon.length == iconBytes.length &&
              listEquals(currentIcon, iconBytes)) {
            return;
          }
          for (final AppInMemory packageListing
              in apps.listingsForPackage(packageId).toList()) {
            apps[packageListing.listingKey] = packageListing.copyWith(
              icon: iconBytes,
            );
          }
          notify();
          return;
        }
      } catch (e) {
        unawaited(logs.add('User icon load failed for $packageId: $e'));
      }
    }

    final File cachedIcon = File('${iconsCacheDir.path}/$packageId.png');
    final bool isInstalled = listing.installedInfo != null;
    if (listing.icon != null && !ignoreCache) {
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
      icon = await _getInstalledAppIconSafely(packageId);
      if (icon != null) {
        icon = await _resizeIconForStorage(icon);
        await cachedIcon.writeAsBytes(icon);
      }
    }
    // Deduced icons are for non-installed apps only: extracted from the app's
    // own APK, or fetched from a store listing. Persisted outside the cache so
    // "clear cache" can't force that download or network fetch to happen again.
    final File deducedIcon = _deducedAppIconPngFile(packageId);
    if (!isInstalled && icon == null && deducedIcon.existsSync()) {
      try {
        icon = await deducedIcon.readAsBytes();
      } catch (e) {
        unawaited(logs.add('Deduced icon load failed for $packageId: $e'));
      }
    }
    if (!isInstalled && icon == null) {
      final url = listing.app.iconUrl;
      if (url != null && url.isNotEmpty) {
        final Uint8List? fetchedIcon = await _fetchIconFromUrl(url);
        if (fetchedIcon != null) {
          icon = await _resizeIconForStorage(fetchedIcon);
          await deducedIcon.writeAsBytes(icon);
          unawaited(mirrorIconToIconsDir(packageId, isUserIcon: false));
        }
      }
    }
    if (icon != null || ignoreCache) {
      final Uint8List? resolvedIcon = icon;
      // Use the constructor (not copyWith) so a null icon actually clears the
      // in-memory icon on ignoreCache resets; preserve the shared DownloadState.
      for (final AppInMemory packageListing
          in apps.listingsForPackage(packageId).toList()) {
        apps[packageListing.listingKey] = AppInMemory(
          packageListing.app,
          null,
          packageListing.installedInfo,
          resolvedIcon,
          sourceType: packageListing.sourceType,
          download: packageListing.download,
        );
      }
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
    final AppInMemory? listing = apps[appId];
    if (listing == null) return null;
    final String packageId = listing.app.id;
    final File cachedIcon = File('${iconsCacheDir.path}/$packageId.png');
    if (cachedIcon.existsSync()) {
      try {
        return await cachedIcon.readAsBytes();
      } catch (e) {
        unawaited(logs.add('loadIconPreviewExcludingUserOverride cache: $e'));
      }
    }
    Uint8List? icon = await _getInstalledAppIconSafely(packageId);
    if (listing.installedInfo != null) {
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
      final String? url = listing.app.iconUrl;
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
    final AppInMemory? listing = apps[appId];
    if (listing == null) {
      return tr('unexpectedError');
    }
    if (!_bytesLookLikePng(bytes)) {
      return tr('changeAppIconInvalidPng');
    }
    final String packageId = listing.app.id;
    try {
      final File dest = _userAppIconPngFile(packageId);
      await dest.writeAsBytes(bytes);
      // One icon file, so every listing of this package shows the new icon.
      for (final AppInMemory packageListing
          in apps.listingsForPackage(packageId).toList()) {
        apps[packageListing.listingKey] = packageListing.copyWith(icon: bytes);
      }
      notify();
      unawaited(mirrorIconToIconsDir(packageId, isUserIcon: true));
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
    final AppInMemory? listing = apps[appId];
    if (listing == null) return;
    final File userFile = _userAppIconPngFile(appId);
    if (userFile.existsSync()) {
      deleteFile(userFile);
      unawaited(
        removeMirroredIconFromIconsDir(listing.app.id, isUserIcon: true),
      );
    }
    await updateAppIcon(appId, ignoreCache: true);
  }

  /// Atomically replaces one app record and invalidates older checkpoints.
  Future<void> _writeAppRecord(
    Directory directory,
    App app,
    AppCheckStore checks,
  ) async {
    final String listingKey = app.listingKey;
    final filePath = '${directory.path}/$listingKey.json';
    final tmpFile = File(
      '$filePath.tmp_${DateTime.now().microsecondsSinceEpoch}_${_saveAppsTmpNonce++}',
    );
    final revision = AppCheckStore.newRevision();
    try {
      await tmpFile.writeAsString(
        jsonEncode(app.toJson()..[appRecordRevisionKey] = revision),
        flush: true,
      );
      await tmpFile.rename(filePath);
      checks.revisions[listingKey] = revision;
    } finally {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (error) {
        unawaited(
          logs.add(
            'Failed to clean save temp for $listingKey: $error',
            level: LogLevel.warning,
          ),
        );
      }
    }
  }

  /// Persists a list of [App] objects to disk and updates in-memory state.
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
    final Set<String> seenListingKeys = <String>{};
    for (int appIndex = apps.length - 1; appIndex >= 0; appIndex--) {
      final App candidate = apps[appIndex];
      if (seenListingKeys.add(candidate.listingKey)) {
        uniqueApps.add(candidate.deepCopy());
      }
    }
    final List<App> effectiveApps = uniqueApps.reversed.toList();

    final Future<void> pendingSaves = _saveAppsQueue;
    final Completer<void> saveCompletion = Completer<void>();
    _saveAppsQueue = saveCompletion.future;
    var stage = 'waiting for an earlier save';
    final slowSave = Timer(const Duration(seconds: 15), () {
      unawaited(
        logs.add(
          'App save still waiting after 15s (${effectiveApps.length} apps): $stage',
          level: LogLevel.warning,
        ),
      );
    });
    try {
      await pendingSaves;
      stage = 'reading installed package information';
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
      final checks = appCheckStore ??= AppCheckStore('app_checks.db');
      final checkpoints = <Map<String, Object?>>[];
      final checkpointApps = <App>[];
      final sourceProvider = SourceProvider();
      final appFolders = settingsProvider.appFolders;
      final Map<String, PackageInfo>? effectiveInstalledInfoSnapshot =
          installedInfoSnapshot;
      const int saveChunkSize = 16;
      stage = 'writing app records';
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
            final String listingKey = app.listingKey;
            final AppInMemory? cached = this.apps[listingKey];
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
            // A cached null may mean the package service was unavailable on
            // launch. Only a fresh query can establish that an app is absent.
            if (attemptToCorrectInstallStatus &&
                (updateInstalledInfo || info != null)) {
              app = getCorrectedInstallStatusAppIfPossible(app, info) ?? app;
            }
            app = normalizeSkippedLatestVersion(
              normalizeSelectedSourceVersion(app),
            );
            // The cached store is only a shortcut past a per-app source lookup
            // on bulk saves. It is stale the moment the URL or override moves,
            // which is exactly what a tracked-source swap does - reusing it
            // there would leave the listing (and its folder memberships)
            // claiming the store it just left.
            final bool cachedSourceStillApplies =
                cached?.sourceType != null &&
                cached!.app.url == app.url &&
                cached.app.overrideSource == app.overrideSource;
            final String sourceIdentifier = cachedSourceStillApplies
                ? cached.sourceType!
                : sourceProvider
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
            if (!onlyIfExists ||
                this.apps.containsListingKey(listingKey) ||
                cached != null) {
              final revision = checks.revisions[listingKey];
              if (!updateInstalledInfo &&
                  checks.isAvailable &&
                  cached != null &&
                  revision != null &&
                  onlyAppCheckTimeChanged(cached.app, app)) {
                checkpoints.add({
                  'id': listingKey,
                  'revision': revision,
                  'checked': app.lastUpdateCheck!.microsecondsSinceEpoch,
                });
                checkpointApps.add(app);
              } else {
                await _writeAppRecord(appsDirectory, app, checks);
              }
            }
            if (cached != null) {
              this.apps[listingKey] = AppInMemory(
                app,
                cached.downloadProgress,
                info,
                icon,
                sourceType: sourceIdentifier,
                download: cached.download,
              );
            } else if (!onlyIfExists) {
              this.apps[listingKey] = AppInMemory(
                app,
                null,
                info,
                icon,
                sourceType: sourceIdentifier,
              );
            }
          }),
        );
        if (chunkEnd < effectiveApps.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      stage = 'saving check timestamps';
      try {
        await checks.save(checkpoints);
      } catch (error) {
        stage = 'saving check timestamps in app records';
        unawaited(
          logs.add(
            'Check timestamp save failed; falling back to ${checkpointApps.length} '
            'app records: $error',
            level: LogLevel.warning,
          ),
        );
        for (final app in checkpointApps) {
          // A fresh record revision also rejects a timed-out SQLite write that
          // commits later with the old revision. No app state is lost on reload.
          await _writeAppRecord(appsDirectory, app, checks);
        }
      }
      stage = 'reading storage modification times';
      appCheckStoreModifiedAt = await checks.modified();
      appDirectoryModifiedAt = (await appsDirectory.stat()).modified;
      markAppsChanged();
      notify();
      if (autoExportAfterSave) {
        scheduleAutoExport();
      }
    } finally {
      slowSave.cancel();
      saveCompletion.complete();
    }
  }

  /// Deletes app JSON files, cached APKs, and icons for the given listing keys
  /// (a bare package ID removes every listing of that package), then updates
  /// state.
  ///
  /// Per-package files - launcher/deduced icons - are only deleted once the
  /// last listing of that package goes, since the other store's listing of the
  /// same package still displays them.
  Future<void> removeApps(List<String> appIds) async {
    if (appIds.isEmpty) return;
    final Directory appsDirectory = await getAppsDir();
    final List<String> listingKeys = _listingKeysFromIds(appIds);
    final Set<String> removedKeys = listingKeys.toSet();
    final Set<String> packagesLosingLastListing =
        {
          for (final String listingKey in listingKeys)
            _packageIdForListingKey(listingKey),
        }..removeWhere(
          (String packageId) => apps
              .listingsForPackage(packageId)
              .any((listing) => !removedKeys.contains(listing.listingKey)),
        );
    final apkFiles = apkDir.listSync();
    await Future.wait(
      listingKeys.map((listingKey) async {
        final String packageId = _packageIdForListingKey(listingKey);
        final bool lastListingForPackage = packagesLosingLastListing.contains(
          packageId,
        );
        final File listingFile = File('${appsDirectory.path}/$listingKey.json');
        if (listingFile.existsSync()) {
          deleteFile(listingFile);
        }
        await Future.wait(
          apkFiles
              .where((element) {
                final String base = _fileBasename(element.path);
                if (base.startsWith('$listingKey-')) return true;
                return lastListingForPackage && base.startsWith('$packageId-');
              })
              .map((element) => element.delete(recursive: true)),
        );
        if (lastListingForPackage) {
          final cachedIcon = File('${iconsCacheDir.path}/$packageId.png');
          if (cachedIcon.existsSync()) cachedIcon.deleteSync();
          final File deducedIcon = _deducedAppIconPngFile(packageId);
          if (deducedIcon.existsSync()) {
            deducedIcon.deleteSync();
            unawaited(
              removeMirroredIconFromIconsDir(packageId, isUserIcon: false),
            );
          }
        }
        apps.remove(listingKey);
      }),
    );
    await appCheckStore?.remove(listingKeys);
    markAppsChanged();
    notify();
    scheduleAutoExport();
  }

  /// Android package behind [listingKey], read from the live listing when it is
  /// still tracked and otherwise recovered from the key itself.
  String _packageIdForListingKey(String listingKey) =>
      apps[listingKey]?.app.id ??
      listingKey.split(appListingKeySeparator).first;

  /// Expands caller-supplied IDs to exact listing keys. A package ID with
  /// several listings expands to all of them, matching the old behavior where
  /// removing an app removed everything tracked for that package.
  List<String> _listingKeysFromIds(List<String> ids) {
    final Set<String> listingKeys = {};
    for (final String id in ids) {
      if (apps.containsListingKey(id)) {
        listingKeys.add(id);
        continue;
      }
      final List<AppInMemory> packageListings = apps
          .listingsForPackage(id)
          .toList();
      if (packageListings.isEmpty) {
        listingKeys.add(id);
      } else {
        listingKeys.addAll(
          packageListings.map((listing) => listing.listingKey),
        );
      }
    }
    return listingKeys.toList();
  }

  /// Persists [updatedApp] under its new package ID, moving the listing stored
  /// under [previousListingKey].
  ///
  /// Only a listing keyed by its package ID (a package's sole listing) changes
  /// key here; one carrying an explicit [App.listingId] keeps its key, and so
  /// its record, throughout.
  Future<void> renameAppPackageId(
    String previousListingKey,
    App updatedApp,
  ) async {
    final String newPackageId = updatedApp.id.trim();
    final AppInMemory? previousEntry = apps[previousListingKey];
    if (newPackageId.isEmpty) {
      throw ObtainiumError(tr('invalidAndroidPackageId'));
    }
    if (previousEntry == null) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    final String previousPackageId = previousEntry.app.id;
    // Keep the listing's stored identity: renaming the package must not move
    // this listing onto another store's record.
    final App renamedApp = updatedApp.copyWith(
      id: newPackageId,
      listingId: previousEntry.app.listingId,
    );
    if (newPackageId == previousPackageId) {
      await saveApps([renamedApp], updateInstalledInfo: false);
      return;
    }
    if (sameStoreListingIn(
          apps,
          renamedApp,
          ignoreKey: previousEntry.listingKey,
        ) !=
        null) {
      throw ObtainiumError(tr('appAlreadyAdded'));
    }
    if (previousEntry.downloadProgress != null) {
      throw ObtainiumError(tr('unexpectedError'));
    }

    // Icons are stored per package, so they may only follow the rename when no
    // other store's listing of the old package is left behind to use them.
    final bool iconsFollowRename =
        apps.listingsForPackage(previousPackageId).length <= 1;
    final File previousUserIcon = _userAppIconPngFile(previousPackageId);
    final File newUserIcon = _userAppIconPngFile(newPackageId);
    final File previousDeducedIcon = _deducedAppIconPngFile(previousPackageId);
    final File newDeducedIcon = _deducedAppIconPngFile(newPackageId);
    if (iconsFollowRename) {
      if (newUserIcon.existsSync()) {
        deleteFile(newUserIcon);
      }
      if (previousUserIcon.existsSync()) {
        previousUserIcon.renameSync(newUserIcon.path);
      }
      if (newDeducedIcon.existsSync()) {
        deleteFile(newDeducedIcon);
      }
      if (previousDeducedIcon.existsSync()) {
        previousDeducedIcon.renameSync(newDeducedIcon.path);
      }
    }

    try {
      await saveApps(
        [renamedApp],
        onlyIfExists: false,
        autoExportAfterSave: false,
      );
    } catch (_) {
      if (iconsFollowRename) {
        if (newUserIcon.existsSync() && !previousUserIcon.existsSync()) {
          newUserIcon.renameSync(previousUserIcon.path);
        }
        if (newDeducedIcon.existsSync() && !previousDeducedIcon.existsSync()) {
          newDeducedIcon.renameSync(previousDeducedIcon.path);
        }
      }
      rethrow;
    }

    if (iconsFollowRename) {
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
    }

    final String newListingKey = renamedApp.listingKey;
    final AppInMemory? newEntry = apps[newListingKey];
    if (newEntry != null) {
      apps[newListingKey] = AppInMemory(
        newEntry.app,
        previousEntry.downloadProgress,
        newEntry.installedInfo,
        previousEntry.icon,
        sourceType: previousEntry.sourceType,
        download: previousEntry.download,
      );
    }

    final ({String? title, String message})? pageError = appPageErrors.remove(
      previousListingKey,
    );
    if (pageError != null) {
      appPageErrors[newListingKey] = pageError;
    }
    detailPageAutoChecksInFlight.remove(previousListingKey);
    lastDetailPageAutoCheckStartedAt.remove(previousListingKey);

    if (newListingKey != previousEntry.listingKey) {
      await removeApps([previousEntry.listingKey]);
    }
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
    final List<AppInMemory> rowSnapshots = [
      for (final App appEntry in appsToAffect)
        apps[appEntry.listingKey]?.deepCopy(),
    ].whereType<AppInMemory>().toList();
    if (uninstall) {
      for (final App appEntry in appsToAffect) {
        if (appEntry.installedVersion != null) {
          await uninstallApp(appEntry.id);
        }
      }
    }
    if (removeFromObtainium) {
      if (uninstall) {
        await removeApps(
          appsToAffect.map((appEntry) => appEntry.listingKey).toList(),
        );
        return const RemoveAppsWithModalResult._(
          confirmed: true,
          removedFromObtainiumImmediately: true,
          obtainiumEntryRemovedOrScheduled: true,
        );
      } else {
        await scheduleDeferredObtainiumRemovals(rowSnapshots);
        return RemoveAppsWithModalResult._(
          confirmed: true,
          deferredUndoAppIds: rowSnapshots.map((row) => row.listingKey).toSet(),
          obtainiumEntryRemovedOrScheduled: true,
        );
      }
    }
    if (uninstall) {
      // Uninstall-only: clear the recorded installed version so the row updates
      // immediately (the real uninstall is reconciled on the next load too).
      // An uninstall through ObtainX also retires any user mark — it is a newer,
      // more explicit statement than the mark it replaces.
      final List<App> cleared = appsToAffect
          .map(
            (a) => a.copyWith(
              installedVersion: null,
              additionalSettings: Map<String, dynamic>.from(
                a.additionalSettings,
              )..remove(trackOnlyUserMarkedInstalledKey),
            ),
          )
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

  /// Strips every category outside [knownCategories] from every saved app, and
  /// rewrites [renamedFrom] to [renamedTo] where a deletion was really a rename.
  ///
  /// `categoryDeleteWarning` promises the user that deleting a category strips
  /// it from every app assigned to it, so this sweeps the durable records in
  /// [getAppsDir] rather than only the listings this isolate happens to hold.
  /// A record written by the background isolate, or one that arrived after the
  /// last load, would otherwise keep a tag that no longer exists anywhere in
  /// [SettingsProvider.categories] - and an orphaned tag is unreachable from
  /// the UI, because the category editor builds its chip list from the saved
  /// category map, so the user has no way to clear it by hand.
  ///
  /// The sweep is a reconcile against the whole map, not a diff against the
  /// names deleted in this one call, so tags orphaned by an earlier delete that
  /// did not reach every record are cleaned up on the next category write.
  ///
  /// Never throws: a failed sweep must not take down the settings write that
  /// triggered it.
  Future<void> reconcileAppCategories(
    Set<String> knownCategories, {
    String? renamedFrom,
    String? renamedTo,
  }) async {
    final bool isRename = renamedFrom != null && renamedTo != null;
    try {
      await waitForAppsToLoad();
      final Map<String, App> savedApps = {
        for (final AppInMemory listing in apps.values)
          listing.listingKey: listing.app,
      };
      final Directory appsDirectory = await getAppsDir();
      List<FileSystemEntity> appFiles = const [];
      try {
        appFiles = await appsDirectory.list().toList();
      } catch (err) {
        unawaited(
          logs.add(
            'Could not list app records while removing categories: $err',
            level: LogLevel.warning,
          ),
        );
      }
      for (final FileSystemEntity item in appFiles) {
        final String fileName = _fileBasename(item.path);
        if (!fileName.toLowerCase().endsWith('.json')) continue;
        final String listingKey = fileName.substring(
          0,
          fileName.length - '.json'.length,
        );
        if (savedApps.containsKey(listingKey)) continue;
        try {
          final json =
              jsonDecode(await File(item.path).readAsString())
                  as Map<String, dynamic>;
          savedApps[listingKey] = App.fromJson(json);
        } catch (err) {
          // A record this sweep cannot parse is left alone; loadApps owns
          // quarantining corrupt JSON.
          unawaited(
            logs.add(
              'Could not read $fileName while removing categories: $err',
              level: LogLevel.warning,
            ),
          );
        }
      }

      final List<App> changedApps = [];
      for (final App app in savedApps.values) {
        final List<String> nextCategories = [];
        bool changed = false;
        for (final String category in app.categories) {
          final String mapped = isRename && category == renamedFrom
              ? renamedTo
              : category;
          // A rename onto an existing category, or a duplicate already in the
          // record, collapses to one entry.
          final bool dropped =
              !knownCategories.contains(mapped) ||
              nextCategories.contains(mapped);
          if (dropped || mapped != category) changed = true;
          if (dropped) continue;
          nextCategories.add(mapped);
        }
        if (changed) changedApps.add(app.copyWith(categories: nextCategories));
      }
      if (changedApps.isEmpty) return;
      // [onlyIfExists] is false because the sweep deliberately reaches records
      // that are not in the in-memory map yet; they exist on disk, so the save
      // is an update, not a stray insert.
      await saveApps(
        changedApps,
        updateInstalledInfo: false,
        onlyIfExists: false,
      );
    } catch (err) {
      unawaited(
        logs.add(
          'Could not remove deleted categories from saved apps: $err',
          level: LogLevel.error,
        ),
      );
    }
  }

  String _fileBasename(String rawPath) {
    final int unix = rawPath.lastIndexOf('/');
    final int win = rawPath.lastIndexOf('\\');
    final int index = unix > win ? unix : win;
    return index < 0 ? rawPath : rawPath.substring(index + 1);
  }

  bool _appRecordFileMatchesPackageOrListing(String fileName, String id) {
    final String lowerName = fileName.toLowerCase();
    final String lowerId = id.toLowerCase();
    if (lowerName == '$lowerId.json') return true;
    if (lowerName.startsWith('$lowerId$appListingKeySeparator') &&
        lowerName.endsWith('.json')) {
      return true;
    }
    return lowerName == '$lowerId.json';
  }

  /// Deletes APK cache, icon files, and optionally the main app JSON under
  /// [getAppsDir] for the given app IDs.
  Future<void> deleteObtainiumAppDiskData(
    List<String> appIds, {
    bool deleteMainJson = true,
  }) async {
    await appCheckStore?.remove(appIds);
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
      final String appId = row.listingKey;
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
    final AppInMemory? previousEntry = apps[previousPackageId];
    if (previousEntry == null) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    final existingApp = previousEntry.app;
    if (trimmed == existingApp.id) {
      return;
    }
    if (!existingApp.settings.getBool('trackOnly')) {
      throw ObtainiumError(tr('unexpectedError'));
    }
    final App renamed = existingApp.copyWith(id: trimmed);
    if (sameStoreListingIn(
          apps,
          renamed,
          ignoreKey: previousEntry.listingKey,
        ) !=
        null) {
      throw ObtainiumError(tr('appAlreadyAdded'));
    }
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
