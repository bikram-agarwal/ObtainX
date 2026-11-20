// Fields added in the v1.7.4 sync (update health D8, detection date D11,
// source-supplied package IDs): copyWith can clear them, JSON round-trips
// them, and the defaults stay out of saved records.

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/models/app.dart';

App _app() => const App(
  id: 'com.example.app',
  url: 'https://example.com/app',
  author: 'Author',
  name: 'App',
  latestVersion: '1.0',
  preferredApkIndex: 0,
  additionalSettings: {},
);

void main() {
  final DateTime changedAt = DateTime.utc(2026, 10, 1, 12);

  App filled() => _app().copyWith(
    latestVersionChangedAt: changedAt,
    consecutiveFailedChecks: 3,
    isArchived: true,
    newerReleasesFilteredOut: 4,
    updateHealthEnabled: false,
    updateHealthDismissedVersion: '1.0',
  );

  test('copyWith sets and clears the nullable fields', () {
    final App app = filled();
    expect(app.latestVersionChangedAt, changedAt);
    expect(app.isArchived, isTrue);
    expect(app.newerReleasesFilteredOut, 4);
    expect(app.updateHealthDismissedVersion, '1.0');

    final App cleared = app.copyWith(
      latestVersionChangedAt: null,
      isArchived: null,
      newerReleasesFilteredOut: null,
      updateHealthDismissedVersion: null,
    );
    expect(cleared.latestVersionChangedAt, isNull);
    expect(cleared.isArchived, isNull);
    expect(cleared.newerReleasesFilteredOut, isNull);
    expect(cleared.updateHealthDismissedVersion, isNull);
    // Untouched fields survive.
    expect(cleared.consecutiveFailedChecks, 3);
    expect(cleared.updateHealthEnabled, isFalse);
  });

  test('JSON round-trips the new fields', () {
    final App restored = App.fromJson(filled().toJson());
    expect(restored.latestVersionChangedAt, changedAt.toLocal());
    expect(restored.consecutiveFailedChecks, 3);
    expect(restored.isArchived, isTrue);
    expect(restored.newerReleasesFilteredOut, 4);
    expect(restored.updateHealthEnabled, isFalse);
    expect(restored.updateHealthDismissedVersion, '1.0');
  });

  test('defaults are omitted from JSON', () {
    final Map<String, dynamic> json = _app().toJson();
    for (final String key in [
      'latestVersionChangedAt',
      'consecutiveFailedChecks',
      'isArchived',
      'newerReleasesFilteredOut',
      'updateHealthEnabled',
      'updateHealthDismissedVersion',
      'disabled',
    ]) {
      expect(json.containsKey(key), isFalse, reason: key);
    }
  });

  test('fromJson tolerates string numbers and missing fields', () {
    final Map<String, dynamic> json = _app().toJson()
      ..['consecutiveFailedChecks'] = '2'
      ..['newerReleasesFilteredOut'] = 5.0;
    final App app = App.fromJson(json);
    expect(app.consecutiveFailedChecks, 2);
    expect(app.newerReleasesFilteredOut, 5);
    expect(app.updateHealthEnabled, isTrue);
  });

  test('an Obtainium "disabled" app becomes on-demand only', () {
    final Map<String, dynamic> json = _app().toJson()..['disabled'] = true;
    final App app = App.fromJson(json);
    expect(app.settings.getBool('onDemandOnly'), isTrue);
    expect(app.toJson().containsKey('disabled'), isFalse);
  });

  test('APKDetails.copyWith keeps and clears appId', () {
    final details = APKDetails(
      '1.0',
      const [],
      const AppNames('a', 'b'),
      appId: 'com.example.app',
      isArchived: true,
      newerReleasesFilteredOut: 2,
    );
    final copy = details.copyWith(version: '2.0');
    expect(copy.appId, 'com.example.app');
    expect(copy.isArchived, isTrue);
    expect(copy.newerReleasesFilteredOut, 2);
    final cleared = details.copyWith(
      appId: null,
      isArchived: null,
      newerReleasesFilteredOut: null,
    );
    expect(cleared.appId, isNull);
    expect(cleared.isArchived, isNull);
    expect(cleared.newerReleasesFilteredOut, isNull);
  });

  test('placeholder APKs mark an app that was never checked', () {
    expect(hasOnlyPlaceholderApks(_app()), isFalse);
    expect(
      hasOnlyPlaceholderApks(
        _app().copyWith(
          apkUrls: const [MapEntry('placeholder', 'placeholder')],
        ),
      ),
      isTrue,
    );
  });
}
