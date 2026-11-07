import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/source_provider.dart';

// What ShizuStore's "Add to Obtainium" button sends:
// "obtainium://add/" + URLEncoder.encode(url, "UTF-8").
const String _encodedLink =
    'obtainium://add/https%3A%2F%2Fgithub.com%2Faistra0528%2FHail';
const String _url = 'https://github.com/aistra0528/Hail';

// These lines are upstream Obtainium's, kept identical so that a sync merges
// them instead of conflicting. A sync that resolved home.dart to this fork's
// side lost them once, so this fails if they go again. interpretLink is a
// closure, which a test can't call, so it reads the source. If upstream changes
// them, take its version here too, and in _dataIn.
const String _upstreamLines = r'''
    Future<void> interpretLink(Uri uri) async {
      final action = uri.host;
      final data =
          uri.queryParameters['url'] ??
          (uri.path.length > 1
              ? Uri.decodeComponent(uri.path.substring(1))
              : '');
      try {
        if (action == 'add') {
''';

/// What [_upstreamLines] read from a [link], which `AppLinks` hands over parsed.
String _dataIn(String link) {
  final Uri uri = Uri.parse(link);
  return uri.queryParameters['url'] ??
      (uri.path.length > 1 ? Uri.decodeComponent(uri.path.substring(1)) : '');
}

void main() {
  test('interpretLink reads an add link with upstream\'s lines', () {
    final String source = File('lib/pages/home.dart').readAsStringSync();

    expect(source, contains(_upstreamLines));
    expect(
      source,
      contains("if (action == 'add') {\n          await handleAddUrl(data);"),
    );
  });

  test('an encoded URL is decoded', () {
    expect(_dataIn(_encodedLink), _url);
  });

  test('a decoded URL finds the source it belongs to', () {
    final String url = _dataIn(_encodedLink);
    final AppSource source = SourceProvider().getSource(url);

    expect(source, isA<GitHub>());
    expect(source.standardizeUrl(url), _url);
  });

  test('what an encoded URL holds comes through whole', () {
    expect(
      _dataIn('obtainium://add/https%3A%2F%2Fa.b%2Fc%3Fd%3D1%26e%3D2%23f'),
      'https://a.b/c?d=1&e=2#f',
    );
    expect(
      _dataIn('obtainium://add/https%3A%2F%2Fa.b%2F%E6%97%A5%E6%9C%AC'),
      'https://a.b/日本',
    );
  });

  test('a URL sent as it is stays as it is', () {
    expect(_dataIn('obtainium://add/$_url'), _url);
  });

  test('a link with no URL gives nothing', () {
    expect(_dataIn('obtainium://add'), '');
    expect(_dataIn('obtainium://add/'), '');
  });

  test('a url query parameter is read, ahead of the path', () {
    expect(
      _dataIn('obtainium://add?url=https%3A%2F%2Fgithub.com%2Fa%2Fb'),
      'https://github.com/a/b',
    );
    expect(
      _dataIn('obtainium://add/https%3A%2F%2Fa.b%2Fc?url=https://d.e/f'),
      'https://d.e/f',
    );
  });

  test('a URL is decoded once, so what it encodes itself stays encoded', () {
    expect(
      _dataIn('obtainium://add/https%3A%2F%2Fa.b%2Fc%252Fd'),
      'https://a.b/c%2Fd',
    );
  });

  test('escapes that are not UTF-8 throw', () {
    for (final String link in <String>[
      'obtainium://add/https://a.b/caf%E9',
      'obtainium://add/%C3%28',
      'obtainium://add/https://a.b/c?d=%FF',
      'obtainium://add?url=%FF',
    ]) {
      expect(() => _dataIn(link), throwsFormatException, reason: link);
    }
  });
}
