import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/app_sources/gitlab.dart';
import 'package:obtainium/app_sources/izzyondroid.dart';
import 'package:obtainium/app_sources/html.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:http/http.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Stub source that returns a controllable [APKDetails] from
/// [getLatestAPKDetails] without doing any network or HTML work.
///
/// Inherits APKMirror so [APKMirror]'s `enforceTrackOnly = true` flag is
/// kept (the size-keying branch we're testing only ever fires for
/// track-only APKMirror apps in production), and so [SourceProvider.getApp]
/// recognizes it via `source is APKMirror` for its (now removed) special
/// case checks. If those special cases ever come back, this stub will
/// surface the regression.
class _StubAPKMirror extends APKMirror {
  _StubAPKMirror({required this.version, this.apkSizeFromSource});
  final String version;
  final int? apkSizeFromSource;

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return APKDetails(
      version,
      const <MapEntry<String, String>>[],
      AppNames('Example', 'example'),
      apkSizeBytes: apkSizeFromSource,
    );
  }

  // tryInferringAppId hits the network in the real APKMirror; short-circuit
  // it so tests never reach out. We always pass an explicit appId via the
  // currentApp/additionalSettings path anyway, so this never fires — it's
  // here as a safety net.
  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async => null;
}

class _StubSource extends AppSource {
  _StubSource({
    this.apkUrls = const <MapEntry<String, String>>[
      MapEntry('example.apk', 'https://example.com/example.apk'),
    ],
    this.version = '2.0',
    this.versionCode,
  }) {
    hosts = <String>['example.com'];
    name = 'Example';
  }

  final List<MapEntry<String, String>> apkUrls;
  final String version;
  final int? versionCode;

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    return url;
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    return APKDetails(
      version,
      apkUrls,
      AppNames('Example Author', 'Readable Name'),
      versionCode: versionCode,
    );
  }

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    return 'org.example.app';
  }
}

class _StubFDroid extends FDroid {
  _StubFDroid(
    this.pageHtml, {
    bool hostChanged = false,
    bool hostIdenticalDespiteAnyChange = false,
  }) {
    this.hostChanged = hostChanged;
    this.hostIdenticalDespiteAnyChange = hostIdenticalDespiteAnyChange;
  }

  final String pageHtml;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    return Response(pageHtml, 200);
  }
}

class _StubFDroidVerification extends FDroid {
  _StubFDroidVerification(this.verificationResponses);

  final List<Response> verificationResponses;
  int verificationRequestCount = 0;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    if (url ==
        'https://f-droid.org/api/v1/packages/app.pwhs.universalinstaller') {
      return Response(
        jsonEncode({
          'packageName': 'app.pwhs.universalinstaller',
          'suggestedVersionCode': 31,
          'packages': [
            {'versionName': '1.9.11', 'versionCode': 31},
          ],
        }),
        200,
      );
    }
    if (url ==
        'https://verification.f-droid.org/unsigned/app.pwhs.universalinstaller_31.apk.json') {
      final int responseIndex =
          verificationRequestCount < verificationResponses.length
          ? verificationRequestCount
          : verificationResponses.length - 1;
      verificationRequestCount++;
      return verificationResponses[responseIndex];
    }
    return Response('', 404);
  }
}

class _StubIzzyOnDroid extends IzzyOnDroid {
  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    if (url == 'https://apt.izzysoft.de/fdroid/repo/index.xml') {
      return _fdroidRepoResponse('''
<fdroid><repo name="IzzyOnDroid"/><application id="org.example.app">
  <name>Example App</name>
  <marketvercode>3</marketvercode>
  <package>
    <version>3.0</version>
    <versioncode>3</versioncode>
    <apkname>org.example.app_3.apk</apkname>
  </package>
</application></fdroid>
''');
    }
    if (url == 'https://apt.izzysoft.de/fdroid/rbtlogs/izzy.json') {
      return Response('{}', 200);
    }
    if (url == 'https://apt.izzysoft.de/fdroid/index/apk/org.example.app') {
      return Response('''
<html><head>
<meta property="og:image" content="/fdroid/repo/org.example.app/en-US/icon.png" />
</head><body></body></html>
''', 200);
    }
    return Response('', 404);
  }
}

class _StubFDroidRepo extends FDroidRepo {
  _StubFDroidRepo(this.indexXml);

  final String indexXml;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    return Response(indexXml, 200, request: Request('GET', Uri.parse(url)));
  }
}

class _StubGitHub extends GitHub {
  bool latestEndpointRequested = false;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    if (url.endsWith('/releases/latest')) {
      latestEndpointRequested = true;
      return Response(
        jsonEncode({
          'tag_name': '1.0',
          'name': '1.0',
          'draft': false,
          'prerelease': false,
          'published_at': '2026-01-01T00:00:00Z',
          'body': '',
          'assets': <Map<String, dynamic>>[],
        }),
        200,
      );
    }
    if (url.endsWith('/releases?per_page=100')) {
      return Response(
        jsonEncode([
          {
            'tag_name': '1.1-Preview-2',
            'name': '1.1-Preview-2',
            'draft': false,
            'prerelease': true,
            'published_at': '2026-01-02T00:00:00Z',
            'body': '',
            'assets': [
              {
                'name': 'example-preview.apk',
                'browser_download_url':
                    'https://github.com/example/app/releases/download/preview/example-preview.apk',
                'url':
                    'https://api.github.com/repos/example/app/releases/assets/2',
                'size': 124,
                'digest': 'sha256:preview123',
              },
            ],
          },
          {
            'tag_name': '1.0',
            'name': '1.0',
            'draft': false,
            'prerelease': false,
            'published_at': '2026-01-01T00:00:00Z',
            'body': '',
            'assets': [
              {
                'name': 'example.apk',
                'browser_download_url':
                    'https://github.com/example/app/releases/download/1.0/example.apk',
                'url':
                    'https://api.github.com/repos/example/app/releases/assets/1',
                'size': 123,
                'digest': 'sha256:abc123',
              },
            ],
          },
        ]),
        200,
      );
    }
    if (url.endsWith('/attestations/sha256:abc123')) {
      return Response(
        jsonEncode({
          'attestations': [{}],
        }),
        200,
      );
    }
    if (url.endsWith('/attestations/sha256:empty123')) {
      return Response(jsonEncode({'attestations': []}), 200);
    }
    if (url.endsWith('/attestations/sha256:error123')) {
      return Response('', 500);
    }
    return Response('', 404);
  }
}

App _buildCurrentApp({required String latestVersion, int? apkSizeBytes}) {
  return App(
    id: 'com.example.app',
    url: 'https://www.apkmirror.com/apk/example/example',
    author: 'Example',
    name: 'Example',
    installedVersion: null,
    latestVersion: latestVersion,
    apkUrls: const <MapEntry<String, String>>[],
    preferredApkIndex: 0,
    additionalSettings: {'trackOnly': true, 'appId': 'com.example.app'},
    lastUpdateCheck: DateTime.now(),
    pinned: false,
    apkSizeBytes: apkSizeBytes,
  );
}

App _buildCurrentNamedApp({required String name}) {
  return App(
    id: 'org.example.app',
    url: 'https://example.com/app',
    author: 'Example Author',
    name: name,
    installedVersion: null,
    latestVersion: '1.0',
    apkUrls: const <MapEntry<String, String>>[
      MapEntry('example.apk', 'https://example.com/example.apk'),
    ],
    preferredApkIndex: 0,
    additionalSettings: <String, dynamic>{},
    lastUpdateCheck: DateTime.now(),
    pinned: false,
  );
}

App _buildCurrentTempIdNamedApp({required String name}) {
  return App(
    id: '123456789',
    url: 'https://example.com/app',
    author: 'Example Author',
    name: name,
    installedVersion: null,
    latestVersion: '1.0',
    apkUrls: const <MapEntry<String, String>>[
      MapEntry('example.apk', 'https://example.com/example.apk'),
    ],
    preferredApkIndex: 0,
    additionalSettings: <String, dynamic>{},
    lastUpdateCheck: DateTime.now(),
    pinned: false,
  );
}

Response _fdroidRepoResponse(String xml) {
  return Response(
    xml,
    200,
    request: Request(
      'GET',
      Uri.parse('https://apt.izzysoft.de/fdroid/repo/index.xml'),
    ),
  );
}

Response _fdroidVerificationResponse({required bool verified}) {
  return Response(
    jsonEncode({
      '1783233447.4899063': {
        'local': {
          'packageName': 'app.pwhs.universalinstaller',
          'versionCode': 31,
          'versionName': '1.9.11',
        },
        'remote': {
          'packageName': 'app.pwhs.universalinstaller',
          'versionCode': 31,
          'versionName': '1.9.11',
        },
        'url': 'https://f-droid.org/repo/app.pwhs.universalinstaller_31.apk',
        'verified': verified,
      },
    }),
    200,
  );
}

App _previousUniversalInstaller({required String reproducibleStatus}) {
  return App(
    id: 'app.pwhs.universalinstaller',
    url: 'https://f-droid.org/packages/app.pwhs.universalinstaller',
    author: 'Nguyen Quang Minh (NQM)',
    name: 'Universal Installer',
    latestVersion: '1.9.11',
    apkUrls: const <MapEntry<String, String>>[
      MapEntry(
        'app.pwhs.universalinstaller_31.apk',
        'https://f-droid.org/repo/app.pwhs.universalinstaller_31.apk',
      ),
    ],
    preferredApkIndex: 0,
    additionalSettings: const <String, dynamic>{
      'trySelectingSuggestedVersionCode': true,
    },
    rawLatestVersionFromSource: '1.9.11',
    latestReproducibleStatus: reproducibleStatus,
    latestReproducibleVersionCode: 31,
  );
}

class _FakeAndroidDeviceInfoPlatform extends DeviceInfoPlatform {
  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    return BaseDeviceInfo({
      'version': {
        'sdkInt': 35,
        'release': '15',
        'codename': 'REL',
        'incremental': '1',
        'previewSdkInt': 0,
        'securityPatch': '2026-05-01',
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
      'systemFeatures': const <String>[],
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The F-Droid reproducible-build error path logs via LogsProvider, which
  // opens a sqflite DB. Initialize the ffi factory so that best-effort write
  // succeeds in the test VM instead of throwing (matches version_order_test).
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  DeviceInfoPlatform.instance = _FakeAndroidDeviceInfoPlatform();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'getApplicationDocumentsDirectory') {
            return Directory.systemTemp.path;
          }
          return null;
        },
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'source resolution reuses templates but returns fresh mutable sources',
    () {
      final SourceProvider provider = SourceProvider();
      const String url = 'https://github.com/example/app';

      final AppSource firstSource = provider.getSource(url);
      final AppSource secondSource = provider.getSource(url);
      final AppSource firstTemplate = provider.getSourceTemplate(url);
      final AppSource secondTemplate = provider.getSourceTemplate(url);

      expect(firstSource, isA<GitHub>());
      expect(secondSource, isA<GitHub>());
      expect(identical(firstSource, secondSource), isFalse);
      expect(identical(firstTemplate, secondTemplate), isTrue);
    },
  );

  test('override resolution mutates only the fresh matched source', () {
    final SourceProvider provider = SourceProvider();
    final AppSource githubTemplate = provider.getSourceTemplate(
      'https://github.com/example/app',
    );
    final AppSource overriddenSource = provider.getSource(
      'https://git.example.com/example/app',
      overrideSource: githubTemplate.sourceIdentifier,
    );

    expect(overriddenSource, isA<GitHub>());
    expect(overriddenSource.hosts, <String>['git.example.com']);
    expect(overriddenSource.hostChanged, isTrue);
    expect(githubTemplate.hosts, contains('github.com'));
  });

  test('same-host GitHub override still normalizes repository URLs', () {
    final SourceProvider provider = SourceProvider();
    final AppSource githubTemplate = provider.getSourceTemplate(
      'https://github.com/example/app',
    );
    final AppSource overriddenSource = provider.getSource(
      'https://github.com/example/app/releases/',
      overrideSource: githubTemplate.sourceIdentifier,
    );

    expect(overriddenSource, isA<GitHub>());
    expect(overriddenSource.hostChanged, isTrue);
    expect(overriddenSource.hostIdenticalDespiteAnyChange, isTrue);
    expect(
      overriddenSource.standardizeUrl(
        'https://github.com/example/app/releases/',
      ),
      'https://github.com/example/app',
    );
  });

  test('GitHub prerelease and latest switches turn each other off', () {
    final List<GeneratedFormSwitch> switches = GitHub()
        .additionalSourceAppSpecificSettingFormItems
        .expand((List<GeneratedFormItem> row) => row)
        .whereType<GeneratedFormSwitch>()
        .toList();
    final GeneratedFormSwitch includePrereleases = switches.firstWhere(
      (GeneratedFormSwitch item) => item.key == 'includePrereleases',
    );
    final GeneratedFormSwitch verifyLatestTag = switches.firstWhere(
      (GeneratedFormSwitch item) => item.key == 'verifyLatestTag',
    );

    expect(includePrereleases.turnsOffKeys, contains('verifyLatestTag'));
    expect(verifyLatestTag.turnsOffKeys, contains('includePrereleases'));
  });

  test(
    'GitHub prerelease selection overrides legacy verify-latest state',
    () async {
      final _StubGitHub source = _StubGitHub();
      final APKDetails details = await source.getLatestAPKDetails(
        'https://github.com/example/app',
        <String, dynamic>{
          'includePrereleases': true,
          'verifyLatestTag': true,
          'sortMethodChoice': 'date',
        },
      );

      expect(source.latestEndpointRequested, false);
      expect(details.version, '1.1-Preview-2');
    },
  );

  test('GitHub download retries 401 without an authorization header', () {
    final Map<String, String> headers = <String, String>{
      HttpHeaders.authorizationHeader: 'Bearer invalid-token',
      HttpHeaders.acceptHeader: 'application/octet-stream',
    };
    final ObtainiumError unauthorizedError = ObtainiumError(
      'Unauthorized',
      code: 'HTTP_ERROR',
      data: <String, dynamic>{'statusCode': HttpStatus.unauthorized},
    );

    expect(
      shouldRetryGitHubDownloadWithoutAuthorization(
        source: GitHub(),
        headers: headers,
        error: unauthorizedError,
      ),
      isTrue,
    );
    expect(
      shouldRetryGitHubDownloadWithoutAuthorization(
        source: GitHub(),
        headers: headers,
        error: ObtainiumError(
          'Forbidden',
          code: 'HTTP_ERROR',
          data: <String, dynamic>{'statusCode': HttpStatus.forbidden},
        ),
      ),
      isFalse,
    );
    expect(
      shouldRetryGitHubDownloadWithoutAuthorization(
        source: _StubSource(),
        headers: headers,
        error: unauthorizedError,
      ),
      isFalse,
    );
  });

  // ── Size cache key invalidation ─────────────────────────────────────
  // The contract: the size persisted onto an App is keyed implicitly by
  // (appId, latestVersion). When a refresh returns the same version,
  // any size already on the App should survive (nothing better is
  // available for APKMirror until the AppPage's lazy resolver runs).
  // When the version changes, the stale size MUST be cleared so the
  // next AppPage open re-resolves.

  test('apkSizeBytes is preserved when source version is unchanged', () async {
    final source = _StubAPKMirror(version: '2.0', apkSizeFromSource: null);
    final currentApp = _buildCurrentApp(
      latestVersion: '2.0',
      apkSizeBytes: 12345678,
    );
    final newApp = await SourceProvider().getApp(
      source,
      'https://www.apkmirror.com/apk/example/example',
      {'trackOnly': true, 'appId': 'com.example.app'},
      currentApp: currentApp,
    );
    expect(newApp.apkSizeBytes, 12345678);
    expect(newApp.latestVersion, '2.0');
  });

  test(
    'apkSizeBytes is cleared when source reports a different version',
    () async {
      final source = _StubAPKMirror(version: '3.0', apkSizeFromSource: null);
      final currentApp = _buildCurrentApp(
        latestVersion: '2.0',
        apkSizeBytes: 12345678,
      );
      final newApp = await SourceProvider().getApp(
        source,
        'https://www.apkmirror.com/apk/example/example',
        {'trackOnly': true, 'appId': 'com.example.app'},
        currentApp: currentApp,
      );
      expect(newApp.apkSizeBytes, isNull);
      expect(newApp.latestVersion, '3.0');
    },
  );

  test('apkSizeBytes from source wins over the cached value', () async {
    final source = _StubAPKMirror(version: '3.0', apkSizeFromSource: 99999999);
    final currentApp = _buildCurrentApp(
      latestVersion: '2.0',
      apkSizeBytes: 12345678,
    );
    final newApp = await SourceProvider().getApp(
      source,
      'https://www.apkmirror.com/apk/example/example',
      {'trackOnly': true, 'appId': 'com.example.app'},
      currentApp: currentApp,
    );
    expect(newApp.apkSizeBytes, 99999999);
  });

  test(
    'preferred APK index is clamped after filtering shrinks assets',
    () async {
      const List<MapEntry<String, String>> originalApkUrls = [
        MapEntry('first.apk', 'https://example.com/first.apk'),
        MapEntry('second.apk', 'https://example.com/second.apk'),
        MapEntry('third.apk', 'https://example.com/third.apk'),
        MapEntry('fourth.apk', 'https://example.com/fourth.apk'),
        MapEntry('last.apk', 'https://example.com/last.apk'),
      ];
      const App currentApp = App(
        id: 'org.example.app',
        url: 'https://example.com/app',
        author: 'Example Author',
        name: 'Example App',
        latestVersion: '1.0',
        apkUrls: originalApkUrls,
        preferredApkIndex: 4,
        additionalSettings: <String, dynamic>{},
      );

      final App refreshedApp = await SourceProvider().getApp(
        _StubSource(apkUrls: originalApkUrls),
        currentApp.url,
        <String, dynamic>{'apkFilterRegEx': r'^first\.apk$'},
        currentApp: currentApp,
      );

      expect(refreshedApp.apkUrls, hasLength(1));
      expect(refreshedApp.apkUrls.single.key, 'first.apk');
      expect(refreshedApp.preferredApkIndex, 0);
    },
  );

  test('APK filters also match the download URL', () async {
    const MapEntry<String, String> ironFoxApk = MapEntry(
      'IronFox-153.0.1.apk',
      'https://example.com/arm64-v8a/ironfox-153.0.1-arm64-v8a.apk',
    );

    final App app = await SourceProvider().getApp(
      _StubSource(apkUrls: const [ironFoxApk]),
      'https://example.com/releases',
      <String, dynamic>{'apkFilterRegEx': 'arm64-v8a'},
    );

    expect(app.apkUrls, const [ironFoxApk]);
  });

  test(
    'apkSizeBytes is null on first add when source returns no size',
    () async {
      final source = _StubAPKMirror(version: '1.0', apkSizeFromSource: null);
      final newApp = await SourceProvider().getApp(
        source,
        'https://www.apkmirror.com/apk/example/example',
        {'trackOnly': true, 'appId': 'com.example.app'},
        // No currentApp — simulating first-time add.
      );
      expect(newApp.apkSizeBytes, isNull);
    },
  );

  test(
    'F-Droid repo parser keeps latest release when enforcement is on',
    () async {
      final details = await FDroidRepo.apkDetailsFromIndexXmlResponse(
        _fdroidRepoResponse('''
<fdroid><repo name="IzzyOnDroid"/><application id="org.example.app">
  <name>Example App</name>
  <marketvercode>3</marketvercode>
  <package>
    <version>3.0</version>
    <versioncode>3</versioncode>
    <apkname>org.example.app_3.apk</apkname>
    <hash type="sha256">hash3</hash>
  </package>
  <package>
    <version>2.0</version>
    <versioncode>2</versioncode>
    <apkname>org.example.app_2.apk</apkname>
    <hash type="sha256">hash2</hash>
  </package>
</application></fdroid>
'''),
        'org.example.app',
        <String, dynamic>{'enforceReproducibleBuilds': true},
        'IzzyOnDroid',
        isReproducibleRelease:
            (String appId, int versionCode, String? apkSha256) async {
              return appId == 'org.example.app' &&
                  versionCode == 2 &&
                  apkSha256 == 'hash2';
            },
      );

      expect(details.version, '3.0');
      expect(details.names.name, 'Example App');
      expect(details.isReproducible, isFalse);
      expect(
        details.reproducibleStatus,
        reproducibleBuildStatusNotReproducible,
      );
      expect(
        details.apkUrls.single.value,
        'https://apt.izzysoft.de/fdroid/repo/org.example.app_3.apk',
      );
    },
  );

  test(
    'F-Droid repo parser keeps latest release when enforcement is off',
    () async {
      final details = await FDroidRepo.apkDetailsFromIndexXmlResponse(
        _fdroidRepoResponse('''
<fdroid><repo name="IzzyOnDroid"/><application id="org.example.app">
  <name>Example App</name>
  <marketvercode>3</marketvercode>
  <package>
    <version>3.0</version>
    <versioncode>3</versioncode>
    <apkname>org.example.app_3.apk</apkname>
    <hash type="sha256">hash3</hash>
  </package>
  <package>
    <version>2.0</version>
    <versioncode>2</versioncode>
    <apkname>org.example.app_2.apk</apkname>
    <hash type="sha256">hash2</hash>
  </package>
</application></fdroid>
'''),
        'org.example.app',
        <String, dynamic>{},
        'IzzyOnDroid',
        isReproducibleRelease:
            (String appId, int versionCode, String? apkSha256) async {
              return appId == 'org.example.app' &&
                  versionCode == 2 &&
                  apkSha256 == 'hash2';
            },
      );

      expect(details.version, '3.0');
      expect(details.isReproducible, isFalse);
      expect(
        details.reproducibleStatus,
        reproducibleBuildStatusNotReproducible,
      );
    },
  );

  test(
    'F-Droid repo parser marks missing reproducible metadata as no data',
    () async {
      final details = await FDroidRepo.apkDetailsFromIndexXmlResponse(
        _fdroidRepoResponse('''
<fdroid><repo name="IzzyOnDroid"/><application id="org.example.app">
  <name>Example App</name>
  <marketvercode>3</marketvercode>
  <package>
    <version>3.0</version>
    <versioncode>3</versioncode>
    <apkname>org.example.app_3.apk</apkname>
    <hash type="sha256">hash3</hash>
  </package>
</application></fdroid>
'''),
        'org.example.app',
        <String, dynamic>{},
        'IzzyOnDroid',
      );

      expect(details.version, '3.0');
      expect(details.isReproducible, isNull);
      expect(details.reproducibleStatus, reproducibleBuildStatusNoData);
    },
  );

  test(
    'F-Droid repo parser does not treat an empty binaries element as verified',
    () async {
      final details = await FDroidRepo.apkDetailsFromIndexXmlResponse(
        _fdroidRepoResponse('''
<fdroid><repo name="Example Repo"/><application id="org.example.app">
  <name>Example App</name>
  <marketvercode>3</marketvercode>
  <package>
    <version>3.0</version>
    <versioncode>3</versioncode>
    <apkname>org.example.app_3.apk</apkname>
    <binaries>   </binaries>
  </package>
</application></fdroid>
'''),
        'org.example.app',
        <String, dynamic>{},
        'Example Repo',
      );

      expect(details.reproducibleStatus, reproducibleBuildStatusNoData);
    },
  );

  test(
    'F-Droid repo source uses shared parser for valid releases and metadata',
    () async {
      final details =
          await _StubFDroidRepo('''
<fdroid><repo name="Example Repo"/><application id="org.example.app">
  <name>Example App</name>
  <icon>example.png</icon>
  <marketvercode>3</marketvercode>
  <package>
    <version>4.0</version>
    <versioncode>4</versioncode>
  </package>
  <package>
    <version>3.0</version>
    <versioncode>3</versioncode>
    <apkname>org.example.app_3.apk</apkname>
    <size>12345</size>
    <binaries>org.example.app_3.apk</binaries>
  </package>
</application></fdroid>
''').getLatestAPKDetails('https://repo.example/fdroid/repo', <String, dynamic>{
            'appIdOrName': 'org.example.app',
          });

      expect(details.version, '3.0');
      expect(details.names.name, 'Example App');
      expect(details.apkSizeBytes, 12345);
      expect(
        details.iconUrl,
        'https://repo.example/fdroid/repo/icons/example.png',
      );
      expect(details.reproducibleStatus, reproducibleBuildStatusVerified);
      expect(
        details.apkUrls.single.value,
        'https://repo.example/fdroid/repo/org.example.app_3.apk',
      );
    },
  );

  test('IzzyOnDroid uses app page metadata as icon fallback', () async {
    final details = await _StubIzzyOnDroid().getLatestAPKDetails(
      'https://apt.izzysoft.de/fdroid/index/apk/org.example.app',
      <String, dynamic>{'appIdOrName': 'org.example.app'},
    );

    expect(details.names.name, 'Example App');
    expect(
      details.iconUrl,
      'https://apt.izzysoft.de/fdroid/repo/org.example.app/en-US/icon.png',
    );
    expect(details.reproducibleStatus, reproducibleBuildStatusNoData);
  });

  test('GitHub verifies release asset attestation from digest', () async {
    final attestationStatus = await _StubGitHub()
        .getAttestationStatusForSha256Digest(
          'https://github.com/example/app',
          'sha256:abc123',
          <String, dynamic>{},
        );

    expect(attestationStatus, githubAttestationStatusVerified);
  });

  test(
    'GitHub marks missing release asset attestation as unsupported',
    () async {
      final attestationStatus = await _StubGitHub()
          .getAttestationStatusForSha256Digest(
            'https://github.com/example/app',
            'sha256:empty123',
            <String, dynamic>{},
          );

      expect(attestationStatus, githubAttestationStatusUnsupported);
    },
  );

  test('GitHub marks attestation API failures as error', () async {
    final attestationStatus = await _StubGitHub()
        .getAttestationStatusForSha256Digest(
          'https://github.com/example/app',
          'sha256:error123',
          <String, dynamic>{},
        );

    expect(attestationStatus, githubAttestationStatusError);
  });

  test(
    'F-Droid API parser uses localized response name when available',
    () async {
      final details = await FDroid().getAPKUrlsFromFDroidPackagesAPIResponse(
        Response(
          jsonEncode({
            'packageName': 'org.example.app',
            'name': {'en-US': 'Readable F-Droid Name'},
            'packages': [
              {'versionName': '1.0', 'versionCode': 1},
            ],
          }),
          200,
        ),
        'http://127.0.0.1:9/repo/org.example.app',
        'https://example.com/packages/org.example.app',
        'F-Droid',
      );

      expect(details.names.name, 'Readable F-Droid Name');
      expect(details.version, '1.0');
      expect(details.isReproducible, isNull);
      expect(details.reproducibleStatus, reproducibleBuildStatusNoData);
    },
  );

  test('App JSON preserves the reproducible verification version code', () {
    final original = _previousUniversalInstaller(
      reproducibleStatus: reproducibleBuildStatusVerified,
    );

    final restored = App.fromJson(original.toJson());

    expect(restored.latestReproducibleStatus, reproducibleBuildStatusVerified);
    expect(restored.latestReproducibleVersionCode, 31);
  });

  test(
    'F-Droid maps a matching successful version report to verified',
    () async {
      final source = _StubFDroidVerification(<Response>[
        _fdroidVerificationResponse(verified: true),
      ]);

      final status = await source.getReproducibleBuildStatus(
        'app.pwhs.universalinstaller',
        31,
        <String, dynamic>{},
      );

      expect(status, reproducibleBuildStatusVerified);
    },
  );

  test('F-Droid maps a matching failed version report to mismatched', () async {
    final source = _StubFDroidVerification(<Response>[
      _fdroidVerificationResponse(verified: false),
    ]);

    final status = await source.getReproducibleBuildStatus(
      'app.pwhs.universalinstaller',
      31,
      <String, dynamic>{},
    );

    expect(status, reproducibleBuildStatusNotReproducible);
  });

  test('F-Droid maps a missing version report to no data', () async {
    final source = _StubFDroidVerification(<Response>[Response('', 404)]);

    final status = await source.getReproducibleBuildStatus(
      'app.pwhs.universalinstaller',
      31,
      <String, dynamic>{},
    );

    expect(status, reproducibleBuildStatusNoData);
  });

  test('F-Droid maps an invalid version report to check error', () async {
    final source = _StubFDroidVerification(<Response>[
      Response('{"unexpected":true}', 200),
    ]);

    final status = await source.getReproducibleBuildStatus(
      'app.pwhs.universalinstaller',
      31,
      <String, dynamic>{},
    );

    expect(status, reproducibleBuildStatusError);
  });

  test('F-Droid maps a verification server failure to check error', () async {
    final source = _StubFDroidVerification(<Response>[Response('', 500)]);

    final status = await source.getReproducibleBuildStatus(
      'app.pwhs.universalinstaller',
      31,
      <String, dynamic>{},
    );

    expect(status, reproducibleBuildStatusError);
  });

  test(
    'F-Droid rechecks no data and observes a delayed verified report',
    () async {
      final source = _StubFDroidVerification(<Response>[
        Response('', 404),
        _fdroidVerificationResponse(verified: true),
      ]);
      source.previouslyCheckedApp = _previousUniversalInstaller(
        reproducibleStatus: reproducibleBuildStatusNoData,
      );

      final firstDetails = await source.getLatestAPKDetails(
        'https://f-droid.org/packages/app.pwhs.universalinstaller',
        <String, dynamic>{'trySelectingSuggestedVersionCode': true},
      );
      final secondDetails = await source.getLatestAPKDetails(
        'https://f-droid.org/packages/app.pwhs.universalinstaller',
        <String, dynamic>{'trySelectingSuggestedVersionCode': true},
      );

      expect(firstDetails.versionCode, 31);
      expect(firstDetails.reproducibleStatus, reproducibleBuildStatusNoData);
      expect(secondDetails.reproducibleStatus, reproducibleBuildStatusVerified);
      expect(source.verificationRequestCount, 2);
    },
  );

  test(
    'F-Droid rechecks legacy verified state without a version code',
    () async {
      final source = _StubFDroidVerification(<Response>[
        _fdroidVerificationResponse(verified: false),
      ]);
      source.previouslyCheckedApp = _previousUniversalInstaller(
        reproducibleStatus: reproducibleBuildStatusVerified,
      ).copyWith(latestReproducibleVersionCode: null);

      final details = await source.getLatestAPKDetails(
        'https://f-droid.org/packages/app.pwhs.universalinstaller',
        <String, dynamic>{'trySelectingSuggestedVersionCode': true},
      );

      expect(
        details.reproducibleStatus,
        reproducibleBuildStatusNotReproducible,
      );
      expect(source.verificationRequestCount, 1);
    },
  );

  test('F-Droid reuses an exact cached verified version report', () async {
    final source = _StubFDroidVerification(<Response>[
      _fdroidVerificationResponse(verified: true),
    ]);
    source.previouslyCheckedApp = _previousUniversalInstaller(
      reproducibleStatus: reproducibleBuildStatusVerified,
    );

    final details = await source.getLatestAPKDetails(
      'https://f-droid.org/packages/app.pwhs.universalinstaller',
      <String, dynamic>{'trySelectingSuggestedVersionCode': true},
    );

    expect(details.reproducibleStatus, reproducibleBuildStatusVerified);
    expect(source.verificationRequestCount, 0);
  });

  test('F-Droid API parser falls back to package page title', () async {
    final details =
        await _StubFDroid(
          '<html><head><title>NewPipe | F-Droid - Free and Open Source Android App Repository</title></head></html>',
        ).getAPKUrlsFromFDroidPackagesAPIResponse(
          Response(
            jsonEncode({
              'packageName': 'org.schabi.newpipe',
              'packages': [
                {'versionName': '0.28.8', 'versionCode': 1013},
              ],
            }),
            200,
          ),
          'http://127.0.0.1:9/repo/org.schabi.newpipe',
          'https://f-droid.org/packages/org.schabi.newpipe',
          'F-Droid',
        );

    expect(details.names.name, 'NewPipe');
  });

  test(
    'F-Droid overridden canonical host still falls back to package page title',
    () async {
      final details =
          await _StubFDroid(
            '<html><head><title>NewPipe | F-Droid - Free and Open Source Android App Repository</title></head></html>',
            hostChanged: true,
            hostIdenticalDespiteAnyChange: true,
          ).getAPKUrlsFromFDroidPackagesAPIResponse(
            Response(
              jsonEncode({
                'packageName': 'org.schabi.newpipe',
                'packages': [
                  {'versionName': '0.28.8', 'versionCode': 1013},
                ],
              }),
              200,
            ),
            'http://127.0.0.1:9/repo/org.schabi.newpipe',
            'https://f-droid.org/packages/org.schabi.newpipe',
            'F-Droid',
          );

      expect(details.names.name, 'NewPipe');
    },
  );

  test('source name replaces stale package-id app name', () async {
    final newApp = await SourceProvider().getApp(
      _StubSource(),
      'https://example.com/app',
      <String, dynamic>{},
      currentApp: _buildCurrentNamedApp(name: 'org.example.app'),
    );

    expect(newApp.name, 'Readable Name');
  });

  test('source name replaces stale package-looking app name', () async {
    final newApp = await SourceProvider().getApp(
      _StubSource(),
      'https://example.com/app',
      <String, dynamic>{},
      currentApp: _buildCurrentTempIdNamedApp(name: 'org.example.app'),
    );

    expect(newApp.name, 'Readable Name');
  });

  test('package-id name override is ignored when source name is readable', () {
    final app = App(
      id: 'org.example.app',
      url: 'https://example.com/app',
      author: 'Example Author',
      name: 'Readable Name',
      installedVersion: null,
      latestVersion: '1.0',
      apkUrls: const <MapEntry<String, String>>[
        MapEntry('example.apk', 'https://example.com/example.apk'),
      ],
      preferredApkIndex: 0,
      additionalSettings: <String, dynamic>{'appName': 'org.example.app'},
      lastUpdateCheck: DateTime.now(),
      pinned: false,
    );

    expect(app.finalName, 'Readable Name');
  });

  test(
    'GitLab getLatestAPKDetails extracts changelog from release description',
    () async {
      final gitlab = _StubGitLab(
        jsonEncode([
          {
            'tag_name': '4.8.3',
            'name': 'Aurora Store 4.8.3',
            'description': '## Release 4.8.3\n- Fixed changelog issue',
            'released_at': '2026-07-27T00:00:00Z',
            'assets': {
              'links': [
                {
                  'name': 'app.apk',
                  'url':
                      'https://gitlab.com/AuroraOSS/AuroraStore/-/releases/4.8.3/downloads/app.apk',
                },
              ],
            },
          },
        ]),
      );

      final details = await gitlab.getLatestAPKDetails(
        'https://gitlab.com/AuroraOSS/AuroraStore',
        const <String, dynamic>{},
      );

      expect(details.changeLog, '## Release 4.8.3\n- Fixed changelog issue');
    },
  );

  group('HTML dynamic download filenames', () {
    test('prefers and decodes RFC 5987 Content-Disposition filenames', () {
      expect(
        extractDownloadFileNameFromContentDisposition(
          'attachment; filename="fallback.apk"; '
          "filename*=UTF-8''LazyMedia%20Deluxe-3.457.apk",
        ),
        'LazyMedia Deluxe-3.457.apk',
      );
    });

    test('sanitizes path components from response filenames', () {
      expect(
        extractDownloadFileNameFromContentDisposition(
          r'attachment; filename="..\..\unsafe:name.apk"',
        ),
        'unsafe_name.apk',
      );
    });

    test('uses Content-Disposition before the final redirected URL', () {
      expect(
        resolveHtmlAssetDisplayName(
          downloadUrl: 'https://example.com/index.php?id=1234',
          version: '3.457',
          appName: 'LazyMedia Deluxe',
          responseMetadata: DownloadResponseMetadata(
            finalUri: Uri.parse('https://cdn.example.com/redirected-name.apk'),
            headers: const {
              'content-disposition': 'attachment; filename="server-name.apk"',
            },
          ),
        ),
        'server-name.apk',
      );
    });

    test('uses a package filename from the final redirected URL', () {
      expect(
        resolveHtmlAssetDisplayName(
          downloadUrl: 'https://example.com/index.php?id=1234',
          version: '3.457',
          appName: 'LazyMedia Deluxe',
          responseMetadata: DownloadResponseMetadata(
            finalUri: Uri.parse(
              'https://cdn.example.com/LazyMedia-Deluxe-3.457.xapk',
            ),
            headers: const {},
          ),
        ),
        'LazyMedia-Deluxe-3.457.xapk',
      );
    });

    test('preserves a package filename from the original download URL', () {
      expect(
        resolveHtmlAssetDisplayName(
          downloadUrl:
              'https://example.com/releases/ironfox-153.0.1-universal.apk',
          version: '153.0.1',
          appName: 'IronFox',
        ),
        'ironfox-153.0.1-universal.apk',
      );
    });

    test('preserves a package filename from the link label', () {
      expect(
        resolveHtmlAssetDisplayName(
          downloadUrl: 'https://example.com/download?id=1234',
          version: '21.0',
          appName: 'Thunderbird',
          linkLabel: 'thunderbird-21.0.apk',
        ),
        'thunderbird-21.0.apk',
      );
    });

    test('falls back to the known app name and version', () {
      expect(
        resolveHtmlAssetDisplayName(
          downloadUrl: 'https://example.com/index.php?id=1234',
          version: '3.457',
          appName: 'LazyMedia Deluxe',
        ),
        'LazyMedia Deluxe-3.457.apk',
      );
    });
  });

  test(
    'getDefaultValuesFromFormItems inflates subform items with full defaults',
    () {
      final html = HTML();
      final defaults = getDefaultValuesFromFormItems(
        html.combinedAppSpecificSettingFormItems,
      );

      final requestHeaders = defaults['requestHeader'] as List?;
      expect(requestHeaders, isNotNull);
      expect(requestHeaders!.length, 1);
      final reqMap = requestHeaders.first as Map<String, dynamic>;
      expect(reqMap.containsKey('requestHeader'), true);
      expect(reqMap['requestHeader'], contains('Mozilla/5.0'));
    },
  );

  test(
    'version-code mode stores the source version code as the latest version',
    () async {
      // The installed version in this mode is the device's versionCode, so the
      // latest version has to be a code too — otherwise the two are unorderable.
      final source = _StubSource(version: '4.8.3', versionCode: 48300);
      final app = await SourceProvider()
          .getApp(source, 'https://example.com/app', <String, dynamic>{
            'appId': 'org.example.app',
            'versionDetection': 'versionCode',
            'useVersionCodeAsOSVersion': true,
          });

      expect(app.latestVersion, '48300');
      // The source's own string is still kept for the RegEx assist helpers.
      expect(app.rawLatestVersionFromSource, '4.8.3');
    },
  );

  test(
    'version-code mode leaves the version string alone without a source code',
    () async {
      final source = _StubSource(version: '4.8.3');
      final app = await SourceProvider()
          .getApp(source, 'https://example.com/app', <String, dynamic>{
            'appId': 'org.example.app',
            'versionDetection': 'versionCode',
            'useVersionCodeAsOSVersion': true,
          });

      expect(app.latestVersion, '4.8.3');
    },
  );

  test(
    'an explicit version-string source outranks version-code mode',
    () async {
      final source = _StubSource(version: '4.8.3', versionCode: 48300);
      final app = await SourceProvider()
          .getApp(source, 'https://example.com/app', <String, dynamic>{
            'appId': 'org.example.app',
            'versionDetection': 'versionCode',
            'useVersionCodeAsOSVersion': true,
            'versionStringSource': versionStringSourceReleaseTitle,
          });

      expect(app.latestVersion, '4.8.3');
    },
  );

  test('per-app VirusTotal switch is offered in the advanced section', () {
    final List<List<GeneratedFormItem>> rows =
        GitHub().combinedAppSpecificSettingFormItems;
    final int advancedHeaderIndex = rows.indexWhere(
      (List<GeneratedFormItem> row) =>
          row.length == 1 && row.first.key == '__formSectionAdvanced',
    );
    final int scanIndex = rows.indexWhere(
      (List<GeneratedFormItem> row) => row.any(
        (GeneratedFormItem item) => item.key == enableVirusTotalScanKey,
      ),
    );

    expect(advancedHeaderIndex, greaterThanOrEqualTo(0));
    expect(scanIndex, greaterThan(advancedHeaderIndex));

    final GeneratedFormItem item = rows[scanIndex].firstWhere(
      (GeneratedFormItem item) => item.key == enableVirusTotalScanKey,
    );
    expect(item, isA<GeneratedFormSwitch>());
    // Enabled by default in the form: the pages disable it only when VirusTotal
    // scanning isn't usable, so a plain form build must leave it interactive.
    expect((item as GeneratedFormSwitch).disabled, false);
    // Same polarity as the global setting - on means "scan" - so it must default
    // to on, matching what an app that was never configured actually does.
    expect(item.value, true);
  });

  test('a saved app with no VirusTotal key is still scanned', () {
    // The switch defaults to on, so every read must pass defaultValue: true.
    // Apps saved before the key existed have no entry for it, and getBool's own
    // default (false) would read as "don't scan" - silently disabling scanning
    // for every pre-existing app on upgrade.
    expect(
      const TypedSettings(
        <String, dynamic>{},
      ).getBool(enableVirusTotalScanKey, defaultValue: true),
      true,
    );
    expect(
      const TypedSettings(<String, dynamic>{
        enableVirusTotalScanKey: false,
      }).getBool(enableVirusTotalScanKey, defaultValue: true),
      false,
    );
    // Backups round-trip additionalSettings through JSON, where a bool can come
    // back as a string.
    expect(
      const TypedSettings(<String, dynamic>{
        enableVirusTotalScanKey: 'false',
      }).getBool(enableVirusTotalScanKey, defaultValue: true),
      false,
    );
  });
}

class _StubGitLab extends GitLab {
  _StubGitLab(this.responseJson);
  final String responseJson;

  @override
  Future<Response> sourceRequest(
    String url,
    Map<String, dynamic> additionalSettings, {
    bool followRedirects = true,
    Object? postBody,
  }) async {
    if (url.contains('/api/v4/projects/')) {
      if (!url.contains('/releases') && !url.contains('/tags')) {
        return Response(jsonEncode(<String, dynamic>{'id': 12345}), 200);
      }
      return Response(responseJson, 200);
    }
    return Response('', 404);
  }
}
