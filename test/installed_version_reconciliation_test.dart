import 'package:android_package_manager/android_package_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

// Replace the platform boundary only, calling the production extensions.
class _Provider implements AppsProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

PackageInfo _package(String version, {int code = 106}) {
  return _InstalledPackage(version, code);
}

class _InstalledPackage extends PackageInfo {
  _InstalledPackage(String version, int code)
    : super(
        installLocation: AndroidInstallLocation.unspecified,
        packageName: 'org.example.app',
        versionName: version,
        versionCode: code,
      );
}

App _app({
  String? installed = 'old alias',
  String latest = '107',
  String mode = 'auto',
}) {
  return App(
    id: 'org.example.app',
    url: 'https://github.com/example/app',
    author: 'Example',
    name: 'Example',
    installedVersion: installed,
    latestVersion: latest,
    preferredApkIndex: 0,
    apkUrls: const [MapEntry('app.apk', 'https://example.com/latest.apk')],
    additionalSettings: {'versionDetection': mode},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final provider = _Provider();
  for (final mode in ['auto', 'standard']) {
    for (final (device, latest, relation) in [
      ('1.1.0', 'v1.1.0', VersionRelation.same),
      ('1.2.0', '1.1.0', VersionRelation.newer),
      ('1.0.0', '1.1.0', VersionRelation.older),
      (
        '2026.04.27.917519149.2-release',
        '2026.03.12.885261117.2-release',
        VersionRelation.newer,
      ),
      ('1.0.915254043.release', '1.0.896819557.release', VersionRelation.newer),
      ('9.18.50', '107', VersionRelation.unknown),
      ('2.19.1 (git 67d1c5a)', 'v2.19.1', VersionRelation.same),
    ]) {
      test(
        '$mode preserves $device against $latest through save and reload',
        () {
          final original = _app(latest: latest, mode: mode);
          final info = _package(device);
          final corrected = provider.getCorrectedInstallStatusAppIfPossible(
            original,
            info,
          )!;
          expect(corrected.installedVersion, device);
          expect(corrected.additionalSettings[observedVersionNameKey], device);
          expect(corrected.additionalSettings[observedVersionCodeKey], 106);
          expect(versionDecisionForApp(corrected).relation, relation);
          final restored = App.fromJson(corrected.toJson());
          expect(restored.installedVersion, device);
          expect(versionDecisionForApp(restored).relation, relation);
          expect(
            provider.getCorrectedInstallStatusAppIfPossible(restored, info),
            isNull,
          );
          expect(original.installedVersion, 'old alias');
        },
      );
    }
  }
  test('Pseudo preserves source baseline while device observations change', () {
    var app = _app(installed: '106', mode: 'pseudo');
    for (final device in ['9.18.50', '9.19.0', '9.17.0']) {
      app =
          provider.getCorrectedInstallStatusAppIfPossible(
            app,
            _package(device),
          ) ??
          app;
      expect(app.installedVersion, '106');
      expect(app.additionalSettings[observedVersionNameKey], device);
      expect(appHasActionableUpdate(app), isTrue);
    }
  });
  for (final mode in ['auto', 'standard', 'pseudo', 'versionCode']) {
    test('install keeps captured release across refresh in $mode', () {
      final downloaded = _app(latest: '107', mode: mode);
      final info = _package('9.18.50');
      final receipt = InstallReleaseSnapshot.fromApp(
        downloaded,
      ).withPackage(info);
      final saved = recordConfirmedInstall(
        downloaded.copyWith(latestVersion: '108'),
        receipt,
        info,
      );
      expect(saved.latestVersion, '108');
      expect(
        saved.installedVersion,
        mode == 'pseudo'
            ? '107'
            : mode == 'versionCode'
            ? '106'
            : '9.18.50',
      );
      expect(saved.additionalSettings[observedVersionNameKey], '9.18.50');
      expect(
        InstallReleaseSnapshot.fromJson(
          saved.additionalSettings[confirmedInstallReleaseKey],
        )!.version,
        '107',
      );
      expect(appHasActionableUpdate(saved), isTrue);
      final restored = App.fromJson(saved.toJson());
      expect(appHasActionableUpdate(restored), isTrue);
      expect(
        provider.getCorrectedInstallStatusAppIfPossible(restored, info),
        isNull,
      );
    });
  }
  test(
    'confirmed receipt outranks misleading raw names without overwriting them',
    () {
      final app = _app(latest: '99.0');
      final info = _package('9.18.50');
      final receipt = InstallReleaseSnapshot.fromApp(app).withPackage(info);
      final installed = recordConfirmedInstall(app, receipt, info);
      expect(installed.installedVersion, '9.18.50');
      expect(
        versionDecisionForApp(installed).reason,
        'confirmedInstalledRelease',
      );
      expect(appIsUpToDateForFiltering(installed), isTrue);
      expect(
        appHasActionableUpdate(installed.copyWith(latestVersion: '100.0')),
        isTrue,
      );
    },
  );
  test('pending install survives restart and is confirmed only by its APK', () {
    final app = _app(installed: '9.17.0');
    final info = _package('9.18.50');
    final receipt = InstallReleaseSnapshot.fromApp(app).withPackage(info);
    final pending = recordPendingInstall(app, receipt);
    expect(pending.installedVersion, '9.17.0');
    expect(pending.additionalSettings[confirmedInstallReleaseKey], isNull);
    final restored = App.fromJson(
      pending.toJson(),
    ).copyWith(latestVersion: '108');
    final oldDevice = provider.getCorrectedInstallStatusAppIfPossible(
      restored,
      _package('9.17.0', code: 105),
    )!;
    expect(oldDevice.additionalSettings[confirmedInstallReleaseKey], isNull);
    final confirmed = provider.getCorrectedInstallStatusAppIfPossible(
      oldDevice,
      info,
    )!;
    expect(confirmed.additionalSettings[pendingInstallReleaseKey], isNull);
    expect(
      InstallReleaseSnapshot.fromJson(
        confirmed.additionalSettings[confirmedInstallReleaseKey],
      )!.version,
      '107',
    );
    expect(confirmed.installedVersion, '9.18.50');
    expect(appHasActionableUpdate(confirmed), isTrue);
  });
  test(
    'cancellation removes only its own attempt and cannot confirm later',
    () {
      final app = _app();
      final info = _package('9.18.50');
      final first = InstallReleaseSnapshot.fromApp(app).withPackage(info);
      final second = InstallReleaseSnapshot.fromApp(
        app.copyWith(latestVersion: '108'),
      ).withPackage(info);
      final pending = recordPendingInstall(app, second);
      expect(discardPendingInstall(pending, first), same(pending));
      final cancelled = discardPendingInstall(pending, second);
      final observed = provider.getCorrectedInstallStatusAppIfPossible(
        cancelled,
        info,
      )!;
      expect(observed.additionalSettings[confirmedInstallReleaseKey], isNull);
      expect(versionOrderUncertainUpdate(observed), isTrue);
    },
  );
  test(
    'receipt is invalidated by source, extraction, package, or asset changes',
    () {
      final app = _app();
      final info = _package('9.18.50');
      final receipt = InstallReleaseSnapshot.fromApp(app).withPackage(info);
      final installed = recordConfirmedInstall(app, receipt, info);
      for (final changed in [
        installed.copyWith(url: 'https://github.com/different/app'),
        installed.copyWith(overrideSource: 'HTML'),
        installed.copyWith(
          additionalSettings: {
            ...installed.additionalSettings,
            'versionExtractionRegEx': 'changed',
          },
        ),
        installed.copyWith(
          apkUrls: const [
            MapEntry('other.apk', 'https://example.com/other.apk'),
          ],
        ),
        installed.copyWith(installedVersion: 'external label'),
      ]) {
        expect(
          versionDecisionForApp(changed).relation,
          VersionRelation.unknown,
        );
      }
      final external = provider.getCorrectedInstallStatusAppIfPossible(
        installed,
        _package('9.20.0', code: 108),
      )!;
      expect(external.additionalSettings[confirmedInstallReleaseKey], isNull);
      expect(external.installedVersion, '9.20.0');
      final switched = recordConfirmedInstall(
        app.copyWith(url: 'https://github.com/different/app'),
        receipt,
        info,
      );
      expect(switched.additionalSettings[confirmedInstallReleaseKey], isNull);
      expect(switched.installedVersion, '9.18.50');
    },
  );
  test(
    'refresh merge preserves live observations and confirmed installation',
    () {
      final requested = _app();
      final info = _package('9.18.50');
      final live = recordConfirmedInstall(
        requested,
        InstallReleaseSnapshot.fromApp(requested).withPackage(info),
        info,
      );
      final merged = mergeFetchedUpdateWithLiveState(
        requestedApp: requested,
        liveApp: live,
        fetchedApp: requested.copyWith(latestVersion: '108'),
      )!;
      expect(merged.installedVersion, '9.18.50');
      expect(
        merged.additionalSettings[confirmedInstallReleaseKey],
        live.additionalSettings[confirmedInstallReleaseKey],
      );
      expect(merged.latestVersion, '108');
      expect(appHasActionableUpdate(merged), isTrue);
    },
  );
  test('mutable URL has a different cache identity for each release', () {
    final first = InstallReleaseSnapshot.fromApp(_app());
    final second = InstallReleaseSnapshot.fromApp(_app(latest: '108'));
    expect(
      downloadReleaseCacheKey(first),
      isNot(downloadReleaseCacheKey(second)),
    );
    expect(
      downloadReleaseCacheKey(first),
      downloadReleaseCacheKey(InstallReleaseSnapshot.fromJson(first.toJson())!),
    );
  });
  test('malformed receipts are ignored without preventing app load', () {
    final snapshot = InstallReleaseSnapshot.fromApp(_app()).toJson();
    for (final value in [
      null,
      [],
      {},
      {...snapshot, 'overrideSource': 4},
      {...snapshot, 'versionName': []},
    ]) {
      expect(InstallReleaseSnapshot.fromJson(value), isNull);
    }
  });
  test('Pseudo cannot make incompatible device versions detectable', () {
    final app = _app(mode: 'pseudo');
    expect(
      provider.isVersionDetectionPossible(
        AppInMemory(app, null, _package('9.18.50'), null),
      ),
      isFalse,
    );
    expect(
      provider.isVersionDetectionPossible(
        AppInMemory(
          app.copyWith(latestVersion: '9.19.0'),
          null,
          _package('9.18.50'),
          null,
        ),
      ),
      isTrue,
    );
  });
  test('a late result does not erase a different pending release', () {
    final app = _app();
    final oldInfo = _package('9.18.50');
    final first = InstallReleaseSnapshot.fromApp(app).withPackage(oldInfo);
    final newer = app.copyWith(latestVersion: '108');
    final second = InstallReleaseSnapshot.fromApp(
      newer,
    ).withPackage(_package('9.19.0', code: 107));
    final late = recordConfirmedInstall(
      recordPendingInstall(newer, second),
      first,
      oldInfo,
    );
    expect(
      InstallReleaseSnapshot.fromJson(
        late.additionalSettings[pendingInstallReleaseKey],
      )!.version,
      '108',
    );
    expect(appHasActionableUpdate(late), true);
  });
}
