import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// Property tests for the version-comparison primitives.
///
/// The bugs this layer has actually shipped were invariant violations rather than
/// wrong answers on a specific pair: two reconcilers that disagreed, a compare
/// that called a version code "newer" than a version string, predicates that
/// could both claim an app is up to date and has an update. Individual example
/// tests kept passing through all of them; these assertions would not have.
///
/// The corpus is a fixed list plus a seeded shuffle, so runs are reproducible.
const List<String> _versionCorpus = <String>[
  '1',
  '1.0',
  '1.2',
  '1.2.0',
  '1.2.3',
  '1.2.4',
  '1.2.3-2',
  '1.2.3-beta',
  '1.2.3-beta1',
  '1.2.3+45',
  '10.0',
  '153.0',
  '153.0.2',
  'v1.1.0',
  '2.0-rc1',
  '26.03',
  '26.03.a4d75424',
  '26.06.9df4c85',
  '106',
  '107',
  '9.18.50',
  '48300',
  '1.0.896819557.release',
  '1.0.915254043.release',
  '2026.03.12.885261117.2-release',
  '2026.04.27.917519149.2-release',
  '8.8 (88957691)',
  '8.6 (86672232)',
  '1.5.3-DEV (75094D8)',
  'debug-75094d8',
  '2026-04-28T09:57:05.000Z',
  '2026-05-02T00:00:00.000Z',
  '1777370225000000',
  '1.0.0-facade',
  '2.0.0-facade',
  '1.0.0+20260412a',
  '2.0.0+20260412a',
  '',
];

App _app({
  required String? installed,
  required String latest,
  Map<String, dynamic> settings = const <String, dynamic>{},
}) => App(
  id: 'app.example',
  url: 'https://github.com/example/example',
  author: 'example',
  name: 'example',
  installedVersion: installed,
  latestVersion: latest,
  apkUrls: const <MapEntry<String, String>>[],
  preferredApkIndex: 0,
  additionalSettings: settings,
  lastUpdateCheck: null,
  pinned: false,
);

int _sign(int value) => value == 0 ? 0 : (value > 0 ? 1 : -1);

void _forEachPair(void Function(String a, String b) body) {
  for (final String a in _versionCorpus) {
    for (final String b in _versionCorpus) {
      body(a, b);
    }
  }
}

void main() {
  test('versionsEffectivelyEqual is symmetric and reflexive', () {
    _forEachPair((String a, String b) {
      expect(
        versionsEffectivelyEqual(a, b),
        versionsEffectivelyEqual(b, a),
        reason: 'asymmetric for ($a, $b)',
      );
    });
    for (final String version in _versionCorpus) {
      if (version.isEmpty) continue;
      expect(
        versionsEffectivelyEqual(version, version),
        true,
        reason: 'not reflexive for $version',
      );
    }
  });

  test('compareVersionsByNumericSegments is antisymmetric', () {
    _forEachPair((String a, String b) {
      final int? forward = compareVersionsByNumericSegments(a, b);
      final int? backward = compareVersionsByNumericSegments(b, a);
      if (forward == null || backward == null) {
        expect(
          forward,
          backward,
          reason: 'comparability differs by direction for ($a, $b)',
        );
        return;
      }
      expect(
        _sign(forward),
        -_sign(backward),
        reason: 'not antisymmetric for ($a, $b)',
      );
    });
  });

  test(
    'reconcileVersionDifferences is reflexive and returns one of its inputs',
    () {
      _forEachPair((String a, String b) {
        final VersionComparison? forward = reconcileVersionDifferences(a, b);
        if (forward != null) {
          expect(<String>[a, b], contains(forward.version));
        }
      });
      for (final String version in _versionCorpus) {
        if (version.isEmpty) continue;
        expect(
          reconcileVersionDifferences(version, version)?.areEqual,
          true,
          reason: 'not reflexive for $version',
        );
      }
    },
  );

  test('reconcileVersionDifferences is symmetric when both sides are standard', () {
    // Reconciliation is DIRECTIONAL by design: the template (first argument, the
    // real device version) is matched strictly, while the comparison version may
    // fall back to loose matching. A pair can therefore be relatable in one
    // direction and unrelatable in the other (e.g. `('7.1', 'v7.1.1')` vs
    // `('v7.1.1', '7.1')`). The equality verdict is only guaranteed to be
    // direction-independent when both sides have a strict standard format —
    // argument order matters everywhere else, which is why the two former
    // copies of this function could disagree without any example test noticing.
    _forEachPair((String a, String b) {
      final bool bothStandard =
          findStandardFormatsForVersion(a, true).isNotEmpty &&
          findStandardFormatsForVersion(b, true).isNotEmpty;
      if (!bothStandard) return;
      expect(
        reconcileVersionDifferences(a, b)?.areEqual,
        reconcileVersionDifferences(b, a)?.areEqual,
        reason: 'equality verdict differs by direction for ($a, $b)',
      );
    });
  });

  test('effectively equal versions never present an update', () {
    for (final String mode in <String>['auto', 'standard', 'pseudo']) {
      _forEachPair((String installed, String latest) {
        if (installed.isEmpty || latest.isEmpty) return;
        if (!versionsEffectivelyEqual(installed, latest)) return;
        final App app = _app(
          installed: installed,
          latest: latest,
          settings: <String, dynamic>{'versionDetection': mode},
        );
        expect(
          appHasActionableUpdate(app),
          false,
          reason: 'actionable update for equal ($installed, $latest) in $mode',
        );
        expect(
          versionOrderUncertainUpdate(app),
          false,
          reason: 'uncertain update for equal ($installed, $latest) in $mode',
        );
        expect(
          appIsUpToDateForFiltering(app),
          true,
          reason: 'not up to date for equal ($installed, $latest) in $mode',
        );
      });
    }
  });

  test('an app never both has an update and is up to date', () {
    for (final String mode in <String>[
      'auto',
      'standard',
      'pseudo',
      'versionCode',
    ]) {
      _forEachPair((String installed, String latest) {
        if (latest.isEmpty) return;
        final App app = _app(
          installed: installed,
          latest: latest,
          settings: <String, dynamic>{'versionDetection': mode},
        );
        final bool actionable = appHasActionableUpdate(app);
        final bool uncertain = versionOrderUncertainUpdate(app);
        final bool upToDate = appIsUpToDateForFiltering(app);

        expect(
          actionable && uncertain,
          false,
          reason:
              'both actionable and uncertain ($installed, $latest) in $mode',
        );
        expect(
          actionable && upToDate,
          false,
          reason:
              'both actionable and up to date ($installed, $latest) in $mode',
        );
        // Anything the UI offers to install must also be what the background
        // path acts on, and vice versa.
        expect(
          appUpdateIsUserVisible(app),
          actionable,
          reason:
              'user-visible verdict diverges ($installed, $latest) in $mode',
        );
      });
    }
  });

  test('skipping the current release suppresses every update affordance', () {
    _forEachPair((String installed, String latest) {
      if (installed.isEmpty || latest.isEmpty) return;
      final App app = _app(
        installed: installed,
        latest: latest,
        settings: <String, dynamic>{
          'versionDetection': 'auto',
          'skippedLatestVersion': latest,
        },
      );
      expect(appHasActionableUpdate(app), false);
      expect(versionOrderUncertainUpdate(app), false);
      expect(appUpdateIsUserVisible(app), false);
      expect(appIsUpToDateForFiltering(app), true);
    });
  });

  test('normalizeSkippedLatestVersion is idempotent', () {
    _forEachPair((String installed, String latest) {
      if (latest.isEmpty) return;
      final App app = _app(
        installed: installed.isEmpty ? null : installed,
        latest: latest,
        settings: <String, dynamic>{
          'versionDetection': 'auto',
          'skippedLatestVersion': latest,
        },
      );
      final App once = normalizeSkippedLatestVersion(app);
      final App twice = normalizeSkippedLatestVersion(once);
      expect(
        twice.additionalSettings['skippedLatestVersion'],
        once.additionalSettings['skippedLatestVersion'],
        reason: 'not idempotent for ($installed, $latest)',
      );
    });
  });

  test('a shared build hash implies effective equality, both ways', () {
    _forEachPair((String a, String b) {
      if (a.isEmpty || b.isEmpty || a == b) return;
      final Set<String> shared = commitHashLikeTokensFromVersion(
        a,
      ).intersection(commitHashLikeTokensFromVersion(b));
      if (shared.isEmpty) return;
      expect(
        versionsEffectivelyEqual(a, b),
        true,
        reason: 'shared hash $shared but not equal ($a, $b)',
      );
    });
  });

  test('words and date stamps are not treated as build hashes', () {
    for (final String word in <String>[
      'facade',
      'decade',
      'beaded',
      'defaced',
      'accede',
      'cabbed',
    ]) {
      expect(
        commitHashLikeTokensFromVersion('1.0.0-$word'),
        isEmpty,
        reason: '$word read as a build hash',
      );
      expect(
        versionsEffectivelyEqual('1.0.0-$word', '2.0.0-$word'),
        false,
        reason: 'unrelated releases equated through $word',
      );
    }
    for (final String stamp in <String>[
      '20260412',
      '20260412a',
      '20260412ab',
    ]) {
      expect(
        commitHashLikeTokensFromVersion('1.0.0+$stamp'),
        isEmpty,
        reason: '$stamp read as a build hash',
      );
    }
    // Real digests still count.
    expect(commitHashLikeTokensFromVersion('26.06.9df4c85'), <String>{
      '9df4c85',
    });
    expect(
      versionsEffectivelyEqual('1.5.3-DEV (75094D8)', 'debug-75094d8'),
      true,
    );
  });

  test('predicates are total over a seeded shuffle of the corpus', () {
    // Guards against a primitive throwing (RangeError/FormatException) on an
    // input shape nobody wrote an example for.
    final Random random = Random(20260801);
    final List<String> shuffled = List<String>.from(_versionCorpus)
      ..shuffle(random);
    for (final String installed in shuffled) {
      for (final String latest in shuffled) {
        final App app = _app(
          installed: installed.isEmpty ? null : installed,
          latest: latest,
          settings: <String, dynamic>{'versionDetection': 'auto'},
        );
        expect(
          () {
            versionsEffectivelyEqual(installed, latest);
            compareVersionsByNumericSegments(installed, latest);
            versionOrderIsUnclear(installed, latest);
            installedVersionIsNewerOrEqual(installed, latest);
            reconcileVersionDifferences(installed, latest);
            appHasActionableUpdate(app);
            versionOrderUncertainUpdate(app);
            appIsUpToDateForFiltering(app);
            appUpdateIsUserVisible(app);
            normalizeSkippedLatestVersion(app);
          },
          returnsNormally,
          reason: 'threw for ($installed, $latest)',
        );
      }
    }
  });
}
