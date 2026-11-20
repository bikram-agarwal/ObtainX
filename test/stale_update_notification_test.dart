import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/notifications_provider.dart';

class _FakeNotificationsProvider extends NotificationsProvider {
  final List<int> cancelled = [];

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}

void main() {
  test('cancels the update notification when no updates remain', () async {
    final provider = _FakeNotificationsProvider();
    await clearStaleUpdateNotification(provider, []);
    expect(provider.cancelled, [updateNotificationId]);
  });

  test('keeps the update notification when updates remain', () async {
    final provider = _FakeNotificationsProvider();
    await clearStaleUpdateNotification(provider, ['com.example.app']);
    expect(provider.cancelled, isEmpty);
  });

  // ObtainX posts track-only updates in a notification of their own.
  test('clears the track-only notification by its own id', () async {
    final provider = _FakeNotificationsProvider();
    await clearStaleUpdateNotification(
      provider,
      [],
      id: trackOnlyUpdateNotificationId,
    );
    await clearStaleUpdateNotification(provider, [
      'com.example.app',
    ], id: trackOnlyUpdateNotificationId);
    expect(provider.cancelled, [trackOnlyUpdateNotificationId]);
  });
}
