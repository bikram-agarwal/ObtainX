import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';

// The "checking for updates" notification's Stop action (v1.7.5 sync U1)
// reaches Dart as `cancelUpdateCheck` on the notifications channel, which
// MainActivity.stopUpdateCheckFromNotification sends. Registration is
// once per process, so this test has its own file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the notification Stop reaches the update-check handler, and download '
      'cancels still reach theirs', () async {
    int stops = 0;
    final List<String> cancelledDownloads = [];
    NativeFeatures.registerDownloadCancelHandler(
      cancelledDownloads.add,
      onUpdateCheckStop: () => stops++,
    );

    Future<void> send(MethodCall call) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'dev.imranr.obtainium/notifications',
            const StandardMethodCodec().encodeMethodCall(call),
            (_) {},
          );
    }

    await send(const MethodCall('cancelUpdateCheck'));
    expect(stops, 1);
    expect(cancelledDownloads, isEmpty);

    await send(const MethodCall('cancelDownload', 'com.example.app'));
    expect(stops, 1);
    expect(cancelledDownloads, ['com.example.app']);
  });
}
