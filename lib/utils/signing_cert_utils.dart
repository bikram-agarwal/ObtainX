import 'package:android_package_manager/android_package_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';

final AndroidPackageManager _packageManager = AndroidPackageManager();
final PackageInfoFlags _signingInfoFlags = PackageInfoFlags({
  PMFlag.getSigningCertificates,
  PMFlag.getSignatures,
});

/// ObtainX's own device-apps channel (MainActivity), for the Android 8/8.1
/// signer read below.
const MethodChannel _deviceAppsChannel = MethodChannel(
  'dev.imranr.obtainium/device_apps',
);

/// Android 9, the first version with `PackageInfo.signingInfo`.
const int _androidApiLevelP = 28;

Future<int>? _androidSdkInt;

Future<int> _deviceSdkInt() => _androidSdkInt ??= DeviceInfoPlugin().androidInfo
    .then((AndroidDeviceInfo info) => info.version.sdkInt)
    .catchError((Object _) => _androidApiLevelP);

/// Formats a signing certificate (DER bytes) as an uppercase, colon-separated
/// SHA-256 digest, the format shown in the app UI and accepted in settings.
String formatCertHash(Uint8List cert) {
  final digest = sha256.convert(cert);
  return digest.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// Signer certificate hashes from [signingInfo]. Multi-signer apps expose the
/// current signers through [SigningInfo.apkContentSigners]; single-signer apps
/// expose the certificate history, which includes any rotation lineage.
Set<String> certHashesFromSigningInfo(SigningInfo? signingInfo) {
  if (signingInfo == null) return {};
  final certs = signingInfo.hasMultipleSigners
      ? signingInfo.apkContentSigners
      : signingInfo.signingCertificateHistory;
  return certs?.map(formatCertHash).toSet() ?? {};
}

/// Signer certificate hashes of the APK at [apkPath], or an empty set when the
/// signing info is unavailable (unreadable archive).
///
/// ObtainX addition (v1.7.4 sync D16 b; keep it when taking upstream's file):
/// below Android 9 the plugin has no `signingInfo` to return, so a pinned
/// expected certificate would block every install there. MainActivity reads
/// the archive's signers with `GET_SIGNATURES` instead.
Future<Set<String>> apkSigningCertHashes(String apkPath) async {
  if (await _deviceSdkInt() < _androidApiLevelP) {
    return _legacyApkSigningCertHashes(apkPath);
  }
  final info = await _packageManager.getPackageArchiveInfo(
    archiveFilePath: apkPath,
    flags: _signingInfoFlags,
  );
  return certHashesFromSigningInfo(info?.signingInfo);
}

Future<Set<String>> _legacyApkSigningCertHashes(String apkPath) async {
  try {
    final List<Uint8List>? signatures = await _deviceAppsChannel
        .invokeListMethod<Uint8List>('getApkArchiveSignatures', {
          'archiveFilePath': apkPath,
        });
    return signatures?.map(formatCertHash).toSet() ?? {};
  } on PlatformException {
    return {};
  } on MissingPluginException {
    return {};
  }
}

/// Union of the signer certificate hashes across [apkPaths] (base APK plus
/// splits); every split of a valid bundle is signed with the same certificate.
Future<Set<String>> apkFilesSigningCertHashes(Iterable<String> apkPaths) async {
  final result = <String>{};
  for (final path in apkPaths) {
    result.addAll(await apkSigningCertHashes(path));
  }
  return result;
}

final RegExp _certHashHex = RegExp(r'^[0-9a-fA-F]{64}$');

/// Normalizes a certificate hash to the uppercase colon-separated form.
/// Accepts hashes with or without separators; unrecognizable input is returned
/// uppercased so it simply won't match anything.
String normalizeCertHash(String raw) {
  final hex = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (!_certHashHex.hasMatch(hex)) return raw.trim().toUpperCase();
  return [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)]
      .join(':')
      .toUpperCase();
}

/// Parses the `allowedSigningCertHashes` setting (hashes separated by newlines,
/// whitespace, commas or semicolons) into a set of normalized hashes.
Set<String> parseAllowedSigningCertHashes(String? raw) => (raw ?? '')
    .split(RegExp(r'[\s,;]+'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .map(normalizeCertHash)
    .toSet();

/// Whether [value] consists only of valid SHA-256 hashes (one or more per
/// line, separated by whitespace/comma/semicolon) or is empty.
bool isValidCertHashList(String? value) {
  if (value == null || value.trim().isEmpty) return true;
  return value
      .split(RegExp(r'[\s,;]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .every((e) {
        return _certHashHex.hasMatch(e.replaceAll(RegExp(r'[^0-9a-fA-F]'), ''));
      });
}
