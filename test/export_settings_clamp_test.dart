import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An imported backup writes `exportSettings` straight into prefs. An
/// out-of-range value must not read as "everything", or auto-export would
/// include secrets without the warning the Backup page shows (D30 #4).
void main() {
  Future<SettingsProvider> withStored(Object? value) async {
    SharedPreferences.setMockInitialValues({'exportSettings': ?value});
    return SettingsProvider()..prefs = await SharedPreferences.getInstance();
  }

  test('valid values read back unchanged', () async {
    for (final int value in [0, 1, 2]) {
      expect((await withStored(value)).exportSettings, value);
    }
  });

  test('out-of-range values read as "settings without secrets"', () async {
    expect((await withStored(3)).exportSettings, 1);
    expect((await withStored(-1)).exportSettings, 1);
    expect((await withStored(null)).exportSettings, 1);
  });
}
