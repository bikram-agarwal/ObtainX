import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider_updates.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/utils/update_health.dart';

// What a check saves into the live row (guide §3.9): fields the v1.7.4 sync
// added (D8 update health, D12 universal APKs) must survive
// mergeFetchedUpdateWithLiveState and mergeTrackedSourceSwap.

const _universal = MapEntry('app-universal.apk', 'https://e.com/u.apk');
const _arm64 = MapEntry('app-arm64-v8a.apk', 'https://e.com/a.apk');

// github.dart's repoArchivedCheckedAtKey.
const _archivedCheckedAt = 'repoArchivedCheckedAt';

App _app({
  String latestVersion = '1.0',
  List<MapEntry<String, String>> apkUrls = const [_universal, _arm64],
  int preferredApkIndex = 0,
  String url = 'https://github.com/example/app',
  DateTime? latestVersionChangedAt,
  int consecutiveFailedChecks = 0,
  bool? isArchived,
  int? newerReleasesFilteredOut,
  bool updateHealthEnabled = true,
  String? updateHealthDismissedVersion,
}) => App(
  id: 'org.example.app',
  url: url,
  author: 'Example',
  name: 'Example',
  installedVersion: '1.0',
  latestVersion: latestVersion,
  apkUrls: apkUrls,
  preferredApkIndex: preferredApkIndex,
  additionalSettings: const {'versionDetection': 'auto'},
  latestVersionChangedAt: latestVersionChangedAt,
  consecutiveFailedChecks: consecutiveFailedChecks,
  isArchived: isArchived,
  newerReleasesFilteredOut: newerReleasesFilteredOut,
  updateHealthEnabled: updateHealthEnabled,
  updateHealthDismissedVersion: updateHealthDismissedVersion,
);

void main() {
  group('preferredApkIndex (D12, #3473)', () {
    test('an app at index 0 with [universal, arm64] stays on arm64', () {
      final requested = _app();
      // getApp moved the saved universal choice to the ABI match.
      final fetched = _app(latestVersion: '1.1', preferredApkIndex: 1);
      final merged = mergeFetchedUpdateWithLiveState(
        requestedApp: requested,
        liveApp: requested,
        fetchedApp: fetched,
      )!;
      expect(merged.preferredApkIndex, 1);
      expect(merged.apkUrls[merged.preferredApkIndex], _arm64);
    });

    test('a choice made while the check ran wins while it exists', () {
      final requested = _app(preferredApkIndex: 1);
      final live = _app(preferredApkIndex: 0);
      final fetched = _app(latestVersion: '1.1', preferredApkIndex: 1);
      expect(
        mergeFetchedUpdateWithLiveState(
          requestedApp: requested,
          liveApp: live,
          fetchedApp: fetched,
        )!.preferredApkIndex,
        0,
      );
      // Gone from the new release: the fetched index stands.
      final live2 = _app(preferredApkIndex: 1);
      expect(
        mergeFetchedUpdateWithLiveState(
          requestedApp: _app(),
          liveApp: live2,
          fetchedApp: _app(
            latestVersion: '1.1',
            apkUrls: const [_arm64],
            preferredApkIndex: 0,
          ),
        )!.preferredApkIndex,
        0,
      );
    });

    test('a tracked-source swap follows the same rule', () {
      final requested = _app(url: 'https://f-droid.org/packages/org.example');
      final live = _app();
      final merged = mergeTrackedSourceSwap(
        originalUrl: live.url,
        originalOverrideSource: null,
        liveApp: live,
        requestedApp: requested,
        fetchedApp: _app(
          url: requested.url,
          latestVersion: '1.1',
          preferredApkIndex: 1,
        ),
      )!;
      expect(merged.preferredApkIndex, 1);
    });
  });

  group('update health fields (D8)', () {
    final firstSeen = DateTime.utc(2026, 10, 1);
    final changed = DateTime.utc(2026, 11, 1);

    App fetchedFrom(App requested) => requested.copyWith(
      latestVersion: '1.1',
      latestVersionChangedAt: changed,
      consecutiveFailedChecks: 0,
      isArchived: true,
      newerReleasesFilteredOut: 3,
    );

    void expectSourceFields(App merged) {
      expect(merged.latestVersionChangedAt, changed);
      expect(merged.consecutiveFailedChecks, 0);
      expect(merged.isArchived, isTrue);
      expect(merged.newerReleasesFilteredOut, 3);
    }

    test('the live-row merge takes the source-owned fields', () {
      final requested = _app(
        latestVersionChangedAt: firstSeen,
        consecutiveFailedChecks: 4,
      );
      expectSourceFields(
        mergeFetchedUpdateWithLiveState(
          requestedApp: requested,
          liveApp: requested,
          fetchedApp: fetchedFrom(requested),
        )!,
      );
    });

    test('and clears the ones the source no longer reports', () {
      final requested = _app(isArchived: true, newerReleasesFilteredOut: 7);
      final merged = mergeFetchedUpdateWithLiveState(
        requestedApp: requested,
        liveApp: requested,
        fetchedApp: requested.copyWith(
          isArchived: null,
          newerReleasesFilteredOut: null,
        ),
      )!;
      expect(merged.isArchived, isNull);
      expect(merged.newerReleasesFilteredOut, isNull);
    });

    test('an Ignore tapped while the check ran survives it', () {
      final requested = _app();
      final live = _app(
        updateHealthEnabled: false,
        updateHealthDismissedVersion: '1.0',
      );
      final merged = mergeFetchedUpdateWithLiveState(
        requestedApp: requested,
        liveApp: live,
        fetchedApp: fetchedFrom(requested),
      )!;
      expectSourceFields(merged);
      expect(merged.updateHealthEnabled, isFalse);
      expect(merged.updateHealthDismissedVersion, '1.0');
    });

    test('a tracked-source swap takes them too', () {
      final live = _app(
        consecutiveFailedChecks: 4,
        updateHealthDismissedVersion: '1.0',
      );
      final requested = _app(url: 'https://f-droid.org/packages/org.example');
      final merged = mergeTrackedSourceSwap(
        originalUrl: live.url,
        originalOverrideSource: null,
        liveApp: live,
        requestedApp: requested,
        fetchedApp: fetchedFrom(requested),
      )!;
      expectSourceFields(merged);
      expect(merged.updateHealthDismissedVersion, '1.0');
    });
  });

  group('failed-check counting (D8)', () {
    final checkedAt = DateTime.utc(2026, 11, 20);

    test('a source that answered without an update counts once', () {
      final app = appAfterAnswerWithoutUpdate(
        _app(consecutiveFailedChecks: 2),
        NoReleasesError(),
        checkedAt,
      );
      expect(app.consecutiveFailedChecks, 3);
      expect(app.lastUpdateCheck, checkedAt);
    });

    test('a background retry of that answer does not count again', () {
      final app = appAfterAnswerWithoutUpdate(
        _app(consecutiveFailedChecks: 2),
        NoAPKError(),
        checkedAt,
        countFailedCheck: false,
      );
      expect(app.consecutiveFailedChecks, 2);
    });

    test('only persistent failures are saved, so only they can count', () {
      // checkUpdates saves persistent failures; the update-health rule agrees
      // on every one of them, and transient ones are never saved (D10).
      for (final Object error in [
        ObtainiumError(
          'HTTP 404',
          code: 'HTTP_ERROR',
          data: const {'statusCode': 404},
        ),
        Exception('unexpected'),
      ]) {
        expect(checkFailureIsPersistent(error), isTrue);
        expect(shouldCountFailedCheck(error), isTrue);
      }
      for (final Object error in [
        const SocketException('offline'),
        ObtainiumError('wrapped', cause: const SocketException('offline')),
        RateLimitError(5),
      ]) {
        expect(checkFailureIsPersistent(error), isFalse);
        expect(shouldCountFailedCheck(error), isFalse);
      }
    });
  });

  test('a swap drops the previous project\'s archived flag', () {
    final app = _app(isArchived: true);
    final prepared = prepareAppForTrackedSourceSwap(
      app: app.copyWith(
        additionalSettings: {
          ...app.additionalSettings,
          _archivedCheckedAt: 1700000000000,
        },
      ),
      previousSource: GitHub(),
      destinationSource: FDroid(),
      standardizedDestinationUrl: 'https://f-droid.org/packages/org.example/',
    );
    expect(prepared.isArchived, isNull);
    expect(
      prepared.additionalSettings.containsKey(_archivedCheckedAt),
      isFalse,
    );
  });

  group('GitHub archived-check throttle (D8)', () {
    App withCheckedAt(App app, int? checkedAt) => app.copyWith(
      additionalSettings: {
        ...app.additionalSettings,
        _archivedCheckedAt: ?checkedAt,
      },
    );

    test('the live-row merge keeps the fetched time', () {
      final requested = withCheckedAt(_app(), 1);
      final merged = mergeFetchedUpdateWithLiveState(
        requestedApp: requested,
        liveApp: requested,
        fetchedApp: withCheckedAt(_app(latestVersion: '1.1'), 2),
      )!;
      expect(merged.additionalSettings[_archivedCheckedAt], 2);
    });

    test('and drops it when the fetch has none', () {
      final requested = withCheckedAt(_app(), 1);
      final merged = mergeFetchedUpdateWithLiveState(
        requestedApp: requested,
        liveApp: requested,
        fetchedApp: _app(latestVersion: '1.1'),
      )!;
      expect(
        merged.additionalSettings.containsKey(_archivedCheckedAt),
        isFalse,
      );
    });

    test('a tracked-source swap keeps the fetched time too', () {
      final live = withCheckedAt(_app(), 1);
      final requested = _app(url: 'https://github.com/example/other');
      final merged = mergeTrackedSourceSwap(
        originalUrl: live.url,
        originalOverrideSource: null,
        liveApp: live,
        requestedApp: requested,
        fetchedApp: withCheckedAt(_app(url: requested.url), 3),
      )!;
      expect(merged.additionalSettings[_archivedCheckedAt], 3);
    });
  });
}
