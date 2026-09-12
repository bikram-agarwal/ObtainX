import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/apps_provider_updates.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/version/app_version.dart';
import 'package:obtainium/version/partial_download_version.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

App _app({
  required String id,
  String url = 'https://github.com/example/app',
  String? overrideSource,
  Map<String, dynamic> additionalSettings = const {},
}) {
  return App(
    id: id,
    url: url,
    author: 'Author',
    name: 'Example',
    latestVersion: '1.0',
    preferredApkIndex: 0,
    overrideSource: overrideSource,
    additionalSettings: Map<String, dynamic>.from(additionalSettings),
  );
}

class _CachePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _CachePathProvider(this.root);

  final String root;

  @override
  Future<String?> getExternalStoragePath() async => root;
}

void main() {
  test('isSwappableGitHubRepoUrl accepts repository URLs only', () {
    expect(isSwappableGitHubRepoUrl('https://github.com/example/app'), isTrue);
    expect(
      isSwappableGitHubRepoUrl(
        'https://github.com/example/app/releases/tag/v1.0.0',
      ),
      isTrue,
    );
    expect(
      isSwappableGitHubRepoUrl('https://f-droid.org/packages/foo/'),
      isFalse,
    );
    expect(isSwappableGitHubRepoUrl('https://github.com/'), isFalse);
    expect(isSwappableGitHubRepoUrl('not-a-url'), isFalse);
  });

  test(
    'resolveSwappableStoreListingUrl uses a known GitHub candidate URL',
    () async {
      expect(
        await resolveSwappableStoreListingUrl(
          storeName: 'GitHub',
          packageId: 'com.example.app',
          candidateUrl: 'https://github.com/example/app/releases',
        ),
        'https://github.com/example/app',
      );
    },
  );

  group('preserveAlternateGitHubSourceInCache', () {
    late PathProviderPlatform previousPathProvider;

    setUp(() async {
      previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _CachePathProvider(
        (await Directory.systemTemp.createTemp('obtainx-github-cache-')).path,
      );
      await BulkScanCache.clear();
    });

    tearDown(() async {
      await BulkScanCache.clear();
      PathProviderPlatform.instance = previousPathProvider;
    });

    test('stores a standardized GitHub repository URL', () async {
      await preserveAlternateGitHubSourceInCache(
        packageId: 'com.example.app',
        githubUrl: 'https://github.com/example/app/releases',
      );

      expect(await BulkScanCache.loadForApp('com.example.app'), {
        'GitHub': 'https://github.com/example/app',
      });
    });

    test('resolveSwappableStoreListingUrl reads cached GitHub URLs', () async {
      await preserveAlternateGitHubSourceInCache(
        packageId: 'com.example.app',
        githubUrl: 'https://github.com/example/app',
      );

      expect(
        await resolveSwappableStoreListingUrl(
          storeName: 'GitHub',
          packageId: 'com.example.app',
        ),
        'https://github.com/example/app',
      );
    });
  });

  test('isApkMirrorStoreSearchUrl detects APKMirror search URLs', () {
    expect(
      isApkMirrorStoreSearchUrl(
        'https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=com.example',
      ),
      isTrue,
    );
    expect(
      isApkMirrorStoreSearchUrl(
        'https://www.apkmirror.com/apk/example/example/',
      ),
      isFalse,
    );
  });

  test('prepareAppForTrackedSourceSwap clears source-bound metadata', () {
    final App app = _app(
      id: 'com.example.app',
      additionalSettings: {
        sourceVersionCodesKey: {'version': '1.0'},
        sourceBuildComparisonKey: {'reason': 'same'},
        acknowledgedSourceReleaseKey: {'version': '1.0'},
        'rawSelectedReleaseTitle': 'Release',
        partialDownloadFingerprintKey: {'url': 'https://example.com'},
        'skippedLatestVersion': '0.9',
        unreconciledVersionComparisonKey: 'older',
      },
    );

    final App prepared = prepareAppForTrackedSourceSwap(
      app: app,
      previousSource: GitHub(),
      destinationSource: FDroid(),
      standardizedDestinationUrl:
          'https://f-droid.org/packages/com.example.app/',
    );

    expect(prepared.url, 'https://f-droid.org/packages/com.example.app/');
    expect(prepared.overrideSource, isNull);
    expect(prepared.pendingRepoRenameUrl, isNull);
    expect(prepared.iconUrl, isNull);
    expect(prepared.latestMalwareScanStatus, isNull);
    expect(
      prepared.additionalSettings.containsKey(sourceVersionCodesKey),
      false,
    );
    expect(
      prepared.additionalSettings.containsKey(acknowledgedSourceReleaseKey),
      false,
    );
    expect(
      prepared.additionalSettings.containsKey('skippedLatestVersion'),
      false,
    );
  });

  test('prepareAppForTrackedSourceSwap enforces track-only on APKMirror', () {
    final App app = _app(
      id: 'com.example.app',
      url: 'https://github.com/example/app',
      additionalSettings: const {'trackOnly': false},
    );

    final App prepared = prepareAppForTrackedSourceSwap(
      app: app,
      previousSource: GitHub(),
      destinationSource: APKMirror(),
      standardizedDestinationUrl:
          'https://www.apkmirror.com/apk/example/example/',
    );

    expect(prepared.additionalSettings['trackOnly'], true);
  });

  test(
    'prepareAppForTrackedSourceSwap clears enforced track-only when leaving APKMirror',
    () {
      final App app = _app(
        id: 'com.example.app',
        url: 'https://www.apkmirror.com/apk/example/example/',
        additionalSettings: const {'trackOnly': true},
      );

      final App prepared = prepareAppForTrackedSourceSwap(
        app: app,
        previousSource: APKMirror(),
        destinationSource: FDroid(),
        standardizedDestinationUrl:
            'https://f-droid.org/packages/com.example.app/',
      );

      expect(prepared.additionalSettings.containsKey('trackOnly'), false);
    },
  );

  test(
    'mergeTrackedSourceSwap commits fetched metadata after a source swap',
    () {
      final App liveApp = _app(
        id: 'com.example.app',
        url: 'https://github.com/example/app',
        additionalSettings: const {'about': 'notes'},
      );
      final App requestedApp = prepareAppForTrackedSourceSwap(
        app: liveApp,
        previousSource: GitHub(),
        destinationSource: FDroid(),
        standardizedDestinationUrl:
            'https://f-droid.org/packages/com.example.app/',
      );
      final App fetchedApp = requestedApp.copyWith(
        latestVersion: '2.0',
        apkUrls: const [MapEntry('app.apk', 'https://f-droid.org/app.apk')],
        lastUpdateCheck: DateTime.utc(2026, 9, 12),
        changeLog: 'New release',
        rawLatestVersionFromSource: '2.0',
      );

      final App? merged = mergeTrackedSourceSwap(
        originalUrl: liveApp.url,
        originalOverrideSource: liveApp.overrideSource,
        liveApp: liveApp,
        requestedApp: requestedApp,
        fetchedApp: fetchedApp,
      );

      expect(merged, isNotNull);
      expect(merged!.url, requestedApp.url);
      expect(merged.latestVersion, '2.0');
      expect(merged.changeLog, 'New release');
      expect(merged.additionalSettings['about'], 'notes');
      expect(merged.latestMalwareScanStatus, isNull);
    },
  );

  test('mergeTrackedSourceSwap is discarded after concurrent URL edits', () {
    final App liveApp = _app(id: 'com.example.app');
    final App requestedApp = liveApp.copyWith(
      url: 'https://f-droid.org/packages/com.example.app/',
    );
    final App fetchedApp = requestedApp.copyWith(latestVersion: '2.0');

    expect(
      mergeTrackedSourceSwap(
        originalUrl: liveApp.url,
        originalOverrideSource: liveApp.overrideSource,
        liveApp: liveApp.copyWith(url: 'https://example.com/moved'),
        requestedApp: requestedApp,
        fetchedApp: fetchedApp,
      ),
      isNull,
    );
    expect(
      mergeTrackedSourceSwap(
        originalUrl: liveApp.url,
        originalOverrideSource: liveApp.overrideSource,
        liveApp: liveApp.copyWith(overrideSource: 'HTML'),
        requestedApp: requestedApp,
        fetchedApp: fetchedApp,
      ),
      isNull,
    );
  });
}
