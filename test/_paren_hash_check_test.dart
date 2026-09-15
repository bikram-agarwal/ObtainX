import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/version/version_strings.dart';

void main() {
  test('paren hash equals numeric core', () {
    expect(
      reconcileVersionDifferences('26.06', '26.06 (9df4c85)')?.areEqual,
      true,
    );
    expect(versionsEffectivelyEqual('26.06', '26.06 (9df4c85)'), true);
  });
}
