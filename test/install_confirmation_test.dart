import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/providers/apps_provider_install.dart';

// Adapted from upstream v1.7.4: ObtainX's stock installer key is 'system',
// never 'stock' (guide §3.10), and Dhizuku is its own installer mode.
void main() {
  group('shouldPollForInstallConfirmation', () {
    test('races stock, Shizuku, Dhizuku and root installs with polling', () {
      expect(
        shouldPollForInstallConfirmation('system', needsBGWorkaround: false),
        isTrue,
      );
      expect(
        shouldPollForInstallConfirmation('shizuku', needsBGWorkaround: false),
        isTrue,
        reason: 'a lost Shizuku result callback must not stall the chain',
      );
      expect(
        shouldPollForInstallConfirmation('dhizuku', needsBGWorkaround: false),
        isTrue,
        reason: 'Dhizuku goes through the same plugin as Shizuku',
      );
      expect(
        shouldPollForInstallConfirmation('root', needsBGWorkaround: false),
        isTrue,
      );
    });

    test(
      'does not poll for the background workaround or external installer',
      () {
        expect(
          shouldPollForInstallConfirmation('system', needsBGWorkaround: true),
          isFalse,
          reason: 'the background stock result never arrives by design (#896)',
        );
        expect(
          shouldPollForInstallConfirmation(
            'external',
            needsBGWorkaround: false,
          ),
          isFalse,
          reason: 'the external installer is confirmed by the package watcher',
        );
      },
    );
  });
}
