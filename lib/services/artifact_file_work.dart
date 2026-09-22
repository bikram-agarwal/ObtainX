import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' as archive;
import 'package:crypto/crypto.dart';

Future<String> sha256FileOffIsolate(String path) {
  return Isolate.run(() async {
    return (await sha256.bind(File(path).openRead()).first).toString();
  }, debugName: 'artifact-sha256');
}

Future<void> extractTarballOffIsolate(String path, String destination) {
  return Isolate.run(
    () => _extractTarball(path, destination),
    debugName: 'artifact-extraction',
  );
}

void _extractTarball(String path, String destination) {
  final input = archive.InputFileStream(path);
  archive.InputFileStream? decodedInput;
  Directory? temporaryDirectory;
  try {
    final signature = input.peekBytes(6).toUint8List();
    final gzip =
        signature.length >= 2 && signature[0] == 0x1f && signature[1] == 0x8b;
    final bzip =
        signature.length >= 3 &&
        signature[0] == 0x42 &&
        signature[1] == 0x5a &&
        signature[2] == 0x68;
    final xz =
        signature.length >= 6 &&
        signature[0] == 0xfd &&
        signature[1] == 0x37 &&
        signature[2] == 0x7a &&
        signature[3] == 0x58 &&
        signature[4] == 0x5a &&
        signature[5] == 0x00;
    if (gzip || bzip || xz) {
      temporaryDirectory = Directory.systemTemp.createTempSync('obtainx-tar-');
      final decodedPath = '${temporaryDirectory.path}/archive.tar';
      final output = archive.OutputFileStream(decodedPath);
      try {
        if (gzip) {
          const archive.GZipDecoder().decodeStream(input, output);
        } else if (bzip) {
          archive.BZip2Decoder().decodeStream(input, output);
        } else {
          archive.XZDecoder().decodeStream(input, output);
        }
      } finally {
        output.closeSync();
      }
      decodedInput = archive.InputFileStream(decodedPath);
    }
    final contents = archive.TarDecoder().decodeStream(decodedInput ?? input);
    final outputDirectory = Directory(destination).absolute;
    outputDirectory.createSync(recursive: true);
    final root = outputDirectory.uri;
    for (final entry in contents) {
      if (!entry.isFile || entry.isSymbolicLink) continue;
      final target = root.resolve(entry.name.replaceAll('\\', '/'));
      if (target.scheme != root.scheme ||
          target.host != root.host ||
          !target.path.startsWith(root.path)) {
        throw const FormatException('Archive entry is outside its destination');
      }
      final file = File.fromUri(target);
      file.parent.createSync(recursive: true);
      final output = archive.OutputFileStream(file.path);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
    }
  } finally {
    decodedInput?.closeSync();
    input.closeSync();
    temporaryDirectory?.deleteSync(recursive: true);
  }
}
