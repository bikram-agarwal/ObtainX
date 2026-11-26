import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/providers/virustotal_provider.dart';
import 'package:obtainium/utils/signing_cert_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Provider implements AppsProvider {
  @override
  AppListings apps = AppListings();
  @override
  final SettingsProvider settingsProvider = SettingsProvider();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

/// [code] recorded for v2.0, the release still on record.
App _blocked(
  String code, {
  String url = 'https://github.com/example/app',
  Map<String, dynamic> settings = const {},
  String? malwareScanStatus,
  String? reproducibleStatus,
  String? attestationStatus,
  // Null for a record kept without a release, as Android's own install
  // conflicts are.
  String? detail = 'v2.0',
}) {
  return App(
    id: 'org.example.app',
    url: url,
    author: 'Example',
    name: 'App',
    installedVersion: 'v1.0',
    latestVersion: 'v2.0',
    preferredApkIndex: 0,
    latestMalwareScanStatus: malwareScanStatus,
    latestReproducibleStatus: reproducibleStatus,
    latestAttestationStatus: attestationStatus,
    additionalSettings: {
      ...settings,
      needsAttentionCodeKey: code,
      needsAttentionDetailKey: ?detail,
    },
  );
}

App _withSettings(App app, Map<String, dynamic> settings) =>
    app.copyWith(additionalSettings: {...app.additionalSettings, ...settings});

const String _fdroidUrl = 'https://f-droid.org/packages/org.example.app';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a release blocked before install', () {
    final List<App> blocked = [
      _blocked(
        needsAttentionMalwareFlagged,
        malwareScanStatus: malwareScanStatusFlagged,
      ),
      _blocked(
        needsAttentionNotReproducible,
        url: _fdroidUrl,
        settings: {'enforceReproducibleBuilds': true},
        reproducibleStatus: reproducibleBuildStatusNotReproducible,
      ),
      _blocked(
        needsAttentionNoAttestation,
        settings: {
          GitHub.buildVerificationModeKey: GitHub.buildVerificationEnforce,
        },
        attestationStatus: githubAttestationStatusUnsupported,
      ),
    ];

    test('needs attention while it is the latest release', () {
      for (final App app in blocked) {
        expect(appNeedsAttention(app), isTrue, reason: app.toString());
      }
    });

    test('stops at a newer release, or once the user skips it', () {
      for (final App app in blocked) {
        expect(appNeedsAttention(app.copyWith(latestVersion: 'v2.1')), isFalse);
        expect(
          appNeedsAttention(
            _withSettings(app, {'skippedLatestVersion': 'v2.0'}),
          ),
          isFalse,
        );
      }
    });

    test('a malware flag stays until a verdict overturns it', () {
      final App flagged = blocked[0];
      // A rescan that couldn't finish says nothing new.
      expect(
        appNeedsAttention(
          flagged.copyWith(latestMalwareScanStatus: malwareScanStatusError),
        ),
        isTrue,
      );
      // A clean rescan, or excluding the app from scanning.
      expect(
        appNeedsAttention(
          flagged.copyWith(latestMalwareScanStatus: malwareScanStatusClean),
        ),
        isFalse,
      );
      expect(
        appNeedsAttention(flagged.copyWith(latestMalwareScanStatus: null)),
        isFalse,
      );
      // Rechecking the same release keeps the verdict; a new one drops it.
      expect(
        appNeedsAttention(
          mergeFetchedUpdateWithLiveState(
            requestedApp: flagged,
            liveApp: flagged,
            fetchedApp: flagged,
          )!,
        ),
        isTrue,
      );
      expect(
        appNeedsAttention(
          mergeFetchedUpdateWithLiveState(
            requestedApp: flagged,
            liveApp: flagged,
            fetchedApp: flagged.copyWith(latestVersion: 'v2.1'),
          )!,
        ),
        isFalse,
      );
    });

    test('an enforcement block ends when enforcement or the verdict does', () {
      final App notReproducible = blocked[1];
      expect(
        appNeedsAttention(
          _withSettings(notReproducible, {'enforceReproducibleBuilds': false}),
        ),
        isFalse,
      );
      expect(
        appNeedsAttention(
          notReproducible.copyWith(
            latestReproducibleStatus: reproducibleBuildStatusVerified,
          ),
        ),
        isFalse,
      );

      final App noAttestation = blocked[2];
      expect(
        appNeedsAttention(
          _withSettings(noAttestation, {
            GitHub.buildVerificationModeKey: GitHub.buildVerificationAudit,
          }),
        ),
        isFalse,
      );
      expect(
        appNeedsAttention(
          noAttestation.copyWith(
            latestAttestationStatus: githubAttestationStatusVerified,
          ),
        ),
        isFalse,
      );
    });
  });

  group('a background run', () {
    late _Provider provider;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      provider = _Provider();
      provider.settingsProvider.prefs = await SharedPreferences.getInstance();
    });

    test('skips a flagged release while scanning is on', () {
      final App flagged = _blocked(
        needsAttentionMalwareFlagged,
        malwareScanStatus: malwareScanStatusFlagged,
      );
      expect(provider.verificationWouldBlockAgain(flagged), isFalse);

      provider.settingsProvider.enableVirusTotalScanning = true;
      provider.settingsProvider.setSettingString(virusTotalApiKeyKey, 'key');
      storeApiKeyValidation('key', provider.settingsProvider);
      expect(provider.verificationWouldBlockAgain(flagged), isTrue);
      expect(
        provider.verificationWouldBlockAgain(
          _withSettings(flagged, {enableVirusTotalScanKey: false}),
        ),
        isFalse,
      );
    });

    test('skips a release that is not reproducible while enforced', () {
      final App notReproducible = _blocked(
        needsAttentionNotReproducible,
        url: _fdroidUrl,
        settings: {'enforceReproducibleBuilds': true},
        reproducibleStatus: reproducibleBuildStatusNotReproducible,
      );
      expect(provider.verificationWouldBlockAgain(notReproducible), isTrue);
      expect(
        provider.verificationWouldBlockAgain(
          _withSettings(notReproducible, {'enforceReproducibleBuilds': false}),
        ),
        isFalse,
      );
    });

    test('skips a release with no attestation while it can be enforced', () {
      final App noAttestation = _blocked(
        needsAttentionNoAttestation,
        settings: {
          GitHub.buildVerificationModeKey: GitHub.buildVerificationEnforce,
          GitHub.githubCredsKey: 'token',
        },
        attestationStatus: githubAttestationStatusUnsupported,
      );
      // Without a validated token nothing is enforced, so the install can run.
      expect(provider.verificationWouldBlockAgain(noAttestation), isFalse);

      GitHub.storePATValidation('token', provider.settingsProvider);
      expect(provider.verificationWouldBlockAgain(noAttestation), isTrue);
    });

    test('skips a release the signing check blocked while a check is on', () {
      // The pre-install signing check records its conflict against the
      // release (D5); the installed-signer comparison is on by default.
      final App conflict = _blocked(needsAttentionInstallConflict);
      expect(provider.verificationWouldBlockAgain(conflict), isTrue);

      provider.settingsProvider.verifySigningCertHashes = false;
      expect(provider.verificationWouldBlockAgain(conflict), isFalse);
      // An app's own expected hashes block whatever the global switch says.
      expect(
        provider.verificationWouldBlockAgain(
          _withSettings(conflict, {'allowedSigningCertHashes': 'a' * 64}),
        ),
        isTrue,
      );
    });

    test('still tries anything else', () {
      expect(
        provider.verificationWouldBlockAgain(
          // Android's own conflict: trying again can work once it's resolved.
          _blocked(needsAttentionInstallConflict, detail: null),
        ),
        isFalse,
      );
      expect(
        provider.verificationWouldBlockAgain(
          _blocked(
            needsAttentionNotReproducible,
            url: _fdroidUrl,
            settings: {'enforceReproducibleBuilds': true},
            // No verdict yet: the verification server can still catch up.
            reproducibleStatus: reproducibleBuildStatusNoData,
          ),
        ),
        isFalse,
      );
    });
  });

  test('the installed signer is read with its certificates (D5)', () async {
    final Uint8List certificate = Uint8List.fromList([1, 2, 3, 4]);
    const MethodChannel channel = MethodChannel(
      'dev.imranr.obtainium/device_apps',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method != 'getInstalledPackageInfo') return null;
      final Map<Object?, Object?> arguments =
          call.arguments as Map<Object?, Object?>;
      return <String, Object?>{
        'packageName': arguments['packageName'],
        // As MainActivity answers: signing info only when asked for.
        if (arguments['includeSigningCertificates'] == true)
          'signingInfo': <String, Object?>{
            'signingCertificateHistory': [certificate],
            'hasMultipleSigners': false,
          },
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    // What loaded apps hold: the light read, without certificates.
    expect((await getInstalledInfo('org.example.app'))?.signingInfo, isNull);
    expect(await installedSigningCertHashes('org.example.app'), {
      formatCertHash(certificate),
    });
  });
}
