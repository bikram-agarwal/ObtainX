import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';

void main() {
  test('installed version reconciliation keeps source latest when equal', () {
    expect(reconciledInstalledVersionFromLatest('1.1.0', '1.1.0'), '1.1.0');
  });

  test(
    'installed version reconciliation keeps source latest when equivalent',
    () {
      expect(reconciledInstalledVersionFromLatest('1.1.0', 'v1.1.0'), 'v1.1.0');
    },
  );

  test('installed version reconciliation accepts higher installed version', () {
    expect(reconciledInstalledVersionFromLatest('1.2.0', '1.1.0'), '1.2.0');
  });

  test('installed version reconciliation accepts lower installed version', () {
    expect(reconciledInstalledVersionFromLatest('1.0.0', '1.1.0'), '1.0.0');
  });

  test(
    'installed version reconciliation accepts long google release versions',
    () {
      const installed = '2026.04.27.917519149.2-release';
      const latest = '2026.04.27.917519149.2-release';
      const previousInstalled = '2026.03.12.885261117.2-release';

      expect(reconciledInstalledVersionFromLatest(installed, latest), latest);
      final reconciled = reconcileVersionDifferences(
        installed,
        previousInstalled,
      );
      expect(reconciled?.key, false);
      expect(reconciled?.value, installed);
    },
  );

  test(
    'installed version reconciliation accepts dotted release suffix versions',
    () {
      const installed = '1.0.915254043.release';
      const previousInstalled = '1.0.896819557.release';

      final reconciled = reconcileVersionDifferences(
        installed,
        previousInstalled,
      );
      expect(reconciled?.key, false);
      expect(reconciled?.value, installed);
    },
  );

  test('installed version reconciliation ignores unreconcilable version', () {
    expect(reconciledInstalledVersionFromLatest('9.18.50', '107'), isNull);
  });

  test(
    'disabled version detection accepts installed version when stored version reconciles',
    () {
      expect(
        reconciledInstalledVersionForDisabledVersionDetection(
          '1.2.0',
          '1.1.0',
          'release-2026-05-27',
        ),
        '1.2.0',
      );
    },
  );

  test(
    'disabled version detection ignores installed version when no version reconciles',
    () {
      expect(
        reconciledInstalledVersionForDisabledVersionDetection(
          '9.18.50',
          '106',
          '107',
        ),
        isNull,
      );
    },
  );
}
