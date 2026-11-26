// #344: GitHub counts a failed response as a rate limit only when GitHub says
// so, by the same rule as every other source, and never names a wait GitHub
// didn't give.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/custom_errors.dart';

Matcher _rateLimit(Object? remainingMinutes) => throwsA(
  isA<RateLimitError>().having(
    (RateLimitError e) => e.remainingMinutes,
    'remainingMinutes',
    remainingMinutes,
  ),
);

void main() {
  final GitHub github = GitHub();

  test('a plain 403 is a refusal, left to the caller', () {
    expect(
      () => github.rateLimitErrorCheck(Response('', 403)),
      returnsNormally,
    );
    // No JSON message either (a proxy's or block page's HTML).
    expect(
      () => github.githubErrorCheck(Response('<html>Forbidden</html>', 403)),
      returnsNormally,
    );
  });

  test('a spent quota waits until GitHub\'s reset time', () {
    final int inTenMinutes =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600;
    expect(
      () => github.rateLimitErrorCheck(
        Response(
          '',
          403,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '$inTenMinutes',
          },
        ),
      ),
      _rateLimit(10),
    );
  });

  test('a secondary rate limit waits for its Retry-After', () {
    expect(
      () => github.githubErrorCheck(
        Response(
          '{"message": "You have exceeded a secondary rate limit."}',
          403,
          headers: {'retry-after': '120'},
        ),
      ),
      _rateLimit(2),
    );
  });

  test('a rate limit without a time does not invent one', () {
    expect(
      () => github.rateLimitErrorCheck(Response('', 429)),
      _rateLimit(isNull),
    );
  });
}
