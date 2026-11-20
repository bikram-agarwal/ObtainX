import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider_updates.dart';

App _app(
  String latestVersion, {
  bool detectionDate = true,
  DateTime? releaseDate,
  DateTime? latestVersionChangedAt,
}) => App(
  id: 'com.example.app',
  url: 'https://example.com/app.apk',
  author: 'Author',
  name: 'App',
  latestVersion: latestVersion,
  preferredApkIndex: 0,
  additionalSettings: {'detectionDateAsReleaseDate': detectionDate},
  releaseDate: releaseDate,
  latestVersionChangedAt: latestVersionChangedAt,
);

void main() {
  final firstSeen = DateTime(2026, 10, 20, 15, 30);
  final laterCheck = DateTime(2026, 10, 22, 9);

  test('a new version without a source date is dated when it was found', () {
    final app = recordLatestVersionChange(
      _app('1.0', latestVersionChangedAt: DateTime(2026, 10, 1)),
      _app('1.1'),
      now: firstSeen,
    );
    expect(app.latestVersionChangedAt, firstSeen);
    expect(app.releaseDate, firstSeen);
  });

  test('the first check after adding does not fabricate a release date', () {
    final app = recordLatestVersionChange(
      _app('1.0'),
      _app('1.0'),
      now: firstSeen,
    );
    expect(app.latestVersionChangedAt, firstSeen);
    expect(app.releaseDate, isNull);
  });

  test('enabling the setting does not date an unchanged first version', () {
    final app = recordLatestVersionChange(
      _app('1.0', latestVersionChangedAt: firstSeen),
      _app('1.0'),
      now: laterCheck,
    );
    expect(app.latestVersionChangedAt, firstSeen);
    expect(app.releaseDate, isNull);
  });

  test('later checks of the same version keep the date it was found', () {
    final app = recordLatestVersionChange(
      _app('1.1', latestVersionChangedAt: firstSeen, releaseDate: firstSeen),
      _app('1.1'),
      now: laterCheck,
    );
    expect(app.releaseDate, firstSeen);
  });

  test('a date from the source wins', () {
    final published = DateTime(2026, 10, 19);
    final app = recordLatestVersionChange(
      _app('1.0'),
      _app('1.1', releaseDate: published),
      now: firstSeen,
    );
    expect(app.releaseDate, published);
  });

  test('without the setting the release date stays unknown', () {
    final app = recordLatestVersionChange(
      _app('1.0', detectionDate: false),
      _app('1.1', detectionDate: false),
      now: firstSeen,
    );
    expect(app.latestVersionChangedAt, firstSeen);
    expect(app.releaseDate, isNull);
  });

  // ObtainX: an app added without a check (D10) has a placeholder version.
  test('the first check of an app added without one dates nothing', () {
    final placeholder = _app('Unknown')
        .copyWith(apkUrls: const [MapEntry('placeholder', 'placeholder')]);
    final app = recordLatestVersionChange(
      placeholder,
      _app('1.0'),
      now: firstSeen,
    );
    expect(app.latestVersionChangedAt, firstSeen);
    expect(app.releaseDate, isNull);
  });

  // ObtainX saves a check by merging it into the live row: the stamp and the
  // date it stands in for must survive that, or every check re-dates the
  // release (UPD-H8).
  test('the live-row merge keeps the date across same-version checks', () {
    final saved = _app(
      '1.1',
      latestVersionChangedAt: firstSeen,
      releaseDate: firstSeen,
    );
    // As getApp answers: the source's (missing) date, the stamp carried over.
    final fetched = _app('1.1', latestVersionChangedAt: firstSeen);
    final merged = mergeFetchedUpdateWithLiveState(
      requestedApp: saved,
      liveApp: saved,
      fetchedApp: recordLatestVersionChange(saved, fetched, now: laterCheck),
    )!;
    expect(merged.latestVersionChangedAt, firstSeen);
    expect(merged.releaseDate, firstSeen);
  });

  test('the live-row merge saves a new version with its detection date', () {
    final saved = _app('1.0', latestVersionChangedAt: firstSeen);
    final merged = mergeFetchedUpdateWithLiveState(
      requestedApp: saved,
      liveApp: saved,
      fetchedApp: recordLatestVersionChange(
        saved,
        _app('1.1', latestVersionChangedAt: firstSeen),
        now: laterCheck,
      ),
    )!;
    expect(merged.latestVersion, '1.1');
    expect(merged.latestVersionChangedAt, laterCheck);
    expect(merged.releaseDate, laterCheck);
  });
}
