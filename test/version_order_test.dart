import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';

void main() {
  test(
    'semver with parenthetical decimal build is not version order unclear',
    () {
      expect(
        versionOrderIsUnclear('8.8 (88957691)', '8.6 (86672232)'),
        false,
      );
      expect(compareVersionsByNumericSegments('8.8 (88957691)', '8.6 (86672232)'), 1);
    },
  );

  test('real hex in version string still participates in versionsEffectivelyEqual', () {
    expect(
      versionsEffectivelyEqual('1.5.3-DEV (75094D8)', 'debug-75094d8'),
      true,
    );
  });
}
