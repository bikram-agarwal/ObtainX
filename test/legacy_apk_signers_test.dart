import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:obtainium/utils/signing_cert_utils.dart';

class _FakeOreoDeviceInfoPlatform extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async => BaseDeviceInfo({
    'version': {
      'sdkInt': 27,
      'release': '8.1.0',
      'codename': 'REL',
      'incremental': '1',
      'previewSdkInt': 0,
      'securityPatch': '2020-01-01',
      'baseOS': '',
    },
    'board': '',
    'bootloader': '',
    'brand': '',
    'device': '',
    'display': '',
    'fingerprint': '',
    'hardware': '',
    'host': '',
    'id': '',
    'manufacturer': '',
    'model': '',
    'product': '',
    'supported32BitAbis': const ['armeabi-v7a'],
    'supported64BitAbis': const ['arm64-v8a'],
    'supportedAbis': const ['arm64-v8a', 'armeabi-v7a'],
    'tags': '',
    'type': 'user',
    'isPhysicalDevice': true,
    'freeDiskSize': 1,
    'totalDiskSize': 1,
    'isLowRamDevice': false,
    'physicalRamSize': 1,
    'availableRamSize': 1,
    'time': 0,
    'systemFeatures': const <String>[],
  });
}

// v1.7.4 sync D16 b: below Android 9 the package-manager plugin returns no
// signingInfo, so the archive's signers come from MainActivity instead, and a
// pinned expected certificate can still match.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DeviceInfoPlatform.instance = _FakeOreoDeviceInfoPlatform();

  const MethodChannel deviceApps = MethodChannel(
    'dev.imranr.obtainium/device_apps',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final Uint8List certificate = Uint8List.fromList(
    List<int>.generate(32, (i) => i),
  );

  tearDown(() => messenger.setMockMethodCallHandler(deviceApps, null));

  test('Android 8.1 reads archive signers natively', () async {
    final List<MethodCall> calls = [];
    messenger.setMockMethodCallHandler(deviceApps, (MethodCall call) async {
      calls.add(call);
      return call.method == 'getApkArchiveSignatures'
          ? <Uint8List>[certificate]
          : null;
    });

    expect(await apkFilesSigningCertHashes(['/data/app.apk']), {
      formatCertHash(certificate),
    });
    expect(calls.single.method, 'getApkArchiveSignatures');
    expect(calls.single.arguments, {'archiveFilePath': '/data/app.apk'});
  });

  test('an unreadable archive or a missing handler gives no signer', () async {
    messenger.setMockMethodCallHandler(deviceApps, (MethodCall call) async {
      return null;
    });
    expect(await apkSigningCertHashes('/data/broken.apk'), isEmpty);

    // A headless (background) engine has no MainActivity channel.
    messenger.setMockMethodCallHandler(deviceApps, null);
    expect(await apkSigningCertHashes('/data/app.apk'), isEmpty);
  });
}
