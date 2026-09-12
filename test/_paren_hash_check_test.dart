import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/version/version_strings.dart';

void main() {
  test('a missing parenthesized hash remains uncertain', () {
    expect(
      reconcileVersionDifferences('26.06', '26.06 (9df4c85)')?.areEqual,
      isNull,
    );
    expect(versionsEffectivelyEqual('26.06', '26.06 (9df4c85)'), false);
    expect(
      compareVersionStrings('26.06', '26.06 (9df4c85)').relation,
      VersionRelation.unknown,
    );
  });
}
