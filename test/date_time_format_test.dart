// #355: dates follow the phone's day/month/year order (Android's
// DateFormat.getDateFormatOrder), not the app's language.

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/date_time_format.dart';

void main() {
  final DateTime now = DateTime(2026, 11, 20);
  final DateTime thisYear = DateTime(2026, 10, 12);
  final DateTime lastYear = DateTime(2025, 10, 12);

  tearDown(() => setSystemDateOrder(null));

  test('day-first regions put the day first', () {
    setSystemDateOrder('dMy');
    expect(formatDeviceOrderedNumericDate(thisYear, now: now), '12-10');
    expect(formatDeviceOrderedNumericDate(lastYear, now: now), '12-10-2025');
  });

  test('month-first regions put the month first', () {
    setSystemDateOrder('Mdy');
    expect(formatDeviceOrderedNumericDate(thisYear, now: now), '10-12');
    expect(formatDeviceOrderedNumericDate(lastYear, now: now), '10-12-2025');
  });

  test('year-first regions keep the year in front', () {
    setSystemDateOrder('yMd');
    expect(formatDeviceOrderedNumericDate(thisYear, now: now), '10-12');
    expect(formatDeviceOrderedNumericDate(lastYear, now: now), '2025-10-12');
  });

  test('no answer or a malformed one falls back to year-month-day', () {
    for (final String? order in [null, '', 'dM', 'dMyy', 'ddM', 'abc']) {
      setSystemDateOrder(order);
      expect(
        formatDeviceOrderedNumericDate(lastYear, now: now),
        '2025-10-12',
        reason: '$order',
      );
    }
  });
}
