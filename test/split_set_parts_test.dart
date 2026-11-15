import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';

void main() {
  late Directory root;
  late Directory setDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('split_set_parts_test');
    setDir = Directory('${root.path}/set')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  File part(String name) => File('${root.path}/$name')..writeAsStringSync(name);

  // Stands in for the zip extraction: writes [entries], each holding its own
  // name, into the destination.
  Future<void> Function(String, String) unzipTo(List<String> entries) =>
      (String zipPath, String destinationPath) async {
        for (final String entry in entries) {
          File('$destinationPath/$entry')
            ..createSync(recursive: true)
            ..writeAsStringSync(entry);
        }
      };

  String nameOf(File file) => file.uri.pathSegments.last;

  test('a plain APK part moves into the set as it is', () async {
    final File apk = part('app-1.apk');
    final List<File> added = await addSplitSetPart(
      apk,
      setDir,
      unzip: unzipTo(const []),
    );
    expect(added.map(nameOf), ['app-1.apk']);
    expect(File('${setDir.path}/app-1.apk').existsSync(), isTrue);
    expect(apk.existsSync(), isFalse);
  });

  test("a .zip part's APK is extracted under the part's name", () async {
    // RuStore serves every part of a split set as a .zip (#3298).
    final File zip = part('app-1.zip');
    final List<File> added = await addSplitSetPart(
      zip,
      setDir,
      unzip: unzipTo(const ['split_config.arm64_v8a.apk']),
    );
    expect(added.map(nameOf), ['app-1.apk']);
    expect(
      File('${setDir.path}/app-1.apk').readAsStringSync(),
      'split_config.arm64_v8a.apk',
    );
    expect(zip.existsSync(), isFalse);
    expect(Directory('${zip.path}-parts').existsSync(), isFalse);
  });

  test('parts holding same-named APKs keep both', () async {
    await addSplitSetPart(
      part('app.zip'),
      setDir,
      unzip: unzipTo(const ['package.apk']),
    );
    await addSplitSetPart(
      part('app-1.zip'),
      setDir,
      unzip: unzipTo(const ['package.apk']),
    );
    expect(setDir.listSync().whereType<File>().map(nameOf).toSet(), {
      'app.apk',
      'app-1.apk',
    });
  });

  test('a part holding several APKs lists base.apk first', () async {
    final List<File> added = await addSplitSetPart(
      part('app.zip'),
      setDir,
      unzip: unzipTo(const [
        'split_config.xxhdpi.apk',
        'base.apk',
        'README.txt',
      ]),
    );
    expect(added.map((File file) => file.readAsStringSync()), [
      'base.apk',
      'split_config.xxhdpi.apk',
    ]);
    expect(added.map(nameOf), ['app.0.apk', 'app.1.apk']);
  });

  test('a part without an APK fails and leaves nothing behind', () async {
    final File zip = part('app-2.zip');
    await expectLater(
      addSplitSetPart(zip, setDir, unzip: unzipTo(const ['README.txt'])),
      throwsA(isA<NoAPKError>()),
    );
    expect(zip.existsSync(), isFalse);
    expect(Directory('${zip.path}-parts').existsSync(), isFalse);
    expect(setDir.listSync(), isEmpty);
  });
}
