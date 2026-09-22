import 'dart:isolate';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' show Response;

/// Read-only repository DOM and lookup tables, shared by apps using one response.
class RepositoryIndex {
  RepositoryIndex(String body) : document = parse(body) {
    applications = document.querySelectorAll('application');
    for (final application in applications) {
      final id = application.attributes['id'];
      if (id != null) byId.putIfAbsent(id, () => application);
      final name = application.querySelector('name')?.innerHtml.toLowerCase();
      if (name != null) byName.putIfAbsent(name, () => application);
    }
  }

  final Document document;
  late final List<Element> applications;
  final Map<String, Element> byId = {};
  final Map<String, Element> byName = {};

  Element? findApplication(String idOrName) {
    final exact = byId[idOrName] ?? byName[idOrName.toLowerCase()];
    if (exact != null) return exact;
    final query = idOrName.toLowerCase();
    for (final entry in byName.entries) {
      if (entry.key.contains(query)) return entry.value;
    }
    return null;
  }
}

// Weak keys let the response and its parsed index be collected after a session.
final _parsedIndexes = Expando<Future<RepositoryIndex>>();

Future<RepositoryIndex> parseRepositoryIndex(Response response) {
  return _parsedIndexes[response] ??= _parseOffIsolate(
    response.bodyBytes,
    response.headers,
  );
}

Future<RepositoryIndex> _parseOffIsolate(
  Uint8List bytes,
  Map<String, String> headers,
) {
  return Isolate.run(
    // Response.body performs character decoding synchronously. Keep that large
    // allocation in the worker too, preserving the HTTP charset rules.
    () => RepositoryIndex(Response.bytes(bytes, 200, headers: headers).body),
    debugName: 'repository-index',
  );
}
