import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Serializes large backups without building their JSON text on the UI isolate.
Future<Uint8List> encodeJsonBytesOffIsolate(Object? value, {String? indent}) {
  return Isolate.run(() {
    final bytes = JsonUtf8Encoder(indent).convert(value);
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }, debugName: 'json-encode');
}

Future<Object?> readJsonFileOffIsolate(String path) {
  return Isolate.run(() {
    final content = File(path).readAsStringSync();
    return content.trim().isEmpty ? null : jsonDecode(content);
  }, debugName: 'json-read');
}

/// The caller serializes writes to [path]; the previous file survives a failure.
Future<void> writeJsonFileOffIsolate(String path, Object value) {
  return Isolate.run(() {
    final temporary = File('$path.tmp');
    temporary.writeAsBytesSync(JsonUtf8Encoder('  ').convert(value));
    temporary.renameSync(path);
  }, debugName: 'json-write');
}
