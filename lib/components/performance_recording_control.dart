import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/services/performance_recorder.dart';

class PerformanceRecordingControl extends StatelessWidget {
  const PerformanceRecordingControl({
    super.key,
    required this.readEnvironment,
    required this.onStarted,
    this.recorder,
  });

  final PerformanceEnvironment Function() readEnvironment;
  final VoidCallback onStarted;
  final PerformanceRecorder? recorder;

  @override
  Widget build(BuildContext context) {
    final recording = recorder ?? PerformanceRecorder.instance;
    return ListenableBuilder(
      listenable: recording,
      builder: (context, _) {
        final String? statusKey = recording.isRecording
            ? 'performanceRecordingActive'
            : recording.isSaving
            ? 'pleaseWait'
            : recording.saveFailed
            ? 'performanceRecordingSaveFailed'
            : recording.latestReport != null
            ? 'performanceRecordingSaved'
            // Idle guidance is the call site's help tooltip, not a paragraph
            // above the button, so the control shows text only once there is a
            // recording state worth reporting.
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (statusKey != null) ...[
              Text(tr(statusKey), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
            ],
            FilledButton.tonalIcon(
              onPressed: recording.isSaving
                  ? null
                  : () async {
                      if (recording.isRecording) {
                        await recording.stop();
                      } else if (recording.start(
                        readEnvironment: readEnvironment,
                      )) {
                        onStarted();
                      }
                    },
              icon: Icon(
                recording.isRecording
                    ? Icons.stop_circle_outlined
                    : Icons.speed_rounded,
              ),
              label: Text(
                tr(
                  recording.isRecording
                      ? 'stopPerformanceRecording'
                      : 'recordPerformance',
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
