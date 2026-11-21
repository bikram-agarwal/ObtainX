import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/home.dart';

// What Remember's "Track updates via ObtainX" row sends.
const String _rememberLink =
    'obtainium://app/%7B%22id%22%3A%22dev.bikram.remember.gh%22%2C%22url%22%3A'
    '%22https%3A%2F%2Fgithub.com%2Fbikram-agarwal%2FRemember%22%2C%22author%22'
    '%3A%22bikram-agarwal%22%2C%22name%22%3A%22Remember%22%2C%22preferredApkIndex'
    '%22%3A0%2C%22additionalSettings%22%3A%22%7B%5C%22apkFilterRegEx%5C%22%3A%5C'
    '%22-github%5C%5C%5C%5C.apk%24%5C%22%7D%22%7D';

/// A link the way "Share app configuration as HTML link" builds each one.
String _sharedLink(Map<String, dynamic> app) =>
    'https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/'
    '${Uri.encodeComponent(jsonEncode(app))}';

/// The payload the link import reads, decoded as `interpretLink` does.
Object? _payloadOf(Uri link) =>
    jsonDecode(Uri.decodeComponent(link.path.substring(1)));

List<Object?> _idsIn(Uri link) => (_payloadOf(link) as List)
    .map((Object? app) => (app as Map)['id'])
    .toList();

void main() {
  test('a pasted app link is taken as it is', () {
    final Uri? link = linkImportIn('  $_rememberLink\n');

    expect(link?.host, 'app');
    final Map<String, dynamic> app = _payloadOf(link!) as Map<String, dynamic>;
    expect(app['id'], 'dev.bikram.remember.gh');
    expect(jsonDecode(app['additionalSettings'] as String), {
      'apkFilterRegEx': r'-github\.apk$',
    });
  });

  test('a shared configuration link is unwrapped from its redirect page', () {
    final Uri? link = linkImportIn(
      _sharedLink({
        'id': 'a.b',
        'url': 'https://github.com/a/b',
        'additionalSettings': jsonEncode({'apkFilterRegEx': 'x?&y#z'}),
      }),
    );

    expect(link?.host, 'app');
    final Map<String, dynamic> app = _payloadOf(link!) as Map<String, dynamic>;
    expect(app['id'], 'a.b');
    expect(jsonDecode(app['additionalSettings'] as String), {
      'apkFilterRegEx': 'x?&y#z',
    });
  });

  test('several links, as sharing several apps sends them, open as one '
      'import', () {
    final String apps = Uri.encodeComponent(
      jsonEncode([
        {'id': 'c.d', 'url': 'https://github.com/c/d'},
        {'id': 'e.f', 'url': 'https://github.com/e/f'},
      ]),
    );
    final String pasted =
        '${_sharedLink({'id': 'a.b', 'url': 'https://github.com/a/b'})}\n\n'
        '$_rememberLink\n\n'
        'obtainium://apps/$apps\n';

    final Uri? link = linkImportIn(pasted);

    expect(link?.host, 'apps');
    expect(_idsIn(link!), ['a.b', 'dev.bikram.remember.gh', 'c.d', 'e.f']);
  });

  test('the JSON a link carries, or an export, is taken too', () {
    final Uri? app = linkImportIn(
      '{\n  "id": "a.b",\n  "url": "https://github.com/a/b"\n}',
    );
    expect(app?.host, 'app');
    expect((_payloadOf(app!) as Map)['id'], 'a.b');

    final Uri? list = linkImportIn(
      '[{"id": "a.b", "url": "https://github.com/a/b"}]',
    );
    expect(list?.host, 'apps');
    expect(_idsIn(list!), ['a.b']);

    // Only an export's apps: its ObtainX-wide settings are never part of a
    // link import.
    // Each app keeps its own settings.
    final Map<String, dynamic> exported = {
      'id': 'a.b',
      'url': 'https://github.com/a/b',
      'additionalSettings': jsonEncode({'apkFilterRegEx': r'-github\.apk$'}),
    };
    final Uri? export = linkImportIn(
      jsonEncode({
        'apps': [exported],
        'settings': {'theme': 1},
      }),
    );
    expect(export?.host, 'apps');
    expect(_payloadOf(export!), [exported]);
  });

  test('anything else is left to the URL list', () {
    expect(linkImportIn('https://github.com/a/b'), isNull);
    // One URL among the links makes the whole text a URL list, whose check
    // then points at the line that isn't a URL.
    expect(linkImportIn('$_rememberLink\nhttps://github.com/a/b'), isNull);
    // Half a link, or half a JSON.
    expect(
      linkImportIn(_rememberLink.substring(0, _rememberLink.length - 10)),
      isNull,
    );
    expect(linkImportIn('{"id": "a.b"'), isNull);
    expect(linkImportIn('obtainium://app/'), isNull);
    expect(linkImportIn('obtainium://app'), isNull);
    // "add" links carry a URL, which the list already takes as it is.
    expect(linkImportIn('obtainium://add/https://github.com/a/b'), isNull);
    expect(linkImportIn(''), isNull);
  });
}
