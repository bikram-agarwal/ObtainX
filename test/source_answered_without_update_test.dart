import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

const String _filter = r'-offline\.apk$';

/// What the listing looked like after a check with the filter removed: two
/// APKs of v1.8.0 on record.
App _previouslyFetched({String? installedVersion = '1.9.0'}) {
  return App(
    id: 'dev.bikram.remember.offline',
    url: 'https://github.com/bikram-agarwal/Remember',
    author: 'bikram-agarwal',
    name: 'Remember',
    installedVersion: installedVersion,
    latestVersion: 'v1.8.0',
    apkUrls: const [
      MapEntry('remember-github.apk', 'https://example.com/github.apk'),
      MapEntry('remember-fdroid.apk', 'https://example.com/fdroid.apk'),
    ],
    preferredApkIndex: 0,
    releaseDate: DateTime(2026, 9),
    changeLog: 'https://github.com/bikram-agarwal/Remember/releases',
    apkSizeBytes: 1024,
    additionalSettings: {'apkFilterRegEx': _filter},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a source that answered with nothing usable still counts as checked',
    () {
      // What an APK filter matching no release asset produces, among others.
      expect(sourceAnsweredWithoutUpdate(NoReleasesError()), isTrue);
      expect(sourceAnsweredWithoutUpdate(NoAPKError()), isTrue);
      expect(sourceAnsweredWithoutUpdate(NoVersionError()), isTrue);
    },
  );

  test('a source that was never heard from does not', () {
    // These keep the app first in line for the next (background) retry.
    expect(
      sourceAnsweredWithoutUpdate(const SocketException('offline')),
      isFalse,
    );
    expect(
      sourceAnsweredWithoutUpdate(const HandshakeException('tls')),
      isFalse,
    );
    expect(sourceAnsweredWithoutUpdate(TimeoutException('slow')), isFalse);
    expect(sourceAnsweredWithoutUpdate(RateLimitError(5)), isFalse);
    expect(sourceAnsweredWithoutUpdate(ObtainiumError('unknown')), isFalse);
  });

  group('no release matching the filter', () {
    final DateTime checkedAt = DateTime(2026, 9, 24, 17, 15);

    test('replaces the release an earlier check found', () {
      final App app = appAfterAnswerWithoutUpdate(
        _previouslyFetched(),
        NoReleasesError(),
        checkedAt,
      );

      expect(appHasNoMatchingRelease(app), isTrue);
      expect(app.latestVersion, isEmpty);
      expect(app.apkUrls, isEmpty);
      expect(app.releaseDate, isNull);
      expect(app.changeLog, isNull);
      expect(app.apkSizeBytes, isNull);
      expect(app.lastUpdateCheck, checkedAt);
      // The user's own settings survive.
      expect(app.additionalSettings['apkFilterRegEx'], _filter);
    });

    test('reads as newer on device, with nothing to install', () {
      final App installed = appAfterAnswerWithoutUpdate(
        _previouslyFetched(),
        NoReleasesError(),
        checkedAt,
      );
      expect(
        appVersionVerdictForDisplay(installed),
        AppVersionDisplayVerdict.newerOnDevice,
      );
      expect(appHasActionableUpdate(installed), isFalse);
      expect(versionOrderUncertainUpdate(installed), isFalse);

      final App notInstalled = appAfterAnswerWithoutUpdate(
        _previouslyFetched(installedVersion: null),
        NoReleasesError(),
        checkedAt,
      );
      expect(appUpdateIsUserVisible(notInstalled), isFalse);
    });

    test('ends at the next check that finds a release', () {
      final App none = appAfterAnswerWithoutUpdate(
        _previouslyFetched(),
        NoReleasesError(),
        checkedAt,
      );

      final App? found = mergeFetchedUpdateWithLiveState(
        requestedApp: none,
        liveApp: none,
        fetchedApp: _previouslyFetched().copyWith(latestVersion: 'v1.9.1'),
      );

      expect(appHasNoMatchingRelease(found!), isFalse);
      expect(found.latestVersion, 'v1.9.1');
      expect(found.apkUrls, hasLength(2));
    });

    test('an unreadable version only moves the check time', () {
      // The source has a release; only its version couldn't be extracted.
      final App app = appAfterAnswerWithoutUpdate(
        _previouslyFetched(),
        NoVersionError(),
        checkedAt,
      );

      expect(appHasNoMatchingRelease(app), isFalse);
      expect(app.latestVersion, 'v1.8.0');
      expect(app.lastUpdateCheck, checkedAt);
    });
  });

  test('an F-Droid source link on GitHub becomes a GitHub listing', () {
    expect(
      gitHubRepoUrlFromSourceCodeLink(
        'https://github.com/bikram-agarwal/Remember',
      ),
      'https://github.com/bikram-agarwal/Remember',
    );
    // F-Droid's own client, which lives on GitLab.
    expect(
      gitHubRepoUrlFromSourceCodeLink('https://gitlab.com/fdroid/fdroidclient'),
      isNull,
    );
    expect(gitHubRepoUrlFromSourceCodeLink('https://github.com/owner'), isNull);
    expect(gitHubRepoUrlFromSourceCodeLink(null), isNull);
  });

  test('a typed filter marks the latest version as filtered', () {
    expect(appHasActiveReleaseFilter(_previouslyFetched()), isTrue);
    expect(
      appHasActiveReleaseFilter(
        _previouslyFetched().copyWith(
          additionalSettings: {
            'apkFilterRegEx': '  ',
            'autoApkFilterByArch': true,
          },
        ),
      ),
      isFalse,
    );
  });
}
