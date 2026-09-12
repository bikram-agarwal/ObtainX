import 'dart:async';
import 'dart:collection';

import 'package:device_info_plus/device_info_plus.dart';

/// Shared across store discovery jobs, including jobs from different pages.
class StoreLookupQueue {
  StoreLookupQueue(this.concurrency) : assert(concurrency > 0);

  final int concurrency;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();
  static Future<StoreLookupQueue>? _deviceQueue;

  static Future<StoreLookupQueue> forDevice() {
    return _deviceQueue ??= _createDeviceQueue();
  }

  static Future<StoreLookupQueue> _createDeviceQueue() async {
    try {
      final device = await DeviceInfoPlugin().androidInfo;
      if (device.isLowRamDevice ||
          (device.physicalRamSize > 0 && device.physicalRamSize <= 3072)) {
        return StoreLookupQueue(2);
      }
    } catch (_) {
      return StoreLookupQueue(2);
    }
    return StoreLookupQueue(4);
  }

  Future<void> run(
    Future<void> Function() action, {
    bool Function()? shouldAbort,
  }) async {
    if (shouldAbort?.call() == true) return;
    if (_active >= concurrency) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      if (shouldAbort?.call() != true) await action();
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}
