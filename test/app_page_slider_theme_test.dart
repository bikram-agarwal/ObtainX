import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/theme.dart';
import 'package:obtainium/theme/app_page_icon_colors.dart';

// The additional options page (and the app page) theme the page from the
// app's icon with `ThemeData.copyWith(colorScheme:)`, which keeps the parent's
// slider theme: the sliders kept the app-wide colours.
void main() {
  test('app page themes colour sliders from the app\'s scheme', () {
    final ColorScheme global = ColorScheme.fromSeed(seedColor: Colors.blue);
    final ColorScheme perApp = ColorScheme.fromSeed(seedColor: Colors.red);
    final ThemeData page = buildAppPageThemedData(
      buildObtainiumTheme(global, null),
      perApp,
    );

    expect(page.sliderTheme.activeTrackColor, perApp.primary);
    expect(page.sliderTheme.thumbColor, perApp.primary);
    expect(page.sliderTheme.inactiveTrackColor, perApp.surfaceContainerHighest);
    expect(page.sliderTheme.activeTrackColor, isNot(global.primary));
  });
}
