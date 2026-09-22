import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_details_container.dart';

void main() {
  for (final mode in ['light', 'dark', 'black']) {
    testWidgets(
      '$mode card morph has no bright flash when opening or closing',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        addTearDown(tester.view.reset);
        final colors = switch (mode) {
          'light' => [
            const Color(0xFFDDD4C6),
            const Color(0xFFC2B5A3),
            const Color(0xFFC9BCD7),
            const Color(0xFF74648A),
          ],
          'dark' => [
            const Color(0xFF121018),
            const Color(0xFF302638),
            const Color(0xFF221930),
            const Color(0xFF66507A),
          ],
          _ => [
            Colors.black,
            Colors.black,
            Colors.black,
            const Color(0xFF30203A),
          ],
        };
        final maximumExpectedChannel = colors
            .expand((color) => [color.r, color.g, color.b])
            .reduce(math.max);
        final maximumByte = (maximumExpectedChannel * 255).round() + 3;
        final boundaryKey = GlobalKey();
        final navigatorKey = GlobalKey<NavigatorState>();
        final recordedFrames = <ui.Image>[];
        final frameLabels = <String>[];
        final peakBrightPixels = <String, int>{};
        final captureDirectory =
            Platform.environment['OBTAINX_MORPH_CAPTURE_DIR'];

        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              navigatorKey: navigatorKey,
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: colors[3],
                  brightness: mode == 'light'
                      ? Brightness.light
                      : Brightness.dark,
                ).copyWith(surface: colors[0]),
                scaffoldBackgroundColor: colors[0],
                canvasColor: colors[0],
              ),
              home: Scaffold(
                body: Align(
                  alignment: const Alignment(0, -0.5),
                  child: SizedBox(
                    width: 312,
                    height: 100,
                    child: AppDetailsContainer(
                      closedShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      closedBuilder: (context, openContainer) =>
                          GestureDetector(
                            key: const ValueKey('app-card'),
                            onTap: openContainer,
                            child: ColoredBox(
                              color: colors[1],
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: ColoredBox(
                                    color: colors[3],
                                    child: const SizedBox(
                                      width: 48,
                                      height: 48,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      openBuilder: (context) => Scaffold(
                        key: const ValueKey('app-details'),
                        backgroundColor: colors[2],
                        body: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [colors[1], colors[2]],
                            ),
                          ),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: ColoredBox(
                                color: colors[3],
                                child: const SizedBox(width: 80, height: 80),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        Future<void> sampleFrames(String direction) async {
          var peak = 0;
          for (var frameIndex = 0; frameIndex <= 20; frameIndex++) {
            if (frameIndex > 0) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final frame = await boundary.toImage();
              final data = (await frame.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!.buffer.asUint8List();
              var brightPixels = 0;
              for (var offset = 0; offset < data.length; offset += 4) {
                if (data[offset] > maximumByte ||
                    data[offset + 1] > maximumByte ||
                    data[offset + 2] > maximumByte) {
                  brightPixels++;
                }
              }
              peak = math.max(peak, brightPixels);
              if (captureDirectory != null &&
                  [0, 2, 4, 6, 10, 20].contains(frameIndex)) {
                recordedFrames.add(frame);
                frameLabels.add('$direction ${frameIndex * 16} ms');
              } else {
                frame.dispose();
              }
            });
          }
          peakBrightPixels[direction] = peak;
        }

        await tester.tap(find.byKey(const ValueKey('app-card')));
        await tester.pump();
        await sampleFrames('open');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-details')), findsOneWidget);
        navigatorKey.currentState!.pop();
        await tester.pump();
        await sampleFrames('close');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-card')), findsOneWidget);
        expect(tester.takeException(), isNull);

        if (captureDirectory != null) {
          await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawColor(const Color(0xFF202020), BlendMode.src);
            for (
              var frameIndex = 0;
              frameIndex < recordedFrames.length;
              frameIndex++
            ) {
              final frame = recordedFrames[frameIndex];
              final left = (frameIndex % 6) * 180.0;
              final top = (frameIndex ~/ 6) * 344.0;
              final label = TextPainter(
                text: TextSpan(
                  text: frameLabels[frameIndex],
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                textDirection: TextDirection.ltr,
              )..layout();
              label.paint(canvas, Offset(left + 6, top + 4));
              canvas.drawImageRect(
                frame,
                const Rect.fromLTWH(0, 0, 360, 640),
                Rect.fromLTWH(left, top + 24, 180, 320),
                Paint(),
              );
              frame.dispose();
            }
            final picture = recorder.endRecording();
            final sheet = await picture.toImage(1080, 688);
            final png = await sheet.toByteData(format: ui.ImageByteFormat.png);
            await Directory(captureDirectory).create(recursive: true);
            await File(
              '$captureDirectory/$mode.png',
            ).writeAsBytes(png!.buffer.asUint8List());
            picture.dispose();
            sheet.dispose();
          });
        }
        expect(
          peakBrightPixels,
          {'open': 0, 'close': 0},
          reason:
              'The morph must not expose a brighter, unrelated canvas color.',
        );
      },
    );
  }
}
