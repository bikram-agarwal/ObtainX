import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/notifications_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

class _FakeNotificationsProvider extends NotificationsProvider {
  final List<int> cancelled = [];

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}

class _PendingTestProvider implements AppsProvider {
  @override
  AppListings apps = AppListings();
  @override
  final SettingsProvider settingsProvider = SettingsProvider();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

App _app(
  String id, {
  bool pending = true,
  bool trackOnly = false,
  bool onDemandOnly = false,
}) => App(
  id: id,
  url: 'https://github.com/example/$id',
  author: 'Example',
  name: id,
  installedVersion: '1.0',
  latestVersion: pending ? '2.0' : '1.0',
  apkUrls: const [MapEntry('app.apk', 'https://example.org/app.apk')],
  preferredApkIndex: 0,
  additionalSettings: {'trackOnly': trackOnly, 'onDemandOnly': onDemandOnly},
);

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

  // Phase C C-1: the refresh paths judge each notification by the apps the
  // background task posts in it: installable updates in one, track-only in
  // the other; on-demand apps are never background-checked.
  group('clearStaleUpdateNotifications', () {
    Future<List<int>> cancelledWith(List<App> apps) async {
      final appsProvider = _PendingTestProvider();
      for (final App app in apps) {
        appsProvider.apps[app.id] = AppInMemory(app, null, null, null);
      }
      final notifications = _FakeNotificationsProvider();
      await appsProvider.clearStaleUpdateNotifications(notifications);
      return notifications.cancelled;
    }

    test('nothing pending clears both notifications', () async {
      expect(await cancelledWith([_app('a', pending: false)]), [
        updateNotificationId,
        trackOnlyUpdateNotificationId,
      ]);
    });

    test('a pending track-only app keeps only its own notification', () async {
      expect(await cancelledWith([_app('t', trackOnly: true)]), [
        updateNotificationId,
      ]);
    });

    test('a pending installable app keeps only its own notification', () async {
      expect(await cancelledWith([_app('a')]), [trackOnlyUpdateNotificationId]);
    });

    test('a pending on-demand app keeps neither notification', () async {
      expect(await cancelledWith([_app('z', onDemandOnly: true)]), [
        updateNotificationId,
        trackOnlyUpdateNotificationId,
      ]);
    });
  });
}
