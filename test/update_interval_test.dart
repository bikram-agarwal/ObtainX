import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SettingsProvider> _settingsWithPrefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  final SettingsProvider settings = SettingsProvider();
  settings.prefs = await SharedPreferences.getInstance();
  return settings;
}

void main() {
  test('every stop and never stay as they are', () {
    expect(snapUpdateInterval(0), 0);
    for (final int stop in SettingsProvider.updateIntervalStops) {
      expect(snapUpdateInterval(stop), stop);
    }
  });

  test('an in-between interval moves to the nearest stop by ratio', () {
    // 225 is 1.25x 180 but 360 is 1.6x 225.
    expect(snapUpdateInterval(225), 180);
    expect(snapUpdateInterval(270), 360);
    // Two days: 1440 is 2x away, 4320 only 1.5x.
    expect(snapUpdateInterval(2880), 4320);
    expect(snapUpdateInterval(5), 15);
    expect(snapUpdateInterval(100000), 43200);
    expect(snapUpdateInterval(-1), 0);
  });

  test('an Obtainium in-between interval is what checks run at and the slider shows', () async {
    // Obtainium's slider at 5.5 means 240 minutes.
    final settings = await _settingsWithPrefs({
      'updateInterval': 240,
      'updateIntervalSliderVal': 5.5,
    });
    addTearDown(settings.dispose);

    expect(settings.updateInterval, 180);
  });

  test(
    'setting the interval keeps Obtainium\'s slider position in step',
    () async {
      final settings = await _settingsWithPrefs({});
      addTearDown(settings.dispose);

      settings.updateInterval = 1440;
      expect(settings.prefs!.getInt('updateInterval'), 1440);
      // Obtainium puts its 8th stop (one day) at 8.
      expect(settings.prefs!.getDouble('updateIntervalSliderVal'), 8.0);

      settings.updateInterval = 0;
      expect(settings.prefs!.getDouble('updateIntervalSliderVal'), 0.0);

      settings.updateInterval = 225;
      expect(settings.prefs!.getInt('updateInterval'), 180);
      expect(settings.prefs!.getDouble('updateIntervalSliderVal'), 5.0);
    },
  );
}
