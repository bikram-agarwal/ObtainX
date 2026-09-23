import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

App _app() {
  return const App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: '1.5.5 (4D91B33C)',
    latestVersion: '1.5.5-ced5040c',
    preferredApkIndex: 0,
    additionalSettings: {'versionDetection': 'auto'},
  );
}

class _GitHub extends GitHub {
  Response response;
  bool failNetwork = false;
  final requests = <String>[];

  _GitHub(this.response);

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    requests.add(url);
    if (failNetwork) throw const SocketException('Offline');
    return response;
  }
}

Response _comparison(String status) {
  return Response(
    jsonEncode({
      'status': status,
      'base_commit': {'sha': '4d91b33c0000000000000000000000000000000000'},
      // Page 2 may be empty even when the head is ahead of the base.
      'commits': [],
    }),
    200,
  );
}

App _expireRetry(App app) {
  return app.copyWith(
    additionalSettings: {
      ...app.additionalSettings,
      sourceBuildComparisonKey: {
        ...app.additionalSettings[sourceBuildComparisonKey] as Map,
        'retryAfter': 0,
      },
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final (status, relation) in [
    ('ahead', VersionRelation.older),
    ('behind', VersionRelation.newer),
    ('identical', VersionRelation.same),
    ('diverged', VersionRelation.unknown),
  ]) {
    test(
      'empty second page preserves $status and caches it after reload',
      () async {
        final source = _GitHub(_comparison(status));
        final resolved = await source.resolveVersionComparison(_app());
        expect(versionDecisionForApp(resolved).relation, relation);
        final request = Uri.parse(source.requests.single);
        expect(request.path, '/repos/example/app/compare/4d91b33c...ced5040c');
        expect(request.queryParameters, {'per_page': '1', 'page': '2'});
        final restarted = _GitHub(Response('', 500));
        final restored = await restarted.resolveVersionComparison(
          App.fromJson(resolved.toJson()),
        );
        expect(versionDecisionForApp(restored).relation, relation);
        expect(restarted.requests, isEmpty);
      },
    );
  }

  for (final response in [
    Response('', 403),
    Response('', 404),
    Response('', 429),
    Response('', 500),
    Response('invalid json', 200),
    Response('{"status":"ahead","base_commit":{"sha":"wrong"}}', 200),
    Response('{"status":"unknown","base_commit":{"sha":"4d91b33c"}}', 200),
  ]) {
    test(
      'failed comparison ${response.statusCode}/${response.body} cools down',
      () async {
        final source = _GitHub(response);
        final before = DateTime.now().millisecondsSinceEpoch;
        final failed = await source.resolveVersionComparison(_app());
        expect(versionDecisionForApp(failed).reason, 'differentBuildHashes');
        expect(appHasActionableUpdate(failed), isFalse);
        final evidence =
            failed.additionalSettings[sourceBuildComparisonKey] as Map;
        expect(evidence['status'], 'unavailable');
        expect(
          evidence['retryAfter'],
          greaterThanOrEqualTo(
            before +
                Duration(
                  minutes: response.statusCode == 404 ? 15 : 1,
                ).inMilliseconds,
          ),
        );
        final restarted = _GitHub(_comparison('ahead'));
        final restored = await restarted.resolveVersionComparison(
          App.fromJson(failed.toJson()),
        );
        expect(restarted.requests, isEmpty);
        expect(
          versionDecisionForApp(restored).relation,
          VersionRelation.unknown,
        );
        final retried = await restarted.resolveVersionComparison(
          _expireRetry(restored),
        );
        expect(restarted.requests, hasLength(1));
        expect(versionDecisionForApp(retried).reason, 'sourceCommitAncestry');
        expect(
          retried.additionalSettings[sourceBuildComparisonKey],
          isNot(contains('retryAfter')),
        );
      },
    );
  }

  test(
    'network failure backs off without failing the source refresh',
    () async {
      final source = _GitHub(_comparison('ahead'))..failNetwork = true;
      final failed = await source.resolveVersionComparison(_app());
      source.failNetwork = false;
      await source.resolveVersionComparison(failed);
      expect(source.requests, hasLength(1));
      expect(versionDecisionForApp(failed).relation, VersionRelation.unknown);
      final retried = await source.resolveVersionComparison(
        _expireRetry(failed),
      );
      expect(appHasActionableUpdate(retried), isTrue);
    },
  );

  test(
    'repeated failures back off exponentially and stop growing at 30 minutes',
    () async {
      final source = _GitHub(Response('', 500));
      var app = _app();
      for (final minutes in [1, 2, 4, 8, 16, 30, 30]) {
        final before = DateTime.now().millisecondsSinceEpoch;
        app = await source.resolveVersionComparison(app);
        final after = DateTime.now().millisecondsSinceEpoch;
        final retryAfter =
            app.additionalSettings[sourceBuildComparisonKey]['retryAfter']
                as int;
        expect(
          retryAfter,
          inInclusiveRange(
            before + Duration(minutes: minutes).inMilliseconds,
            after + Duration(minutes: minutes).inMilliseconds,
          ),
        );
        app = _expireRetry(app);
      }
      expect(source.requests, hasLength(7));
    },
  );

  test(
    'Retry-After seconds and HTTP date and primary quota reset are respected',
    () async {
      final reset = DateTime.now().add(const Duration(hours: 1));
      for (final headers in [
        {'retry-after': '3600'},
        {'retry-after': HttpDate.format(reset)},
        {
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '${reset.millisecondsSinceEpoch ~/ 1000}',
        },
        {
          'retry-after': '60',
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '${reset.millisecondsSinceEpoch ~/ 1000}',
        },
      ]) {
        final source = _GitHub(Response('', 403, headers: headers));
        final failed = await source.resolveVersionComparison(_app());
        final retryAfter =
            failed.additionalSettings[sourceBuildComparisonKey]['retryAfter']
                as int;
        expect(
          retryAfter,
          greaterThanOrEqualTo(reset.millisecondsSinceEpoch ~/ 1000 * 1000),
        );
        await source.resolveVersionComparison(failed);
        expect(source.requests, hasLength(1));
      }
    },
  );

  test(
    'invalid and expired server retry headers retain local backoff',
    () async {
      for (final value in [
        'invalid',
        '-1',
        '0',
        HttpDate.format(DateTime.utc(2000)),
      ]) {
        final source = _GitHub(
          Response('', 429, headers: {'retry-after': value}),
        );
        final before = DateTime.now().millisecondsSinceEpoch;
        final failed = await source.resolveVersionComparison(_app());
        expect(
          failed.additionalSettings[sourceBuildComparisonKey]['retryAfter'],
          greaterThanOrEqualTo(
            before + const Duration(minutes: 1).inMilliseconds,
          ),
        );
      }
    },
  );

  test(
    'changed versions, source, observation or selected APK bypass old backoff',
    () async {
      final source = _GitHub(Response('', 500));
      final failed = await source.resolveVersionComparison(_app());
      for (final changed in [
        failed.copyWith(latestVersion: '1.5.5-ab12cd34'),
        failed.copyWith(installedVersion: '1.5.5 (ABC12345)'),
        failed.copyWith(url: 'https://github.com/example/other'),
        failed.copyWith(
          additionalSettings: {
            ...failed.additionalSettings,
            observedVersionCodeKey: 123,
          },
        ),
        failed.copyWith(
          apkUrls: const [
            MapEntry('other.apk', 'https://example.com/other.apk'),
          ],
        ),
      ]) {
        final before = source.requests.length;
        final retried = await source.resolveVersionComparison(changed);
        expect(source.requests, hasLength(before + 1));
        expect(
          retried.additionalSettings[sourceBuildComparisonKey]['failureCount'],
          1,
        );
      }
    },
  );

  test(
    'changed per-app credentials or proxy bypass failure backoff without storing credentials',
    () async {
      final source = _GitHub(Response('', 403));
      final failed = await source.resolveVersionComparison(_app());
      for (final config in [
        {GitHub.githubCredsKey: 'test-credential'},
        {GitHub.githubReqPrefixKey: 'https://proxy.example/'},
        {GitHub.githubReqPrefixUseTokenKey: 'true'},
      ]) {
        final before = source.requests.length;
        final retried = await source.resolveVersionComparison(
          failed.copyWith(
            additionalSettings: {...failed.additionalSettings, ...config},
          ),
        );
        expect(source.requests, hasLength(before + 1));
        expect(
          jsonEncode(retried.additionalSettings[sourceBuildComparisonKey]),
          isNot(contains('test-credential')),
        );
        expect(
          retried.additionalSettings[sourceBuildComparisonKey]['failureCount'],
          1,
        );
      }
    },
  );

  test('changed global credentials bypass failure backoff', () async {
    final source = _GitHub(Response('', 403));
    final failed = await source.resolveVersionComparison(_app());
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(GitHub.githubCredsKey, 'test-new-credential');
    final retried = await source.resolveVersionComparison(failed);
    expect(source.requests, hasLength(2));
    expect(
      retried.additionalSettings[sourceBuildComparisonKey]['failureCount'],
      1,
    );
  });
}
