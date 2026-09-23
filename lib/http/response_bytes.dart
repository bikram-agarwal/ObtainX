import 'dart:async';
import 'dart:typed_data';

const sourceConnectionTimeout = Duration(seconds: 30);
const sourceResponseTimeout = Duration(seconds: 45);

/// Stops the subscription at a byte boundary, even when Range is ignored.
/// Does not retain or serialize the HTTP transport's chunk layout.
Future<Uint8List> readBytePrefix(
  Stream<List<int>> stream,
  int limit, {
  Duration idleTimeout = sourceResponseTimeout,
}) async {
  if (limit <= 0) throw ArgumentError.value(limit, 'limit');
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(idleTimeout)) {
    final remaining = limit - bytes.length;
    bytes.add(chunk.length > remaining ? chunk.sublist(0, remaining) : chunk);
    if (bytes.length == limit) break;
  }
  return bytes.takeBytes();
}
