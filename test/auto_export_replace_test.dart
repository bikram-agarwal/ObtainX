import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider_import_export.dart';
import 'package:shared_storage/shared_storage.dart' as saf;

/// A file as the export folder lists it: its URI ends in the document ID.
saf.DocumentFile _listed(String documentId, {String? name}) =>
    saf.DocumentFile.fromMap({
      'uri':
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ABackups/document/${Uri.encodeComponent(documentId)}',
      'name': name,
    });

void main() {
  test('an earlier auto-export is matched by its name (D21a)', () {
    expect(
      isReplacedAutoExport(
        _listed('primary:Backups/obtainx.json', name: 'obtainx.json'),
        'obtainx',
      ),
      isTrue,
    );
    // Without a display name: the last part of the document ID.
    expect(
      isReplacedAutoExport(_listed('primary:Backups/obtainx.json'), 'obtainx'),
      isTrue,
    );
    expect(
      isReplacedAutoExport(
        _listed(
          'primary:Backups/obtainx-export-2026-10-04T10-00-00-auto.json',
          name: 'obtainx-export-2026-10-04T10-00-00-auto.json',
        ),
        null,
      ),
      isTrue,
    );
    expect(
      isReplacedAutoExport(
        _listed('primary:Backups/obtainx.json', name: 'obtainx.json'),
        null,
      ),
      isFalse,
    );
    expect(
      isReplacedAutoExport(
        _listed('primary:Backups/notes.json', name: 'notes.json'),
        'obtainx',
      ),
      isFalse,
    );
  });
}
