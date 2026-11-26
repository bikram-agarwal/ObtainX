import 'package:flutter_test/flutter_test.dart';
import 'package:obtainium/installers/root_installer.dart';

// Upstream #3478, adapted for ObtainX (v1.7.5 sync D-07): the user is the
// install script's `$uid` (the Android user ObtainX runs as), not a number.
void main() {
  group('buildRootInstallCommand', () {
    test('builds the standard install command', () {
      expect(
        buildRootInstallCommand(
          installerPackageName: '',
          stagedApks: ['"\$d/obt0.apk"'],
          bypassLowTargetSdkBlock: false,
        ),
        'pm install -r --user "\$uid" "\$d/obt0.apk"',
      );
    });

    test('sets the installer package', () {
      expect(
        buildRootInstallCommand(
          installerPackageName: 'com.example.store',
          stagedApks: ['"\$d/obt0.apk"'],
          bypassLowTargetSdkBlock: false,
        ),
        "pm install -r -i 'com.example.store' --user \"\$uid\" \"\$d/obt0.apk\"",
      );
    });

    test('quotes an installer package for the shell', () {
      expect(
        buildRootInstallCommand(
          installerPackageName: "it's",
          stagedApks: ['"\$d/obt0.apk"'],
          bypassLowTargetSdkBlock: false,
        ),
        "pm install -r -i 'it'\\''s' --user \"\$uid\" \"\$d/obt0.apk\"",
      );
    });

    test('adds the low-target-SDK bypass flag before the APKs', () {
      expect(
        buildRootInstallCommand(
          installerPackageName: '',
          stagedApks: ['"\$d/obt0.apk"', '"\$d/obt1.apk"'],
          bypassLowTargetSdkBlock: true,
        ),
        'pm install -r --user "\$uid" --bypass-low-target-sdk-block '
        '"\$d/obt0.apk" "\$d/obt1.apk"',
      );
    });
  });
}
