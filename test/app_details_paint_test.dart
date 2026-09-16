import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_details_container.dart';
import 'package:obtainium/components/app_smooth_surface.dart';
import 'package:obtainium/pages/app.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();
  @override
  final Map<String, ({String? title, String message})> appPageErrors = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.delegate);

  final CustomPainter delegate;
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    delegate.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _CountingPainter oldDelegate) {
    return delegate.shouldRepaint(oldDelegate.delegate);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> translations;
  late Uint8List icon;
  setUpAll(() async {
    translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    icon = (await rootBundle.load(
      'assets/graphics/logo_remember.png',
    )).buffer.asUint8List();
  });

  testWidgets('static details are not rebuilt for every card morph frame', (
    tester,
  ) async {
    final painter = _CountingPainter(const _SolidPainter(Color(0xFF66507A)));
    final navigator = GlobalKey<NavigatorState>();
    var detailBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 312,
              height: 100,
              child: AppDetailsContainer(
                closedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                closedBuilder: (context, open) => GestureDetector(
                  onTap: open,
                  child: const ColoredBox(color: Color(0xFF302638)),
                ),
                openBuilder: (context) {
                  detailBuilds++;
                  return CustomPaint(painter: painter);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(GestureDetector).first);
    await tester.pump();
    // Move past the fully transparent opening frames.
    await tester.pump(const Duration(milliseconds: 80));
    final openingPaints = painter.paints;
    final openingBuilds = detailBuilds;
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(painter.paints - openingPaints, lessThanOrEqualTo(1));
    expect(detailBuilds - openingBuilds, 0);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final closingPaints = painter.paints;
    final closingBuilds = detailBuilds;
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(painter.paints - closingPaints, lessThanOrEqualTo(1));
    expect(detailBuilds - closingBuilds, 0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'retained details still receive updates during and after opening',
    (tester) async {
      final revision = ValueNotifier<int>(0);
      addTearDown(revision.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<ValueNotifier<int>>.value(
          value: revision,
          child: MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 312,
                  height: 100,
                  child: AppDetailsContainer(
                    closedShape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    closedBuilder: (context, open) => GestureDetector(
                      key: const ValueKey('open-details'),
                      onTap: open,
                      child: const ColoredBox(color: Color(0xFF302638)),
                    ),
                    openBuilder: (context) => Material(
                      child: Text(
                        'Revision ${context.watch<ValueNotifier<int>>().value}',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-details')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Revision 0'), findsOneWidget);
      revision.value = 1;
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Revision 1'), findsOneWidget);
      await tester.pumpAndSettle();
      revision.value = 2;
      await tester.pump();
      expect(find.text('Revision 2'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      revision.value = 3;
      await tester.tap(find.byKey(const ValueKey('open-details')));
      await tester.pumpAndSettle();
      expect(find.text('Revision 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (mode, reducedEffects) in [
    for (final mode in ['light', 'dark', 'black'])
      for (final reducedEffects in [false, true]) (mode, reducedEffects),
  ]) {
    testWidgets(
      '$mode details retain cards and simplify rendering (reduced effects: $reducedEffects)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'matchAppPageToIconColors': false,
          'checkUpdateOnDetailPage': false,
          'showAppWebpage': false,
          'reduceVisualEffects': reducedEffects,
          'useGradientBackground': false,
          'progressiveBlurEnabled': false,
          'cardCornerScale': 1.5,
          'useBlackTheme': mode == 'black',
        });
        final settings = SettingsProvider()
          ..prefs = await SharedPreferences.getInstance();
        settings.theme = mode == 'light'
            ? ThemeSettings.light
            : ThemeSettings.dark;
        final colors = ColorScheme.fromSeed(
          seedColor: const Color(0xFF66507A),
          brightness: mode == 'light' ? Brightness.light : Brightness.dark,
        );
        Localization.load(
          const Locale('en'),
          translations: Translations(translations),
        );
        final provider = _Apps();
        final model = App(
          id: 'org.example.app',
          url: 'https://github.com/example/app',
          author: 'Example',
          name: 'Example',
          installedVersion: '1.0.0',
          latestVersion: '1.1.0',
          preferredApkIndex: 0,
          additionalSettings: {
            'trackOnly': true,
            'about': List.filled(
              40,
              'Description of the release.',
            ).join('\n\n'),
          },
        );
        provider.apps[model.id] = AppInMemory(model, null, null, icon);
        addTearDown(provider.dispose);
        addTearDown(settings.dispose);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(480, 800);
        addTearDown(tester.view.reset);

        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MultiProvider(
              providers: [
                ChangeNotifierProvider<AppsProvider>.value(value: provider),
                ChangeNotifierProvider<SettingsProvider>.value(value: settings),
              ],
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  colorScheme: mode == 'black'
                      ? colors.copyWith(surface: Colors.black)
                      : colors,
                ),
                home: AppPage(appId: model.id),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> capture(String label) async {
          final directory = Platform.environment['OBTAINX_DETAILS_CAPTURE_DIR'];
          if (directory == null) return;
          await tester.runAsync(() async {
            final boundary =
                captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(directory).create(recursive: true);
            await File(
              '$directory/details-$mode-$reducedEffects-$label.png',
            ).writeAsBytes(png!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('initial');
        void expectEffects(bool reduced) {
          final offscreenClips = tester.layers
              .whereType<ClipRRectLayer>()
              .where(
                (layer) => layer.clipBehavior == Clip.antiAliasWithSaveLayer,
              );
          expect(offscreenClips, reduced ? isEmpty : isNotEmpty);
          final shadows = tester
              .widgetList<DecoratedBox>(
                find.descendant(
                  of: find.byType(AppPage),
                  matching: find.byType(DecoratedBox),
                ),
              )
              .where(
                (box) =>
                    box.decoration is BoxDecoration &&
                    ((box.decoration as BoxDecoration).boxShadow?.isNotEmpty ??
                        false),
              );
          expect(shadows, reduced ? isEmpty : isNotEmpty);
        }

        // Count real section-card paints without changing their appearance.
        final surfaces = find.byType(AppSmoothRoundedSurface);
        expect(surfaces, findsAtLeastNWidgets(3));
        final painters = <_CountingPainter>[];
        for (final surface in surfaces.evaluate()) {
          final paintFinder = find
              .descendant(
                of: find.byWidget(surface.widget),
                matching: find.byType(CustomPaint),
              )
              .first;
          final renderPaint = tester.renderObject<RenderCustomPaint>(
            paintFinder,
          );
          final painter = _CountingPainter(renderPaint.painter!);
          renderPaint.painter = painter;
          painters.add(painter);
        }
        await tester.pump();
        final initialPaints = painters
            .map((painter) => painter.paints)
            .toList();
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(scrollable.position.maxScrollExtent, greaterThan(200));
        final initialCardPosition = tester.getTopLeft(surfaces.first);
        for (var step = 1; step <= 10; step++) {
          scrollable.position.jumpTo(step * 10);
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          tester.getTopLeft(surfaces.first).dy,
          initialCardPosition.dy - 100,
        );
        await capture('scrolled');
        expect(
          painters.map((painter) => painter.paints).toList(),
          initialPaints,
          reason:
              'Scrolling must move retained cards, not repaint their shadows, clips and text.',
        );
        expectEffects(reducedEffects);
        // A mounted details page must update even when blur and gradients were
        // already off before the master switch changed.
        settings.reduceVisualEffects = !reducedEffects;
        await tester.pumpAndSettle();
        expectEffects(!reducedEffects);
        settings.reduceVisualEffects = reducedEffects;
        await tester.pumpAndSettle();
        expectEffects(reducedEffects);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _SolidPainter extends CustomPainter {
  const _SolidPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SolidPainter oldDelegate) {
    return color != oldDelegate.color;
  }
}
