/// How an app's stored version relates to what the device reports.
///
/// Part of `lib/version/` — the single home for version semantics. This file has
/// no dependencies on the app model or providers on purpose: it is the bottom of
/// the stack, so `source_provider.dart` (which owns [App]) can import it without
/// a cycle.
library;

/// The parsed form of `additionalSettings['versionDetection']`.
///
/// This is the ONE place the raw setting is interpreted. It used to be re-derived
/// with inline `== 'auto' || == 'standard' || == true || == null` chains in six
/// places (reconciliation, the app page, the additional-options page, the update
/// predicates, add-app), each with slightly different handling of legacy values —
/// read it through `App.versionDetectionMode` instead.
enum VersionDetectionMode {
  /// Compare with the device, and fall back to [pseudo] if the source's version
  /// strings turn out to be unreconcilable with the device's.
  auto('auto'),

  /// Always compare with the device; never auto-disable.
  standard('standard'),

  /// The source's version string is not the device's version — don't compare.
  pseudo('pseudo'),

  /// The source publishes a version *code*; compare against the device's
  /// `versionCode` rather than its `versionName`.
  versionCode('versionCode');

  const VersionDetectionMode(this.key);

  /// The value persisted in `additionalSettings['versionDetection']`.
  final String key;

  /// Parses a stored value, tolerating every legacy encoding that
  /// `appJSONCompatibilityModifiers` migrates away from. That migration is
  /// skipped when `App.fromJson` falls back to unmigrated JSON, so these legacy
  /// forms are still reachable at runtime:
  ///   `true`/null → [auto], `false` → [pseudo], plus the pre-dropdown strings.
  /// Anything unrecognised is treated as [auto]: detection stays on and, being
  /// [auto], converges to [pseudo] on its own if the versions can't be related.
  static VersionDetectionMode fromStored(Object? value) {
    if (value == null || value == true) {
      return auto;
    }
    if (value == false) {
      return pseudo;
    }
    switch (value) {
      case 'auto':
      case 'standardVersionDetection':
        return auto;
      case 'standard':
        return standard;
      case 'pseudo':
      case 'noVersionDetection':
      case 'releaseDateAsVersion':
        return pseudo;
      case 'versionCode':
        return versionCode;
    }
    return auto;
  }
}

/// [VersionDetectionMode] for a raw `additionalSettings` map, for the code paths
/// that edit settings before an `App` exists (the additional-options form).
VersionDetectionMode versionDetectionModeOf(
  Map<String, dynamic> additionalSettings,
) => VersionDetectionMode.fromStored(additionalSettings['versionDetection']);

/// Whether [additionalSettings] compares against the device's `versionCode`.
/// Mirrors `App.usesVersionCodeAsOsVersion` for raw maps.
bool versionCodeAsOsVersionFor(Map<String, dynamic> additionalSettings) =>
    versionDetectionModeOf(additionalSettings) ==
        VersionDetectionMode.versionCode ||
    additionalSettings['useVersionCodeAsOSVersion'] == true;

/// Rewrites `versionDetection` to its canonical [VersionDetectionMode.key] and
/// brings the derived `useVersionCodeAsOSVersion` boolean in line with it. The
/// boolean is still written for backup/downgrade compatibility; nothing should
/// read it directly (see `App.usesVersionCodeAsOsVersion`).
///
/// [promoteLegacyBoolean] lets a stale `useVersionCodeAsOSVersion: true` pull the
/// mode to [VersionDetectionMode.versionCode], which is what you want when
/// reading *stored* settings — either signal means version-code mode. It must
/// stay false once edited form values have been merged in: there the dropdown is
/// authoritative, and promoting the old boolean would make leaving version-code
/// mode impossible.
void normalizeVersionDetectionSettings(
  Map<String, dynamic> additionalSettings, {
  bool promoteLegacyBoolean = false,
}) {
  final VersionDetectionMode mode = promoteLegacyBoolean
      ? (versionCodeAsOsVersionFor(additionalSettings)
            ? VersionDetectionMode.versionCode
            : versionDetectionModeOf(additionalSettings))
      : versionDetectionModeOf(additionalSettings);
  additionalSettings['versionDetection'] = mode.key;
  additionalSettings['useVersionCodeAsOSVersion'] =
      mode == VersionDetectionMode.versionCode;
}
