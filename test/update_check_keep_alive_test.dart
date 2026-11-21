// #360: a user-started update check holds UpdateCheckForegroundService for its
// whole run, releases it however the check ends, and only posts progress once
// Android would show the service's notification anyway.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider_updates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel notificationsChannel = MethodChannel(
    'dev.imranr.obtainium/notifications',
  );
  late List<MethodCall> calls;
  late bool serviceStarts;

  setUp(() {
    calls = [];
    serviceStarts = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, (
          MethodCall call,
        ) async {
          calls.add(call);
          return call.method == 'startUpdateCheckForegroundService'
              ? serviceStarts
              : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, null);
  });

  List<String> methods() => [for (final MethodCall c in calls) c.method];

  test('holds the service for the check and releases it after', () async {
    final int result = await runUpdateCheckKeptAlive((_) async {
      expect(methods(), ['startUpdateCheckForegroundService']);
      return 7;
    });
    expect(result, 7);
    expect(methods(), [
      'startUpdateCheckForegroundService',
      'stopUpdateCheckForegroundService',
    ]);
  });

  test('releases the service when the check fails', () async {
    await expectLater(
      runUpdateCheckKeptAlive<void>((_) async => throw StateError('failed')),
      throwsStateError,
    );
    expect(methods().last, 'stopUpdateCheckForegroundService');
  });

  test(
    'without the service, runs the check bare and releases nothing',
    () async {
      serviceStarts = false;
      Object? onProgress = 'not called';
      await runUpdateCheckKeptAlive((progress) async => onProgress = progress);
      expect(onProgress, isNull);
      expect(methods(), ['startUpdateCheckForegroundService']);
    },
  );

  test('progress waits out the first 10 s, is spaced 1 s apart, and the last '
      'count always posts', () async {
    Duration now = Duration.zero;
    await runUpdateCheckKeptAlive((progress) async {
      progress!(1, 10); // Android still holds the notification back.
      now = const Duration(seconds: 10);
      progress(2, 10);
      now = const Duration(seconds: 10, milliseconds: 500);
      progress(3, 10); // Under 1 s since the last post.
      progress(10, 10); // The last count goes through regardless.
    }, elapsed: () => now);
    expect(
      [
        for (final MethodCall c in calls)
          if (c.method == 'showUpdateCheckProgress')
            (c.arguments as Map<Object?, Object?>)['completed'],
      ],
      [2, 10],
    );
    expect(methods().last, 'stopUpdateCheckForegroundService');
  });
}
