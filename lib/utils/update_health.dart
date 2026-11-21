// Update health (upstream #1753): flags apps whose configuration may be
// keeping updates from arriving (a stale release, a version that never
// changes, repeated failed checks, an archived project, newer releases the
// filters skip).
//
// Adopted fork-shaped in the v1.7.4 sync (D8). It is separate from Needs
// attention, which covers blocking states only; update health is advisory.
// Differences from upstream:
// - no `App.disabled`: ObtainX maps Obtainium's disabled apps to on-demand
//   only (D6), so on-demand-only apps are left out, as upstream leaves out
//   disabled ones (they aren't checked on a schedule, so "not updated in N
//   days" would flag them for no reason);
// - failed checks are counted only for persistent failures, judged on the
//   wrapped `ObtainiumError.cause` too (upstream counts a wrapped network
//   error as a failure, the main source of false positives);
// - per-app option labels are localized here, because the fork's form
//   renderer prints option labels as given.

import 'package:easy_localization/easy_localization.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/models/app.dart';
import 'package:obtainium/providers/settings_provider.dart';

enum UpdateHealthReason {
  staleRelease,
  staleVersion,
  failedChecks,
  archived,
  filteredReleases,
}

class UpdateHealthConfig {
  final int? staleReleaseDays;
  final int? staleVersionDays;
  final int? failedChecksCount;
  final bool archivedEnabled;
  final int? filteredReleasesCount;

  const UpdateHealthConfig({
    this.staleReleaseDays,
    this.staleVersionDays,
    this.failedChecksCount,
    this.archivedEnabled = false,
    this.filteredReleasesCount,
  });
}

const List<int> updateHealthDayOptions = [0, 30, 60, 90, 180, 365, 730];
const List<int> updateHealthFailedChecksOptions = [
  0,
  1,
  2,
  3,
  5,
  8,
  10,
  15,
  20,
];
const List<int> updateHealthFilteredReleasesOptions = [
  0,
  1,
  2,
  3,
  5,
  8,
  10,
  15,
  20,
];

/// Section-header key of the per-app "Update health" card on the
/// additional-options page; it doubles as that card's scroll target.
const String updateHealthSectionKey = '__formSectionUpdateHealth';

int? _resolveThreshold(Object? override, int globalValue) {
  if (override is String && override.isNotEmpty) {
    if (override == 'off') return null;
    final parsed = int.tryParse(override);
    if (parsed != null) return parsed < 1 ? null : parsed;
  }
  return globalValue < 1 ? null : globalValue;
}

bool _resolveArchived(Object? override, bool globalEnabled) {
  if (override == 'off') return false;
  if (override == 'on') return true;
  return globalEnabled;
}

UpdateHealthConfig resolveUpdateHealthConfig(
  Map<String, dynamic> additionalSettings,
  SettingsProvider settingsProvider,
) {
  return UpdateHealthConfig(
    staleReleaseDays: _resolveThreshold(
      additionalSettings['updateHealthStaleRelease'],
      settingsProvider.updateHealthStaleReleaseDays,
    ),
    staleVersionDays: _resolveThreshold(
      additionalSettings['updateHealthStaleVersion'],
      settingsProvider.updateHealthStaleVersionDays,
    ),
    failedChecksCount: _resolveThreshold(
      additionalSettings['updateHealthFailedChecks'],
      settingsProvider.updateHealthFailedChecksCount,
    ),
    archivedEnabled: _resolveArchived(
      additionalSettings['updateHealthArchived'],
      settingsProvider.updateHealthArchivedEnabled,
    ),
    filteredReleasesCount: _resolveThreshold(
      additionalSettings['updateHealthFilteredReleases'],
      settingsProvider.updateHealthFilteredReleasesCount,
    ),
  );
}

/// Whether the user ignored this app's update health, for good or for its
/// current latest version.
bool isUpdateHealthIgnored(App app) =>
    !app.updateHealthEnabled ||
    (app.updateHealthDismissedVersion != null &&
        app.updateHealthDismissedVersion == app.latestVersion);

List<UpdateHealthReason> evaluateUpdateHealthReasons(
  App app,
  UpdateHealthConfig config, {
  DateTime? now,
}) {
  final currentTime = now ?? DateTime.now();
  final reasons = <UpdateHealthReason>[];
  final staleReleaseDays = config.staleReleaseDays;
  final releaseDate = app.releaseDate;
  if (staleReleaseDays != null &&
      releaseDate != null &&
      currentTime.difference(releaseDate).inDays >= staleReleaseDays) {
    reasons.add(UpdateHealthReason.staleRelease);
  }
  final staleVersionDays = config.staleVersionDays;
  final versionChangedAt = app.latestVersionChangedAt;
  if (staleVersionDays != null &&
      versionChangedAt != null &&
      currentTime.difference(versionChangedAt).inDays >= staleVersionDays) {
    reasons.add(UpdateHealthReason.staleVersion);
  }
  final failedChecksCount = config.failedChecksCount;
  if (failedChecksCount != null &&
      app.consecutiveFailedChecks >= failedChecksCount) {
    reasons.add(UpdateHealthReason.failedChecks);
  }
  if (config.archivedEnabled && app.isArchived == true) {
    reasons.add(UpdateHealthReason.archived);
  }
  final filteredReleasesCount = config.filteredReleasesCount;
  final filteredOut = app.newerReleasesFilteredOut;
  if (filteredReleasesCount != null &&
      filteredOut != null &&
      filteredOut >= filteredReleasesCount) {
    reasons.add(UpdateHealthReason.filteredReleases);
  }
  return reasons;
}

bool hasUpdateHealthIssues(App app, SettingsProvider settingsProvider) {
  if (app.hasPendingRepoRename ||
      app.settings.getBool('onDemandOnly') ||
      isUpdateHealthIgnored(app)) {
    return false;
  }
  return evaluateUpdateHealthReasons(
    app,
    resolveUpdateHealthConfig(app.additionalSettings, settingsProvider),
  ).isNotEmpty;
}

String updateHealthReasonLabel(
  UpdateHealthReason reason,
  App app,
  UpdateHealthConfig config,
) {
  switch (reason) {
    case UpdateHealthReason.staleRelease:
      return tr(
        'updateHealthReasonStaleRelease',
        args: ['${config.staleReleaseDays}'],
      );
    case UpdateHealthReason.staleVersion:
      return tr(
        'updateHealthReasonStaleVersion',
        args: ['${config.staleVersionDays}'],
      );
    case UpdateHealthReason.failedChecks:
      return plural(
        'updateHealthReasonFailedChecks',
        app.consecutiveFailedChecks,
      );
    case UpdateHealthReason.archived:
      return tr('updateHealthReasonArchived');
    case UpdateHealthReason.filteredReleases:
      return plural(
        'updateHealthReasonFilteredReleases',
        app.newerReleasesFilteredOut ?? 0,
      );
  }
}

/// Whether a failed check counts towards the "failed checks" heuristic: only
/// failures a retry won't fix. Network problems, timeouts, rate limits,
/// server errors and pending repo renames don't count, including when a
/// source wrapped the network exception in an [ObtainiumError] (its
/// `cause`). Mirrors `checkFailureIsPersistent` in apps_provider_updates,
/// except that a source's "nothing matched" answer does count here: it is
/// exactly the kind of configuration problem update health is for.
bool shouldCountFailedCheck(Object error) {
  final Object? cause = error is ObtainiumError ? error.cause : null;
  if (cause != null && !shouldCountFailedCheck(cause)) return false;
  if (isTransientNetworkError(error) ||
      error is RateLimitError ||
      error is RepositoryRenamedError) {
    return false;
  }
  if (error is ObtainiumError && error.code == 'HTTP_ERROR') {
    final Object? statusCode = error.data['statusCode'];
    return !(statusCode is int &&
        (statusCode >= 500 || statusCode == 408 || statusCode == 429));
  }
  return true;
}

String updateHealthDaysLabel(int days) =>
    days < 1 ? tr('disabled') : plural('day', days);
String updateHealthFailedChecksLabel(int count) =>
    count < 1 ? tr('disabled') : plural('checks', count);
String updateHealthFilteredReleasesLabel(int count) =>
    count < 1 ? tr('disabled') : plural('releases', count);

// No '' ("use global default") stop: the sliders' globalValue puts the
// thumb on the global value's stop instead.
List<MapEntry<String, String>> _thresholdSliderOptions(
  List<int> values,
  String Function(int) label,
) {
  return [
    MapEntry('off', tr('disabled')),
    ...values.where((v) => v > 0).map((v) => MapEntry(v.toString(), label(v))),
  ];
}

/// The [_thresholdSliderOptions] key of a global threshold.
String _thresholdOptionKey(int globalValue) =>
    globalValue < 1 ? 'off' : globalValue.toString();

/// The per-app update-health overrides, shown as their own card after the
/// fork's four option cards (D24 + D8). Each falls back to the global value.
List<List<GeneratedFormItem>> updateHealthOverrideFormItems() {
  return [
    [
      GeneratedFormSectionHeader(
        updateHealthSectionKey,
        label: tr('sectionUpdateHealthDetection'),
      ),
    ],
    [
      GeneratedFormSlider(
        'updateHealthStaleRelease',
        _thresholdSliderOptions(updateHealthDayOptions, updateHealthDaysLabel),
        label: tr('updateHealthOverrideStaleRelease'),
        value: '',
        required: false,
        globalValue: (s) => _thresholdOptionKey(s.updateHealthStaleReleaseDays),
      ),
    ],
    [
      GeneratedFormSlider(
        'updateHealthStaleVersion',
        _thresholdSliderOptions(updateHealthDayOptions, updateHealthDaysLabel),
        label: tr('updateHealthOverrideStaleVersion'),
        value: '',
        required: false,
        globalValue: (s) => _thresholdOptionKey(s.updateHealthStaleVersionDays),
      ),
    ],
    [
      GeneratedFormSlider(
        'updateHealthFailedChecks',
        _thresholdSliderOptions(
          updateHealthFailedChecksOptions,
          updateHealthFailedChecksLabel,
        ),
        label: tr('updateHealthOverrideFailedChecks'),
        value: '',
        required: false,
        globalValue: (s) =>
            _thresholdOptionKey(s.updateHealthFailedChecksCount),
      ),
    ],
    [
      GeneratedFormSlider(
        'updateHealthFilteredReleases',
        _thresholdSliderOptions(
          updateHealthFilteredReleasesOptions,
          updateHealthFilteredReleasesLabel,
        ),
        label: tr('updateHealthOverrideFilteredReleases'),
        value: '',
        required: false,
        globalValue: (s) =>
            _thresholdOptionKey(s.updateHealthFilteredReleasesCount),
      ),
    ],
    [
      GeneratedFormDropdown(
        'updateHealthArchived',
        [
          MapEntry('', tr('useGlobalDefault')),
          MapEntry('off', tr('disabled')),
          MapEntry('on', tr('enabled')),
        ],
        label: tr('updateHealthOverrideArchived'),
        value: '',
        required: false,
        globalValue: (s) => s.updateHealthArchivedEnabled ? 'on' : 'off',
      ),
    ],
  ];
}
