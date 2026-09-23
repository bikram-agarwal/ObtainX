import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/services/diagnostic_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('density buckets match the usual Android dpi steps', () {
    expect(androidDensityBucket(0.75), 'ldpi');
    expect(androidDensityBucket(1.0), 'mdpi');
    expect(androidDensityBucket(1.5), 'hdpi');
    expect(androidDensityBucket(2.625), 'xhdpi');
    expect(androidDensityBucket(3.0), 'xxhdpi');
    expect(androidDensityBucket(4.0), 'xxxhdpi');
  });

  test('saved secret status keeps the previous share wording', () {
    expect(formatSavedSecretStatus(saved: false), 'Not Saved');
    expect(
      formatSavedSecretStatus(saved: true, validated: true),
      'Saved (Validated: true)',
    );
  });

  test('display scale separates the user setting from the app cap', () {
    expect(
      formatDisplayScale({
        'stableDensityDpi': 420,
        'systemDensityDpi': 420,
        'effectiveDensityDpi': 420,
      }),
      'stock (420 dpi)',
    );
    expect(
      formatDisplayScale({
        'stableDensityDpi': 420,
        'systemDensityDpi': 480,
        'effectiveDensityDpi': 480,
      }),
      '1.14x of stock (480 dpi, stock 420 dpi)',
    );
    expect(
      formatDisplayScale({
        'stableDensityDpi': 420,
        'systemDensityDpi': 600,
        'effectiveDensityDpi': 504,
      }),
      '1.43x of stock, capped by the app to 1.2x '
      '(system 600 dpi, app 504 dpi, stock 420 dpi)',
    );
  });

  test('display scale is omitted when the platform cannot answer', () {
    expect(formatDisplayScale(null), isNull);
    expect(formatDisplayScale(const <String, Object?>{}), isNull);
    expect(
      formatDisplayScale({
        'stableDensityDpi': 0,
        'systemDensityDpi': 420,
        'effectiveDensityDpi': 420,
      }),
      isNull,
    );
  });

  test('display line carries the size, density and text scale knobs', () {
    final StringBuffer buffer = StringBuffer();
    DiagnosticDisplayInfo(
      logicalSize: const Size(411.4, 914.3),
      devicePixelRatio: 2.625,
      textScale: 1.3,
      boldText: true,
      platformBrightness: Brightness.dark,
    ).writeTo(buffer);

    expect(
      buffer.toString(),
      'Screen: 411.4 x 914.3 dp @ 2.625 (xhdpi)\n'
      'Text scale: 1.3 (bold text on)\n',
    );
  });

  testWidgets('the dump keeps behavioral state and drops the trivia', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'installMethod': 'external',
      'externalInstallerPackage': 'com.example.installer',
      'enableBackgroundUpdates': false,
      'parallelDownloads': true,
      'groupBy': 'category',
      GitHub.githubCredsKey: 'ghp_should_never_appear_in_the_log',
      // Cosmetic settings that used to be dumped and should not come back.
      'showAuthorBadge': true,
      'rightSwipeActionName': 'pin',
      'categories': '{"Productivity":123}',
      'searchDeselected': <String>['GitHub'],
    });
    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(
          size: Size(360, 800),
          devicePixelRatio: 2,
          textScaler: TextScaler.linear(1.15),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(),
        ),
      ),
    );

    final String dump = await buildObtainxDiagnosticLog(
      settings: settings,
      trackedAppCount: 100,
      display: DiagnosticDisplayInfo.fromContext(
        tester.element(find.byType(SizedBox)),
      ),
      appLocale: 'en',
      deviceLocale: 'en-US',
      probeNativePlatform: false,
    );

    expect(dump, contains('=== ObtainX Diagnostic Log ==='));
    expect(dump, contains('Tracked apps: 100'));
    expect(dump, contains('Locale: en (device en-US, forced no)'));
    expect(dump, contains('Screen: 360 x 800 dp @ 2 (xhdpi)'));
    expect(dump, contains('Text scale: 1.15'));
    expect(dump, contains('Installer: external (com.example.installer)'));
    expect(dump, contains('background false'));
    expect(dump, contains('parallel true'));
    expect(dump, contains('group by category'));
    expect(dump, contains('GitHub PAT: Saved (Validated: false)'));

    expect(dump, isNot(contains('ghp_should_never_appear_in_the_log')));
    expect(dump, isNot(contains('Fingerprint')));
    expect(dump, isNot(contains('Orientation')));
    expect(dump, isNot(contains('Invert colors')));
    expect(dump, isNot(contains('High contrast')));
    expect(dump, isNot(contains('Accessible navigation')));
    expect(dump, isNot(contains('Is physical device')));
    expect(dump, isNot(contains('Categories')));
    expect(dump, isNot(contains('Search deselected')));
    expect(dump, isNot(contains('badge')));
    expect(dump, isNot(contains('swipe')));
    expect(dump, isNot(contains('All prefs')));
  });

  testWidgets('conditional sections stay out when their feature is off', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'installMethod': 'system',
      'enableBackgroundUpdates': false,
      'enableVirusTotalScanning': false,
    });
    final SettingsProvider settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(size: Size(360, 800), devicePixelRatio: 2),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.expand(),
        ),
      ),
    );

    final String dump = await buildObtainxDiagnosticLog(
      settings: settings,
      trackedAppCount: 3,
      display: DiagnosticDisplayInfo.fromContext(
        tester.element(find.byType(SizedBox)),
      ),
      appLocale: 'en',
      probeNativePlatform: false,
    );

    expect(dump, contains('Installer: system'));
    expect(dump, isNot(contains('Background conditions')));
    expect(dump, isNot(contains('VirusTotal API Key')));
    expect(dump, isNot(contains('Custom font')));
    expect(dump, isNot(contains('Device type')));
    expect(dump, isNot(contains('Build flavor')));
    expect(dump, isNot(contains('GitHub request prefix')));
  });
}
