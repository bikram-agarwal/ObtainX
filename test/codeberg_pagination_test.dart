import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/codeberg.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _release(String tag, DateTime publishedAt) => {
  'tag_name': tag,
  'name': tag,
  'body': '',
  'prerelease': false,
  'draft': false,
  'published_at': publishedAt.toIso8601String(),
  'assets': [
    <String, dynamic>{
      'name': 'app.apk',
      'url': 'https://codeberg.org/owner/repo/releases/download/$tag/app.apk',
      'browser_download_url':
          'https://codeberg.org/owner/repo/releases/download/$tag/app.apk',
    },
  ],
};

/// Forgejo's release list, 50 a page: a page of nightlies, then a short page
/// with four more nightlies and the stable release.
class _PagedForgejoApi extends GitHub {
  _PagedForgejoApi() : super(hostChanged: true);

  final List<Uri> requested = <Uri>[];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    final Uri uri = Uri.parse(url);
    requested.add(uri);
    final int page = int.parse(uri.queryParameters['page'] ?? '1');
    final DateTime newest = DateTime(2026, 11, 3);
    final List<Map<String, dynamic>> releases = page == 1
        ? [
            for (var i = 0; i < 50; i++)
              _release('nightly-$i', newest.subtract(Duration(days: i))),
          ]
        : [
            for (var i = 50; i < 54; i++)
              _release('nightly-$i', newest.subtract(Duration(days: i))),
            _release('v0.7.2', DateTime(2026, 9, 4)),
          ];
    return Response(jsonEncode(releases), 200);
  }
}

// v1.7.5 sync S3 (upstream #3533): Forgejo ignores per_page and serves 30
// releases a page, so Codeberg reads every page before filtering.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const deviceChannel = MethodChannel('dev.fluttercommunity.plus/device_info');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => Directory.systemTemp.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      deviceChannel,
      (_) async => {
        'version': {
          'codename': 'REL',
          'incremental': '',
          'release': '17',
          'sdkInt': 37,
        },
        for (final key in [
          'board',
          'bootloader',
          'brand',
          'device',
          'display',
          'fingerprint',
          'hardware',
          'host',
          'id',
          'manufacturer',
          'model',
          'product',
          'tags',
          'type',
        ])
          key: '',
        for (final key in [
          'time',
          'freeDiskSize',
          'totalDiskSize',
          'physicalRamSize',
          'availableRamSize',
        ])
          key: 0,
        'isPhysicalDevice': false,
        'isLowRamDevice': false,
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      deviceChannel,
      null,
    );
  });

  test('Codeberg reads every release page with limit/page', () async {
    final _PagedForgejoApi api = _PagedForgejoApi();
    final details = await Codeberg(apiHelper: api)
        .getLatestAPKDetails('https://codeberg.org/owner/repo', {
          'fallbackToOlderReleases': true,
          'sortMethodChoice': 'date',
          'filterReleaseTitlesByRegEx': '^nightly',
          'invertReleaseTitlesFilter': true,
          'updateHealthArchived': 'off',
        });

    expect(details.version, 'v0.7.2');
    expect(api.requested.map((uri) => uri.path).toSet(), {
      '/api/v1/repos/owner/repo/releases',
    });
    expect(api.requested.map((uri) => uri.queryParameters).toList(), [
      {'limit': '50', 'page': '1'},
      {'limit': '50', 'page': '2'},
    ]);
  });
}
