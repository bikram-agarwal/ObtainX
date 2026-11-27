// GitHub release selection from the v1.7.4 sync: the /releases/latest
// fallback (fork PR #375, folded in with its 4 fixes), drafts (#3447),
// inverted title/notes filters (#3337), the filtered-out count and the
// throttled archived check (update health, D8).
// Platform test doubles use the interfaces supplied by the existing plugins.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repoPath = '/repos/owner/app';
const _releasesPath = '$_repoPath/releases';
const _latestPath = '$_releasesPath/latest';
const _standardUrl = 'https://github.com/owner/app';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _Device extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    return BaseDeviceInfo({
      'version': {
        'sdkInt': 35,
        'release': '15',
        'codename': 'REL',
        'incremental': '1',
        'previewSdkInt': 0,
        'securityPatch': '',
        'baseOS': '',
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
      ])
        key: '',
      'type': 'user',
      'supported32BitAbis': ['armeabi-v7a'],
      'supported64BitAbis': ['arm64-v8a'],
      'supportedAbis': ['arm64-v8a', 'armeabi-v7a'],
      'isPhysicalDevice': true,
      'freeDiskSize': 1,
      'totalDiskSize': 1,
      'physicalRamSize': 4096,
      'availableRamSize': 2048,
      'time': 0,
      'isLowRamDevice': false,
      'systemFeatures': <String>[],
    });
  }
}

/// Answers API requests by path; anything else is a 404.
class _GitHub extends GitHub {
  _GitHub(this.responses);
  final Map<String, Response> responses;
  final List<String> requestedPaths = [];

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    final String path = Uri.parse(url).path;
    requestedPaths.add(path);
    return responses[path] ?? Response('{"message":"Not Found"}', 404);
  }
}

Map<String, dynamic> _release(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  String? name,
  String body = '',
  required DateTime published,
}) => {
  'tag_name': tag,
  'name': name ?? tag,
  'prerelease': prerelease,
  'draft': draft,
  'body': body,
  'published_at': published.toUtc().toIso8601String(),
  'assets': [
    {
      'name': 'app-$tag.apk',
      'browser_download_url':
          'https://github.com/owner/app/releases/download/$tag/app-$tag.apk',
      'url': 'https://api.github.com/repos/owner/app/releases/assets/$tag',
      'size': 1024,
      'updated_at': published.toUtc().toIso8601String(),
    },
  ],
};

Response _json(Object body) => Response(jsonEncode(body), 200);

final DateTime _now = DateTime.now();
DateTime _daysAgo(int days) => _now.subtract(Duration(days: days));

Map<String, dynamic> _settings([Map<String, dynamic> extra = const {}]) => {
  'sortMethodChoice': 'date',
  ...extra,
};

void main() {
  late Directory directory;
  late PathProviderPlatform previousPaths;
  late DeviceInfoPlatform previousDevice;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    directory = Directory.systemTemp.createTempSync('github_selection_');
    previousPaths = PathProviderPlatform.instance;
    previousDevice = DeviceInfoPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    DeviceInfoPlatform.instance = _Device();
  });

  tearDown(() {
    PathProviderPlatform.instance = previousPaths;
    DeviceInfoPlatform.instance = previousDevice;
    directory.deleteSync(recursive: true);
  });

  group('/releases/latest fallback (fork PR #375)', () {
    final prereleasePage = _json([
      _release('v2.0-beta3', prerelease: true, published: _daysAgo(10)),
      _release('v2.0-beta2', prerelease: true, published: _daysAgo(20)),
      _release('v2.0-beta1', prerelease: true, published: _daysAgo(30)),
    ]);

    test('picks the latest stable release off the first page', () async {
      final source = _GitHub({
        _releasesPath: prereleasePage,
        _latestPath: _json(_release('v1.0', published: _daysAgo(400))),
      });
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings(),
      );
      expect(details.version, 'v1.0');
      expect(source.requestedPaths, contains(_latestPath));
      expect(details.rawReleaseTitleCandidates.last, 'v1.0');
    });

    test('runs /latest through the minimum-age passes', () async {
      final source = _GitHub({
        _releasesPath: prereleasePage,
        _latestPath: _json(_release('v1.0', published: _daysAgo(1))),
      });
      // Too young for the first pass; the second keeps it, so the update
      // check can hold it back until it ages.
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings({'minimumUpdateAgeDays': '7'}),
      );
      expect(details.version, 'v1.0');
    });

    test('is not asked when a stable release is on the page', () async {
      final source = _GitHub({
        _releasesPath: _json([
          _release('v2.0-beta1', prerelease: true, published: _daysAgo(10)),
          _release('v1.0', published: _daysAgo(400)),
        ]),
        _latestPath: _json(_release('v1.0', published: _daysAgo(400))),
      });
      await expectLater(
        source.getLatestAPKDetails(
          _standardUrl,
          _settings({'filterReleaseTitlesByRegEx': 'nomatch'}),
        ),
        throwsA(isA<NoReleasesError>()),
      );
      expect(source.requestedPaths, isNot(contains(_latestPath)));
    });

    test('is not asked when prereleases are included', () async {
      final source = _GitHub({_releasesPath: prereleasePage});
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings({'includePrereleases': true}),
      );
      expect(details.version, 'v2.0-beta3');
      expect(source.requestedPaths, isNot(contains(_latestPath)));
    });

    test('no published release is still "no releases"', () async {
      final source = _GitHub({_releasesPath: prereleasePage});
      await expectLater(
        source.getLatestAPKDetails(_standardUrl, _settings()),
        throwsA(isA<NoReleasesError>()),
      );
      expect(source.requestedPaths, contains(_latestPath));
    });

    test('a rate limit on /latest is reported as one', () async {
      final source = _GitHub({
        _releasesPath: prereleasePage,
        _latestPath: Response(
          '{"message":"API rate limit exceeded"}',
          403,
          headers: {'x-ratelimit-remaining': '0'},
        ),
      });
      await expectLater(
        source.getLatestAPKDetails(_standardUrl, _settings()),
        throwsA(isA<RateLimitError>()),
      );
    });
  });

  group('release filters', () {
    final page = _json([
      _release('v2.0', name: 'v2.0 beta', published: _daysAgo(10)),
      _release('v1.9', published: _daysAgo(20)),
      _release('v1.8', published: _daysAgo(30)),
    ]);

    test('an inverted title filter skips matching releases', () async {
      final details = await _GitHub({_releasesPath: page}).getLatestAPKDetails(
        _standardUrl,
        _settings({
          'filterReleaseTitlesByRegEx': 'beta',
          'invertReleaseTitlesFilter': true,
          'fallbackToOlderReleases': true,
        }),
      );
      expect(details.version, 'v1.9');
      expect(details.newerReleasesFilteredOut, 1);
    });

    test('a normal title filter keeps matching releases', () async {
      final details = await _GitHub({_releasesPath: page}).getLatestAPKDetails(
        _standardUrl,
        _settings({
          'filterReleaseTitlesByRegEx': 'beta',
          'fallbackToOlderReleases': true,
        }),
      );
      expect(details.version, 'v2.0');
      expect(details.newerReleasesFilteredOut, 0);
    });

    test('an inverted notes filter skips matching releases', () async {
      final details =
          await _GitHub({
            _releasesPath: _json([
              _release('v2.0', body: 'nightly', published: _daysAgo(10)),
              _release('v1.9', body: 'stable', published: _daysAgo(20)),
            ]),
          }).getLatestAPKDetails(
            _standardUrl,
            _settings({
              'filterReleaseNotesByRegEx': 'nightly',
              'invertReleaseNotesFilter': true,
              'fallbackToOlderReleases': true,
            }),
          );
      expect(details.version, 'v1.9');
    });

    test('the filtered-out count is that of the minimum-age pass', () async {
      // v3.0 is too young; the first pass skips it (not a filter) and the
      // filtered v2.0 before reaching v1.9.
      final details =
          await _GitHub({
            _releasesPath: _json([
              _release('v3.0', published: _daysAgo(1)),
              _release('v2.0', name: 'v2.0 beta', published: _daysAgo(20)),
              _release('v1.9', published: _daysAgo(30)),
            ]),
          }).getLatestAPKDetails(
            _standardUrl,
            _settings({
              'filterReleaseTitlesByRegEx': 'beta',
              'invertReleaseTitlesFilter': true,
              'fallbackToOlderReleases': true,
              'minimumUpdateAgeDays': '7',
            }),
          );
      expect(details.version, 'v1.9');
      expect(details.newerReleasesFilteredOut, 1);
    });

    test('drafts are picked only when included', () async {
      final drafts = _json([
        _release('v3.0', draft: true, published: _daysAgo(1)),
        _release('v2.0', published: _daysAgo(10)),
      ]);
      expect(
        (await _GitHub({
          _releasesPath: drafts,
        }).getLatestAPKDetails(_standardUrl, _settings())).version,
        'v2.0',
      );
      expect(
        (await _GitHub({_releasesPath: drafts}).getLatestAPKDetails(
          _standardUrl,
          _settings({'includeDrafts': true}),
        )).version,
        'v3.0',
      );
    });

    test('the drafts switch is paired with verifyLatestTag', () {
      final items = GitHub().additionalSourceAppSpecificSettingFormItems
          .expand((row) => row)
          .toList();
      final keys = items.map((item) => item.key).toList();
      expect(keys.where((key) => key == 'verifyLatestTag'), hasLength(1));
      expect(keys, contains('includeDrafts'));
      expect(
        keys,
        isNot(
          containsAll([
            'invertReleaseTitlesFilter',
            'invertReleaseNotesFilter',
          ]),
        ),
      );
      final GeneratedFormSwitch draftsSwitch = items
          .whereType<GeneratedFormSwitch>()
          .singleWhere((item) => item.key == 'includeDrafts');
      expect(draftsSwitch.labelTooltip, isNotNull);
      expect(draftsSwitch.labelTooltip, isNotEmpty);

      final GeneratedFormTextField titleRegexField = items
          .whereType<GeneratedFormTextField>()
          .singleWhere((item) => item.key == 'filterReleaseTitlesByRegEx');
      final GeneratedFormTextField notesRegexField = items
          .whereType<GeneratedFormTextField>()
          .singleWhere((item) => item.key == 'filterReleaseNotesByRegEx');
      expect(titleRegexField.invertToggleKey, 'invertReleaseTitlesFilter');
      expect(notesRegexField.invertToggleKey, 'invertReleaseNotesFilter');

      final Map<String, dynamic> defaults = getDefaultValuesFromFormItems(
        GitHub().additionalSourceAppSpecificSettingFormItems,
      );
      expect(defaults['invertReleaseTitlesFilter'], isFalse);
      expect(defaults['invertReleaseNotesFilter'], isFalse);
    });
  });

  group('archived repository check (update health)', () {
    Map<String, Response> responses(DateTime published, {bool? archived}) => {
      _releasesPath: _json([_release('v1.0', published: published)]),
      _repoPath: _json({'archived': archived ?? true}),
    };

    App previous({bool? isArchived, int? checkedAt}) => App(
      id: 'org.example.app',
      url: _standardUrl,
      author: 'owner',
      name: 'app',
      latestVersion: 'v1.0',
      preferredApkIndex: 0,
      additionalSettings: {repoArchivedCheckedAtKey: ?checkedAt},
      isArchived: isArchived,
    );

    test('reads the flag once the latest release looks stale', () async {
      final source = _GitHub(responses(_daysAgo(400)));
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings(),
      );
      expect(details.isArchived, isTrue);
      expect(source.requestedPaths, contains(_repoPath));
      final stamped = source.postProcessApp(previous());
      expect(stamped.additionalSettings[repoArchivedCheckedAtKey], isA<int>());
    });

    test('costs no request while the release is fresh', () async {
      final source = _GitHub(responses(_daysAgo(10)));
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings(),
      );
      expect(details.isArchived, isNull);
      expect(source.requestedPaths, isNot(contains(_repoPath)));
      final app = previous();
      expect(source.postProcessApp(app), same(app));
    });

    test('reuses a flag read within 7 days', () async {
      final checkedAt = _daysAgo(3).millisecondsSinceEpoch;
      final source = _GitHub(responses(_daysAgo(400)))
        ..previouslyCheckedApp = previous(isArchived: true);
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings({repoArchivedCheckedAtKey: checkedAt}),
      );
      expect(details.isArchived, isNull);
      expect(source.requestedPaths, isNot(contains(_repoPath)));
    });

    test('reads it again after 7 days', () async {
      final source = _GitHub(responses(_daysAgo(400), archived: false));
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings({
          repoArchivedCheckedAtKey: _daysAgo(8).millisecondsSinceEpoch,
        }),
      );
      expect(details.isArchived, isFalse);
    });

    test('rechecks an archived app even with a fresh release', () async {
      final source = _GitHub(responses(_daysAgo(10), archived: false))
        ..previouslyCheckedApp = previous(isArchived: true);
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings(),
      );
      expect(details.isArchived, isFalse);
    });

    test('reuses the rename check response', () async {
      final source = _GitHub(responses(_daysAgo(10)));
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings({'checkRepoRename': true}),
      );
      expect(details.isArchived, isTrue);
      expect(source.requestedPaths.where((path) => path == _repoPath), [
        _repoPath,
      ]);
    });

    test('sends nothing when the archived heuristic is off', () async {
      final source = _GitHub(responses(_daysAgo(400)));
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings({'updateHealthArchived': 'off'}),
      );
      expect(details.isArchived, isNull);
      expect(source.requestedPaths, isNot(contains(_repoPath)));
    });

    test('a failed read keeps the stored flag', () async {
      final source = _GitHub({
        _releasesPath: _json([_release('v1.0', published: _daysAgo(400))]),
        _repoPath: Response('{"message":"Server Error"}', 500),
      });
      final details = await source.getLatestAPKDetails(
        _standardUrl,
        _settings(),
      );
      expect(details.isArchived, isNull);
      final app = previous();
      expect(source.postProcessApp(app), same(app));
    });
  });
}
