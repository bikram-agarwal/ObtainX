import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/custom_app_bar.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'progressiveBlurEnabled': true,
    });
  });

  testWidgets('solid page background retains progressive blur when enabled', (
    WidgetTester tester,
  ) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final SettingsProvider settingsProvider = SettingsProvider()
      ..prefs = preferences;
    const Color surfaceColor = Color(0xFF123456);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settingsProvider,
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(surface: surfaceColor),
          ),
          home: const Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                CustomAppBar(title: 'Apps', matchGradientBackground: false),
                SliverToBoxAdapter(child: SizedBox(height: 1000)),
              ],
            ),
          ),
        ),
      ),
    );

    final Finder appBar = find.byType(CustomAppBar);
    final SliverAppBar renderedAppBar = tester.widget<SliverAppBar>(
      find.descendant(of: appBar, matching: find.byType(SliverAppBar)),
    );
    expect(renderedAppBar.backgroundColor, Colors.transparent);
    expect(renderedAppBar.forceMaterialTransparency, isTrue);
    expect(
      find.descendant(
        of: appBar,
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is ColoredBox && widget.color == surfaceColor,
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: appBar,
        matching: find.byType(ScrollLinkedProgressiveBlur),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'gradient page background retains progressive blur when enabled',
    (WidgetTester tester) async {
      final SharedPreferences preferences =
          await SharedPreferences.getInstance();
      final SettingsProvider settingsProvider = SettingsProvider()
        ..prefs = preferences;

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settingsProvider,
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: const Scaffold(
              body: CustomScrollView(
                slivers: <Widget>[
                  CustomAppBar(title: 'Apps', matchGradientBackground: true),
                  SliverToBoxAdapter(child: SizedBox(height: 1000)),
                ],
              ),
            ),
          ),
        ),
      );

      final SliverAppBar renderedAppBar = tester.widget<SliverAppBar>(
        find.descendant(
          of: find.byType(CustomAppBar),
          matching: find.byType(SliverAppBar),
        ),
      );
      expect(renderedAppBar.backgroundColor, Colors.transparent);
      expect(renderedAppBar.forceMaterialTransparency, isTrue);
      expect(
        find.descendant(
          of: find.byType(CustomAppBar),
          matching: find.byType(ScrollLinkedProgressiveBlur),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('solid page background becomes opaque when blur is disabled', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'progressiveBlurEnabled': false,
    });
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final SettingsProvider settingsProvider = SettingsProvider()
      ..prefs = preferences;
    const Color surfaceColor = Color(0xFF123456);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settingsProvider,
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(surface: surfaceColor),
          ),
          home: const Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                CustomAppBar(title: 'Apps', matchGradientBackground: false),
                SliverToBoxAdapter(child: SizedBox(height: 1000)),
              ],
            ),
          ),
        ),
      ),
    );

    final Finder appBar = find.byType(CustomAppBar);
    final SliverAppBar renderedAppBar = tester.widget<SliverAppBar>(
      find.descendant(of: appBar, matching: find.byType(SliverAppBar)),
    );
    expect(renderedAppBar.backgroundColor, surfaceColor);
    expect(renderedAppBar.forceMaterialTransparency, isFalse);
    expect(
      find.descendant(
        of: appBar,
        matching: find.byType(ScrollLinkedProgressiveBlur),
      ),
      findsNothing,
    );
  });

  testWidgets('fully visible blur does not rebuild on every scroll tick', (
    tester,
  ) async {
    final settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    final controller = ScrollController();
    addTearDown(settings.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: const [
                CustomAppBar(title: 'Apps'),
                SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
      ),
    );
    controller.jumpTo(100);
    await tester.pumpAndSettle();
    int blurBuilds = 0;
    final previousObserver = debugOnRebuildDirtyWidget;
    addTearDown(() => debugOnRebuildDirtyWidget = previousObserver);
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previousObserver?.call(element, builtOnce);
      if (element.widget is ScrollLinkedProgressiveBlur ||
          (element.widget is AnimatedBuilder &&
              element
                      .findAncestorWidgetOfExactType<
                        ScrollLinkedProgressiveBlur
                      >() !=
                  null)) {
        blurBuilds++;
      }
    };
    for (final offset in [120.0, 140.0, 160.0, 180.0, 200.0]) {
      controller.jumpTo(offset);
      await tester.pump();
    }
    expect(blurBuilds, 0);
    expect(find.byType(BackdropFilter), findsOneWidget);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('blur follows its new scroll position and updates its tint', (
    tester,
  ) async {
    final controllers = [
      ScrollController(initialScrollOffset: 18),
      ScrollController(initialScrollOffset: 60),
    ];
    for (final controller in controllers) {
      addTearDown(controller.dispose);
    }
    final blurKey = GlobalKey();
    late StateSetter updateHost;
    int activePane = 0;
    Color tint = Colors.red;
    bool showBlur = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return Row(
              children: List.generate(2, (paneIndex) {
                return Expanded(
                  child: CustomScrollView(
                    controller: controllers[paneIndex],
                    slivers: [
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 100,
                          child: showBlur && paneIndex == activePane
                              ? ScrollLinkedProgressiveBlur(
                                  key: blurKey,
                                  overlayColor: tint,
                                  blurSigma: 3,
                                )
                              : null,
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 2000)),
                    ],
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
      ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
    );
    final initialState = tester.state(find.byKey(blurKey));
    updateHost(() => activePane = 1);
    await tester.pumpAndSettle();
    expect(tester.state(find.byKey(blurKey)), same(initialState));
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
      ImageFilter.blur(sigmaX: 3, sigmaY: 3),
    );
    controllers[0].jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    updateHost(() => tint = Colors.blue);
    await tester.pumpAndSettle();
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(blurKey),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(
      (decoration.gradient! as LinearGradient).colors.first.toARGB32(),
      Colors.blue.toARGB32(),
    );
    updateHost(() => showBlur = false);
    await tester.pumpAndSettle();
    controllers[1].jumpTo(0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
