import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

/// A file the user picked: its name, when the phone gives one, and what's in
/// it.
class PickedDocument {
  const PickedDocument(this.name, this.bytes);

  final String? name;
  final Uint8List bytes;
}

/// Opens Android's document picker, and reads the file picked. Returns null
/// if the user cancels.
///
/// Every file ObtainX asks for is picked this way: a backup to import or
/// restore, Import from URL list's file, an app's icon, and a font. Only
/// [type] differs between them: the MIME type the picker offers, such as
/// `image/png`, or any file (`*/*`). It takes one type, so a kind of file
/// with no type every phone agrees on (JSON, fonts) is picked as any file and
/// checked once read. [startIn] is a folder to open in.
///
/// Throws when there's no file picker, or the file can't be read.
Future<PickedDocument?> pickFile({String type = '*/*', Uri? startIn}) async {
  final List<Uri>? picked;
  try {
    picked = await saf.openDocument(
      initialUri: startIn,
      grantWritePermission: false,
      persistablePermission: false,
      mimeType: type,
    );
  } catch (e) {
    throw ObtainiumError(tr('noFilePickerAvailable'));
  }
  if (picked == null || picked.isEmpty) return null;
  final Uint8List? bytes = await saf.getDocumentContent(picked.single);
  if (bytes == null) throw ObtainiumError(tr('unexpectedError'));
  String? name;
  try {
    name = (await saf.fromTreeUri(picked.single))?.name;
  } catch (_) {
    // Only a font's fallback name needs it.
  }
  return PickedDocument(name, bytes);
}

/// The text of a file picked with [pickFile], opening in the export folder,
/// where ObtainX saves its exports. Backup import, restore and Import from
/// URL list's file take any file.
///
/// It's read loosely: bytes that aren't text become placeholder characters
/// rather than failing, so the caller's own parsing says what's wrong with
/// the file.
Future<String?> pickTextFile(SettingsProvider settingsProvider) async {
  final PickedDocument? picked = await pickFile(
    startIn: await settingsProvider.getExportDir(requireAccess: false),
  );
  if (picked == null) return null;
  return utf8.decode(picked.bytes, allowMalformed: true);
}
