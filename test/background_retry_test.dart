// A background update check retries a failed app within the same run only
// when asking again can help (backgroundRetryWaitSeconds).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';

ObtainiumError _httpError(int statusCode) => ObtainiumError(
  'HTTP $statusCode',
  code: 'HTTP_ERROR',
  data: {'statusCode': statusCode},
);

void main() {
  test('a rate limit is waited out in full', () {
    expect(backgroundRetryWaitSeconds(RateLimitError(45), attempt: 0), 45 * 60);
    expect(
      backgroundRetryWaitSeconds(RateLimitError.withoutRetryTime(), attempt: 0),
      RateLimitError.defaultRetryWaitMinutes * 60,
    );
  });

  test('a CAPTCHA waits like a rate limit', () {
    expect(
      backgroundRetryWaitSeconds(BotVerificationError('Farsroid'), attempt: 0),
      RateLimitError.defaultRetryWaitMinutes * 60,
    );
  });

  test('a transient failure is retried soon, a little later each time', () {
    expect(backgroundRetryWaitSeconds(_httpError(503), attempt: 0), 1);
    expect(backgroundRetryWaitSeconds(_httpError(503), attempt: 2), 3);
    expect(
      backgroundRetryWaitSeconds(const SocketException('offline'), attempt: 1),
      2,
    );
  });

  // #339: repeating a refused request seconds later only adds load.
  test('a plain 403 refusal is reported now, not retried', () {
    expect(backgroundRetryWaitSeconds(_httpError(403), attempt: 0), isNull);
  });

  test('a source that answered with nothing usable is not asked again', () {
    expect(backgroundRetryWaitSeconds(NoReleasesError(), attempt: 0), isNull);
    expect(backgroundRetryWaitSeconds(NoAPKError(), attempt: 0), isNull);
  });

  test('nothing is retried after the last attempt', () {
    expect(backgroundRetryWaitSeconds(RateLimitError(1), attempt: 4), isNull);
    expect(backgroundRetryWaitSeconds(_httpError(503), attempt: 4), isNull);
  });
}
