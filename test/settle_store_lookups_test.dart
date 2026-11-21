import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';

const String _packageId = 'com.example.app';
const String _fdroidUrl = 'https://f-droid.org/packages/com.example.app/';

void main() {
  test('a throwing store does not cost the others their answers', () async {
    final List<String> failedStores = [];

    final Map<String, String?> answers = await settleStoreLookups(_packageId, {
      // What checkApkPure does when the package's own ID can't be looked up.
      'APKPure': Future<Map<String, String?>>.error(
        const SocketException('tapi.pureapk.com unreachable'),
      ),
      'F-Droid': Future.value(<String, String?>{_packageId: _fdroidUrl}),
      'PlayStore': Future.value(<String, String?>{_packageId: null}),
    }, onError: (String store, Object error) => failedStores.add(store));

    expect(answers, <String, String?>{
      'F-Droid': _fdroidUrl,
      'PlayStore': null,
    });
    expect(failedStores, ['APKPure']);
  });

  test('a store that confirmed absence is kept as absent', () async {
    final Map<String, String?> answers = await settleStoreLookups(_packageId, {
      'F-Droid': Future.value(<String, String?>{_packageId: null}),
    });

    expect(answers.containsKey('F-Droid'), isTrue);
    expect(answers['F-Droid'], isNull);
  });

  test('a lookup with no answer for the package is left out', () async {
    // What checkApkMirror returns when its batch request fails: nothing for
    // the package, which means "couldn't tell", not "absent".
    final Map<String, String?> answers = await settleStoreLookups(_packageId, {
      'APKMirror': Future.value(<String, String?>{}),
      'F-Droid': Future.value(<String, String?>{'com.example.other': null}),
    });

    expect(answers, isEmpty);
  });

  test('no lookups settle to no answers', () async {
    expect(await settleStoreLookups(_packageId, {}), isEmpty);
  });
}
