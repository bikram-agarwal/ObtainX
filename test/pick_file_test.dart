import 'dart:ui' show Locale;

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/pick_file.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Every file ObtainX asks for (a backup, Import from URL list's file, an
// icon, a font) is picked by pickFile, through shared_storage's channel.
const MethodChannel _documents = MethodChannel(
  'io.alexrintt.plugins/sharedstorage/documentfile',
);
const String _picked =
    'content://com.android.externalstorage.documents/document/primary%3ADownload%2Ffile';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final Map<String, dynamic> translations;
  final List<MethodCall> calls = [];
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
  });
  setUp(() {
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
    calls.clear();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_documents, null);
  });

  /// The picker answers [openDocument], and the file picked holds [bytes]
  /// and is called [name] (the phone may not say).
  void pickerAnswers({
    Object? Function()? openDocument,
    Uint8List? bytes,
    String? name,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_documents, (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'openDocument' => openDocument == null ? [_picked] : openDocument(),
            'getDocumentContent' => bytes,
            'fromTreeUri' =>
              name == null ? null : {'uri': _picked, 'name': name},
            _ => null,
          };
        });
  }

  test('only the file type differs between callers', () async {
    pickerAnswers(bytes: Uint8List.fromList([1, 2, 3]), name: 'icon.png');

    final PickedDocument? picked = await pickFile(type: 'image/png');

    expect(picked!.name, 'icon.png');
    expect(picked.bytes, [1, 2, 3]);
    final Map<Object?, Object?> opened =
        calls.first.arguments as Map<Object?, Object?>;
    expect(calls.first.method, 'openDocument');
    expect(opened['mimeType'], 'image/png');
    expect(opened.containsKey('initialUri'), isFalse);
    // Read once, never kept.
    expect(opened['persistablePermission'], isFalse);
    expect(opened['grantWritePermission'], isFalse);
    expect(calls.map((MethodCall call) => call.method), [
      'openDocument',
      'getDocumentContent',
      'fromTreeUri',
    ]);
  });

  test('cancelling picks nothing', () async {
    pickerAnswers(openDocument: () => null);

    expect(await pickFile(), isNull);
    expect(calls.map((MethodCall call) => call.method), ['openDocument']);
  });

  test('a phone with no picker says so', () async {
    pickerAnswers(
      openDocument: () => throw PlatformException(code: 'no_activity'),
    );

    await expectLater(
      pickFile(),
      throwsA(
        isA<ObtainiumError>().having(
          (ObtainiumError error) => error.message,
          'message',
          tr('noFilePickerAvailable'),
        ),
      ),
    );
  });

  test('a file the phone gives no name for is still read', () async {
    pickerAnswers(bytes: Uint8List.fromList([7]));

    final PickedDocument? picked = await pickFile();

    expect(picked!.name, isNull);
    expect(picked.bytes, [7]);
  });

  test('text files open in the export folder, read loosely', () async {
    const String exportDir =
        'content://com.android.externalstorage.documents/tree/primary%3AObtainX';
    SharedPreferences.setMockInitialValues({'exportDir': exportDir});
    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    addTearDown(settings.dispose);
    // "ok" and a byte that isn't UTF-8.
    pickerAnswers(bytes: Uint8List.fromList([0x6f, 0x6b, 0xff]));

    expect(await pickTextFile(settings), 'ok�');
    final Map<Object?, Object?> opened =
        calls.first.arguments as Map<Object?, Object?>;
    expect(opened['initialUri'], exportDir);
    expect(opened['mimeType'], '*/*');
  });
}
