import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/folders/app_folder.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/services/json_file_work.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _CachePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _CachePathProvider(this.path);
  final String path;

  @override
  Future<String?> getExternalStoragePath() async {
    return path;
  }
}

class _ExportProvider implements AppsProvider {
  _ExportProvider(this.apps, this.settingsProvider);

  @override
  AppListings apps;
  @override
  final SettingsProvider settingsProvider;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _ExportSettings extends SettingsProvider {
  int folderReads = 0;

  @override
  List<AppFolder> get appFolders {
    folderReads++;
    return const [AppFolder(id: 'tools', name: 'Outils é 🔧')];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'worker export bytes preserve indentation, escaping and Unicode',
    () async {
      final data = {
        'apps': [
          {'name': 'Café 🔧', 'additionalSettings': '{"quote":"a\\nb"}'},
          {
            'name': '中文',
            'categories': ['tools', '"quoted"'],
          },
        ],
        'settings': {'null': null, 'bool': true, 'number': 1.5},
      };
      for (final indent in <String?>[null, '    ']) {
        final bytes = await encodeJsonBytesOffIsolate(data, indent: indent);
        expect(
          bytes,
          utf8.encode(JsonEncoder.withIndent(indent).convert(data)),
        );
        expect(jsonDecode(utf8.decode(bytes)), data);
      }
    },
  );

  test('worker encoding propagates unsupported JSON errors', () async {
    await expectLater(
      encodeJsonBytesOffIsolate({'date': DateTime(2026)}),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
  });

  test(
    'export preserves app schema and folders without modifying live settings',
    () async {
      final settings = _ExportSettings();
      final apps = AppListings();
      for (final appId in ['first', 'second', 'excluded']) {
        final app = App(
          id: appId,
          url: 'https://github.com/example/$appId',
          author: 'Example',
          name: 'Café $appId',
          latestVersion: '1.2.3',
          preferredApkIndex: 0,
          categories: const ['Utilities'],
          additionalSettings: {
            'folderIds': ['tools', 'deleted'],
            'nested': {'enabled': true},
          },
        );
        apps[appId] = AppInMemory(app, null, null, null);
      }
      final provider = _ExportProvider(apps, settings);
      final exported = provider.generateExportJSON(
        appIds: ['second', 'first', 'first'],
        overrideExportSettings: 0,
      );
      expect(settings.folderReads, 1);
      final exportedApps = exported['apps'] as List;
      expect(exportedApps.map((app) => app['id']), ['first', 'second']);
      for (final exportedApp in exportedApps) {
        final original = apps[exportedApp['id']]!.app;
        final expected = original.toJson();
        expected['additionalSettings'] = jsonEncode({
          ...original.additionalSettings,
          'folderNames': {'tools': 'Outils é 🔧'},
        });
        expect(exportedApp, expected);
        expect(original.additionalSettings.containsKey('folderNames'), isFalse);
      }
      final encoded = await encodeJsonBytesOffIsolate(exported, indent: '    ');
      final restored = provider.parseBackupContent(utf8.decode(encoded));
      expect(restored.apps.map((app) => app.id), ['first', 'second']);
      expect(restored.apps.first.additionalSettings['folderNames'], {
        'tools': 'Outils é 🔧',
      });
      expect(restored.apps.first.additionalSettings['nested'], {
        'enabled': true,
      });
    },
  );

  group('store cache persistence', () {
    late Directory directory;
    late File cacheFile;
    late PathProviderPlatform previousPathProvider;

    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp('obtainx-cache-test-');
      cacheFile = File('${directory.path}/bulk_scan_data/store_url_map.json');
      previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _CachePathProvider(directory.path);
    });
    setUp(() async {
      await BulkScanCache.clear();
    });
    tearDownAll(() async {
      await BulkScanCache.clear();
      PathProviderPlatform.instance = previousPathProvider;
      final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final resolved = await directory.resolveSymbolicLinks();
      expect(
        resolved.startsWith(
          '$temporaryRoot${Platform.pathSeparator}obtainx-cache-test-',
        ),
        isTrue,
      );
      await directory.delete(recursive: true);
    });

    test(
      'single-app and full snapshots cannot modify the stored map',
      () async {
        final data = {
          'first': {'F-Droid': 'https://f-droid.org/packages/first'},
          'second': {'APKPure': ''},
        };
        await BulkScanCache.save(data);
        final entry = (await BulkScanCache.loadForApp('first'))!;
        entry['F-Droid'] = 'changed';
        final full = await BulkScanCache.load();
        full['first']!.clear();
        full.remove('second');
        expect(await BulkScanCache.load(), data);
        expect(await BulkScanCache.loadForApp('missing'), isNull);
        expect(await readJsonFileOffIsolate(cacheFile.path), data);
      },
    );

    test(
      'queued saves capture input and merge independent store results',
      () async {
        final input = {
          'app': {'F-Droid': 'original'},
        };
        final first = BulkScanCache.save(input);
        input['app']!['F-Droid'] = 'mutated after enqueue';
        final second = BulkScanCache.save({
          'app': {'APKPure': 'second'},
        });
        await Future.wait([first, second]);
        expect(await BulkScanCache.loadForApp('app'), {
          'F-Droid': 'original',
          'APKPure': 'second',
        });
        expect(
          await readJsonFileOffIsolate(cacheFile.path),
          await BulkScanCache.load(),
        );
      },
    );

    test('a stale store scan saves only its own results', () async {
      await BulkScanCache.save({
        'app': {'F-Droid': 'old'},
      });
      final stale = await BulkScanCache.load();
      await BulkScanCache.save({
        'app': {'F-Droid': 'new'},
      });
      await BulkScanCache.mergeStoreAndSave(stale, 'APKPure', {'app': 'pure'});
      expect(stale['app']!['APKPure'], 'pure');
      expect(await BulkScanCache.loadForApp('app'), {
        'F-Droid': 'new',
        'APKPure': 'pure',
      });
    });

    test(
      'unchanged saves and absent store removal do not rewrite the file',
      () async {
        final data = {
          'app': {'F-Droid': 'url'},
        };
        await BulkScanCache.save(data);
        await cacheFile.setLastModified(DateTime(2020));
        final modified = await cacheFile.lastModified();
        await BulkScanCache.save(data);
        await BulkScanCache.clearStores({'APKPure'});
        expect(await cacheFile.lastModified(), modified);
        await BulkScanCache.clearStores({'F-Droid'});
        expect(await BulkScanCache.cachedStores(), isEmpty);
      },
    );

    test('the F-Droid page read for GitHub goes with either store, and is '
        'no store itself', () async {
      const String read = BulkScanCache.fdroidSourceCodeReadFromKey;
      const String page = 'https://f-droid.org/packages/app/';
      Future<void> saveRead() => BulkScanCache.save({
        'app': {'F-Droid': page, 'GitHub': '', read: page},
      });

      await saveRead();
      expect(await BulkScanCache.cachedStores(), {'F-Droid', 'GitHub'});
      await BulkScanCache.clearStores({'APKPure'});
      expect((await BulkScanCache.loadForApp('app'))![read], page);
      for (final String store in ['GitHub', 'F-Droid']) {
        await saveRead();
        await BulkScanCache.clearStores({store});
        final Map<String, String> left = (await BulkScanCache.loadForApp(
          'app',
        ))!;
        expect(left.containsKey(read), isFalse, reason: store);
        expect(left.containsKey(store), isFalse);
      }
    });

    test('clearing the cache cannot delete the save queued after it', () async {
      await BulkScanCache.save({
        'old': {'F-Droid': 'old'},
      });
      await Future.wait([
        BulkScanCache.clear(),
        BulkScanCache.save({
          'new': {'APKPure': 'new'},
        }),
      ]);
      expect(await readJsonFileOffIsolate(cacheFile.path), {
        'new': {'APKPure': 'new'},
      });
      expect(await BulkScanCache.loadForApp('old'), isNull);
    });

    test(
      'failed writes preserve committed data and the queue recovers',
      () async {
        final original = {
          'app': {'F-Droid': 'original'},
        };
        await BulkScanCache.save(original);
        final blocker = await Directory('${cacheFile.path}.tmp').create();
        try {
          await expectLater(
            BulkScanCache.save({
              'app': {'F-Droid': 'failed'},
            }),
            throwsA(isA<FileSystemException>()),
          );
          expect(await BulkScanCache.load(), original);
          expect(await readJsonFileOffIsolate(cacheFile.path), original);
        } finally {
          await blocker.delete();
        }
        await BulkScanCache.save({
          'app': {'F-Droid': 'recovered'},
        });
        expect(await BulkScanCache.loadForApp('app'), {'F-Droid': 'recovered'});
      },
    );
  });
}
