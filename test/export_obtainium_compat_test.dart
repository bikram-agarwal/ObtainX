import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/apps_provider_import_export.dart';
import 'package:obtainium/providers/settings_provider.dart';

void main() {
  // ── sortColumn is the one shared key ObtainX can set out of Obtainium's
  // range (its 5th value, lastUpdateCheck = index 4). It must be sanitized in
  // the shared block and preserved in the overlay for an ObtainX self-import.
  test(
    'sortColumn 4 is sanitized in settings and preserved in settingsObtainX',
    () {
      final SplitExportSettings split = splitSettingsForExport(
        <String, dynamic>{
          'sortColumn': SortColumnSettings.lastUpdateCheck.index,
          'theme': ThemeSettings.dark.index,
        },
      );

      expect(
        split.settings['sortColumn'],
        SortColumnSettings.releaseDate.index,
      );
      expect(
        split.settingsObtainX?['sortColumn'],
        SortColumnSettings.lastUpdateCheck.index,
      );
      expect(split.settings['theme'], ThemeSettings.dark.index);
      expect(split.settingsObtainX?.containsKey('theme'), isFalse);
    },
  );

  test('safe sortColumn stays only in settings', () {
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'sortColumn': SortColumnSettings.nameAuthor.index,
    });

    expect(split.settings['sortColumn'], SortColumnSettings.nameAuthor.index);
    expect(split.settingsObtainX?.containsKey('sortColumn'), isNot(true));
  });

  // ── Convergence: grouping and installer are now stored under upstream's own
  // keys/values, so they pass through to the shared block verbatim — no mapping,
  // no overlay. Obtainium reads them directly.
  test('groupBy passes through to shared settings unchanged', () {
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'groupBy': AppsListGroupBy.source.name,
    });

    expect(split.settings['groupBy'], AppsListGroupBy.source.name);
    expect(split.settingsObtainX?.containsKey('groupBy'), isNot(true));
  });

  test('installMethod passes through to shared settings unchanged', () {
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'installMethod': InstallerMode.external.name,
    });

    expect(split.settings['installMethod'], InstallerMode.external.name);
    expect(split.settingsObtainX?.containsKey('installMethod'), isNot(true));
  });

  test('groupBy appType stays verbatim in shared settings (Obtainium tolerates it)', () {
    // ObtainX's extra grouping value has no Obtainium equivalent, but Obtainium's
    // groupBy getter falls back to none for unknown values, so it need not be
    // stripped — and keeping it lets an ObtainX self-import restore it exactly.
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'groupBy': AppsListGroupBy.appType.name,
    });

    expect(split.settings['groupBy'], AppsListGroupBy.appType.name);
    expect(split.settingsObtainX?.containsKey('groupBy'), isNot(true));
  });

  test('ObtainX-only keys stay out of shared settings', () {
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'appFolders': '[]',
      'appAccentColorSource': 'custom',
      'folderView_abc': jsonEncode(<String, dynamic>{'sortColumn': 4}),
      'collapsedGroups': <String>['src:GitHub'],
      'settingsSection_themes': true,
      'groupNonInstalledSeparately': true,
      'enableVirusTotalScanning': true,
      'hideBatteryOptimizationWarning': true,
      // Converged shared keys — must NOT be treated as ObtainX-only.
      'installMethod': InstallerMode.external.name,
      'groupBy': AppsListGroupBy.category.name,
      'buryNonInstalled': true,
      'checkUpdateOnDetailPage': false,
      'theme': ThemeSettings.light.index,
    });

    expect(split.settings.containsKey('appFolders'), isFalse);
    expect(split.settings.containsKey('collapsedGroups'), isFalse);
    expect(split.settings.containsKey('settingsSection_themes'), isFalse);
    expect(split.settings.containsKey('groupNonInstalledSeparately'), isFalse);
    expect(split.settings.containsKey('enableVirusTotalScanning'), isFalse);
    expect(
      split.settings.containsKey('hideBatteryOptimizationWarning'),
      isFalse,
    );
    expect(split.settingsObtainX?['hideBatteryOptimizationWarning'], isTrue);
    expect(split.settings['installMethod'], InstallerMode.external.name);
    expect(split.settings['groupBy'], AppsListGroupBy.category.name);
    expect(split.settings['buryNonInstalled'], isTrue);
    expect(split.settings['checkUpdateOnDetailPage'], isFalse);
    expect(split.settingsObtainX?['appFolders'], '[]');
    expect(split.settingsObtainX?['collapsedGroups'], <String>['src:GitHub']);
    expect(split.settings['theme'], ThemeSettings.light.index);
  });

  test('shared (non-ObtainX-only) keys stay in settings, not the overlay', () {
    // Keys without an ObtainX-only classification go to the shared block so
    // Obtainium restores the ones it recognizes; none leak into the overlay.
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'checkUpdateOnDetailPage': true,
      'buryNonInstalled': true,
    });

    expect(split.settings['checkUpdateOnDetailPage'], isTrue);
    expect(split.settings['buryNonInstalled'], isTrue);
    expect(
      split.settingsObtainX?.containsKey('checkUpdateOnDetailPage'),
      isNot(true),
    );
    expect(split.settingsObtainX?.containsKey('buryNonInstalled'), isNot(true));
  });

  test('settings includes most prefs like Obtainium export', () {
    final Map<String, dynamic> fullSettings = <String, dynamic>{
      for (int index = 0; index < 80; index++) 'pref_$index': index,
      'theme': ThemeSettings.dark.index,
      'groupBy': AppsListGroupBy.source.name,
      'appFolders': '[]',
    };
    final SplitExportSettings split = splitSettingsForExport(fullSettings);

    expect(split.settings.length, greaterThan(70));
    expect(split.settings['groupBy'], AppsListGroupBy.source.name);
    expect(split.settingsObtainX?['appFolders'], '[]');
  });

  test('mergeImportedSettingsMaps overlays ObtainX settings on import', () {
    final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
      <String, dynamic>{
        'sortColumn': SortColumnSettings.releaseDate.index,
        'installMethod': InstallerMode.system.name,
        'theme': ThemeSettings.system.index,
      },
      <String, dynamic>{
        'sortColumn': SortColumnSettings.lastUpdateCheck.index,
        'appFolders': '[]',
      },
    );

    // Overlay wins on conflict (real sortColumn over the sanitized one).
    expect(merged?['sortColumn'], SortColumnSettings.lastUpdateCheck.index);
    expect(merged?['theme'], ThemeSettings.system.index);
    expect(merged?['installMethod'], InstallerMode.system.name);
    expect(merged?['appFolders'], '[]');
  });

  test('imported groupBy / installMethod survive the merge unchanged', () {
    // No translation on import: an Obtainium backup's shared keys are read
    // directly by ObtainX, so the merge is a plain pass-through.
    final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
      <String, dynamic>{
        'groupBy': AppsListGroupBy.source.name,
        'installMethod': InstallerMode.shizuku.name,
      },
      null,
    );

    expect(merged?['groupBy'], AppsListGroupBy.source.name);
    expect(merged?['installMethod'], InstallerMode.shizuku.name);
  });

  test('imported dhizuku installMethod survives the merge unchanged', () {
    final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
      <String, dynamic>{'installMethod': InstallerMode.dhizuku.name},
      null,
    );

    expect(merged?['installMethod'], InstallerMode.dhizuku.name);
  });

  test('dhizuku installMethod exports as Obtainium\'s Shizuku mode with the '
      'Dhizuku backend and round-trips via overlay', () {
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'installMethod': InstallerMode.dhizuku.name,
    });

    // Shared block is Obtainium-compatible: Shizuku mode on its Dhizuku
    // backend (Obtainium #2844), so Obtainium really installs via Dhizuku.
    expect(split.settings['installMethod'], InstallerMode.shizuku.name);
    expect(split.settings['shizukuInstallerMode'], 'dhizuku');
    // ObtainX overlay retains 'dhizuku'
    expect(split.settingsObtainX?['installMethod'], InstallerMode.dhizuku.name);
    expect(
      split.settingsObtainX?.containsKey('shizukuInstallerMode'),
      isNot(true),
    );

    final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
      split.settings,
      split.settingsObtainX,
    );
    // ObtainX import restores 'dhizuku'
    expect(merged?['installMethod'], InstallerMode.dhizuku.name);
  });

  test('other installer modes export without a Shizuku backend', () {
    for (final InstallerMode mode in [
      InstallerMode.system,
      InstallerMode.shizuku,
      InstallerMode.external,
      InstallerMode.root,
    ]) {
      final SplitExportSettings split = splitSettingsForExport(
        <String, dynamic>{'installMethod': mode.name},
      );
      expect(split.settings['installMethod'], mode.name);
      expect(split.settings.containsKey('shizukuInstallerMode'), isFalse);
    }
  });

  test('an Obtainium Dhizuku backend imports as ObtainX\'s Dhizuku mode', () {
    final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
      <String, dynamic>{
        'installMethod': InstallerMode.shizuku.name,
        'shizukuInstallerMode': 'dhizuku',
      },
      null,
    );

    expect(merged?['installMethod'], InstallerMode.dhizuku.name);
    // The upstream key itself is skipped when the settings are applied.
    expect(droppedUpstreamSettingKeys, contains('shizukuInstallerMode'));
  });

  test('an Obtainium auto or Shizuku backend imports as Shizuku mode', () {
    for (final String backend in ['auto', 'shizuku']) {
      final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
        <String, dynamic>{
          'installMethod': InstallerMode.shizuku.name,
          'shizukuInstallerMode': backend,
        },
        null,
      );
      expect(merged?['installMethod'], InstallerMode.shizuku.name);
    }
    // The backend only qualifies Shizuku mode.
    final Map<String, dynamic>? system = mergeImportedSettingsMaps(
      <String, dynamic>{
        'installMethod': InstallerMode.system.name,
        'shizukuInstallerMode': 'dhizuku',
      },
      null,
    );
    expect(system?['installMethod'], InstallerMode.system.name);
  });

  test('an Obtainium Dhizuku backend also moves per-app Shizuku apps', () {
    App app(String? mode) => App(
      id: 'org.example.${mode ?? 'none'}',
      url: 'https://example.org/${mode ?? 'none'}',
      author: 'Example',
      name: 'Example',
      latestVersion: '1.0',
      apkUrls: const [],
      preferredApkIndex: 0,
      additionalSettings: {'installerMode': ?mode},
    );
    final List<App> apps = [
      app(InstallerMode.shizuku.name),
      app(InstallerMode.system.name),
      app(null),
    ];

    final List<App> dhizuku = appsWithImportedShizukuBackend(apps, {
      'installMethod': InstallerMode.dhizuku.name,
      'shizukuInstallerMode': 'dhizuku',
    });
    expect(dhizuku.map((a) => a.additionalSettings['installerMode']), [
      InstallerMode.dhizuku.name,
      InstallerMode.system.name,
      null,
    ]);
    // Any other backend (or none) leaves per-app modes alone.
    final List<App> shizuku = appsWithImportedShizukuBackend(apps, {
      'shizukuInstallerMode': 'shizuku',
    });
    expect(
      shizuku.first.additionalSettings['installerMode'],
      InstallerMode.shizuku.name,
    );
    expect(appsWithImportedShizukuBackend(apps, null), same(apps));
  });

  test('an older backup\'s Wi-Fi / charging switches become guard modes', () {
    final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
      <String, dynamic>{
        'bgUpdatesOnWiFiOnly': true,
        'bgUpdatesWhileChargingOnly': false,
      },
      null,
    );
    // ON meant no background work at all (D5).
    expect(merged?['bgGuardOnWiFi'], BgGuardMode.nothing.name);
    expect(merged?['bgGuardWhileCharging'], BgGuardMode.checksAndUpdates.name);

    // A backup that has the guard key keeps it.
    final Map<String, dynamic>? newer = mergeImportedSettingsMaps(
      <String, dynamic>{
        'bgUpdatesOnWiFiOnly': true,
        'bgGuardOnWiFi': BgGuardMode.checksOnly.name,
      },
      null,
    );
    expect(newer?['bgGuardOnWiFi'], BgGuardMode.checksOnly.name);
  });

  test('import keeps only a content:// export folder (SET-H8)', () {
    // Obtainium on a TV stores its Downloads sentinel; there's no folder
    // behind it in ObtainX, and every auto-export would fail.
    final Map<String, dynamic>? tv = mergeImportedSettingsMaps(
      <String, dynamic>{'exportDir': 'tv-downloads:', 'theme': 1},
      null,
    );
    expect(tv?.containsKey('exportDir'), isFalse);
    expect(tv?['theme'], 1);

    const String tree =
        'content://com.android.externalstorage.documents/tree/primary%3ABackups';
    final Map<String, dynamic>? saf = mergeImportedSettingsMaps(
      <String, dynamic>{'exportDir': tree},
      null,
    );
    expect(saf?['exportDir'], tree);
  });

  test(
    'ObtainX self-import round-trips groupBy=appType via the shared block',
    () {
      final SplitExportSettings split = splitSettingsForExport(
        <String, dynamic>{'groupBy': AppsListGroupBy.appType.name},
      );
      final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
        split.settings,
        split.settingsObtainX,
      );

      expect(merged?['groupBy'], AppsListGroupBy.appType.name);
    },
  );

  test('mergeImportedSettingsMaps falls back to shared settings only', () {
    final Map<String, dynamic>? merged = mergeImportedSettingsMaps(
      <String, dynamic>{'sortColumn': SortColumnSettings.added.index},
      null,
    );

    expect(merged?['sortColumn'], SortColumnSettings.added.index);
  });

  test('ExportSchema emits settingsObtainX when present', () {
    final ExportSchema schema = ExportSchema(
      schemaVersion: currentExportSchemaVersion,
      exportedAt: '2026-01-01T00:00:00.000',
      appVersion: '1.0.0',
      apps: <Map<String, dynamic>>[],
      settings: <String, dynamic>{'sortColumn': 3},
      settingsObtainX: <String, dynamic>{'sortColumn': 4},
    );

    final Map<String, dynamic> json = schema.toJson();
    expect(json['settings'], <String, dynamic>{'sortColumn': 3});
    expect(json['settingsObtainX'], <String, dynamic>{'sortColumn': 4});
  });

  test('Obtainium-facing settings never contain sortColumn >= 4', () {
    final SplitExportSettings split = splitSettingsForExport(<String, dynamic>{
      'sortColumn': 4,
      'groupBy': AppsListGroupBy.appType.name,
      'collapsedGroups': <String>[],
    });

    final int sortColumn = split.settings['sortColumn'] as int;
    expect(sortColumn >= obtainiumSortColumnCount, isFalse);
    expect(split.settings.containsKey('collapsedGroups'), isFalse);
  });

  test('no-secrets export drops tokens and their validation fingerprints', () {
    final Set<String> keys = {
      'theme',
      'github-creds',
      'githubValidatedPATFingerprint',
      'gitlab-creds',
      'gitlab-validated-pat-fingerprint',
      'virustotal-api-key',
      'virustotal-api-key-validated-fingerprint',
      'updateInterval',
    };
    keys.removeWhere(isSecretSettingKey);
    expect(keys, {'theme', 'updateInterval'});
  });

  test('import detects PAT fingerprints as secrets', () {
    expect(
      hasSecretsInSettingsMap(<String, dynamic>{
        'githubValidatedPATFingerprint': 'abc',
        'theme': 0,
      }),
      isTrue,
    );
    expect(
      hasSecretsInSettingsMap(<String, dynamic>{
        'gitlab-validated-pat-fingerprint': 'abc',
      }),
      isTrue,
    );
    expect(hasSecretsInSettingsMap(<String, dynamic>{'theme': 0}), isFalse);
  });

  test('categoryColorHexFromInt and parseCategoryColorHex round-trip', () {
    expect(categoryColorHexFromInt(0xFFFF5733), '#FF5733');
    expect(categoryColorHexFromInt(0xFF00AB12), '#00AB12');
    expect(parseCategoryColorHex('#FF5733'), 0xFFFF5733);
    expect(parseCategoryColorHex('00ab12'), 0xFF00AB12);
    expect(parseCategoryColorHex('#80FF5733'), 0x80FF5733);
    expect(parseCategoryColorHex(' #FF5733 '), 0xFFFF5733);
    expect(parseCategoryColorHex('invalid'), isNull);
    // Only an optional leading '#' and six or eight hex digits.
    expect(parseCategoryColorHex('-12345'), isNull);
    expect(parseCategoryColorHex('+12345'), isNull);
    expect(parseCategoryColorHex('FF#5733'), isNull);
    expect(parseCategoryColorHex('##FF5733'), isNull);
    expect(parseCategoryColorHex('#FF573'), isNull);
  });

  group('category colors in backups', () {
    const int red = 0xFFFF0000;
    const int blue = 0xFF0000FF;
    const int green = 0xFF00FF00;

    App app(String id, List<String> categories) => App(
      id: id,
      url: 'https://github.com/example/$id',
      author: 'example',
      name: id,
      latestVersion: '1.0',
      preferredApkIndex: 0,
      additionalSettings: const {},
      categories: categories,
    );

    test('an export with settings leaves them to the categories setting', () {
      expect(
        categoryColorsForExport(
          settingsExported: true,
          colors: {'Games': red},
          appJsons: [
            {
              'categories': ['Games'],
            },
          ],
        ),
        isNull,
      );
    });

    test('an export without settings writes the exported apps\' colors', () {
      expect(
        categoryColorsForExport(
          settingsExported: false,
          colors: {'Games': red, 'Tools': blue, 'Unused': green},
          appJsons: [
            {
              'categories': ['Games', 'Uncolored'],
            },
            {
              'categories': ['Tools', 7],
            },
            {'categories': null},
          ],
        ),
        {'Games': '#FF0000', 'Tools': '#0000FF'},
      );
      expect(
        categoryColorsForExport(
          settingsExported: false,
          colors: {'Games': red},
          appJsons: [
            {'categories': <String>[]},
          ],
        ),
        isNull,
      );
    });

    test('colors come from categoryColors, else the categories setting', () {
      expect(
        categoryColorsFromBackup(
          hexColors: {'Games': '#FF0000', 'Bad': 'nope'},
          settingsMap: {'categories': '{"Games":$blue}'},
        ),
        {'Games': red},
      );
      // ObtainX and Obtainium store the setting as a JSON string.
      expect(
        categoryColorsFromBackup(
          settingsMap: {'categories': '{"Games":$red,"Tools":"x"}'},
        ),
        {'Games': red},
      );
      expect(
        categoryColorsFromBackup(
          settingsMap: {
            'categories': {'Tools': blue},
          },
        ),
        {'Tools': blue},
      );
      expect(
        categoryColorsFromBackup(settingsMap: {'categories': '{broken'}),
        isNull,
      );
      expect(categoryColorsFromBackup(settingsMap: {'theme': 1}), isNull);
      expect(categoryColorsFromBackup(), isNull);
    });

    test('importing settings takes every backup color over the current', () {
      final Map<String, int> result = categoriesAfterImport(
        current: {'Games': red, 'LocalOnly': green},
        backupColors: {'Games': blue, 'Tools': red},
        settingsImported: true,
        importedApps: [app('a', [])],
        library: [
          app('a', []),
          app('b', ['LocalOnly']),
        ],
        newColor: () => fail('no category lacks a color'),
      );
      expect(result, {'Games': blue, 'Tools': red, 'LocalOnly': green});
    });

    test('without settings, only the imported apps\' categories are added', () {
      final Map<String, int> result = categoriesAfterImport(
        current: {'Games': red},
        backupColors: {'Games': blue, 'Tools': blue, 'Unused': green},
        settingsImported: false,
        importedApps: [
          app('a', ['Games', 'Tools']),
        ],
        library: [
          app('a', ['Games', 'Tools']),
        ],
        newColor: () => fail('no category lacks a color'),
      );
      expect(result, {'Games': red, 'Tools': blue});
    });

    test('a category no color covers gets a new one, so none is orphaned', () {
      int colorsMade = 0;
      final Map<String, int> result = categoriesAfterImport(
        current: const {},
        backupColors: null,
        settingsImported: false,
        importedApps: [
          app('a', ['Games']),
        ],
        library: [
          app('a', ['Games']),
          app('b', ['Games', 'Tools']),
        ],
        newColor: () => green + colorsMade++,
      );
      expect(result, {'Games': green, 'Tools': green + 1});
    });
  });

  test('ExportSchema preserves categoryColors HEX map', () {
    final ExportSchema schema = ExportSchema(
      schemaVersion: currentExportSchemaVersion,
      exportedAt: '2026-11-21T00:00:00.000',
      appVersion: '2.22.0',
      apps: const <Map<String, dynamic>>[],
      categoryColors: const <String, String>{
        'Games': '#FF5733',
        'Tools': '#1E88E5',
      },
    );

    final Map<String, dynamic> encoded = schema.toJson();
    expect(encoded['categoryColors'], <String, String>{
      'Games': '#FF5733',
      'Tools': '#1E88E5',
    });

    final ExportSchema decoded = ExportSchema.fromJson(
      jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>,
    );
    expect(decoded.categoryColors, <String, String>{
      'Games': '#FF5733',
      'Tools': '#1E88E5',
    });
  });
}
