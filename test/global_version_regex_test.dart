// Global version-trimming regex (upstream #3368, v1.7.4 sync D9). Adapted
// from upstream's test: ObtainX keeps the helper in lib/version (no
// version_service) and passes the validated globals in explicitly.

import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/version/version_strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _scraped = 'v2.5.5.1 - Pro Latest';

Future<SettingsProvider> _settings([
  Map<String, Object> prefs = const {},
]) async {
  SharedPreferences.setMockInitialValues(prefs);
  return SettingsProvider()..prefs = await SharedPreferences.getInstance();
}

/// What SourceProvider.getApp passes: the globals only when the source
/// offers the per-app setting.
String? _extract(
  Map<String, dynamic> appSettings,
  SettingsProvider settings,
  String version, {
  bool allowGlobalDefault = true,
}) => extractVersionWithGlobalDefault(
  appSettings,
  version,
  globalRegEx: allowGlobalDefault
      ? settings.globalVersionExtractionRegEx
      : null,
  globalMatchGroup: settings.globalMatchGroupToUse,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('extractVersionWithGlobalDefault', () {
    test('trims with the global regex when the app has none', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'\d+(\.\d+)+',
      });
      expect(
        _extract(
          const {'versionExtractionRegEx': '', 'matchGroupToUse': ''},
          settings,
          _scraped,
        ),
        '2.5.5.1',
      );
    });

    test('a blank app regex counts as unset', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'\d+(\.\d+)+',
      });
      expect(
        _extract(const {'versionExtractionRegEx': '   '}, settings, _scraped),
        '2.5.5.1',
      );
    });

    test('uses the global match group', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'v(\d+(\.\d+)+) - (\w+)',
        'globalMatchGroupToUse': r'$1-$3',
      });
      expect(_extract(const {}, settings, _scraped), '2.5.5.1-Pro');
    });

    test('prefers the app regex and match group', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'\d+(\.\d+)+',
        'globalMatchGroupToUse': '0',
      });
      expect(
        _extract(
          const {'versionExtractionRegEx': r'v(\d+)\.', 'matchGroupToUse': '1'},
          settings,
          _scraped,
        ),
        '2',
      );
    });

    test('keeps the version when the global regex does not match', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'^\d+$',
      });
      expect(_extract(const {}, settings, _scraped), isNull);
    });

    test('still fails when the app regex does not match', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'\d+(\.\d+)+',
      });
      expect(
        () => _extract(
          const {'versionExtractionRegEx': r'^\d+$'},
          settings,
          _scraped,
        ),
        throwsA(isA<NoVersionError>()),
      );
    });

    test('ignores the global regex for sources without the setting', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'\d+',
      });
      expect(
        _extract(const {}, settings, '-1234567890', allowGlobalDefault: false),
        isNull,
      );
    });

    test('an invalid global regex is ignored, not thrown', () async {
      final settings = await _settings({
        'globalVersionExtractionRegEx': r'(\d+',
      });
      expect(settings.globalVersionExtractionRegEx, isNull);
      expect(_extract(const {}, settings, _scraped), isNull);
    });

    test('does nothing without any regex', () async {
      final settings = await _settings();
      expect(_extract(const {}, settings, _scraped), isNull);
    });
  });

  test('global trimming settings are trimmed and cleared when empty', () async {
    final settings = await _settings();
    settings.globalVersionExtractionRegEx = r'  \d+(\.\d+)+ ';
    settings.globalMatchGroupToUse = ' 0 ';
    expect(settings.globalVersionExtractionRegEx, r'\d+(\.\d+)+');
    expect(settings.globalMatchGroupToUse, '0');
    settings.globalVersionExtractionRegEx = '';
    settings.globalMatchGroupToUse = null;
    expect(
      settings.prefs!.containsKey('globalVersionExtractionRegEx'),
      isFalse,
    );
    expect(settings.prefs!.containsKey('globalMatchGroupToUse'), isFalse);
  });
}
