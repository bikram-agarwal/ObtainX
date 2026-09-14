import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:obtainium/providers/logs_provider.dart';

enum PerformanceOperation { appsPageBuild, appsFilterSort }

class PerformanceEnvironment {
  const PerformanceEnvironment({
    required this.refreshRate,
    required this.blur,
    required this.reducedEffects,
    required this.gradients,
    required this.appCount,
  });

  final double refreshRate;
  final bool blur;
  final bool reducedEffects;
  final bool gradients;
  final int appCount;

  Map<String, Object?> toJson() => {
    'reported_refresh_hz': refreshRate.isFinite && refreshRate > 0
        ? refreshRate
        : null,
    'progressive_blur': blur,
    'reduced_effects': reducedEffects,
    'gradients': gradients,
    'tracked_apps': appCount,
  };
}

class PerformanceSpan {
  PerformanceSpan._(this.session) : watch = Stopwatch()..start();

  final int session;
  final Stopwatch watch;
}

/// Opt-in, foreground-only diagnostics. No listener, timer, per-frame logging,
/// or operation stopwatch runs while idle. Storage is bounded even if the UI
/// isolate stalls and the automatic stop timer is delayed.
class PerformanceRecorder extends ChangeNotifier with WidgetsBindingObserver {
  PerformanceRecorder({Future<void> Function(String)? saveReport})
    : _saveReport = saveReport ?? _writeLog;

  static final instance = PerformanceRecorder();
  static const duration = Duration(seconds: 60);
  static const _saveTimeout = Duration(seconds: 5);
  final Future<void> Function(String) _saveReport;
  final Stopwatch _elapsed = Stopwatch();
  final Map<int, _PerformanceWindow> _windows = {};
  final Map<PerformanceOperation, _TimingDistribution> _operations = {};
  PerformanceEnvironment Function()? _readEnvironment;
  Timer? _timer;
  int? _armingFrame;
  int? _firstFrameMicros;
  int _session = 0;
  bool _recording = false;
  bool _disposed = false;
  Future<void>? _saving;
  DateTime? _startedAt;
  Map<String, Object?>? _startEnvironment;
  String? latestReport;
  bool saveFailed = false;

  bool get isRecording => _recording;
  bool get isSaving => _saving != null;

  static Future<void> _writeLog(String report) async {
    await LogsProvider().add(report);
  }

  bool start({required PerformanceEnvironment Function() readEnvironment}) {
    if (_disposed || _recording || isSaving) return false;
    _session++;
    _windows.clear();
    _operations.clear();
    latestReport = null;
    saveFailed = false;
    _firstFrameMicros = null;
    _readEnvironment = readEnvironment;
    _startEnvironment = readEnvironment().toJson();
    _startedAt = DateTime.now();
    _elapsed
      ..reset()
      ..start();
    _recording = true;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    binding.addTimingsCallback(_onTimings);
    // Engine timings arrive in batches. Anchor to the next frame so timings
    // buffered before the user started cannot contaminate this recording.
    _armingFrame = binding.scheduleFrameCallback((_) {
      _armingFrame = null;
      _firstFrameMicros = binding.currentSystemFrameTimeStamp.inMicroseconds;
    });
    _timer = Timer(duration, () => unawaited(stop(reason: 'time_limit')));
    notifyListeners();
    return true;
  }

  PerformanceSpan? startOperation() {
    if (!_recording) return null;
    return PerformanceSpan._(_session);
  }

  void finishOperation(PerformanceOperation operation, PerformanceSpan? span) {
    if (span == null) return;
    span.watch.stop();
    if (!_recording || span.session != _session) return;
    (_operations[operation] ??= _TimingDistribution()).add(
      span.watch.elapsedMicroseconds,
    );
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_recording || _firstFrameMicros == null) return;
    if (_elapsed.elapsed >= duration) {
      unawaited(stop(reason: 'time_limit'));
      return;
    }
    // At most twelve five-second windows. Environment is observed on batch
    // delivery, not claimed to be the exact setting for each historical frame.
    final windowIndex = _elapsed.elapsedMilliseconds ~/ 5000;
    final environment = _readEnvironment!();
    final window = _windows[windowIndex] ??= _PerformanceWindow();
    window.environment = environment;
    for (final timing in timings) {
      if (timing.timestampInMicroseconds(FramePhase.buildStart) <
          _firstFrameMicros!) {
        continue;
      }
      window.add(timing, environment.refreshRate);
    }
  }

  Future<void> stop({String reason = 'manual'}) {
    if (!_recording) return _saving ?? Future<void>.value();
    _recording = false;
    _elapsed.stop();
    _timer?.cancel();
    _timer = null;
    final binding = WidgetsBinding.instance;
    binding.removeTimingsCallback(_onTimings);
    binding.removeObserver(this);
    if (_armingFrame != null) {
      binding.cancelFrameCallbackWithId(_armingFrame!);
      _armingFrame = null;
    }
    final environment = _readEnvironment!();
    _readEnvironment = null;
    final data = {
      'schema': 1,
      'started_at': _startedAt!.toUtc().toIso8601String(),
      'duration_ms': _elapsed.elapsedMilliseconds,
      'stop_reason': reason,
      'build_mode': kReleaseMode
          ? 'release'
          : (kProfileMode ? 'profile' : 'debug'),
      'environment_at_start': _startEnvironment,
      'environment_at_stop': environment.toJson(),
      'frame_windows': [
        for (final entry in _windows.entries)
          {'batch_window_start_ms': entry.key * 5000, ...entry.value.toJson()},
      ],
      'operations': {
        for (final entry in _operations.entries)
          entry.key.name: entry.value.toJson(),
      },
      'notes': [
        'Only rendered frames are counted. Idle time is not low FPS.',
        'Stage-over-budget counts are not a measured display FPS or dropped-frame count.',
        'Budgets use the reported display refresh rate at batch delivery; adaptive refresh may differ.',
        'Timings are batched by Flutter. The final undelivered batch may be absent (about one second in release).',
        'Environment is sampled at batch delivery. Windows may include frames from just before a setting change.',
        'p95 is an upper bound rounded to 1 ms; null means above 1000 ms or no samples.',
        'appsPageBuild measures the page build method; frame UI timing also includes descendant builds and layout. appsFilterSort is a subset of appsPageBuild.',
      ],
    };
    latestReport =
        '=== ObtainX Performance Recording ===\n'
        '${const JsonEncoder.withIndent('  ').convert(data)}\n'
        '=== End Performance Recording ===\n';
    // Keep the report in memory as an export fallback if persistence fails or
    // hangs. Never hold the recording state open on SQLite I/O.
    _saving = _persist(latestReport!);
    if (!_disposed) notifyListeners();
    return _saving!;
  }

  Future<void> _persist(String report) async {
    try {
      await Future<void>.sync(() => _saveReport(report)).timeout(_saveTimeout);
    } catch (_) {
      saveFailed = true;
    } finally {
      _saving = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Include the current report even if the log viewer loaded before the
  /// recording ended, or its date/row limit excludes the saved log entry.
  Future<String> reportForExport(String visibleLogs) async {
    await stop(reason: 'export');
    final report = latestReport;
    return report != null && !visibleLogs.contains(report) ? report : '';
  }

  Future<void> discard() async {
    await stop(reason: 'discard');
    latestReport = null;
    saveFailed = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(stop(reason: 'background'));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop(reason: 'disposed'));
    super.dispose();
  }
}

class _TimingDistribution {
  // Fixed memory; long stalls go into the final overflow bucket.
  final List<int> _buckets = List.filled(1002, 0);
  int count = 0;
  int _totalMicros = 0;
  int _maxMicros = 0;

  void add(int microseconds) {
    count++;
    _totalMicros += microseconds;
    if (microseconds > _maxMicros) _maxMicros = microseconds;
    _buckets[((microseconds + 999) ~/ 1000).clamp(0, 1001)]++;
  }

  Map<String, Object?> toJson() {
    int cumulative = 0;
    int? percentile;
    if (count > 0) {
      for (int bucket = 0; bucket <= 1000; bucket++) {
        cumulative += _buckets[bucket];
        if (cumulative >= (count * 0.95).ceil()) {
          percentile = bucket;
          break;
        }
      }
    }
    return {
      'samples': count,
      'mean_ms': count == 0 ? null : _totalMicros / count / 1000,
      'p95_ms_upper_bound': percentile,
      'max_ms': count == 0 ? null : _maxMicros / 1000,
    };
  }
}

class _PerformanceWindow {
  final _ui = _TimingDistribution();
  final _raster = _TimingDistribution();
  final _latency = _TimingDistribution();
  final _vsyncDelay = _TimingDistribution();
  PerformanceEnvironment? environment;
  int _budgetedFrames = 0;
  int _slowUi = 0;
  int _slowRaster = 0;
  int _slowEither = 0;
  int _slowLatency = 0;

  void add(FrameTiming timing, double refreshRate) {
    final ui = timing.buildDuration.inMicroseconds;
    final raster = timing.rasterDuration.inMicroseconds;
    final latency = timing.totalSpan.inMicroseconds;
    _ui.add(ui);
    _raster.add(raster);
    _latency.add(latency);
    _vsyncDelay.add(timing.vsyncOverhead.inMicroseconds);
    if (!refreshRate.isFinite || refreshRate <= 0) return;
    final budget = 1000000 / refreshRate;
    _budgetedFrames++;
    if (ui > budget) _slowUi++;
    if (raster > budget) _slowRaster++;
    if (ui > budget || raster > budget) _slowEither++;
    if (latency > budget) _slowLatency++;
  }

  Map<String, Object?> toJson() => {
    'environment_at_batch_delivery': environment?.toJson(),
    'ui': _ui.toJson(),
    'raster': _raster.toJson(),
    'total_latency': _latency.toJson(),
    'vsync_delay': _vsyncDelay.toJson(),
    'frames_with_known_budget': _budgetedFrames,
    'ui_over_budget': _slowUi,
    'raster_over_budget': _slowRaster,
    'either_stage_over_budget': _slowEither,
    'latency_over_budget': _slowLatency,
  };
}
