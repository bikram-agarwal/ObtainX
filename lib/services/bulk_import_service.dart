import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:android_package_manager/android_package_manager.dart';
import 'package:http/http.dart' as http;

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

class _Semaphore {
  final int maxCount;
  int _count = 0;
  final List<Completer<void>> _waiters = [];

  _Semaphore(this.maxCount);

  Future<void> acquire() async {
    if (_count < maxCount) {
      _count++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _count--;
    }
  }
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
  }) async {
    final result = <String, String?>{};
    const batchSize = 100;
    // Authorization header uses APKUpdater credentials to access the API endpoint
    const auth = 'Basic YXBpLWFwa3VwZGF0ZXI6cm01cmNmcnVVakt5MDRzTXB5TVBKWFc4';

    for (int i = 0; i < packageNames.length; i += batchSize) {
      final batch = packageNames.sublist(
        i,
        min(i + batchSize, packageNames.length),
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
      onProgress?.call(min(i + batchSize, packageNames.length), packageNames.length);
      // Small delay between batches to respect rate limits
      if (i + batchSize < packageNames.length) {
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
  }) async {
    final result = <String, String?>{};
    const batchSize = 50;
    final rng = Random();

    for (int i = 0; i < packageNames.length; i += batchSize) {
      final batch = packageNames.sublist(
        i,
        min(i + batchSize, packageNames.length),
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
      onProgress?.call(min(i + batchSize, packageNames.length), packageNames.length);
      if (i + batchSize < packageNames.length) {
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
  }) async {
    final result = <String, String?>{};
    final semaphore = _Semaphore(8); // max 8 concurrent requests
    int done = 0;

    await Future.wait(
      packageNames.map((pkg) async {
        await semaphore.acquire();
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
        } finally {
          done++;
          onProgress?.call(done, packageNames.length);
          semaphore.release();
        }
      }),
    );
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
