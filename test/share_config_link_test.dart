import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/pages/home.dart';
import 'package:obtainium/providers/source_provider.dart';

void main() {
  test('a shared configuration link leaves out per-app tokens', () {
    const App app = App(
      id: 'org.example.app',
      url: 'https://git.example.org/owner/app',
      author: 'owner',
      name: 'App',
      latestVersion: '1.0',
      preferredApkIndex: 0,
      additionalSettings: {
        'github-creds': 'ghp_secret',
        'forgejo-creds': 'forgejo-secret',
        'apkFilterRegEx': r'arm64',
      },
      overrideSource: 'Forgejo',
    );

    final Map<String, dynamic> shared =
        jsonDecode(linkJson(Uri.parse(appConfigLink(app))))
            as Map<String, dynamic>;
    final Map<String, dynamic> settings =
        jsonDecode(shared['additionalSettings'] as String)
            as Map<String, dynamic>;

    expect(settings.keys, isNot(contains('github-creds')));
    expect(settings.keys, isNot(contains('forgejo-creds')));
    expect(settings['apkFilterRegEx'], 'arm64');
    expect(shared['url'], app.url);
    expect(shared['overrideSource'], 'Forgejo');
    // The app keeps its tokens; only the link goes without.
    expect(app.additionalSettings['github-creds'], 'ghp_secret');
  });
}
