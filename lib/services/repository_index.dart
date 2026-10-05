import 'dart:convert';
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

  Element? findApplication(String idOrName) =>
      _findByIdOrName(byId, byName, idOrName);
}

/// Exact id, then exact case-insensitive name, then the first name containing
/// [idOrName]. Shared by both index formats so they resolve apps alike.
T? _findByIdOrName<T>(
  Map<String, T> byId,
  Map<String, T> byName,
  String idOrName,
) {
  final exact = byId[idOrName] ?? byName[idOrName.toLowerCase()];
  if (exact != null) return exact;
  final query = idOrName.toLowerCase();
  for (final entry in byName.entries) {
    if (entry.key.contains(query)) return entry.value;
  }
  return null;
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

/// One release in an F-Droid `index-v2.json`.
class RepositoryIndexV2Release {
  const RepositoryIndexV2Release({
    required this.versionName,
    required this.versionCode,
    required this.apkName,
    this.size,
    this.nativecode = const [],
    this.added,
    this.releaseChannels = const [],
  });

  final String versionName;
  final int versionCode;

  /// The file's path below the repo directory.
  final String apkName;
  final int? size;

  /// ABIs the APK has native code for; empty means architecture-universal.
  final List<String> nativecode;
  final DateTime? added;

  /// fdroidserver puts builds newer than the app's suggested version code in
  /// the `Beta` channel; stable builds have no channel.
  final List<String> releaseChannels;
}

/// One app in an F-Droid `index-v2.json`, its releases newest first.
class RepositoryIndexV2Application {
  const RepositoryIndexV2Application({
    required this.id,
    required this.name,
    this.summary = '',
    this.description = '',
    this.author,
    this.changelog,
    this.iconPath,
    this.releases = const [],
  });

  final String id;
  final String name;
  final String summary;
  final String description;
  final String? author;
  final String? changelog;

  /// The icon's path below the repo directory.
  final String? iconPath;
  final List<RepositoryIndexV2Release> releases;
}

/// A parsed `index-v2.json`, with the same app lookup as [RepositoryIndex].
class RepositoryIndexV2 {
  RepositoryIndexV2({
    required this.url,
    this.repoName,
    required this.applications,
  }) {
    for (final application in applications) {
      byId.putIfAbsent(application.id, () => application);
      byName.putIfAbsent(application.name.toLowerCase(), () => application);
    }
  }

  /// Where the index was served from. APK and icon paths are relative to its
  /// directory.
  final String url;
  final String? repoName;
  final List<RepositoryIndexV2Application> applications;
  final Map<String, RepositoryIndexV2Application> byId = {};
  final Map<String, RepositoryIndexV2Application> byName = {};

  RepositoryIndexV2Application? findApplication(String idOrName) =>
      _findByIdOrName(byId, byName, idOrName);
}

final _parsedV2Indexes = Expando<Future<RepositoryIndexV2?>>();

/// Parses an `index-v2.json` [response] off the UI isolate, once per response.
/// Completes with null when the body isn't a v2 index (for example an HTML
/// error page served with status 200).
Future<RepositoryIndexV2?> parseRepositoryIndexV2(Response response) {
  final bytes = response.bodyBytes;
  final url = (response.request?.url ?? Uri()).toString();
  return _parsedV2Indexes[response] ??= Isolate.run(
    () => _repositoryIndexV2FromBytes(bytes, url),
    debugName: 'repository-index-v2',
  );
}

RepositoryIndexV2? _repositoryIndexV2FromBytes(Uint8List bytes, String url) {
  final Object? decoded;
  try {
    // JSON is UTF-8 whatever charset the server declares.
    decoded = utf8.decoder.fuse(json.decoder).convert(bytes);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final packages = decoded['packages'];
  if (packages is! Map) return null;
  final applications = <RepositoryIndexV2Application>[];
  packages.forEach((id, package) {
    if (id is! String || package is! Map) return;
    final metadata = package['metadata'] is Map
        ? package['metadata'] as Map
        : const {};
    final releases = <RepositoryIndexV2Release>[];
    final versions = package['versions'];
    if (versions is Map) {
      for (final version in versions.values) {
        if (version is! Map) continue;
        final file = version['file'];
        final manifest = version['manifest'];
        if (file is! Map || manifest is! Map) continue;
        final versionName = manifest['versionName']?.toString();
        final versionCode = manifest['versionCode'];
        final apkName = _indexV2FilePath(file);
        if (versionName == null || versionCode is! int || apkName == null) {
          continue;
        }
        final size = file['size'];
        releases.add(
          RepositoryIndexV2Release(
            versionName: versionName,
            versionCode: versionCode,
            apkName: apkName,
            size: size is int ? size : null,
            nativecode: _indexV2StringList(manifest['nativecode']),
            added: _indexV2Timestamp(version['added']),
            releaseChannels: _indexV2StringList(version['releaseChannels']),
          ),
        );
      }
    }
    releases.sort((a, b) => b.versionCode.compareTo(a.versionCode));
    applications.add(
      RepositoryIndexV2Application(
        id: id,
        name: _indexV2Localized(metadata['name'], _nonEmptyString) ?? id,
        summary: _indexV2Localized(metadata['summary'], _nonEmptyString) ?? '',
        description:
            _indexV2Localized(metadata['description'], _nonEmptyString) ?? '',
        author: _indexV2Localized(metadata['authorName'], _nonEmptyString),
        changelog: _indexV2Localized(metadata['changelog'], _nonEmptyString),
        iconPath: _indexV2Localized(metadata['icon'], _indexV2FilePath),
        releases: releases,
      ),
    );
  });
  final repo = decoded['repo'];
  return RepositoryIndexV2(
    url: url,
    repoName: repo is Map
        ? _indexV2Localized(repo['name'], _nonEmptyString)
        : null,
    applications: applications,
  );
}

/// index-v2 localizes text and files as a locale map (`{"en-US": …}`). Picks
/// English, then the first usable value; a plain value is used as it is.
T? _indexV2Localized<T>(Object? value, T? Function(Object? value) read) {
  if (value is! Map) return read(value);
  for (final locale in const ['en-US', 'en']) {
    final picked = read(value[locale]);
    if (picked != null) return picked;
  }
  for (final candidate in value.values) {
    final picked = read(candidate);
    if (picked != null) return picked;
  }
  return null;
}

String? _nonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A file entry's path below the repo directory (fdroidserver writes it with
/// a leading `/`).
String? _indexV2FilePath(Object? entry) {
  final name = entry is Map ? entry['name'] : null;
  if (name is! String) return null;
  final path = name.startsWith('/') ? name.substring(1) : name;
  return path.isEmpty ? null : path;
}

List<String> _indexV2StringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

/// fdroidserver writes milliseconds since the epoch; seconds and ISO strings
/// are accepted too.
DateTime? _indexV2Timestamp(Object? added) {
  if (added is int) {
    return DateTime.fromMillisecondsSinceEpoch(
      added > 1e12 ? added : added * 1000,
    );
  }
  if (added is String) return DateTime.tryParse(added);
  return null;
}
