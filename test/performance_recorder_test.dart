import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/components/app_bottom_sheet.dart';
import 'package:obtainium/components/performance_recording_control.dart';
import 'package:obtainium/services/performance_recorder.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Apps extends ChangeNotifier implements AppsProvider {
  @override
  final AppListings apps = AppListings();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _Logs implements LogsProvider {
  @override
  Future<List<Log>> get({
    DateTime? before,
    DateTime? after,
    int? limit,
    String? orderBy,
  }) async {
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

const environment = PerformanceEnvironment(
  refreshRate: 60,
  blur: true,
  reducedEffects: false,
  gradients: false,
  appCount: 120,
);

Map<String, dynamic> reportData(PerformanceRecorder recorder) {
  final report = recorder.latestReport!;
  return jsonDecode(
        report.substring(report.indexOf('{'), report.lastIndexOf('}') + 1),
      )
      as Map<String, dynamic>;
}

FrameTiming frame(int start, int build, int raster) {
  return FrameTiming(
    vsyncStart: start,
    buildStart: start,
    buildFinish: start + build,
    rasterStart: start + build,
    rasterFinish: start + build + raster,
    rasterFinishWallTime: start + build + raster,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final translations = (await const RootBundleAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
    Localization.load(
      const Locale('en'),
      translations: Translations(translations),
    );
  });

  testWidgets('App logs closes on start and reopening can stop and share', (
    tester,
  ) async {
    final recorder = PerformanceRecorder(saveReport: (_) async {});
    addTearDown(recorder.dispose);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider()
      ..prefs = await SharedPreferences.getInstance();
    final apps = _Apps();
    addTearDown(settings.dispose);
    addTearDown(apps.dispose);
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<LogsProvider>.value(value: _Logs()),
          ChangeNotifierProvider<AppsProvider>.value(value: apps),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () => showAppModalSheet<void>(
                    context: context,
                    builder: (_) => LogsSheet(
                      initialDays: 1,
                      performanceRecorder: recorder,
                    ),
                  ),
                  child: const Text('Open logs'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open logs'));
    await tester.pumpAndSettle();
    expect(find.byType(LogsSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Record performance'));
    await tester.pumpAndSettle();
    expect(find.byType(LogsSheet), findsNothing);
    expect(recorder.isRecording, isTrue);
    await tester.tap(find.text('Open logs'));
    await tester.pumpAndSettle();
    expect(find.text('Stop recording'), findsOneWidget);
    await tester.tap(find.text('Stop recording'));
    await tester.pumpAndSettle();
    expect(recorder.isRecording, isFalse);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Share as file'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'idle does no work; duplicate start and stop do not duplicate logs',
    (tester) async {
      final reports = <String>[];
      final recorder = PerformanceRecorder(
        saveReport: (report) async {
          reports.add(report);
        },
      );
      addTearDown(recorder.dispose);
      expect(recorder.startOperation(), isNull);
      await tester.pump(const Duration(minutes: 2));
      expect(reports, isEmpty);
      expect(recorder.start(readEnvironment: () => environment), isTrue);
      expect(recorder.start(readEnvironment: () => environment), isFalse);
      await tester.pump();
      final finishing = recorder.stop();
      expect(recorder.isRecording, isFalse);
      expect(recorder.isSaving, isTrue);
      expect(recorder.start(readEnvironment: () => environment), isFalse);
      await finishing;
      await recorder.stop();
      expect(recorder.isSaving, isFalse);
      expect(reports, hasLength(1));
      expect(recorder.startOperation(), isNull);
    },
  );

  testWidgets(
    'frame budgets distinguish expensive stages from pipeline latency',
    (tester) async {
      final recorder = PerformanceRecorder(saveReport: (_) async {});
      addTearDown(recorder.dispose);
      recorder.start(readEnvironment: () => environment);
      await tester.pump(const Duration(milliseconds: 16));
      final anchor = tester.binding.currentSystemFrameTimeStamp.inMicroseconds;
      tester.binding.platformDispatcher.onReportTimings!([
        frame(anchor - 1000, 99000, 99000), // Buffered before start: excluded.
        frame(anchor, 10000, 9000),
        frame(anchor + 100000, 22000, 2000),
        frame(anchor + 200000, 1000, 18000),
      ]);
      await recorder.stop();
      final window = (reportData(recorder)['frame_windows'] as List).single;
      expect(window['ui']['samples'], 3);
      expect(window['ui']['max_ms'], 22);
      expect(window['ui']['p95_ms_upper_bound'], 22);
      expect(window['ui_over_budget'], 1);
      expect(window['raster_over_budget'], 1);
      expect(window['either_stage_over_budget'], 2);
      expect(window['latency_over_budget'], 3);
      final original = recorder.latestReport;
      tester.binding.platformDispatcher.onReportTimings!([
        frame(anchor, 999999, 999999),
      ]);
      expect(recorder.latestReport, original);
    },
  );

  testWidgets(
    '120 Hz has its own budget; invalid rates never invent a budget',
    (tester) async {
      for (final rate in [120.0, 0.0, double.nan]) {
        final recorder = PerformanceRecorder(saveReport: (_) async {});
        recorder.start(
          readEnvironment: () => PerformanceEnvironment(
            refreshRate: rate,
            blur: false,
            reducedEffects: true,
            gradients: false,
            appCount: 20,
          ),
        );
        await tester.pump();
        final anchor =
            tester.binding.currentSystemFrameTimeStamp.inMicroseconds;
        tester.binding.platformDispatcher.onReportTimings!([
          frame(anchor, 10000, 10000),
        ]);
        await recorder.stop();
        final window = (reportData(recorder)['frame_windows'] as List).single;
        expect(window['frames_with_known_budget'], rate == 120 ? 1 : 0);
        expect(window['either_stage_over_budget'], rate == 120 ? 1 : 0);
        recorder.dispose();
      }
    },
  );

  testWidgets('60 second limit saves an idle recording without inventing FPS', (
    tester,
  ) async {
    final reports = <String>[];
    final recorder = PerformanceRecorder(
      saveReport: (report) async {
        reports.add(report);
      },
    );
    addTearDown(recorder.dispose);
    recorder.start(readEnvironment: () => environment);
    await tester.pump();
    await tester.pump(const Duration(seconds: 60));
    await recorder.stop();
    expect(recorder.isRecording, isFalse);
    expect(reports, hasLength(1));
    expect(reportData(recorder)['stop_reason'], 'time_limit');
    expect(reportData(recorder)['frame_windows'], isEmpty);
    await tester.pump(const Duration(minutes: 2));
    expect(reports, hasLength(1));
  });

  testWidgets('background stops and unregisters; foreground does not restart', (
    tester,
  ) async {
    final recorder = PerformanceRecorder(saveReport: (_) async {});
    addTearDown(recorder.dispose);
    recorder.start(readEnvironment: () => environment);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await recorder.stop();
    expect(reportData(recorder)['stop_reason'], 'background');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(recorder.isRecording, isFalse);
  });

  testWidgets(
    'export finishes recording and covers stale or failed database logs',
    (tester) async {
      final recorder = PerformanceRecorder(
        saveReport: (_) => throw StateError('database unavailable'),
      );
      addTearDown(recorder.dispose);
      recorder.start(readEnvironment: () => environment);
      await tester.pump();
      final report = await recorder.reportForExport('older logs');
      expect(report, contains('ObtainX Performance Recording'));
      expect(reportData(recorder)['stop_reason'], 'export');
      expect(recorder.isRecording, isFalse);
      expect(recorder.isSaving, isFalse);
      expect(recorder.saveFailed, isTrue);
      expect(await recorder.reportForExport('older logs\n$report'), isEmpty);
      await recorder.discard();
      expect(await recorder.reportForExport(''), isEmpty);
    },
  );

  testWidgets(
    'hung persistence is bounded and cannot overwrite the next recording',
    (tester) async {
      final pending = Completer<void>();
      int saves = 0;
      final recorder = PerformanceRecorder(
        saveReport: (_) {
          saves++;
          return saves == 1 ? pending.future : Future<void>.value();
        },
      );
      addTearDown(recorder.dispose);
      recorder.start(readEnvironment: () => environment);
      await tester.pump();
      final export = recorder.reportForExport('');
      await tester.pump(const Duration(seconds: 5));
      expect(await export, contains('Performance Recording'));
      expect(recorder.saveFailed, isTrue);
      expect(recorder.start(readEnvironment: () => environment), isTrue);
      await tester.pump();
      await recorder.stop();
      final latest = recorder.latestReport;
      pending.complete();
      await tester.pump();
      expect(recorder.latestReport, latest);
      expect(recorder.saveFailed, isFalse);
    },
  );

  testWidgets('operation spans never leak across sessions', (tester) async {
    final recorder = PerformanceRecorder(saveReport: (_) async {});
    addTearDown(recorder.dispose);
    recorder.start(readEnvironment: () => environment);
    final oldSpan = recorder.startOperation();
    await recorder.stop();
    recorder.start(readEnvironment: () => environment);
    recorder.finishOperation(PerformanceOperation.appsFilterSort, oldSpan);
    final span = recorder.startOperation();
    recorder.finishOperation(PerformanceOperation.appsPageBuild, span);
    await recorder.stop();
    final operations = reportData(recorder)['operations'];
    expect(operations['appsFilterSort'], isNull);
    expect(operations['appsPageBuild']['samples'], 1);
  });

  testWidgets(
    'dialog control starts, survives reopening, stops, and offers another recording',
    (tester) async {
      final recorder = PerformanceRecorder(saveReport: (_) async {});
      addTearDown(recorder.dispose);
      int starts = 0;
      Widget control() {
        return MaterialApp(
          home: Scaffold(
            body: PerformanceRecordingControl(
              recorder: recorder,
              readEnvironment: () => environment,
              onStarted: () {
                starts++;
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(control());
      await tester.tap(find.text('Record performance'));
      await tester.pump();
      expect(starts, 1);
      expect(find.text('Stop recording'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(recorder.isRecording, isTrue);
      await tester.pumpWidget(control());
      await tester.tap(find.text('Stop recording'));
      await tester.pumpAndSettle();
      expect(find.text('Record performance'), findsOneWidget);
      expect(
        find.text(
          'Performance recording finished. Share logs to include the results.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
