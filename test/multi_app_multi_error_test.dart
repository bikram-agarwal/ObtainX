import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';

void main() {
  test('apps failing the same way share one error group', () {
    final MultiAppMultiError errors = MultiAppMultiError()
      ..add('a', 'offline')
      ..add('b', 'offline')
      ..add('c', 'offline')
      ..add('d', 'rate limited');
    expect(errors.idsByErrorString, {
      'offline': ['a', 'b', 'c'],
      'rate limited': ['d'],
    });
  });

  test('an app added again leaves its old group', () {
    final MultiAppMultiError errors = MultiAppMultiError()
      ..add('a', 'offline')
      ..add('b', 'offline')
      ..add('a', 'rate limited');
    expect(errors.idsByErrorString, {
      'offline': ['b'],
      'rate limited': ['a'],
    });
  });
}
