import 'package:material_ui/material_ui.dart';
import 'package:obtainium/app_sources/samsunggalaxystore.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';

/// The installer of record to claim for [app]'s install, or '' for none: the
/// Samsung Galaxy Store for a Samsung app that opts in, otherwise Google Play
/// when the global or per-app "pretend to be Google Play" switch is on
/// (upstream a652ee08, D14).
///
/// This is the one `installerPackageName` install option every privileged
/// installer reads (Shizuku and Root; Dhizuku can't set a source and ignores
/// it), so the two can't drift apart again (INST-H2).
String installerPackageNameForApp(App app, {required bool googlePlayDefault}) {
  var isGalaxyStore = false;
  if (app.settings.getBool('shizukuPretendToBeGalaxyStore')) {
    try {
      // Only a type test, so the cached template is enough: no per-install
      // source instance (guide §3.2).
      isGalaxyStore = SourceProvider().getSourceTemplate(
        app.url,
        overrideSource: app.overrideSource,
      ) is SamsungGalaxyStore;
    } catch (_) {
      isGalaxyStore = false;
    }
  }
  if (isGalaxyStore) {
    return 'com.sec.android.app.samsungapps';
  }
  return googlePlayDefault ||
          app.settings.getBool('shizukuPretendToBeGooglePlay')
      ? 'com.android.vending'
      : '';
}

/// Android PackageInstaller status codes. 0 = success (public: the fork's tests
/// use it); 3 = STATUS_FAILURE_ABORTED, i.e. the user cancelled.
const int installSuccessCode = 0;
const int _installAbortedCode = 3;

enum InstallOutcome { success, cancelled, handedOff, error }

/// Unified result of an install operation, replacing the previous
/// "nullable int code" pattern used by the platform install APIs.
class InstallResult {
  final InstallOutcome outcome;
  final int? errorCode;

  const InstallResult({required this.outcome, this.errorCode});

  factory InstallResult.success() =>
      const InstallResult(outcome: InstallOutcome.success);

  factory InstallResult.cancelled() =>
      const InstallResult(outcome: InstallOutcome.cancelled);

  /// The APK reached an installer that reports no result of its own, and no
  /// confirmation had arrived by the time the handoff returned. Distinct from
  /// [cancelled], which discards the pending install: the install may still be
  /// running (a backgrounded third-party installer), so the receipt must
  /// survive until the system package broadcast settles it either way.
  factory InstallResult.handedOff() =>
      const InstallResult(outcome: InstallOutcome.handedOff);

  factory InstallResult.error(int code) =>
      InstallResult(outcome: InstallOutcome.error, errorCode: code);

  /// Maps a raw platform install status code to an [InstallResult].
  /// [installSuccessCode] is a completed install. A null code and
  /// [_installAbortedCode] (STATUS_FAILURE_ABORTED: the user backed out of the
  /// prompt) are cancelled, so the pending-install receipt is cleared (upstream
  /// 0c90b12e). Any other value is an error carrying the original code.
  factory InstallResult.fromPlatformCode(int? code) {
    if (code == null) {
      return InstallResult.cancelled();
    }
    if (code == _installAbortedCode) {
      return InstallResult.cancelled();
    }
    if (code == installSuccessCode) {
      return InstallResult.success();
    }
    return InstallResult.error(code);
  }

  bool get isSuccess => outcome == InstallOutcome.success;
  bool get isCancelled => outcome == InstallOutcome.cancelled;
  bool get isHandedOff => outcome == InstallOutcome.handedOff;
  bool get isError => outcome == InstallOutcome.error;
}

/// Strategy that performs the platform-specific parts of an app installation.
///
/// Implementations are intentionally thin: the surrounding harness in
/// [AppsProvider] handles download validation, downgrade checks, the background
/// completion workaround, persistence, file cleanup, and notifications. An
/// installer only decides silent-install eligibility, manages its own
/// permissions, and performs the terminal platform call.
abstract class Installer {
  final SettingsProvider settingsProvider;

  Installer(this.settingsProvider);

  /// Unique key identifying this installer mode: 'system' (the stock
  /// installer), 'shizuku', 'dhizuku', 'external' or 'root'. Never 'stock'.
  String get modeKey;

  /// Whether directory/bundle installs should hand off the original container
  /// file (XAPK/ZIP/tarball) rather than extracted split APKs.
  bool get wantsContainerHandoff => false;

  /// The installer-specific portion of the silent-install decision. Shared
  /// pre-checks (background updates enabled, exemptions, multi-URL, target SDK)
  /// are handled by the caller before this is invoked.
  Future<bool> canInstallSilently(App app);

  /// Whether the installer currently has the privileges needed to install
  /// without prompting the user. Does not prompt.
  Future<bool> checkPermission();

  /// Ensures the installer has the privileges needed to install, prompting the
  /// user if necessary. Throws an [ObtainiumError] if permission is denied.
  Future<void> ensurePermission({ThemeData? toastTheme});

  /// Installs one or more APK file paths (a base APK plus optional splits).
  /// [installOptions] carries installer-specific key-value flags:
  /// `installerPackageName` (see [installerPackageNameForApp]; Shizuku and
  /// Root) and `requestUpdateOwnership` (a first install; Shizuku and Dhizuku).
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  });

  /// Called when the provider's install race (#3369, D15) has settled an
  /// install's outcome by polling the package while this installer's own
  /// [installApk] call is still pending. Installers whose platform call holds
  /// a shared resource release it here; the default holds nothing.
  Future<void> releaseStalledInstall() async {}
}
