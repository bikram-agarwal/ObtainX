import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/installers/dhizuku_installer.dart';
import 'package:obtainium/installers/shizuku_installer.dart';
import 'package:obtainium/installers/shizuku_plugin.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shizuku_apk_installer/shizuku_apk_installer_platform_interface.dart';

// Adapted from upstream v1.7.4 for ObtainX (INST-4/5/6/7): Dhizuku is its own
// installer mode rather than a backend of Shizuku mode, so upstream's
// `shizukuInstallerMode` cases (default auto, explicit backends, Galaxy Store
// refused on the Dhizuku backend) don't apply. The retry counts are the
// fork's (#230: three retries).
class _FakeShizukuPlatform extends ShizukuApkInstallerPlatform {
  String? mode;
  String? permissionResult = 'granted_adb';
  int checkCalls = 0;
  int servicesNotFoundFailures = 0;
  int platformVersionCalls = 0;
  final installs =
      <
        ({
          List<String> uris,
          String source,
          String? mode,
          bool requestUpdateOwnership,
        })
      >[];

  /// When set, installs wait on it, as a stalled native call does.
  Completer<int?>? stalledInstall;

  /// The stalled native job in flight. Like the real plugin, any call made
  /// while it is active cancels it and is itself answered with `cancelled`;
  /// the stalled call's own result never arrives.
  bool _stalledJobActive = false;

  void _cancelStalledJob() {
    if (_stalledJobActive) {
      _stalledJobActive = false;
      throw PlatformException(code: 'cancelled', message: 'Job cancelled');
    }
  }

  @override
  Future<int?> getPlatformVersion() async {
    platformVersionCalls++;
    _cancelStalledJob();
    return 26;
  }

  @override
  Future<void> setInstallerMode(String mode) async {
    _cancelStalledJob();
    this.mode = mode;
  }

  @override
  Future<String?> checkPermission() async {
    _cancelStalledJob();
    checkCalls++;
    if (servicesNotFoundFailures > 0) {
      servicesNotFoundFailures--;
      return 'services_not_found';
    }
    return permissionResult;
  }

  @override
  Future<int?> installAPKs(
    List<String> apkFilesURIs,
    String fakeInstallSource, {
    String? packageName,
    bool requestUpdateOwnership = false,
  }) async {
    installs.add((
      uris: apkFilesURIs,
      source: fakeInstallSource,
      mode: mode,
      requestUpdateOwnership: requestUpdateOwnership,
    ));
    final Completer<int?>? stalled = stalledInstall;
    if (stalled != null) {
      _stalledJobActive = true;
      return stalled.future;
    }
    return 0;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeShizukuPlatform fake;
  late SettingsProvider settings;

  setUp(() async {
    fake = _FakeShizukuPlatform();
    ShizukuApkInstallerPlatform.instance = fake;
    SharedPreferences.setMockInitialValues({});
    settings = SettingsProvider();
    settings.prefs = await SharedPreferences.getInstance();
  });

  test('each installer selects its own backend', () async {
    expect(await ShizukuInstaller(settings).checkPermission(), isTrue);
    expect(fake.mode, 'shizuku');

    fake.permissionResult = 'granted_owner';
    expect(await DhizukuInstaller(settings).checkPermission(), isTrue);
    expect(fake.mode, 'dhizuku');
  });

  test('ensurePermission retries a transient missing binder', () async {
    fake.servicesNotFoundFailures = 2;

    await ShizukuInstaller(settings).ensurePermission();

    expect(fake.checkCalls, 3);
  });

  test('ensurePermission surfaces persistent backend errors', () async {
    fake.permissionResult = 'services_not_found';
    await expectLater(
      ShizukuInstaller(settings).ensurePermission(),
      throwsA(isA<ObtainiumError>()),
    );
    expect(fake.checkCalls, 4);
  });

  test('each single or split install forwards its selected source', () async {
    final installer = ShizukuInstaller(settings);
    for (final source in [
      '',
      'com.android.vending',
      'com.sec.android.app.samsungapps',
      '',
    ]) {
      expect(
        (await installer.installApk(
          ['/tmp/base.apk'],
          appId: 'com.example.app',
          installOptions: {'installerPackageName': source},
        )).isSuccess,
        isTrue,
      );
    }
    await installer.installApk(
      ['/tmp/base.apk', '/tmp/split.apk'],
      appId: 'com.example.app',
      installOptions: {
        'installerPackageName': 'com.sec.android.app.samsungapps',
      },
    );
    expect(fake.installs.map((i) => i.source), [
      '',
      'com.android.vending',
      'com.sec.android.app.samsungapps',
      '',
      'com.sec.android.app.samsungapps',
    ]);
    expect(fake.installs.map((i) => i.mode).toSet(), {'shizuku'});
    expect(fake.installs.last.uris, [
      'file:///tmp/base.apk',
      'file:///tmp/split.apk',
    ]);
  });

  test('forwards update ownership for new installs only', () async {
    final installer = ShizukuInstaller(settings);
    await installer.installApk(
      ['/tmp/base.apk'],
      appId: 'com.example.app',
      installOptions: {'requestUpdateOwnership': true},
    );
    await installer.installApk(
      ['/tmp/base.apk'],
      appId: 'com.example.app',
      installOptions: {'requestUpdateOwnership': false},
    );
    expect(fake.installs.map((i) => i.requestUpdateOwnership), [true, false]);
  });

  test(
    'Dhizuku forwards update ownership but never an install source',
    () async {
      final installer = DhizukuInstaller(settings);
      await installer.installApk(
        ['/tmp/base.apk', '/tmp/split.apk'],
        appId: 'com.example.app',
        installOptions: {
          'installerPackageName': 'com.sec.android.app.samsungapps',
          'requestUpdateOwnership': true,
        },
      );
      expect(fake.installs.single.mode, 'dhizuku');
      expect(fake.installs.single.source, isEmpty);
      expect(fake.installs.single.requestUpdateOwnership, isTrue);
    },
  );

  group('a stalled plugin call (D15, #3369)', () {
    test('is released after the grace with one sacrificial call, freeing the queue', () async {
      final Duration defaultGrace = shizukuStalledCallGrace;
      shizukuStalledCallGrace = const Duration(milliseconds: 200);
      addTearDown(() => shizukuStalledCallGrace = defaultGrace);
      fake.stalledInstall = Completer<int?>();
      final installer = ShizukuInstaller(settings);
      final Future<Object?> stalled = installer
          .installApk(['/tmp/base.apk'], appId: 'com.example.app')
          .then<Object?>((r) => r, onError: (Object e) => e);
      await pumpEventQueue();
      expect(fake.installs, hasLength(1));

      // Queued behind the stalled install: can't reach the plugin yet.
      final Future<String?> next = runExclusiveShizukuPluginCall(
        () => fake.checkPermission(),
      );
      await pumpEventQueue();
      expect(fake.checkCalls, 0);

      var released = false;
      final Future<void> release = installer.releaseStalledInstall().then(
        (_) => released = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(released, isFalse, reason: 'still within the grace');
      expect(fake.platformVersionCalls, 0);

      await release;
      expect(fake.platformVersionCalls, 1);
      expect(await next, 'granted_adb');
      final Object? stalledOutcome = await stalled;
      expect(stalledOutcome, isA<PlatformException>());
      expect((stalledOutcome! as PlatformException).code, 'cancelled');
    });

    test('waits out the grace and leaves a call that returns alone', () async {
      final Completer<int?> slow = Completer<int?>();
      final ShizukuPluginCall<int?> call = startExclusiveShizukuPluginCall(
        () => slow.future,
      );
      await pumpEventQueue();
      final Future<void> release = call.releaseIfStalled(
        grace: const Duration(seconds: 2),
      );
      slow.complete(0);
      await release;
      expect(await call.result, 0);
      expect(fake.platformVersionCalls, 0);
    });

    test('a call still waiting in the queue is dropped from it', () async {
      final Completer<void> blocker = Completer<void>();
      final ShizukuPluginCall<void> first = startExclusiveShizukuPluginCall(
        () => blocker.future,
      );
      var queuedRan = false;
      final ShizukuPluginCall<void> queued = startExclusiveShizukuPluginCall(
        () async => queuedRan = true,
      );
      final Future<Object?> queuedOutcome = queued.result.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await queued.releaseIfStalled(grace: Duration.zero);
      blocker.complete();
      await first.result;
      await pumpEventQueue();
      expect(queuedRan, isFalse);
      expect(await queuedOutcome, isA<PlatformException>());
      expect(fake.platformVersionCalls, 0);
    });
  });
}
