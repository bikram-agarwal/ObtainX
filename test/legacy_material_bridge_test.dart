// ignore: deprecated_member_use
import 'package:flutter/material.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/legacy_material_bridge.dart';

/// Packages still on flutter/material read the framework's Theme, which a
/// material_ui app never provides. The bridge must hand them the *nearest*
/// material_ui theme (so per-app page themes reach them) and keep the values
/// their fallbacks read.
void main() {
  testWidgets('legacy widgets see the nearest material_ui theme', (
    tester,
  ) async {
    final ColorScheme appScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2E7D32),
    );
    final ColorScheme pageScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFEF6C00),
      brightness: Brightness.dark,
    );
    late legacy.ThemeData seenUnderApp;
    late legacy.ThemeData seenUnderPage;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: appScheme),
        home: Column(
          children: [
            LegacyMaterialBridge(
              child: Builder(
                builder: (BuildContext context) {
                  seenUnderApp = legacy.Theme.of(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
            Theme(
              data: ThemeData(colorScheme: pageScheme),
              child: LegacyMaterialBridge(
                child: Builder(
                  builder: (BuildContext context) {
                    seenUnderPage = legacy.Theme.of(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );

    expect(seenUnderApp.colorScheme.primary, appScheme.primary);
    expect(seenUnderPage.colorScheme.primary, pageScheme.primary);
    expect(seenUnderPage.colorScheme.brightness, Brightness.dark);
    expect(
      seenUnderPage.colorScheme.surfaceContainerHighest,
      pageScheme.surfaceContainerHighest,
    );
  });

  test('the mapping is cached and keeps the markdown fallback colours', () {
    final ThemeData theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
      cardColor: const Color(0xFF123456),
      dividerColor: const Color(0xFF654321),
    );
    final legacy.ThemeData mapped = legacyThemeFor(theme);

    expect(identical(mapped, legacyThemeFor(theme)), isTrue);
    expect(mapped.cardColor, theme.cardColor);
    expect(mapped.dividerColor, theme.dividerColor);
    expect(mapped.primaryColor, theme.primaryColor);
    expect(
      mapped.textTheme.bodyMedium?.fontSize,
      theme.textTheme.bodyMedium?.fontSize,
    );
  });
}
