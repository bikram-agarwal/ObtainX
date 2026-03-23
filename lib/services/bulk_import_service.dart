import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:http/http.dart' as http;
import 'package:obtainium/app_sources/github.dart';

const int _flagSystem = 1; // ApplicationInfo.FLAG_SYSTEM = 0x1
const int _flagUpdatedSystemApp = 128; // ApplicationInfo.FLAG_UPDATED_SYSTEM_APP = 0x80

class InstalledAppInfo {
  final String packageName;
  final String name;
  final Uint8List? icon;
  final bool isSystemApp;

  InstalledAppInfo({
    required this.packageName,
    required this.name,
    this.icon,
    required this.isSystemApp,
  });
}

class BulkImportService {
  static final _pm = AndroidPackageManager();

  /// Returns all installed apps, filtered by system/user.
  static Future<List<InstalledAppInfo>> getInstalledApps({
    bool includeSystem = false,
    bool includeUser = true,
  }) async {
    final packages =
        await _pm.getInstalledPackages(
          flags: PackageInfoFlags({PMFlag.getSigningCertificates}),
        ) ??
        [];

    final result = <InstalledAppInfo>[];
    for (final pkg in packages) {
      final pkgName = pkg.packageName ?? '';
      if (pkgName.isEmpty) continue;
      // Skip ObtainX itself
      if (pkgName == 'dev.imranr.obtainium') continue;

      final appFlags = pkg.applicationInfo?.flags ?? 0;
      final isSystem =
          (appFlags & _flagSystem) != 0 ||
          (appFlags & _flagUpdatedSystemApp) != 0;

      if (isSystem && !includeSystem) continue;
      if (!isSystem && !includeUser) continue;

      final name =
          await pkg.applicationInfo?.getAppLabel() ??
          pkg.applicationInfo?.processName ??
          pkgName;

      result.add(
        InstalledAppInfo(
          packageName: pkgName,
          name: name,
          icon: null, // Icons loaded lazily per-row
          isSystemApp: isSystem,
        ),
      );
    }

    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  /// Gets app icon for a given package name. Used for lazy loading.
  static Future<Uint8List?> getAppIcon(String packageName) async {
    try {
      final info = await _pm.getPackageInfo(
        packageName: packageName,
        flags: PackageInfoFlags({}),
      );
      return await info?.applicationInfo?.getAppIcon();
    } catch (_) {
      return null;
    }
  }

  /// Checks APKMirror for a list of package names.
  /// Returns a map of packageName -> apkmirror URL (null if not found).
  /// Uses APKMirror's REST API with batch requests of 100 apps.
  static Future<Map<String, String?>> checkApkMirror(
    List<String> packageNames, {
    void Function(int done, int total)? onProgress,
    Map<String, String?>? alreadyKnown,
    bool Function()? shouldAbort,
  }) async {
    final result = <String, String?>{};
    if (alreadyKnown != null) {
      for (final String packageName in packageNames) {
        if (alreadyKnown.containsKey(packageName)) {
          result[packageName] = alreadyKnown[packageName];
        }
      }
    }
    void reportProgress() {
      int resolved = 0;
      for (final String packageName in packageNames) {
        if (result.containsKey(packageName)) resolved++;
      }
      onProgress?.call(resolved, packageNames.length);
    }

    reportProgress();
    final List<String> toQuery = packageNames
        .where((String packageName) => !result.containsKey(packageName))
        .toList();
    if (toQuery.isEmpty) {
      return result;
    }

    const batchSize = 100;
    // Authorization header uses APKUpdater credentials to access the API endpoint
    const auth = 'Basic YXBpLWFwa3VwZGF0ZXI6cm01cmNmcnVVakt5MDRzTXB5TVBKWFc4';

    for (int i = 0; i < toQuery.length; i += batchSize) {
      if (shouldAbort?.call() == true) {
        return result;
      }
      final batch = toQuery.sublist(
        i,
        min(i + batchSize, toQuery.length),
      );
      try {
        final response = await http
            .post(
              Uri.parse(
                'https://www.apkmirror.com/wp-json/apkm/v1/app_exists/',
              ),
              headers: {
                'Authorization': auth,
                'Content-Type': 'application/json',
                'User-Agent': 'APKUpdater-v3.5.9',
              },
              body: jsonEncode({
                'pnames': batch,
                'exclude': ['alpha', 'beta'],
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final dataList = data['data'] as List? ?? [];
          for (final item in dataList) {
            final pname = item['pname'] as String?;
            final exists = item['exists'] as bool? ?? false;
            // app.link is a relative path like /apk/google-inc/google-maps/
            final appLink = item['app']?['link'] as String?;
            if (pname != null && exists && appLink != null) {
              result[pname] = 'https://www.apkmirror.com$appLink';
            } else if (pname != null) {
              result[pname] = null;
            }
          }
          // Mark any that weren't in the response as not found
          for (final pkg in batch) {
            result.putIfAbsent(pkg, () => null);
          }
        } else {
          for (final pkg in batch) {
            result[pkg] = null;
          }
        }
      } catch (_) {
        for (final pkg in batch) {
          result[pkg] = null;
        }
      }
      reportProgress();
      if (shouldAbort?.call() == true) {
        return result;
      }
      // Small delay between batches to respect rate limits
      if (i + batchSize < toQuery.length) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return result;
  }

  /// Checks APKPure for a list of package names.
  /// Returns a map of packageName -> apkpure URL (null if not found).
  static Future<Map<String, String?>> checkApkPure(
    List<String> packageNames, {
    void Function(int done, int total)? onProgress,
    Map<String, String?>? alreadyKnown,
    bool Function()? shouldAbort,
  }) async {
    final result = <String, String?>{};
    if (alreadyKnown != null) {
      for (final String packageName in packageNames) {
        if (alreadyKnown.containsKey(packageName)) {
          result[packageName] = alreadyKnown[packageName];
        }
      }
    }
    void reportProgress() {
      int resolved = 0;
      for (final String packageName in packageNames) {
        if (result.containsKey(packageName)) resolved++;
      }
      onProgress?.call(resolved, packageNames.length);
    }

    reportProgress();
    final List<String> toQuery = packageNames
        .where((String packageName) => !result.containsKey(packageName))
        .toList();
    if (toQuery.isEmpty) {
      return result;
    }

    const batchSize = 50;
    final rng = Random();

    for (int i = 0; i < toQuery.length; i += batchSize) {
      if (shouldAbort?.call() == true) {
        return result;
      }
      final batch = toQuery.sublist(
        i,
        min(i + batchSize, toQuery.length),
      );
      try {
        // Random device ID to avoid rate limiting (mirrors APKUpdater approach)
        final androidId =
            rng.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0') +
            rng.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');

        final deviceInfo = jsonEncode({
          'abis': ['arm64-v8a', 'armeabi-v7a', 'armeabi'],
          'android_id': androidId,
          'os_ver': '30',
          'os_ver_name': '11',
          'platform': 1,
          'screen_height': 2400,
          'screen_width': 1080,
        });

        final appInfoList = batch
            .map((pkg) => {'package_name': pkg, 'version_code': 0})
            .toList();

        final response = await http
            .post(
              Uri.parse('https://api.pureapk.com/v3/get_app_update'),
              headers: {
                'content-type': 'application/json',
                'ual-access-businessid': 'projecta',
                'ual-access-projecta': deviceInfo,
                'User-Agent': 'APKPure/3.19.39 (Aegon)',
              },
              body: jsonEncode({
                'app_info_for_update': appInfoList,
                'android_id': androidId,
                'application_id': 'com.apkpure.aegon',
                'cached_size': -1,
              }),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          // Handle both List and wrapped object responses
          List<dynamic> apps;
          if (body is List) {
            apps = body;
          } else if (body is Map && body.containsKey('data')) {
            apps = body['data'] as List? ?? [];
          } else {
            apps = [];
          }

          final foundPackages = <String>{};
          for (final app in apps) {
            final pname = app['package_name'] as String?;
            final label = app['label'] as String?;
            if (pname != null && label != null && label.isNotEmpty) {
              final slug = _slugify(label);
              result[pname] = 'https://apkpure.net/$slug/$pname';
              foundPackages.add(pname);
            } else if (pname != null) {
              result[pname] = null;
              foundPackages.add(pname);
            }
          }
          for (final pkg in batch) {
            result.putIfAbsent(pkg, () => null);
          }
        } else {
          for (final pkg in batch) {
            result[pkg] = null;
          }
        }
      } catch (_) {
        for (final pkg in batch) {
          result[pkg] = null;
        }
      }
      reportProgress();
      if (shouldAbort?.call() == true) {
        return result;
      }
      if (i + batchSize < toQuery.length) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    return result;
  }

  /// Checks F-Droid for a list of package names using their REST API.
  /// Returns a map of packageName -> fdroid URL (null if not found).
  static Future<Map<String, String?>> checkFDroid(
    List<String> packageNames, {
    void Function(int done, int total)? onProgress,
    Map<String, String?>? alreadyKnown,
    bool Function()? shouldAbort,
  }) async {
    final result = <String, String?>{};
    if (alreadyKnown != null) {
      for (final String packageName in packageNames) {
        if (alreadyKnown.containsKey(packageName)) {
          result[packageName] = alreadyKnown[packageName];
        }
      }
    }
    void reportProgress() {
      int resolved = 0;
      for (final String packageName in packageNames) {
        if (result.containsKey(packageName)) resolved++;
      }
      onProgress?.call(resolved, packageNames.length);
    }

    reportProgress();
    final List<String> toQuery = packageNames
        .where((String packageName) => !result.containsKey(packageName))
        .toList();
    if (toQuery.isEmpty) {
      return result;
    }

    for (final String pkg in toQuery) {
      if (shouldAbort?.call() == true) {
        return result;
      }
      try {
        final response = await http
            .get(
              Uri.parse('https://f-droid.org/api/v1/packages/$pkg'),
              headers: {'User-Agent': 'ObtainX/1.4.0'},
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          result[pkg] = 'https://f-droid.org/packages/$pkg/';
        } else {
          result[pkg] = null;
        }
      } catch (_) {
        result[pkg] = null;
      }
      reportProgress();
    }
    return result;
  }

  /// GitHub code search by package id. Results are best-effort: many repos match
  /// generic strings, and the API is rate-limited without a PAT (set under GitHub
  /// source settings). Uses the same search approach as common tooling: quoted
  /// package id in file contents, then prefers AndroidManifest / Gradle paths.
  static Future<Map<String, String?>> checkGitHub(
    List<String> packageNames, {
    void Function(int done, int total)? onProgress,
    Map<String, String?>? alreadyKnown,
    bool Function()? shouldAbort,
  }) async {
    final Map<String, String?> result = <String, String?>{};
    if (alreadyKnown != null) {
      for (final String packageName in packageNames) {
        if (alreadyKnown.containsKey(packageName)) {
          result[packageName] = alreadyKnown[packageName];
        }
      }
    }
    void reportProgress() {
      int resolved = 0;
      for (final String packageName in packageNames) {
        if (result.containsKey(packageName)) resolved++;
      }
      onProgress?.call(resolved, packageNames.length);
    }

    reportProgress();
    final List<String> toQuery = packageNames
        .where((String packageName) => !result.containsKey(packageName))
        .toList();
    if (toQuery.isEmpty) {
      return result;
    }

    final GitHub githubSource = GitHub();
    final Map<String, String> headers = <String, String>{
      'Accept': 'application/vnd.github.v3+json',
      'User-Agent': 'ObtainX-BulkImport',
    };
    final Map<String, String>? authHeaders = await githubSource.getRequestHeaders(
      <String, dynamic>{},
      'https://api.github.com/search/code',
    );
    if (authHeaders != null) {
      headers.addAll(authHeaders);
    }
    final bool hasAuthToken =
        headers.containsKey('Authorization') || headers.containsKey('authorization');

    for (final String pkg in toQuery) {
      if (shouldAbort?.call() == true) {
        return result;
      }
      try {
        // Quoted id reduces unrelated matches; "in:file" scopes to file contents.
        final Uri uri = Uri(
          scheme: 'https',
          host: 'api.github.com',
          path: '/search/code',
          queryParameters: <String, String>{
            'q': '"$pkg" in:file',
            'per_page': '15',
          },
        );
        final http.Response response =
            await http.get(uri, headers: headers).timeout(
                  const Duration(seconds: 25),
                );
        if (response.statusCode == 200) {
          final Object? decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            final List<dynamic> items =
                decoded['items'] as List<dynamic>? ?? <dynamic>[];
            String? chosenUrl;
            for (final dynamic raw in items) {
              if (raw is! Map<String, dynamic>) continue;
              final String path =
                  (raw['path'] as String? ?? '').toLowerCase();
              final Object? repo = raw['repository'];
              if (repo is! Map<String, dynamic>) continue;
              final String? htmlUrl = repo['html_url'] as String?;
              if (htmlUrl == null || !htmlUrl.contains('github.com')) continue;
              if (path.contains('androidmanifest') ||
                  path.endsWith('build.gradle') ||
                  path.endsWith('build.gradle.kts')) {
                chosenUrl = htmlUrl;
                break;
              }
              chosenUrl ??= htmlUrl;
            }
            result[pkg] = chosenUrl;
          } else {
            result[pkg] = null;
          }
        } else {
          result[pkg] = null;
        }
      } catch (_) {
        result[pkg] = null;
      }
      reportProgress();
      if (!hasAuthToken) {
        await Future.delayed(const Duration(milliseconds: 850));
      } else {
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }
    return result;
  }

  static String _slugify(String label) {
    return label
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim()
        .replaceAll(RegExp(r'[\s_]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-');
  }
}
