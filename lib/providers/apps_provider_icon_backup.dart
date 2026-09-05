import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:obtainium/providers/apps_provider.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

/// Counts from a completed [AppsProviderIconBackup.importIconsFromIconsDir] sweep.
class IconImportSweepResult {
  const IconImportSweepResult({
    required this.restoredUserIcons,
    required this.restoredDeducedIcons,
    required this.skipped,
  });

  static const IconImportSweepResult none = IconImportSweepResult(
    restoredUserIcons: 0,
    restoredDeducedIcons: 0,
    skipped: 0,
  );

  final int restoredUserIcons;
  final int restoredDeducedIcons;
  final int skipped;

  int get restoredTotal => restoredUserIcons + restoredDeducedIcons;
}

/// Mirrors app icon files (user overrides and deduced icons, see
/// AppsProviderLifecycle) out to a user-picked SAF folder
/// ([SettingsProvider.getIconsDir]), and pulls them back in with a one-time
/// sweep when that folder is (re)selected or a backup restore reconnects it.
///
/// Private on-disk storage stays authoritative for everyday icon loading -
/// this extension is never a live read path, so normal icon display cost is
/// unaffected whether or not a folder is configured.
extension AppsProviderIconBackup on AppsProvider {
  String _mirroredIconDisplayName(String appId, {required bool isUserIcon}) =>
      isUserIcon ? '$appId.user.png' : '$appId.png';

  File _localIconFile(String appId, {required bool isUserIcon}) {
    final Directory dir = isUserIcon ? userAppIconsDir : deducedAppIconsDir;
    return File(
      '${dir.path}/${_mirroredIconDisplayName(appId, isUserIcon: isUserIcon)}',
    );
  }

  /// Whether [bytes] are identical to the icon already stored locally for
  /// [appId], so a restore sweep can skip re-writing (and, more importantly,
  /// skip *counting*) a file that would not actually change anything.
  Future<bool> _iconBytesUnchanged(
    String appId,
    Uint8List bytes, {
    required bool isUserIcon,
  }) async {
    final File localFile = _localIconFile(appId, isUserIcon: isUserIcon);
    if (!localFile.existsSync()) return false;
    try {
      return listEquals(await localFile.readAsBytes(), bytes);
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteMirroredDoc(Uri treeUri, String displayName) async {
    final saf.DocumentFile? existing = await saf.findFile(treeUri, displayName);
    if (existing != null) {
      await saf.delete(existing.uri);
    }
  }

  /// Best-effort push of an already-written local icon file out to the
  /// configured icons folder. Swallows all errors - a backup mirror must never
  /// block or fail the primary icon write it follows.
  Future<void> mirrorIconToIconsDir(
    String appId, {
    required bool isUserIcon,
  }) async {
    try {
      final Uri? treeUri = await settingsProvider.getIconsDir();
      if (treeUri == null) return;
      final File localFile = _localIconFile(appId, isUserIcon: isUserIcon);
      if (!localFile.existsSync()) return;
      final Uint8List bytes = await localFile.readAsBytes();
      final String displayName = _mirroredIconDisplayName(
        appId,
        isUserIcon: isUserIcon,
      );
      await _deleteMirroredDoc(treeUri, displayName);
      await saf.createFile(
        treeUri,
        mimeType: 'image/png',
        displayName: displayName,
        bytes: bytes,
      );
    } catch (e) {
      unawaited(logs.add('Icon mirror failed for $appId: $e'));
    }
  }

  /// Best-effort removal of a mirrored icon copy, so the folder does not keep
  /// files for icons that were reset, removed, or renamed away locally.
  Future<void> removeMirroredIconFromIconsDir(
    String appId, {
    required bool isUserIcon,
  }) async {
    try {
      final Uri? treeUri = await settingsProvider.getIconsDir();
      if (treeUri == null) return;
      await _deleteMirroredDoc(
        treeUri,
        _mirroredIconDisplayName(appId, isUserIcon: isUserIcon),
      );
    } catch (e) {
      unawaited(logs.add('Icon mirror cleanup failed for $appId: $e'));
    }
  }

  Future<bool> _restoreDeducedIconBytes(String appId, Uint8List bytes) async {
    try {
      await _localIconFile(appId, isUserIcon: false).writeAsBytes(bytes);
    } catch (e) {
      unawaited(logs.add('Deduced icon restore failed for $appId: $e'));
      return false;
    }
    if (apps.containsKey(appId) &&
        apps[appId]!.installedInfo == null &&
        !hasUserAppIconOverride(appId)) {
      apps.update(appId, (value) => value.copyWith(icon: bytes));
      notify();
    }
    return true;
  }

  /// Pushes every icon file currently on disk (user overrides and deduced
  /// icons) out to the configured icons folder, skipping any file that's
  /// already there with identical bytes. For backfilling a folder picked
  /// after icons already existed - [mirrorIconToIconsDir] only fires on new
  /// writes going forward, so it never catches up on its own.
  Future<int> exportAllIconsToIconsDir() async {
    final Uri? treeUri = await settingsProvider.getIconsDir();
    if (treeUri == null) return 0;

    int exported = 0;
    for (final bool isUserIcon in [true, false]) {
      final Directory dir = isUserIcon ? userAppIconsDir : deducedAppIconsDir;
      if (!dir.existsSync()) continue;
      final String suffix = isUserIcon ? '.user.png' : '.png';
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is! File) continue;
        final String fileName = entity.uri.pathSegments.last;
        // ".png" also matches ".user.png"; skip those on the deduced pass so
        // each file is exported exactly once.
        if (!fileName.endsWith(suffix) ||
            (!isUserIcon && fileName.endsWith('.user.png'))) {
          continue;
        }
        try {
          final Uint8List bytes = await entity.readAsBytes();
          final saf.DocumentFile? existing = await saf.findFile(
            treeUri,
            fileName,
          );
          if (existing != null) {
            final Uint8List? existingBytes = await saf.getDocumentContent(
              existing.uri,
            );
            if (existingBytes != null && listEquals(existingBytes, bytes)) {
              // Already up to date - not an export, so don't count it as one.
              continue;
            }
            await saf.delete(existing.uri);
          }
          await saf.createFile(
            treeUri,
            mimeType: 'image/png',
            displayName: fileName,
            bytes: bytes,
          );
          exported++;
        } catch (e) {
          unawaited(logs.add('Icon export failed for $fileName: $e'));
        }
      }
    }
    return exported;
  }

  /// One-time sweep: reads icon files back out of the configured icons folder
  /// into private storage, for every currently-tracked app that has a matching
  /// file there. Intended to run once, right after the folder is (re)selected
  /// or a backup restore reconnects it - not on every icon load.
  Future<IconImportSweepResult> importIconsFromIconsDir() async {
    final Uri? treeUri = await settingsProvider.getIconsDir();
    if (treeUri == null) return IconImportSweepResult.none;

    int restoredUserIcons = 0;
    int restoredDeducedIcons = 0;
    int skipped = 0;
    try {
      final List<saf.DocumentFile> entries = await saf
          .listFiles(
            treeUri,
            columns: [
              saf.DocumentFileColumn.id,
              saf.DocumentFileColumn.displayName,
            ],
          )
          .toList();
      for (final saf.DocumentFile entry in entries) {
        final String? name = entry.name;
        if (name == null) {
          skipped++;
          continue;
        }
        final bool isUserIcon = name.endsWith('.user.png');
        final String appId = isUserIcon
            ? name.substring(0, name.length - '.user.png'.length)
            : (name.endsWith('.png')
                  ? name.substring(0, name.length - '.png'.length)
                  : '');
        if (appId.isEmpty || !apps.containsKey(appId)) {
          skipped++;
          continue;
        }
        try {
          final Uint8List? bytes = await saf.getDocumentContent(entry.uri);
          if (bytes == null) {
            skipped++;
            continue;
          }
          if (await _iconBytesUnchanged(appId, bytes, isUserIcon: isUserIcon)) {
            // Already up to date (e.g. this is the same file a prior sweep or
            // an export just wrote) - not a restore, so don't count it as one.
            continue;
          }
          if (isUserIcon) {
            final String? error = await applyUserAppIconPngBytes(appId, bytes);
            if (error != null) {
              skipped++;
              continue;
            }
            restoredUserIcons++;
          } else {
            if (!await _restoreDeducedIconBytes(appId, bytes)) {
              skipped++;
              continue;
            }
            restoredDeducedIcons++;
          }
        } catch (e) {
          skipped++;
          unawaited(logs.add('Icon restore failed for $name: $e'));
        }
      }
    } catch (e) {
      unawaited(logs.add('Icon folder sweep failed: $e'));
    }
    return IconImportSweepResult(
      restoredUserIcons: restoredUserIcons,
      restoredDeducedIcons: restoredDeducedIcons,
      skipped: skipped,
    );
  }
}
