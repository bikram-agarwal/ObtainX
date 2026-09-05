import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/http/obtainx_user_agent.dart';

void main() {
  test('default user agent is ObtainX', () {
    expect(obtainXUserAgent, 'ObtainX');
  });

  test('fills in a User-Agent only when the source did not send one', () {
    expect(
      withDefaultObtainXUserAgent(null)[HttpHeaders.userAgentHeader],
      obtainXUserAgent,
    );
    expect(
      withDefaultObtainXUserAgent(<String, String>{
        'Accept': 'application/json',
      })[HttpHeaders.userAgentHeader],
      obtainXUserAgent,
    );

    final Map<String, String> alreadySet = withDefaultObtainXUserAgent(
      <String, String>{'user-agent': 'curl/8.0.1'},
    );
    expect(alreadySet['user-agent'], 'curl/8.0.1');
    expect(
      alreadySet.values.where((String value) => value.contains('ObtainX')),
      isEmpty,
    );

    expect(
      withDefaultObtainXUserAgent(<String, String>{
        'User-Agent': 'F-Droid/1.0 (+https://f-droid.org)',
      })['User-Agent'],
      'F-Droid/1.0 (+https://f-droid.org)',
    );
  });
}
