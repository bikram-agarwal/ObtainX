import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/version/version_strings.dart';

void main() {
  test('an omitted parenthesized hash preserves the same release', () {
    expect(
      reconcileVersionDifferences('26.06', '26.06 (9df4c85)')?.areEqual,
      isTrue,
    );
    expect(versionsEffectivelyEqual('26.06', '26.06 (9df4c85)'), true);
    expect(
      compareVersionStrings('26.06', '26.06 (9df4c85)').relation,
      VersionRelation.same,
    );
  });
}
