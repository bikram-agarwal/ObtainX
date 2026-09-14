import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show Factory, Listenable, listEquals, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:obtainium/app_sources/apkmirror.dart';
import 'package:obtainium/app_sources/github.dart';
import 'package:obtainium/components/app_bottom_sheet.dart';
import 'package:obtainium/components/app_page_section_title.dart';
import 'package:obtainium/components/app_smooth_surface.dart';
import 'package:obtainium/components/category_action_chip.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/pages/additional_options_page.dart';
import 'package:obtainium/pages/page_route_slide_up.dart';
import 'package:obtainium/theme/app_dialog_theme.dart';
import 'package:obtainium/theme/app_form_field_styles.dart';
import 'package:obtainium/theme/app_page_icon_colors.dart';
import 'package:obtainium/theme/app_theme_accent.dart';
import 'package:obtainium/widgets/app_toast.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/date_time_format.dart';
import 'package:obtainium/main.dart';
import 'package:obtainium/pages/apps.dart';
import 'package:obtainium/pages/settings.dart';
import 'package:obtainium/providers/apps_provider.dart';
import 'package:obtainium/providers/logs_provider.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:obtainium/store_source_icons.dart';
import 'package:obtainium/services/bulk_import_service.dart';
import 'package:obtainium/services/bulk_scan_cache.dart';
import 'package:obtainium/services/store_icon_resolver.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:provider/provider.dart';
import 'package:markdown/markdown.dart' as md;

enum AppVersionDisplayVerdict {
  notInstalled,
  sameVersion,
  effectivelyEqual,
  newerOnDevice,
  uncertain,
  updateAvailable,
}

/// Version meaning shown by the details stripe, independent of Skip or whether
/// the user has enabled background installation.
AppVersionDisplayVerdict appVersionVerdictForDisplay(App? app) {
  if (app == null || app.installedVersion == null) {
    return AppVersionDisplayVerdict.notInstalled;
  }
  final decision = versionDecisionForApp(app);
  return switch (decision.relation) {
    VersionRelation.unknown ||
    VersionRelation.sourceChanged => AppVersionDisplayVerdict.uncertain,
    VersionRelation.older => AppVersionDisplayVerdict.updateAvailable,
    VersionRelation.newer => AppVersionDisplayVerdict.newerOnDevice,
    VersionRelation.same =>
      normalizeVersionLabel(app.installedVersion!) ==
                  normalizeVersionLabel(app.latestVersion) ||
              decision.reason == 'sameBuildHash'
          ? AppVersionDisplayVerdict.sameVersion
          : AppVersionDisplayVerdict.effectivelyEqual,
  };
}

String versionDecisionTitleKey(VersionDecision decision) {
  return switch (decision.reason) {
    'differentVariants' => 'version_variant_differs',
    'sourceAcknowledged' => 'sameVersion',
    _ =>
      decision.relation == VersionRelation.same
          ? 'effectivelyEqual'
          : 'versionOrderUnclear',
  };
}

String versionDecisionDetailKey(VersionDecision decision) {
  return switch (decision.reason) {
    'differentVariants' => 'version_variant_differs_detail',
    'sourceCommitAncestry' => 'version_commit_ancestry_detail',
    _ => 'versionOrderUnclearSubtitle',
  };
}

@visibleForTesting
bool isInstalledVersionPseudoForDisplay(AppInMemory appInMemory) {
  final App appModel = appInMemory.app;
  final String? displayedInstalledVersion = appModel.installedVersion;
  if (displayedInstalledVersion == null || displayedInstalledVersion.isEmpty) {
    return false;
  }

  if (appModel.additionalSettings['trackOnly'] == true) {
    return appInMemory.installedInfo == null &&
        versionsEffectivelyEqual(
          displayedInstalledVersion,
          appModel.latestVersion,
        );
  }

  // Auto can still carry a source-version alias recorded by an installation or
  // an older reconciliation. Explicit Standard and Version Code cannot:
  // those modes must never present themselves as pseudo regardless of any
  // mismatch in stored, source, or OS-reported versions.
  if (appModel.versionDetectionMode == VersionDetectionMode.standard ||
      appModel.versionDetectionMode == VersionDetectionMode.versionCode) {
    return false;
  }

  if (!versionsEffectivelyEqual(
    displayedInstalledVersion,
    appModel.latestVersion,
  )) {
    return false;
  }

  final installedInfo = appInMemory.installedInfo;
  if (installedInfo == null) {
    return false;
  }
  final String? realInstalledVersion = appModel.usesVersionCodeAsOsVersion
      ? installedInfo.versionCode.toString()
      : installedInfo.versionName;
  if (realInstalledVersion == null || realInstalledVersion.isEmpty) {
    return false;
  }
  return !versionsEffectivelyEqual(
    realInstalledVersion,
    displayedInstalledVersion,
  );
}

/// The real OS-reported installed version (versionName, or versionCode when the
/// app uses [App.usesVersionCodeAsOsVersion]). Null when nothing is installed.
/// Surfaced on the app page only when the displayed version is a pseudo-version,
/// so the user can still see what's actually installed.
String? _realOsInstalledVersion(AppInMemory appInMemory) {
  final installedInfo = appInMemory.installedInfo;
  if (installedInfo == null) return null;
  return appInMemory.app.usesVersionCodeAsOsVersion
      ? installedInfo.versionCode.toString()
      : installedInfo.versionName;
}

/// Optional debug logger — guarded by the consolidated [apkMirrorSizeDebug]
/// flag so it short-circuits in release builds.
void _logApkMirrorSizeDebugFromAppPage(String message) {
  if (!apkMirrorSizeDebug) {
    return;
  }
  unawaited(() async {
    try {
      await LogsProvider(
        runDefaultClear: false,
      ).add('OBTAINX-APK-SIZE-DEBUG AppPage: $message', level: LogLevel.debug);
    } catch (_) {}
  }());
}

class _MeasureSize extends StatefulWidget {
  const _MeasureSize({required this.child, required this.onChange});

  final Widget child;
  final ValueChanged<Size> onChange;

  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  final GlobalKey _measureKey = GlobalKey();
  Size? _lastReportedSize;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportSizeIfChanged();
    });
    return SizedBox(key: _measureKey, child: widget.child);
  }

  void _reportSizeIfChanged() {
    final BuildContext? measuredContext = _measureKey.currentContext;
    if (measuredContext == null) return;
    final Size? currentSize = measuredContext.size;
    if (currentSize == null || currentSize == _lastReportedSize) return;
    _lastReportedSize = currentSize;
    widget.onChange(currentSize);
  }
}

/// True when [trackedUrl]'s host contains [hostFragment].
/// Used to suppress an "other sources" chip when the app is already tracked
/// from that store (e.g. pass `'apkmirror.com'` to hide the APKMirror chip).
bool _trackedUrlIsFromHost(String? trackedUrl, String hostFragment) {
  if (trackedUrl == null || trackedUrl.isEmpty) return false;
  final uri = Uri.tryParse(trackedUrl);
  if (uri == null || uri.host.isEmpty) return false;
  return uri.host.toLowerCase().contains(hostFragment);
}

/// Maps a listing URL to the store name whose "other sources" slot it fills,
/// or null when that source has no slot of its own.
///
/// Used to fold a package's *other* tracked listings into the row, so the five
/// scannable slots prefer a sibling's real URL over a guessed one.
String? _storeSlotNameForUrl(String url) {
  const Map<String, String> slotNamesByHostFragment = <String, String>{
    'github.com': 'GitHub',
    'f-droid.org': 'F-Droid',
    'apkpure.': 'APKPure',
    'apkmirror.com': 'APKMirror',
  };
  for (final MapEntry<String, String> slot in slotNamesByHostFragment.entries) {
    if (_trackedUrlIsFromHost(url, slot.key)) return slot.value;
  }
  return null;
}

/// Resolves the URL to display for a store chip, consulting the bulk-scan cache.
/// Returns null when the chip should be hidden.
///
/// Logic:
/// - [alreadyTracked] → hide (user already tracks this store)
/// - [siblingListingUrl] != null → another listing of this same package tracks
///   this store → show its URL (known-good, outranks any scan result)
/// - [storeData] == null → app never scanned → show [fallbackUrl] (unverified)
/// - cache entry == `""` → confirmed absent → hide
/// - cache entry is a non-empty URL → show with that URL
/// - cache entry missing for this store (but app was scanned for others) → hide
///   (we have scan data for this app; don't surface unconfirmed stores)
String? _resolveStoreUrl({
  required Map<String, String>? storeData,
  required String storeName,
  required String? fallbackUrl,
  required bool alreadyTracked,
  String? siblingListingUrl,
}) {
  if (alreadyTracked) return null;
  // A sibling listing's URL is already proven to resolve on this store, so it
  // beats the scan cache - including the "confirmed absent" sentinel, which a
  // store scan writes for any source whose URL it cannot derive from a package
  // ID (GitHub repo URLs, most notably).
  if (siblingListingUrl != null && siblingListingUrl.isNotEmpty) {
    return siblingListingUrl;
  }
  // Key absent means this store was never explicitly checked for this app
  // (either no scan at all, or a different store's check ran first).
  // In both cases show the fallback URL — don't suppress unverified stores.
  if (storeData == null || !storeData.containsKey(storeName)) {
    return fallbackUrl;
  }
  final entry = storeData[storeName]!;
  if (entry.isEmpty) return null; // confirmed absent (empty string sentinel)
  if (storeName == 'APKPure' && !isWellFormedApkPureUrl(entry)) {
    // Known-broken shape from a past bug - don't surface a link we know
    // 404s just because it's sitting in the cache.
    return null;
  }
  return entry; // confirmed present
}

/// Checks whether a package exists on the Play Store by sending a HEAD request
/// without following redirects. Play Store returns 200 for valid listings and
/// 302 (redirect to search) for non-existent packages.
///
/// Returns the Play Store URL if the app is present, or null if absent.
/// Returns null also on network error — caller should not cache the result.
Future<String?> _checkPlayStoreAvailability(String packageId) async {
  final candidates = BulkImportService.getPackageIdCandidates(packageId);
  for (final candidate in candidates) {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse(
        'https://play.google.com/store/apps/details?id=$candidate&hl=en&gl=US',
      );
      final request = await client.headUrl(uri);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      await response.drain<void>();
      client.close();
      if (response.statusCode == 200) {
        return 'https://play.google.com/store/apps/details?id=$candidate';
      }
    } catch (_) {
      if (candidate == packageId) {
        return null; // network error on primary -> skip caching
      }
    }
  }
  return null;
}

void _toastUrl(BuildContext context, String url) {
  showAppToast(
    url,
    context: context,
    icon: Icons.link_rounded,
    type: ToastType.info,
    duration: const Duration(seconds: 4),
  );
}

int _additionalSettingsRebuildToken(Map<String, dynamic> map) {
  if (map.isEmpty) return 0;
  final List<String> keys = map.keys.map((k) => k.toString()).toList()..sort();
  int accumulator = map.length;
  for (final String key in keys) {
    accumulator = Object.hash(accumulator, key, map[key]?.hashCode ?? 0);
  }
  return accumulator;
}

int _apkUrlEntriesRebuildToken(List<MapEntry<String, String>> entries) {
  int accumulator = entries.length;
  for (final MapEntry<String, String> entry in entries) {
    accumulator = Object.hash(accumulator, entry.key, entry.value);
  }
  return accumulator;
}

/// Fingerprint so [AppPage] rebuilds only when this app or global download
/// state changes, not on every [AppsProvider.notifyListeners].
int appPageAppsRebuildToken(AppsProvider provider, String appId) {
  final bool downloadsRunning = provider.areDownloadsRunning();
  final AppInMemory? inMemory = provider.apps[appId];
  if (inMemory == null) {
    return Object.hash(appId, downloadsRunning, 0);
  }
  final App model = inMemory.app;
  final dynamic packageInfo = inMemory.installedInfo;
  return Object.hashAll([
    downloadsRunning,
    appId,
    // Only whether a download is active (start/stop) — NOT the live fraction.
    // The fraction ticks ~4 Hz during a download; including it here forced the
    // entire ~2700-line AppPage build to re-run on every tick. The live bar is
    // now rendered by [_DownloadProgressAction], which subscribes to the
    // fraction itself, so the page only rebuilds when the download begins/ends.
    inMemory.downloadProgress != null,
    identityHashCode(inMemory.icon),
    inMemory.icon?.length,
    model.id,
    model.url,
    model.name,
    model.author,
    model.installedVersion,
    model.latestVersion,
    model.pinned,
    model.lastUpdateCheck,
    model.releaseDate,
    model.changeLog?.hashCode,
    model.preferredApkIndex,
    model.latestIsReproducible,
    model.latestReproducibleStatus,
    model.latestAttestationStatus,
    model.latestMalwareScanStatus,
    model.overrideSource,
    _apkUrlEntriesRebuildToken(model.apkUrls),
    _apkUrlEntriesRebuildToken(model.otherAssetUrls),
    _additionalSettingsRebuildToken(model.additionalSettings),
    model.categories.length,
    Object.hashAll(model.categories),
    // Do not touch [AppInMemory.certificateHashes] here: it runs SHA256 per hash
    // and this selector runs on every [AppsProvider.notifyListeners].
    packageInfo?.versionName,
    packageInfo?.packageName,
    model.iconUrl,
    model.apkSizeBytes,
  ]);
}

int appPageSettingsRebuildToken(SettingsProvider settings) {
  return Object.hash(
    settings.matchAppPageToIconColors,
    settings.blackThemeActive,
    settings.showAppWebpage,
    settings.checkUpdateOnDetailPage,
    settings.highlightTouchTargets,
    settings.cardCornerScale,
    settings.updateButtonsAtTopOfAppPage,
    Object.hashAll(
      settings.categories.entries.map((e) => '${e.key}=${e.value}'),
    ),
  );
}

/// The download/install progress button shown in the app action area.
///
/// Subscribes narrowly to its own app's [AppInMemory.downloadProgress] and
/// [AppInMemory.downloadTotalBytes] via [context.select], so the ~4 Hz progress
/// ticks rebuild only this small widget — not the whole ~2700-line [AppPage]
/// build. The page-level rebuild token ([appPageAppsRebuildToken]) tracks only
/// whether a download is active, so the page rebuilds once on start and once on
/// finish; everything in between is this widget repainting alone.
class _DownloadProgressAction extends StatelessWidget {
  const _DownloadProgressAction({
    required this.appId,
    required this.actionTheme,
    required this.expressiveRadius,
  });

  final String appId;
  final ThemeData actionTheme;
  final double expressiveRadius;

  @override
  Widget build(BuildContext context) {
    final (double? dpOrNull, int? totalBytes, String? scanStatus) = context
        .select<AppsProvider, (double?, int?, String?)>((p) {
          final a = p.apps[appId];
          return (
            a?.downloadProgress,
            a?.downloadTotalBytes,
            a?.app.latestMalwareScanStatus,
          );
        });
    // Race guard: the download may have ended between the page rebuild that
    // mounted this widget and this build. The page will rebuild and remove us.
    if (dpOrNull == null) {
      return const SizedBox.shrink();
    }
    final double dp = dpOrNull;
    final bool isScanning = dp == -2;
    final bool isInstalling = dp == -1;
    final bool isFlaggedState = dp == -3;
    final bool isBusy = isScanning || isInstalling;
    final String bytesLabel = !isBusy && !isFlaggedState && totalBytes != null
        ? ' · ${formatBytesForDisplay((dp / 100 * totalBytes).round())} / ${formatBytesForDisplay(totalBytes)}'
        : '';
    final String label = isScanning
        ? '${tr('scanningWithVirusTotal')}…'
        : isInstalling
        ? '${tr('installing')}…'
        : isFlaggedState
        ? (scanStatus == malwareScanStatusFlagged
              ? tr('flaggedByVirusTotal')
              : tr('virusTotalScanFailed'))
        : tr('downloadingX', args: ['${dp.round()}%$bytesLabel']);
    final Widget progressBar = ClipRRect(
      borderRadius: BorderRadius.circular(expressiveRadius),
      child: SizedBox(
        height: 52,
        child: isFlaggedState
            ? Container(
                color: actionTheme.colorScheme.error,
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: actionTheme.textTheme.labelLarge?.copyWith(
                    color: actionTheme.colorScheme.onError,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : isBusy
            ? Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: actionTheme.colorScheme.surfaceContainerHighest,
                  ),
                  LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                    color: actionTheme.colorScheme.primary,
                  ),
                  Center(
                    child: Text(
                      label,
                      style: actionTheme.textTheme.labelLarge?.copyWith(
                        color: actionTheme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              )
            : LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final double progress = (dp / 100).clamp(0.0, 1.0);
                  final double fillWidth = constraints.maxWidth * progress;

                  Widget buildCenteredLabel(Color textColor) => Center(
                    child: Text(
                      label,
                      style: actionTheme.textTheme.labelLarge?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        color: actionTheme.colorScheme.surfaceContainerHighest,
                      ),
                      buildCenteredLabel(
                        actionTheme.colorScheme.onSurfaceVariant,
                      ),
                      if (fillWidth > 0)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: fillWidth,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: constraints.maxWidth,
                              maxWidth: constraints.maxWidth,
                              minHeight: constraints.maxHeight,
                              maxHeight: constraints.maxHeight,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(
                                    color: actionTheme.colorScheme.primary,
                                  ),
                                  buildCenteredLabel(
                                    actionTheme.colorScheme.onPrimary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        progressBar,
        if (!isBusy)
          Center(
            child: TextButton(
              onPressed: () =>
                  context.read<AppsProvider>().cancelDownload(appId),
              child: Text(tr('cancel')),
            ),
          ),
      ],
    );
  }
}

enum _UnsavedAction { keepEditing, discard, saveAndExit }

class AppPage extends StatefulWidget {
  const AppPage({
    super.key,
    required this.appId,
    this.showOppositeOfPreferredView = false,
    this.openInEditMode = false,
    this.appsListHeroFolderId,
    this.isEmbedded = false,
  });

  final String appId;
  final bool showOppositeOfPreferredView;

  /// Folder id when opened from [AppsPage] with [AppsPage.folderId]; matches list [Hero] tags.
  final String? appsListHeroFolderId;

  /// When true (e.g. swipe-to-edit), enter inline edit mode once the app is loaded.
  final bool openInEditMode;

  final bool isEmbedded;

  @override
  State<AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<AppPage> with WidgetsBindingObserver {
  static const Duration _detailPageAutoCheckCooldown = Duration(minutes: 1);
  // 92 + the 8px gap after the label = a 100px value-column offset, matching
  // the details card's detailRow (label width 100, no gap) so the two cards'
  // value columns line up vertically.
  static const double _versionRowLabelWidth = 92;

  // Android's WebView never renders an attachment response; it hands it to a
  // DownloadListener, which webview_flutter bridges back into
  // onNavigationRequest indistinguishable from a tap. Approving it just
  // re-requests the same URL and nothing is ever downloaded, so URLs ending in
  // one of these go to the system instead of the WebView.
  static const Set<String> _webViewDownloadExtensions = <String>{
    'apk',
    'apks',
    'xapk',
    'apkm',
    'aab',
    'zip',
    '7z',
    'rar',
    'tar',
    'gz',
    'tgz',
    'bz2',
    'xz',
    'zst',
    'exe',
    'msi',
    'dmg',
    'pkg',
    'deb',
    'rpm',
    'appimage',
    'iso',
    'img',
    'jar',
    'bin',
    'sig',
    'asc',
    'pdf',
  };

  WebViewController? _webViewController;
  bool _webViewUrlLoaded = false;
  // True while the in-app webpage is loading, to drive the loading indicator.
  bool _webViewLoading = false;
  // Whether the embedded page has history to go back through. Drives the
  // webpage scaffold's PopScope.canPop, so it must be refreshed after every
  // navigation: predictive back reads canPop *before* the gesture completes,
  // and a stale value animates the wrong outcome.
  bool _webViewCanGoBack = false;
  bool _scheduledDetailPageRefresh = false;
  bool _requestedMissingIconLoad = false;
  // Once true, the lazy APKMirror size resolver has fired for this AppPage
  // mount and won't run again until the user navigates to a different app.
  // Re-resets in [didUpdateWidget] when [widget.appId] changes.
  bool _attemptedApkMirrorSizeResolution = false;
  Color? _lastWebViewSurfaceColorApplied;
  bool updating = false;
  bool _swappingTrackedSource = false;
  // Set while a second listing for this package is being created from another
  // store. Shares the swap's blocking overlay: both are page-wide source
  // actions the user must not interact around, and both end with the page
  // pointing somewhere else.
  bool _trackingAdditionalSource = false;
  App? _swapSecurityAppSnapshot;
  AppSource? _swapSecuritySourceSnapshot;
  List<String>? _swapSecurityCertificateHashesSnapshot;
  bool? _swapSecurityHasMultipleSignersSnapshot;
  int _updateCheckRunToken = 0;
  double _bottomActionBarHeight = 0;
  double _editModeFloatingActionButtonsHeight = 0;
  Timer? _detailPageAutoCheckDelayTimer;
  String? _pendingDetailPageAutoCheckAppId;
  AppsProvider? _pendingDetailPageAutoCheckAppsProvider;
  bool _detailPageAutoCheckRunning = false;

  ColorScheme? _iconDerivedColorScheme;
  String? _iconSchemeCacheKey;
  String? _iconSchemeLoadingForKey;
  String? _iconSchemeFailedCacheKey;

  final SourceProvider _sourceProvider = SourceProvider();

  // Cache for the resolved AppSource. getSource() constructs a fresh source
  // (running tr() in its constructor) on every call, but the result is a pure
  // function of the app's url + overrideSource, which rarely change for an open
  // page — so recompute only when that key changes instead of every build.
  AppSource? _cachedSource;
  String? _cachedSourceKey;

  /// Resolves to this app's store-availability map from [BulkScanCache], or null.
  Future<Map<String, String>?>? _storeAvailabilityCacheFuture;
  String? _signingCertificateLoadKey;
  Future<SigningCertificateInfo?>? _signingCertificateInfoFuture;
  bool? _uses24HourFormat;

  // Cache for the per-page ThemeData derived from the icon color scheme.
  // Recomputed only when the icon scheme key or parent brightness changes.
  ThemeData? _cachedPageTheme;
  String? _cachedPageThemeKey;

  // ── Inline edit mode ────────────────────────────────────────────────────
  bool _editMode = false;
  bool _scheduledOpenInEditMode = false;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _authorController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _packageController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final ScrollController _appPageScrollController = ScrollController();
  final FocusNode _notesEditFocusNode = FocusNode();
  final GlobalKey _notesEditSectionKey = GlobalKey();
  List<String> _editCategories = [];

  String _editBaselineName = '';
  String _editBaselineAuthor = '';
  String _editBaselineNotes = '';
  String _editBaselineUrl = '';
  String _editBaselinePackage = '';
  List<String> _editBaselineCategories = [];
  int _editBaselineIconFingerprint = 0;
  bool _editBaselineHadUserOverride = false;

  Uint8List? _editStagedIconBytes;
  bool _editStagedClearOverride = false;
  Uint8List? _editNonUserIconPreview;

  void _cancelPendingDetailPageAutoCheck() {
    final String? appId = _pendingDetailPageAutoCheckAppId;
    if (appId != null &&
        _detailPageAutoCheckDelayTimer?.isActive == true &&
        !_detailPageAutoCheckRunning) {
      _detailPageAutoCheckDelayTimer?.cancel();
      _pendingDetailPageAutoCheckAppsProvider?.finishDetailPageAutoCheck(appId);
      _pendingDetailPageAutoCheckAppId = null;
      _pendingDetailPageAutoCheckAppsProvider = null;
    }
  }

  Future<void> _runScheduledDetailPageAutoCheck(
    String refreshAppId,
    AppsProvider appsProvider,
  ) async {
    try {
      await _runCheckUpdate(refreshAppId);
    } finally {
      _detailPageAutoCheckRunning = false;
      appsProvider.finishDetailPageAutoCheck(refreshAppId);
      if (_pendingDetailPageAutoCheckAppId == refreshAppId) {
        _pendingDetailPageAutoCheckAppId = null;
        _pendingDetailPageAutoCheckAppsProvider = null;
      }
    }
  }

  void _startScheduledDetailPageAutoCheck(
    String refreshAppId,
    AppsProvider appsProvider,
  ) {
    if (!mounted || widget.appId != refreshAppId) {
      appsProvider.finishDetailPageAutoCheck(refreshAppId);
      _pendingDetailPageAutoCheckAppId = null;
      _pendingDetailPageAutoCheckAppsProvider = null;
      return;
    }
    _detailPageAutoCheckRunning = true;
    unawaited(_runScheduledDetailPageAutoCheck(refreshAppId, appsProvider));
  }

  double get _editModeBottomSpacerHeight {
    final double measuredHeight = math.max(
      _bottomActionBarHeight,
      _editModeFloatingActionButtonsHeight,
    );
    return measuredHeight > 0 ? measuredHeight : 104;
  }

  void _handleBottomActionBarSizeChanged(Size size) {
    if (!mounted) return;
    if (size.height == 0) return;
    if (_bottomActionBarHeight == size.height) return;
    setState(() {
      _bottomActionBarHeight = size.height;
    });
  }

  void _handleEditModeFloatingActionButtonsSizeChanged(Size size) {
    if (!mounted || _editModeFloatingActionButtonsHeight == size.height) return;
    setState(() {
      _editModeFloatingActionButtonsHeight = size.height;
    });
  }

  Future<void> _refreshUses24HourFormat() async {
    final uses24HourFormat = await BulkImportService.uses24HourFormat();
    if (!mounted ||
        uses24HourFormat == null ||
        uses24HourFormat == _uses24HourFormat) {
      return;
    }
    setState(() {
      _uses24HourFormat = uses24HourFormat;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshUses24HourFormat());
    }
  }

  @override
  void didUpdateWidget(covariant AppPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appId != widget.appId) {
      _cancelPendingDetailPageAutoCheck();
      _updateCheckRunToken++;
      updating = false;
      _iconDerivedColorScheme = null;
      _iconSchemeCacheKey = null;
      _iconSchemeLoadingForKey = null;
      _iconSchemeFailedCacheKey = null;
      _cachedPageTheme = null;
      _cachedPageThemeKey = null;
      _webViewUrlLoaded = false;
      _webViewLoading = false;
      _webViewCanGoBack = false;
      _scheduledDetailPageRefresh = false;
      _requestedMissingIconLoad = false;
      _attemptedApkMirrorSizeResolution = false;
      _lastWebViewSurfaceColorApplied = null;
      _scheduledOpenInEditMode = false;
      _swappingTrackedSource = false;
      _trackingAdditionalSource = false;
      _swapSecurityAppSnapshot = null;
      _swapSecuritySourceSnapshot = null;
      _swapSecurityCertificateHashesSnapshot = null;
      _swapSecurityHasMultipleSignersSnapshot = null;
      _clearEditIconStaging();
      _signingCertificateLoadKey = null;
      _signingCertificateInfoFuture = null;
      // Cached per Android package, which is not the listing key once a package
      // is tracked from two stores.
      _storeAvailabilityCacheFuture = BulkScanCache.loadForApp(
        Provider.of<AppsProvider>(
              context,
              listen: false,
            ).apps[widget.appId]?.app.id ??
            widget.appId,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_maybeLazyResolveApkMirrorSize());
      });
    } else if (oldWidget.openInEditMode != widget.openInEditMode) {
      _scheduledOpenInEditMode = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelPendingDetailPageAutoCheck();
    _nameController.dispose();
    _authorController.dispose();
    _urlController.dispose();
    _packageController.dispose();
    _notesController.dispose();
    _appPageScrollController.dispose();
    _notesEditFocusNode.dispose();
    super.dispose();
  }

  // ── Edit mode helpers ───────────────────────────────────────────────────

  int _iconFingerprintForEditBaseline(Uint8List? iconBytes) {
    if (iconBytes == null || iconBytes.isEmpty) return 0;
    return Object.hash(
      iconBytes.length,
      iconBytes[0],
      iconBytes[iconBytes.length ~/ 2],
    );
  }

  void _captureEditBaseline(AppInMemory appData) {
    _editBaselineName = _nameController.text;
    _editBaselineAuthor = _authorController.text;
    _editBaselineUrl = _urlController.text;
    _editBaselinePackage = _packageController.text;
    _editBaselineNotes = _notesController.text;
    _editBaselineCategories = List<String>.from(_editCategories);
    _editBaselineIconFingerprint = _iconFingerprintForEditBaseline(
      appData.icon,
    );
  }

  void _clearEditIconStaging() {
    _editStagedIconBytes = null;
    _editStagedClearOverride = false;
    _editNonUserIconPreview = null;
  }

  bool _editIconStagingIsDirty() {
    if (_editStagedClearOverride && _editBaselineHadUserOverride) return true;
    if (_editStagedIconBytes != null) {
      return _iconFingerprintForEditBaseline(_editStagedIconBytes) !=
          _editBaselineIconFingerprint;
    }
    return false;
  }

  Uint8List? _heroIconMemoryOverrideForEdit(AppInMemory? appInMemory) {
    if (!_editMode) return null;
    if (_editStagedIconBytes != null) return _editStagedIconBytes;
    if (_editStagedClearOverride) return _editNonUserIconPreview;
    return null;
  }

  bool _isEditDirty(AppInMemory? currentApp) {
    if (!_editMode || currentApp == null) return false;
    if (_nameController.text != _editBaselineName) return true;
    if (_authorController.text != _editBaselineAuthor) return true;
    if (_urlController.text != _editBaselineUrl) return true;
    if (_packageController.text != _editBaselinePackage) return true;
    if (_notesController.text != _editBaselineNotes) return true;
    if (!listEquals(_editCategories, _editBaselineCategories)) return true;
    if (_editIconStagingIsDirty()) return true;
    return false;
  }

  void _exitEditWithoutSaving() {
    _clearEditIconStaging();
    setState(() => _editMode = false);
    if (_appPageScrollController.hasClients) {
      _appPageScrollController.jumpTo(0);
    }
  }

  // --- Unsaved changes dialog ---
  Future<_UnsavedAction?> _showUnsavedChangesDialog(
    BuildContext context,
    ThemeData dialogTheme, {
    required bool canSave,
  }) {
    return showDialog<_UnsavedAction>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Theme(
          data: dialogTheme,
          child: AlertDialog(
            title: Text(tr('appEditsUnsavedTitle')),
            contentPadding: appDialogContentPadding,
            content: Text(tr('appEditsUnsavedBody')),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _UnsavedAction.discard),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(dialogContext).colorScheme.error,
                ),
                child: Text(tr('discard')),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _UnsavedAction.keepEditing),
                child: Text(tr('keepEditing')),
              ),
              FilledButton(
                onPressed: canSave
                    ? () => Navigator.pop(
                        dialogContext,
                        _UnsavedAction.saveAndExit,
                      )
                    : null,
                child: Text(tr('saveAndExit')),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _onCancelEditPressed(
    BuildContext actionContext,
    AppInMemory? appData,
    ThemeData dialogTheme,
  ) async {
    if (updating) return;
    if (!_isEditDirty(appData)) {
      _exitEditWithoutSaving();
      return;
    }
    final _UnsavedAction? action = await _showUnsavedChangesDialog(
      actionContext,
      dialogTheme,
      canSave: !updating && appData?.downloadProgress == null,
    );

    if (!actionContext.mounted || appData == null) return;

    switch (action) {
      case _UnsavedAction.discard:
        _exitEditWithoutSaving();
        break;
      case _UnsavedAction.saveAndExit:
        if (appData.downloadProgress != null || updating) {
          break;
        }
        final appsProvider = Provider.of<AppsProvider>(
          actionContext,
          listen: false,
        );
        await _saveEdit(appData, appsProvider);
        break;
      case _UnsavedAction.keepEditing:
      default:
        break;
    }
  }

  Widget? _editModeFloatingActionButtons(
    BuildContext themeContext,
    AppInMemory? appData,
    AppsProvider appsProvider,
    ThemeData pageThemeForDialogs,
  ) {
    if (!_editMode || appData == null) return null;
    final ColorScheme colorScheme = Theme.of(themeContext).colorScheme;
    final Color disabledSaveFabColor =
        Color.lerp(
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurface,
          Theme.of(themeContext).brightness == Brightness.dark ? 0.18 : 0.08,
        ) ??
        colorScheme.surfaceContainerHighest;
    return _MeasureSize(
      onChange: _handleEditModeFloatingActionButtonsSizeChanged,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'app_page_edit_cancel',
            tooltip: widget.isEmbedded ? null : tr('cancel'),
            onPressed: updating
                ? null
                : () => _onCancelEditPressed(
                    themeContext,
                    appData,
                    pageThemeForDialogs,
                  ),
            child: const Icon(Icons.close),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: Listenable.merge([
              _nameController,
              _authorController,
              _urlController,
              _packageController,
              _notesController,
            ]),
            builder: (BuildContext context, Widget? child) {
              final bool canSave =
                  appData.downloadProgress == null &&
                  !updating &&
                  _isEditDirty(appData);
              return FloatingActionButton(
                heroTag: 'app_page_edit_save',
                tooltip: widget.isEmbedded ? null : tr('save'),
                backgroundColor: canSave ? null : disabledSaveFabColor,
                foregroundColor: canSave
                    ? null
                    : colorScheme.onSurface.withValues(alpha: 0.48),
                elevation: canSave ? null : 0,
                onPressed: canSave
                    ? () => _saveEdit(appData, appsProvider)
                    : null,
                child: const Icon(Icons.check),
              );
            },
          ),
        ],
      ),
    );
  }

  void _startEdit(AppInMemory appData, AppsProvider appsProvider) {
    _clearEditIconStaging();
    _nameController.text = appData.name;
    _authorController.text = appData.author;
    final dynamic aboutRaw = appData.app.additionalSettings['about'];
    _notesController.text = aboutRaw is String
        ? aboutRaw
        : (aboutRaw?.toString() ?? '');
    _urlController.text = appData.app.url;
    _packageController.text = appData.app.id;
    _editCategories = List<String>.from(appData.app.categories);
    _editBaselineHadUserOverride = appsProvider.hasUserAppIconOverride(
      widget.appId,
    );
    _captureEditBaseline(appData);
    setState(() => _editMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      void placeCaretAtEnd(TextEditingController controller) {
        final String text = controller.text;
        controller.selection = TextSelection.collapsed(offset: text.length);
      }

      placeCaretAtEnd(_nameController);
      placeCaretAtEnd(_authorController);
      placeCaretAtEnd(_notesController);
      placeCaretAtEnd(_urlController);
      placeCaretAtEnd(_packageController);
    });
  }

  Future<void> _saveEdit(AppInMemory appData, AppsProvider appsProvider) async {
    if (appData.downloadProgress != null || updating) return;
    App updatedApp =
        appsProvider.apps[widget.appId]?.app.deepCopy() ??
        appData.app.deepCopy();
    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      updatedApp.additionalSettings.remove('appName');
    } else {
      updatedApp.additionalSettings['appName'] = newName;
    }
    final String newAuthor = _authorController.text.trim();
    if (newAuthor.isEmpty) {
      updatedApp.additionalSettings.remove('appAuthor');
    } else {
      updatedApp.additionalSettings['appAuthor'] = newAuthor;
    }
    final newUrl = _urlController.text.trim();
    updatedApp = updatedApp.copyWith(url: newUrl);
    final String newId = _packageController.text.trim();
    if (newId.isEmpty) {
      _showPageError(ObtainiumError(tr('invalidAndroidPackageId')));
      return;
    }
    final bool packageIdChanged = newId != updatedApp.id;
    if (packageIdChanged) {
      updatedApp = updatedApp.copyWith(allowIdChange: true, id: newId);
      // The same package from a different store is allowed, so only a listing
      // of the new package on *this* listing's store is a conflict.
      if (sameStoreListingIn(
            appsProvider.apps,
            updatedApp,
            ignoreKey: widget.appId,
          ) !=
          null) {
        _showPageError(ObtainiumError(tr('appAlreadyAdded')));
        return;
      }
    }
    updatedApp = updatedApp.copyWith(categories: _editCategories);

    final String notesText = _notesController.text.trim();
    if (notesText.isEmpty) {
      updatedApp.additionalSettings.remove('about');
    } else {
      updatedApp.additionalSettings['about'] = notesText;
    }

    if (_editStagedClearOverride &&
        appsProvider.hasUserAppIconOverride(widget.appId)) {
      await appsProvider.resetAppIconToDefault(widget.appId);
    }
    if (_editStagedIconBytes != null) {
      final String? iconErr = await appsProvider.applyUserAppIconPngBytes(
        widget.appId,
        _editStagedIconBytes!,
      );
      if (iconErr != null) {
        if (mounted) {
          _showPageError(
            ObtainiumError(iconErr),
            title: tr('errorChangingIcon'),
          );
        }
        return;
      }
    }

    try {
      if (packageIdChanged) {
        await appsProvider.renameAppPackageId(widget.appId, updatedApp);
      } else {
        await appsProvider.saveApps(
          [updatedApp],
          onlyIfExists: true,
          updateInstalledInfo: false,
        );
      }
      await appsProvider.updateAppIcon(updatedApp.listingKey);
    } catch (error) {
      if (mounted) {
        _showPageError(error);
      }
      return;
    }
    if (mounted) {
      _clearEditIconStaging();
      if (packageIdChanged) {
        if (widget.isEmbedded) {
          final AppsPageState? appsPageState = context
              .findAncestorStateOfType<AppsPageState>();
          if (appsPageState != null) {
            appsPageState.openAppById(updatedApp.listingKey, autoScroll: false);
          } else {
            unawaited(
              Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) =>
                      AppPage(appId: updatedApp.listingKey, isEmbedded: true),
                ),
              ),
            );
          }
        } else {
          unawaited(
            Navigator.of(context).pushReplacement(
              heroFriendlyAppPageRoute<void>(
                (BuildContext context) => AppPage(
                  appId: updatedApp.listingKey,
                  appsListHeroFolderId: widget.appsListHeroFolderId,
                ),
              ),
            ),
          );
        }
        return;
      }
      setState(() => _editMode = false);
      if (_appPageScrollController.hasClients) {
        _appPageScrollController.jumpTo(0);
      }
    }
  }

  Future<void> _pickEditIcon(AppsProvider appsProvider) async {
    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['png'],
      );
    } catch (e) {
      if (mounted) {
        _showPageError(
          ObtainiumError(tr('noFilePickerAvailable')),
          title: tr('errorChangingIcon'),
        );
      }
      return;
    }
    if (!mounted) return;
    if (picked == null) return;
    final Uint8List? bytes = await _readPickedFileBytes(picked);
    if (bytes == null) return;
    if (!appsProvider.validateUserAppIconPngBytes(bytes)) {
      if (mounted) {
        _showPageError(
          ObtainiumError(tr('changeAppIconInvalidPng')),
          title: tr('errorChangingIcon'),
        );
      }
      return;
    }
    setState(() {
      _editStagedIconBytes = bytes;
      _editStagedClearOverride = false;
      _editNonUserIconPreview = null;
    });
  }

  Future<Uint8List?> _readPickedFileBytes(PlatformFile picked) async {
    try {
      return await picked.readAsBytes();
    } catch (_) {
      final String? path = picked.path;
      if (path == null) return null;
      try {
        return await File(path).readAsBytes();
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _onResetEditIconPressed(AppsProvider appsProvider) async {
    Uint8List? preview;
    bool shouldClearOverride = false;

    // If there is a user-set icon override, we load the non-override icon
    // so we can show it live. We also set a flag to clear the override on save.
    // If there is no override but the user has picked a new icon in this edit
    // session, all we need to do is null out the staged icon bytes.
    if (appsProvider.hasUserAppIconOverride(widget.appId)) {
      shouldClearOverride = true;
      preview = await appsProvider.loadIconPreviewExcludingUserOverride(
        widget.appId,
      );
    }

    if (!mounted) return;

    setState(() {
      _editStagedIconBytes = null;
      _editStagedClearOverride = shouldClearOverride;
      _editNonUserIconPreview = preview;
    });
  }

  void _openIconWebSearch(AppInMemory appData) {
    final String query =
        '${appData.name} square app icon transparent background';
    launchUrlString(
      'https://images.google.com/search?tbm=isch&q=${Uri.encodeComponent(query)}',
      mode: LaunchMode.externalApplication,
    );
  }

  void _showPageError(dynamic error, {String? title}) {
    unawaited(LogsProvider().add(error.toString(), level: LogLevel.error));
    final BuildContext? appContext = globalNavigatorKey.currentContext;
    if (appContext == null) return;
    Provider.of<AppsProvider>(
      appContext,
      listen: false,
    ).setAppPageError(widget.appId, error, title: title);
  }

  void _showPageMessage(dynamic message) {
    showMessage(message, theme: _cachedPageTheme);
  }

  Widget _buildPersistentPageError(
    BuildContext ctx,
    ThemeData pageTheme,
    String? error, {
    String? title,
  }) {
    if ((title == null || title.isEmpty) && (error == null || error.isEmpty)) {
      return const SizedBox.shrink();
    }
    // Only collapse to a single line when the title IS the message verbatim
    // (the build-verification-blocked case passes the same string as both) -
    // any real title/detail pair (a specific title plus its own message)
    // should always show both, not just the title.
    final bool showErrorDetails =
        error != null && error.isNotEmpty && error != title;

    final BoxDecoration baseDecoration = appPageSectionCardDecoration(ctx);
    final ColorScheme colorScheme = pageTheme.colorScheme;
    final TextTheme textTheme = pageTheme.textTheme;
    final Color errorFill = Color.alphaBlend(
      colorScheme.error.withValues(alpha: 0.08),
      baseDecoration.color ?? colorScheme.surfaceContainer,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: baseDecoration.copyWith(
        color: errorFill,
        border: Border.all(
          color: colorScheme.error.withValues(alpha: 0.42),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: showErrorDetails
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          spacing: 12,
          children: [
            Container(
              height: 32,
              width: 32,
              decoration: BoxDecoration(
                color: colorScheme.error.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.error_outline_rounded,
                color: colorScheme.error,
                size: 20,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title ?? tr('error'),
                    style: textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: showErrorDetails
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                  if (showErrorDetails) ...[
                    const SizedBox(height: 3),
                    SelectableText(
                      error,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<T?> _showPageDialog<T>({
    required BuildContext hostContext,
    required WidgetBuilder builder,
  }) {
    final ThemeData? pageTheme = _cachedPageTheme;
    return showDialog<T>(
      context: hostContext,
      builder: (BuildContext dialogContext) {
        final Widget dialog = builder(dialogContext);
        return pageTheme == null
            ? dialog
            : Theme(data: pageTheme, child: dialog);
      },
    );
  }

  Widget _materialAppPageSectionCard(
    BuildContext ctx,
    String sectionTitle,
    List<Widget> children, {
    Color? sectionBackgroundColor,
    Color? sectionTitleColor,
    Widget? sectionHeaderTrailing,
    Widget? headerStripe,
    Widget? cardWatermark,
  }) {
    final BoxDecoration baseDecoration = appPageSectionCardDecoration(ctx);
    final BoxDecoration decoration = sectionBackgroundColor != null
        ? baseDecoration.copyWith(color: sectionBackgroundColor)
        : baseDecoration;
    final BorderRadius cardBorderRadius =
        decoration.borderRadius?.resolve(Directionality.of(ctx)) ??
        BorderRadius.zero;
    final BorderSide cardBorderSide = (decoration.border! as Border).top;

    final Widget bodyColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sectionHeaderTrailing == null)
          appPageCardSectionHeaderLabel(
            ctx,
            sectionTitle,
            color: sectionTitleColor,
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              appPageCardSectionHeaderLabel(
                ctx,
                sectionTitle,
                color: sectionTitleColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: sectionHeaderTrailing,
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: 12),
        ...children,
      ],
    );

    final Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: cardWatermark != null
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                bodyColumn,
                Positioned(bottom: 0, right: 0, child: cardWatermark),
              ],
            )
          : bodyColumn,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: AppSmoothRoundedSurface(
        backgroundColor: decoration.color ?? Colors.transparent,
        borderColor: cardBorderSide.color,
        borderWidth: cardBorderSide.width,
        borderRadius: cardBorderRadius.topLeft.x,
        boxShadow: decoration.boxShadow ?? const [],
        // Only these cards have a child that paints to the edge (the header
        // stripe / corner watermark), so only they need the content clipped to
        // the rounded corners; plain cards keep the smooth painted corner
        // without a saveLayer.
        clipContent: headerStripe != null || cardWatermark != null,
        child: headerStripe != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [headerStripe, body],
              )
            : body,
      ),
    );
  }

  Widget _buildEditMetadataSection(
    BuildContext ctx,
    AppInMemory appData,
    AppsProvider appsProvider,
    SettingsProvider settingsProvider,
  ) {
    final bool showResetIconButton =
        appsProvider.hasUserAppIconOverride(widget.appId) ||
        _editStagedIconBytes != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _materialAppPageSectionCard(ctx, tr('nameAndLinks'), [
          TextField(
            controller: _nameController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('appName'),
              isDense: true,
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _authorController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('author'),
              isDense: true,
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _packageController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('package'),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            decoration: appPageOutlinedInputDecoration(
              ctx,
              labelText: tr('trackedSource'),
              isDense: true,
            ),
            keyboardType: TextInputType.url,
          ),
        ]),
        _materialAppPageSectionCard(ctx, tr('appIconActionsTitle'), [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonal(
                onPressed: () => _pickEditIcon(appsProvider),
                child: Text(tr('changeAppIcon')),
              ),
              OutlinedButton(
                onPressed: () => _openIconWebSearch(appData),
                child: Text(tr('searchWebForAppIcon')),
              ),
              if (showResetIconButton)
                OutlinedButton(
                  onPressed: updating
                      ? null
                      : () => _onResetEditIconPressed(appsProvider),
                  child: Text(tr('resetAppIcon')),
                ),
            ],
          ),
        ]),
        _materialAppPageSectionCard(ctx, tr('categories'), [
          CategoryEditorSelector(
            key: ValueKey<String>('app_categories_${widget.appId}'),
            preselected: _editCategories.toSet(),
            alignment: WrapAlignment.start,
            showLabelWhenNotEmpty: false,
            showSelectedCheckmark: true,
            onSelected: (cats) => setState(() => _editCategories = cats),
          ),
        ]),
        KeyedSubtree(
          key: _notesEditSectionKey,
          child: _materialAppPageSectionCard(ctx, tr('notes'), [
            TextField(
              controller: _notesController,
              focusNode: _notesEditFocusNode,
              scrollPadding: const EdgeInsets.only(bottom: 160),
              decoration: appPageOutlinedInputDecoration(
                ctx,
                labelText: null,
                hintText: tr('notes'),
                isDense: true,
              ),
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildRepoRenameWarning({
    required AppInMemory? app,
    required AppsProvider appsProvider,
    required Future<void> Function(String id) onUpdate,
  }) {
    if (app?.app.hasPendingRepoRename != true) {
      return const SizedBox.shrink();
    }
    final appValue = app!;
    final pendingUrl = appValue.app.pendingRepoRenameUrl!;
    final colorScheme = ColorScheme.of(context);
    final textTheme = TextTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 2,
      children: [
        Material(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(16),
              bottom: Radius.circular(4),
            ),
          ),
          color: colorScheme.surfaceContainer,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                spacing: 12,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 24,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          tr('repoRenamed'),
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          tr('repoRenamedExplanation'),
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Material(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          color: colorScheme.surfaceContainer,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                spacing: 12,
                children: [
                  Icon(
                    Icons.link_rounded,
                    size: 24,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          tr('newUrl'),
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          pendingUrl,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Material(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(4),
              bottom: Radius.circular(16),
            ),
          ),
          color: colorScheme.surfaceContainer,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                // Min tap target has a height of 48dp
                vertical: 10 - 4,
              ),
              child: Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.fromMap({
                          WidgetState.disabled: colorScheme.onSurface
                              .withValues(alpha: 0.10),
                          WidgetState.any: Colors.transparent,
                        }),
                        side: WidgetStatePropertyAll(
                          BorderSide(
                            width: 1,
                            strokeAlign: BorderSide.strokeAlignInside,
                            color: colorScheme.outlineVariant,
                          ),
                        ),
                        elevation: const WidgetStatePropertyAll(0),
                        overlayColor: WidgetStateProperty.fromMap({
                          WidgetState.disabled: colorScheme.onSurfaceVariant
                              .withAlpha(0),
                          WidgetState.pressed: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.10),
                          WidgetState.focused: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.10),
                          WidgetState.hovered: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.08),
                          WidgetState.any: colorScheme.onSurfaceVariant
                              .withAlpha(0),
                        }),
                        foregroundColor: WidgetStateProperty.fromMap({
                          WidgetState.disabled: colorScheme.onSurface
                              .withValues(alpha: 0.38),
                          WidgetState.any: colorScheme.onSurfaceVariant,
                        }),
                        textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
                      ),
                      onPressed: () async {
                        await appsProvider.updatePendingRepoRename(
                          appValue.listingKey,
                          null,
                        );
                      },
                      child: Text(tr('dismiss')),
                    ),
                  ),
                  Expanded(
                    child: FilledButton.tonal(
                      style: ButtonStyle(
                        elevation: const WidgetStatePropertyAll(0),
                        textStyle: WidgetStatePropertyAll(
                          textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      onPressed: () async {
                        await appsProvider.acceptRepoRename(
                          appValue.listingKey,
                          pendingUrl,
                        );
                        if (mounted) {
                          unawaited(onUpdate(appValue.listingKey));
                        }
                      },
                      child: Text(tr('updateUrl')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Hero / dialog icons must not use [FutureBuilder] + [updateAppIcon] in build:
  /// a new [Future] every rebuild restarts the work, and [ignoreCache] forces
  /// expensive installed-app icon reloads and [notifyListeners] in a loop.
  Widget _tappableAppIconDisplay({
    required BuildContext themeContext,
    required AppInMemory? appInMemory,
    required double size,
    required double borderRadius,
    required Widget emptyPlaceholder,
    Object? heroTag,
    VoidCallback? onTap,
    Uint8List? iconMemoryBytes,
    bool exclusiveIconMemoryBytes = false,
  }) {
    final Uint8List? bytesForImage = exclusiveIconMemoryBytes
        ? iconMemoryBytes
        : (iconMemoryBytes ?? appInMemory?.icon);
    // Cap the decoded bitmap at the rendered logical size × DPR. Without
    // this hint, [Image.memory] decodes the full source PNG (often 512×512
    // for a launcher icon) and keeps it in the raster cache at full
    // resolution even when displayed at 56 logical px. Sizing the cache
    // here keeps RAM usage bounded for the AppPage's hero icon and the
    // large-format dialog preview.
    final int iconCachePx = (size * MediaQuery.devicePixelRatioOf(themeContext))
        .round();
    Widget iconChild;
    if (bytesForImage != null) {
      iconChild = GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.memory(
            bytesForImage,
            height: size,
            width: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: iconCachePx,
            cacheHeight: iconCachePx,
          ),
        ),
      );
    } else {
      iconChild = GestureDetector(onTap: onTap, child: emptyPlaceholder);
    }
    if (heroTag != null) {
      return Hero(
        tag: heroTag,
        flightShuttleBuilder:
            (
              BuildContext flightContext,
              Animation<double> animation,
              HeroFlightDirection flightDirection,
              BuildContext fromHeroContext,
              BuildContext toHeroContext,
            ) {
              final Uint8List? shuttleBytes = bytesForImage;
              if (shuttleBytes != null) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(borderRadius),
                  child: Image.memory(
                    shuttleBytes,
                    height: size,
                    width: size,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: iconCachePx,
                    cacheHeight: iconCachePx,
                  ),
                );
              }
              return emptyPlaceholder;
            },
        child: iconChild,
      );
    }
    return iconChild;
  }

  void _startIconSchemeLoadIfNeeded(Uint8List iconBytes, String cacheKey) {
    if (!mounted) return;
    if (_iconSchemeCacheKey == cacheKey) return;
    if (_iconSchemeLoadingForKey == cacheKey) return;
    _iconSchemeLoadingForKey = cacheKey;
    _extractColorSchemeFromIcon(iconBytes, cacheKey);
  }

  Future<void> _extractColorSchemeFromIcon(
    Uint8List iconBytes,
    String cacheKey,
  ) async {
    if (!context.mounted) return;
    final Brightness brightness = Theme.of(context).brightness;
    final AppsProvider apps = context.read<AppsProvider>();
    final SettingsProvider settings = context.read<SettingsProvider>();
    final ColorScheme? scheme = await loadColorSchemeFromAppIcon(
      iconBytes: iconBytes,
      brightness: brightness,
    );
    if (!mounted) return;
    if (!identical(apps.apps[widget.appId]?.icon, iconBytes)) return;
    if (!settings.matchAppPageToIconColors) return;
    if (scheme != null) {
      setState(() {
        if (_iconSchemeLoadingForKey == cacheKey) {
          _iconDerivedColorScheme = scheme;
          _iconSchemeCacheKey = cacheKey;
          _iconSchemeLoadingForKey = null;
          _iconSchemeFailedCacheKey = null;
        }
      });
    } else {
      setState(() {
        if (_iconSchemeLoadingForKey == cacheKey) {
          _iconSchemeLoadingForKey = null;
          _iconSchemeFailedCacheKey = cacheKey;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshUses24HourFormat());
    // Cached per Android package, which is not the listing key once a package
    // is tracked from two stores.
    _storeAvailabilityCacheFuture = BulkScanCache.loadForApp(
      Provider.of<AppsProvider>(
            context,
            listen: false,
          ).apps[widget.appId]?.app.id ??
          widget.appId,
    );
    // Defer to post-frame so the first paint isn't competing with our
    // SourceProvider lookup. The actual HTTP walk inside is fully async.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_maybeLazyResolveApkMirrorSize());
    });
    _notesEditFocusNode.addListener(() {
      if (!_notesEditFocusNode.hasFocus || !mounted) return;
      void scrollNotesIntoView() {
        if (!mounted || !_notesEditFocusNode.hasFocus) return;
        final BuildContext? notesContext = _notesEditSectionKey.currentContext;
        if (notesContext == null) return;
        Scrollable.ensureVisible(
          notesContext,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.1,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollNotesIntoView();
        Future<void>.delayed(
          const Duration(milliseconds: 120),
          scrollNotesIntoView,
        );
      });
    });
  }

  /// Opts the page out of the inset handling Android's WebView adopted in M139,
  /// where it reserves space in the web content for the system bars and display
  /// cutout. This view is deliberately full-bleed under those bars, and the
  /// reservation disagrees with the size Flutter gives the native view - which
  /// paints a blank slab over part of the page that only clears on the next
  /// scroll (flutter/flutter#175840). The IME inset is deliberately left in
  /// place so a focused field still gets the viewport shrunk for the keyboard.
  Future<void> _ignoreSystemBarInsetsInWebContent(
    AndroidWebViewController androidController,
  ) async {
    try {
      await androidController.setInsetsForWebContentToIgnore(
        const <AndroidWebViewInsets>[
          AndroidWebViewInsets.systemBars,
          AndroidWebViewInsets.displayCutout,
        ],
      );
    } catch (error) {
      // Older WebView builds have no inset listener to install, and their
      // pre-M139 behavior is what this call was asking for anyway.
      unawaited(LogsProvider().add(error.toString(), level: LogLevel.info));
    }
  }

  WebViewController _ensureWebViewController() {
    final WebViewController? existingController = _webViewController;
    if (existingController != null) return existingController;
    final WebViewController controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          // The loading indicator covers only the initial page load (started
          // when loadRequest is issued). We never re-show it on later
          // navigations: sites like GitHub fire onPageStarted again after
          // finishing, which would otherwise leave the spinner running for
          // several seconds after the page is already visible.
          onProgress: (int progress) {
            if (progress >= 100 && mounted && _webViewLoading) {
              setState(() => _webViewLoading = false);
            }
          },
          onPageFinished: (String url) {
            if (mounted && _webViewLoading) {
              setState(() => _webViewLoading = false);
            }
            unawaited(_refreshWebViewCanGoBack());
          },
          // Single-page apps (GitHub, most docs sites) push history entries
          // without a full page load, so onPageFinished alone would miss them.
          onUrlChange: (UrlChange change) {
            unawaited(_refreshWebViewCanGoBack());
          },
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame == true) {
              if (mounted && _webViewLoading) {
                setState(() => _webViewLoading = false);
              }
              _showPageError(
                ObtainiumError(error.description, unexpected: true),
                title: tr('errorLoadingPage'),
              );
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            final String url = request.url;
            if (!(url.startsWith('http://') ||
                url.startsWith('https://') ||
                url.startsWith('ftp://') ||
                url.startsWith('ftps://'))) {
              return NavigationDecision.prevent;
            }
            final String lastPathSegment =
                Uri.tryParse(url)?.pathSegments.lastOrNull ?? '';
            final int extensionStart = lastPathSegment.lastIndexOf('.');
            if (extensionStart > 0 &&
                _webViewDownloadExtensions.contains(
                  lastPathSegment.substring(extensionStart + 1).toLowerCase(),
                )) {
              unawaited(_handOffSourceWebpageDownload(url));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      unawaited(_ignoreSystemBarInsetsInWebContent(platformController));
    }
    _webViewController = controller;
    return controller;
  }

  Future<void> _refreshWebViewCanGoBack() async {
    final WebViewController? controller = _webViewController;
    if (controller == null) return;
    final bool canGoBack = await controller.canGoBack();
    if (!mounted || _webViewCanGoBack == canGoBack) return;
    setState(() => _webViewCanGoBack = canGoBack);
  }

  Future<void> _handleSourceWebpageBack(BuildContext pageContext) async {
    final WebViewController? controller = _webViewController;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      await _refreshWebViewCanGoBack();
      return;
    }
    // canPop was computed from a stale history check (the page dropped its
    // last entry since the last refresh), so this press was swallowed. Correct
    // the flag and leave the screen, which is what the user asked for.
    if (!mounted) return;
    setState(() => _webViewCanGoBack = false);
    if (pageContext.mounted) {
      await Navigator.of(pageContext).maybePop();
    }
  }

  /// Sends a file the embedded page asked for to the system browser or download
  /// manager, the only place it can actually land: the WebView will not save it,
  /// and ObtainX's own downloader only handles APKs for apps it tracks.
  Future<void> _handOffSourceWebpageDownload(String url) async {
    bool launched = false;
    try {
      launched = await launchUrlString(
        url,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      unawaited(LogsProvider().add(error.toString(), level: LogLevel.error));
    }
    if (!mounted) return;
    _showPageMessage(
      launched
          ? tr('downloadOpenedExternally')
          : tr('downloadCouldNotOpenExternally'),
    );
  }

  /// The webpage view has no browser chrome, so a long press on the details FAB
  /// is its only way to re-fetch a page. The loading indicator is re-shown here
  /// (unlike on in-page navigations) because an explicit reload of an unchanged
  /// page can otherwise look like nothing happened.
  Future<void> _reloadSourceWebpage() async {
    final WebViewController? controller = _webViewController;
    if (controller == null || !_webViewUrlLoaded || _webViewLoading) return;
    hapticMediumImpact();
    setState(() => _webViewLoading = true);
    await controller.reload();
  }

  Widget _buildSourceWebpageView(BuildContext themeContext) {
    final Color webViewSurface =
        Color.lerp(
          Theme.of(themeContext).colorScheme.surface,
          Colors.black,
          Theme.of(themeContext).brightness == Brightness.dark ? 0.055 : 0.045,
        ) ??
        Theme.of(themeContext).colorScheme.surface;
    _applyWebViewSurfaceColorIfNeeded(webViewSurface);
    return WebViewWidget(
      key: ObjectKey(_webViewController),
      controller: _ensureWebViewController(),
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
        Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
      },
    );
  }

  Widget _buildSourceWebpageScaffold({
    required BuildContext themedPageContext,
    required ThemeData pageTheme,
    required ColorScheme pageColorScheme,
    required SettingsProvider settingsProvider,
    required AppInMemory? app,
    required String? persistentPageError,
    required String? persistentPageErrorTitle,
  }) {
    return PopScope(
      // Back walks the embedded page's own history first, like a browser, and
      // only leaves the screen once the page has nowhere left to go back to.
      canPop: !_webViewCanGoBack,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        unawaited(_handleSourceWebpageBack(themedPageContext));
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: pageColorScheme.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: pageColorScheme.surface,
          floatingActionButton: GestureDetector(
            // FloatingActionButton has no onLongPress, and its InkWell only
            // claims long presses when it has a handler of its own - so this
            // ancestor wins the gesture without costing the FAB its tap.
            onLongPress: () => unawaited(_reloadSourceWebpage()),
            child: FloatingActionButton(
              heroTag: 'app_page_webview_details_${widget.appId}',
              tooltip: widget.isEmbedded ? null : tr('detailsLongPressReload'),
              onPressed: () {
                // MaterialPageRoute (not the hero-friendly fade route the apps
                // list uses) so this push gets the theme's
                // FadeForwardsPageTransitions slide. There is no icon Hero on
                // the webpage screen to preserve.
                Navigator.of(themedPageContext).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) => AppPage(
                      appId: widget.appId,
                      showOppositeOfPreferredView:
                          settingsProvider.showAppWebpage,
                      appsListHeroFolderId: widget.appsListHeroFolderId,
                    ),
                  ),
                );
              },
              child: const Icon(Icons.info_outline_rounded),
            ),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (app == null)
                const SizedBox.shrink()
              else
                _buildSourceWebpageView(themedPageContext),
              if (_webViewLoading)
                Center(
                  child: ExpressiveLoadingIndicator(
                    color: pageColorScheme.primary,
                  ),
                ),
              Positioned(
                top: MediaQuery.paddingOf(themedPageContext).top,
                left: 0,
                right: 0,
                child: _buildPersistentPageError(
                  themedPageContext,
                  pageTheme,
                  persistentPageError,
                  title: persistentPageErrorTitle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// After a pull-to-refresh, checks all 4 stores (APKMirror, F-Droid, APKPure,
  /// Play Store) for this single app concurrently. Cached stores are skipped,
  /// except that APKMirror is rechecked when its existing availability response
  /// can also fill a missing app icon. Presence always runs for every store
  /// that is still uncached. Icon resolution is separate: APKMirror API icon
  /// first, then listing-page icons APKMirror -> F-Droid -> APKPure -> Play
  /// Store, stopping at the first hit - and skipped entirely for installed apps
  /// or when an icon was already extracted from a downloaded APK. Caches results
  /// and triggers a FutureBuilder rebuild so the Other Sources row updates in
  /// place.
  Future<void> _maybeCheckAndCacheAllStores(String listingKey) async {
    if (listingKey.isEmpty || !mounted) return;

    final appsProvider = Provider.of<AppsProvider>(context, listen: false);
    final AppInMemory? appBeforeStoreCheck = appsProvider.apps[listingKey];
    if (appBeforeStoreCheck == null) return;
    // Store availability and icons belong to the Android package, so they are
    // shared by every listing of it - only the library lookups above are keyed
    // by listing.
    final String appId = appBeforeStoreCheck.app.id;
    final trackedUrl = appBeforeStoreCheck.app.url;
    // No icon to hunt for when the device already supplies one (app is
    // installed), or when one was deduced from a downloaded APK and stored
    // permanently - that one is authoritative and needs no improving on.
    final shouldResolveMissingIcon =
        appBeforeStoreCheck.icon == null &&
        appBeforeStoreCheck.installedInfo == null &&
        appBeforeStoreCheck.app.iconUrl?.isNotEmpty != true &&
        !appsProvider.hasDeducedAppIcon(appId);

    final storeData = await BulkScanCache.loadForApp(appId) ?? {};
    // Resolve cheapest-first: the library, then the scan cache, and only then
    // the network. Another listing of this same package is the most
    // authoritative answer available and costs nothing, so fold those URLs in
    // before deciding what still needs looking up - every store a sibling
    // already tracks then falls out of the checks below instead of being
    // fetched again. Persisting them also means the answer outlives that
    // sibling being deleted, which for GitHub is the difference between
    // knowing the repo URL and never being able to derive it again.
    final Map<String, String> siblingStoreUrls = <String, String>{};
    for (final AppInMemory sibling in appsProvider.apps.listingsForPackage(
      appId,
    )) {
      if (sibling.listingKey == listingKey || sibling.app.url.isEmpty) continue;
      final String? slotName = _storeSlotNameForUrl(sibling.app.url);
      if (slotName == null || storeData[slotName] == sibling.app.url) continue;
      if (slotName == 'GitHub' && !isSwappableGitHubRepoUrl(sibling.app.url)) {
        continue;
      }
      siblingStoreUrls[slotName] = sibling.app.url;
      storeData[slotName] = sibling.app.url;
    }
    if (siblingStoreUrls.isNotEmpty) {
      await BulkScanCache.save(<String, Map<String, String>>{
        appId: siblingStoreUrls,
      });
    }
    final apkMirrorIconUrls = <String, String>{};

    final futures = <Future<MapEntry<String, String?>>>[];

    if (!_trackedUrlIsFromHost(trackedUrl, 'apkmirror.com') &&
        ((storeData['APKMirror'] ?? '').isEmpty || shouldResolveMissingIcon)) {
      futures.add(
        BulkImportService.checkApkMirror(
          [appId],
          resolvedIconUrls: apkMirrorIconUrls,
        ).then((result) => MapEntry('APKMirror', result[appId])),
      );
    }
    if (!_trackedUrlIsFromHost(trackedUrl, 'f-droid.org') &&
        (storeData['F-Droid'] ?? '').isEmpty) {
      futures.add(
        BulkImportService.checkFDroid([
          appId,
        ]).then((result) => MapEntry('F-Droid', result[appId])),
      );
    }
    final String cachedApkPureUrl = storeData['APKPure'] ?? '';
    if (!_trackedUrlIsFromHost(trackedUrl, 'apkpure.') &&
        (cachedApkPureUrl.isEmpty ||
            !isWellFormedApkPureUrl(cachedApkPureUrl))) {
      futures.add(
        BulkImportService.checkApkPure([
          appId,
        ]).then((result) => MapEntry('APKPure', result[appId])),
      );
    }
    if (!_trackedUrlIsFromHost(trackedUrl, 'play.google.com') &&
        (storeData['PlayStore'] ?? '').isEmpty) {
      futures.add(
        _checkPlayStoreAvailability(
          appId,
        ).then((url) => MapEntry('PlayStore', url)),
      );
    }

    final entry = Map<String, String>.from(storeData);
    if (futures.isNotEmpty) {
      final results = await Future.wait(futures);
      final changedStores = <String, String>{};
      for (final result in results) {
        final String existing = entry[result.key] ?? '';
        // A malformed cached APKPure entry is never usable - a fresh "not
        // found" (null) result must be allowed to overwrite it with the
        // empty-string sentinel, not just a fresh URL. Every other store's
        // cached value is trusted as-is once non-empty.
        final bool existingIsUsable = result.key == 'APKPure'
            ? existing.isNotEmpty && isWellFormedApkPureUrl(existing)
            : existing.isNotEmpty;
        if (result.value != null || !existingIsUsable) {
          entry[result.key] = result.value ?? '';
          changedStores[result.key] = result.value ?? '';
        }
      }
      if (changedStores.isNotEmpty) {
        await BulkScanCache.save({appId: changedStores});
      }
    } else if (!shouldResolveMissingIcon) {
      return;
    }

    String? resolvedIconUrl;
    if (shouldResolveMissingIcon) {
      resolvedIconUrl = await resolveIconUrlFromOtherStores(
        apkMirrorIconUrl: apkMirrorIconUrls[appId],
        apkMirrorListingUrl: entry['APKMirror'],
        fdroidListingUrl: entry['F-Droid'],
        apkPureListingUrl: entry['APKPure'],
        playStoreListingUrl: entry['PlayStore'],
      );
    }
    final AppInMemory? currentApp = appsProvider.apps[listingKey];
    if (resolvedIconUrl != null &&
        currentApp != null &&
        currentApp.icon == null &&
        currentApp.app.iconUrl?.isNotEmpty != true &&
        currentApp.app.url == trackedUrl) {
      await appsProvider.saveApps([
        currentApp.app.copyWith(iconUrl: resolvedIconUrl),
      ], updateInstalledInfo: false);
      await appsProvider.updateAppIcon(listingKey);
    }

    if (mounted && widget.appId == listingKey) {
      setState(() {
        _storeAvailabilityCacheFuture = Future.value(entry);
      });
    }
  }

  /// Lazily fills in [App.apkSizeBytes] for APKMirror apps the first time
  /// the user opens the AppPage after a refresh that bumped the version.
  ///
  /// Why this lives here and not in the update-check pipeline:
  /// resolving an APKMirror size requires walking the release page plus
  /// one GET per ranked download candidate, so doing it on every refresh
  /// for every APKMirror app — just to display " · 43 MB" next to the
  /// install/update button — was the worst single offender in the update
  /// path. Doing it lazily on AppPage open means at most one app pays
  /// the cost, and only when the user actually looks at it.
  ///
  /// The resolved value is persisted onto the App via [AppsProvider.saveApps];
  /// [SourceProvider.getApp] preserves it across refreshes that don't
  /// change [App.latestVersion] and clears it when the version changes,
  /// so the cache key is effectively `(appId, latestVersion)`.
  Future<void> _maybeLazyResolveApkMirrorSize() async {
    if (!mounted) return;
    if (_attemptedApkMirrorSizeResolution) return;
    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    final App? currentApp = appsProvider.apps[widget.appId]?.app;
    if (currentApp == null) return;
    if (currentApp.apkSizeBytes != null) {
      // Already cached on the App itself.
      _attemptedApkMirrorSizeResolution = true;
      return;
    }
    final AppSource source = SourceProvider().getSource(
      currentApp.url,
      overrideSource: currentApp.overrideSource,
    );
    if (source is! APKMirror) return;
    _attemptedApkMirrorSizeResolution = true;
    try {
      final int? resolvedSize = await source.resolveLatestApkSizeBytes(
        releasePageUrl: currentApp.changeLog,
        additionalSettings: currentApp.additionalSettings,
      );
      if (!mounted || resolvedSize == null) return;
      final App? freshApp = appsProvider.apps[widget.appId]?.app;
      if (freshApp == null) return;
      // The user may have navigated away or the app may have been
      // refreshed onto a new version while the network walk was running;
      // in either case we want to skip the stale write.
      if (freshApp.latestVersion != currentApp.latestVersion) return;
      if (freshApp.apkSizeBytes == resolvedSize) return;
      final App updated = freshApp.copyWith(apkSizeBytes: resolvedSize);
      await appsProvider.saveApps(
        [updated],
        // No need to re-export to disk just because we filled in a size.
        autoExportAfterSave: false,
        updateInstalledInfo: false,
      );
      _logApkMirrorSizeDebugFromAppPage(
        'lazy resolve persisted id=${widget.appId} size=$resolvedSize',
      );
    } catch (error) {
      _logApkMirrorSizeDebugFromAppPage(
        'lazy resolve error id=${widget.appId} error=${error.toString()}',
      );
    }
  }

  Future<void> _runCheckUpdate(
    String listingKey, {
    bool resetVersion = false,
  }) async {
    final int updateCheckRunToken = ++_updateCheckRunToken;
    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    try {
      setState(() {
        updating = true;
      });
      await appsProvider.checkUpdate(listingKey);
      appsProvider.clearAppPageError(listingKey);
      if (!mounted || widget.appId != listingKey) return;
      // saveApps (called inside checkUpdate) replaces the in-memory icon with
      // null for non-installed apps.  Reset the one-shot flag so the rebuild
      // that follows will re-invoke updateAppIcon and restore any user icon.
      // Also reload the bulk-scan cache: the page's future was resolved at
      // initState time and won't see cache writes made by a bulk scan that ran
      // while this page was already open in the navigation stack.
      setState(() {
        _requestedMissingIconLoad = false;
        _storeAvailabilityCacheFuture = BulkScanCache.loadForApp(
          appsProvider.apps[listingKey]?.app.id ?? listingKey,
        );
      });
      // Independently check Play Store in the background so other store
      // buttons (F-Droid, APKPure, APKMirror) appear immediately from cache
      // without waiting for the Play Store network round-trip.
      unawaited(_maybeCheckAndCacheAllStores(listingKey));
      // The version may have just bumped, in which case [SourceProvider.getApp]
      // cleared the cached size and we need to walk APKMirror again. The
      // resolver is a no-op when the size is still present.
      _attemptedApkMirrorSizeResolution = false;
      unawaited(_maybeLazyResolveApkMirrorSize());
      if (resetVersion) {
        final app = appsProvider.apps[listingKey]?.app;
        if (app != null) {
          unawaited(
            appsProvider.saveApps([app.copyWith(installedVersion: null)]),
          );
        }
      }
    } catch (err) {
      if (!mounted || widget.appId != listingKey) return;
      if (err is RepositoryRenamedError && mounted) {
        await appsProvider.updatePendingRepoRename(listingKey, err.newUrl);
      } else if (mounted) {
        _showPageError(err, title: tr('errorCheckingUpdates'));
      }
    } finally {
      if (mounted &&
          widget.appId == listingKey &&
          _updateCheckRunToken == updateCheckRunToken) {
        setState(() {
          updating = false;
        });
      }
    }
  }

  void _applyWebViewSurfaceColorIfNeeded(Color background) {
    final controller = _webViewController;
    if (controller == null) return;
    if (_lastWebViewSurfaceColorApplied == background) return;
    _lastWebViewSurfaceColorApplied = background;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        controller.setBackgroundColor(background);
      }
    });
  }

  static const double _storeSourceIconSize = 32;
  static const double _storeSourceButtonSize = 48;

  Future<void> _showAlternateStoreSwapMenu({
    required BuildContext menuContext,
    required Offset globalPosition,
    required String url,
    String? storeName,
    String? trackedListingKey,
  }) async {
    final RelativeRect position = RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      globalPosition.dx + 1,
      globalPosition.dy + 1,
    );
    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      menuContext,
      listen: false,
    );
    final AppInMemory? currentListing = appsProvider.apps[widget.appId];
    // A package gets one listing per store, so when this store already has one
    // the swap would duplicate it. Offer that listing instead of a dead action.
    final AppInMemory? existingStoreListing = trackedListingKey != null
        ? appsProvider.apps[trackedListingKey]
        : currentListing == null
        ? null
        : sameStoreListingIn(
            appsProvider.apps,
            currentListing.app.copyWith(url: url, overrideSource: null),
            ignoreKey: currentListing.listingKey,
          );
    final String? choice = await showMenu<String>(
      context: menuContext,
      position: position,
      items: [
        if (existingStoreListing != null)
          PopupMenuItem<String>(
            value: 'open',
            child: Text(tr('showTrackedItem')),
          )
        else if (storeName != null) ...[
          PopupMenuItem<String>(
            value: 'track',
            child: Text(tr('trackHereToo')),
          ),
          PopupMenuItem<String>(
            value: 'swap',
            child: Text(tr('swapToThisSource')),
          ),
        ],
        PopupMenuItem<String>(value: 'copy', child: Text(tr('copyLink'))),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'track':
        hapticSelection();
        await _runTrackAdditionalSource(candidateUrl: url);
      case 'swap':
        hapticSelection();
        await _runSwapTrackedSource(storeName: storeName!, candidateUrl: url);
      case 'open':
        hapticSelection();
        _openListing(existingStoreListing!.listingKey);
      case 'copy':
        if (!menuContext.mounted) return;
        _toastUrl(menuContext, url);
        await Clipboard.setData(ClipboardData(text: url));
      default:
        break;
    }
  }

  /// Shows another listing of this same package, selecting it in the embedded
  /// two-pane layout.
  ///
  /// Replaces this page rather than stacking on it: hopping between a package's
  /// store listings is a sideways move, so back stays one level from the app
  /// list however many times the user hops.
  void _openListing(String listingKey) {
    if (widget.isEmbedded) {
      final AppsPageState? appsPageState = context
          .findAncestorStateOfType<AppsPageState>();
      if (appsPageState != null) {
        appsPageState.openAppById(listingKey);
        return;
      }
      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                AppPage(appId: listingKey, isEmbedded: true),
          ),
        ),
      );
      return;
    }
    unawaited(
      Navigator.of(context).pushReplacement(
        heroFriendlyAppPageRoute<void>(
          (BuildContext _) => AppPage(
            appId: listingKey,
            appsListHeroFolderId: widget.appsListHeroFolderId,
          ),
        ),
      ),
    );
  }

  Future<void> _runTrackAdditionalSource({required String candidateUrl}) async {
    if (updating) return;
    final String currentListingKey = widget.appId;
    bool openedNewListing = false;
    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    try {
      final AppInMemory? currentListing = appsProvider.apps[currentListingKey];
      if (currentListing == null) return;
      setState(() {
        updating = true;
        _trackingAdditionalSource = true;
      });

      final AppSource destinationSource = _sourceProvider.getSource(
        candidateUrl,
      );
      final Map<String, dynamic> destinationSettings =
          getDefaultValuesFromFormItems(
            destinationSource.combinedAppSpecificSettingFormItems,
          );
      // This action starts from a listing whose package is already known.
      // Supplying it avoids downloading an APK merely to rediscover the same ID
      // and prevents a store page from being associated with the wrong package.
      destinationSettings['appId'] = currentListing.app.id;
      App additionalListing = await _sourceProvider.getApp(
        destinationSource,
        candidateUrl,
        destinationSettings,
        trackOnlyOverride: destinationSource.enforceTrackOnly,
      );
      if (additionalListing.id != currentListing.app.id) {
        throw ObtainiumError(tr('appIdMismatch'));
      }
      if (sameStoreListingIn(appsProvider.apps, additionalListing) != null) {
        throw ObtainiumError(tr('appAlreadyAdded'));
      }

      additionalListing = additionalListing.copyWith(
        categories: currentListing.app.categories,
      );
      additionalListing = appsProvider.withAllocatedListingId(
        additionalListing,
      );
      await appsProvider.saveApps([additionalListing], onlyIfExists: false);
      final App? savedListing =
          appsProvider.apps[additionalListing.listingKey]?.app;
      if (savedListing != null) {
        await appsProvider.assignMatchingFoldersToAppIfNeeded(savedListing);
      }
      await appsProvider.updateAppIcon(additionalListing.listingKey);
      appsProvider.clearAppPageError(currentListingKey);
      if (!mounted || widget.appId != currentListingKey) return;
      // Show what was just created. Replaces this page rather than stacking on
      // it, like every other hop between a package's listings (see
      // [_openListing]). The overlay is deliberately left up until the new page
      // takes over, so the wait never ends on a page that looks idle.
      _openListing(additionalListing.listingKey);
      openedNewListing = true;
    } catch (error) {
      if (!mounted || widget.appId != currentListingKey) return;
      _showPageError(error, title: tr('error'));
    } finally {
      if (!openedNewListing && mounted && widget.appId == currentListingKey) {
        setState(() {
          updating = false;
          _trackingAdditionalSource = false;
        });
      }
    }
  }

  Future<void> _runSwapTrackedSource({
    required String storeName,
    required String candidateUrl,
  }) async {
    if (updating) return;
    final String appId = widget.appId;
    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    try {
      final AppInMemory? swapEntry = appsProvider.apps[appId];
      setState(() {
        updating = true;
        _swappingTrackedSource = true;
        _cachedSource = null;
        _cachedSourceKey = null;
        if (swapEntry != null) {
          _swapSecurityAppSnapshot = swapEntry.app;
          _swapSecuritySourceSnapshot = _sourceProvider.getSource(
            swapEntry.app.url,
            overrideSource: swapEntry.app.overrideSource,
          );
          _swapSecurityCertificateHashesSnapshot = List<String>.from(
            swapEntry.certificateHashes,
          );
          _swapSecurityHasMultipleSignersSnapshot =
              swapEntry.hasMultipleSigners;
        }
      });
      await appsProvider.swapTrackedSource(
        appId: appId,
        storeName: storeName,
        candidateUrl: candidateUrl,
      );
      appsProvider.clearAppPageError(appId);
      if (!mounted || widget.appId != appId) return;
      setState(() {
        _requestedMissingIconLoad = false;
        // Cached per Android package, not per listing.
        _storeAvailabilityCacheFuture = BulkScanCache.loadForApp(
          appsProvider.apps[appId]?.app.id ?? appId,
        );
        _cachedSource = null;
        _cachedSourceKey = null;
      });
      await appsProvider.updateAppIcon(appId);
      unawaited(_maybeCheckAndCacheAllStores(appId));
      _attemptedApkMirrorSizeResolution = false;
      unawaited(_maybeLazyResolveApkMirrorSize());
    } catch (error) {
      if (!mounted || widget.appId != appId) return;
      _showPageError(error, title: tr('errorSwappingTrackedSource'));
    } finally {
      if (mounted && widget.appId == appId) {
        setState(() {
          updating = false;
          _swappingTrackedSource = false;
          _swapSecurityAppSnapshot = null;
          _swapSecuritySourceSnapshot = null;
          _swapSecurityCertificateHashesSnapshot = null;
          _swapSecurityHasMultipleSignersSnapshot = null;
        });
      }
    }
  }

  Widget _buildStoreSourceLaunchIcon({
    required BuildContext iconContext,
    required String url,
    String? assetPath,
    String? swapStoreName,
    String? trackedListingKey,
  }) {
    final String? swappableStoreName =
        swapStoreName != null &&
            swappableAlternateStoreNames.contains(swapStoreName)
        ? swapStoreName
        : null;
    final bool hasLongPressMenu =
        swappableStoreName != null || trackedListingKey != null;
    return Builder(
      builder: (BuildContext iconBuilderContext) {
        final ColorScheme colorScheme = Theme.of(
          iconBuilderContext,
        ).colorScheme;
        final Widget picture = assetPath != null
            ? StoreSourceIconImage(
                assetPath: assetPath,
                size: _storeSourceIconSize,
                errorBuilder: (context, error, stackTrace) => Icon(
                  Icons.link,
                  size: _storeSourceIconSize * 0.75,
                  color: colorScheme.primary,
                ),
              )
            : StoreSourceIconForUrl(url: url, size: _storeSourceIconSize);
        final Widget iconButton = Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () =>
                launchUrlString(url, mode: LaunchMode.externalApplication),
            onLongPress: hasLongPressMenu
                ? null
                : () {
                    _toastUrl(iconBuilderContext, url);
                    Clipboard.setData(ClipboardData(text: url));
                  },
            borderRadius: BorderRadius.circular(12),
            child: SizedBox.square(
              dimension: _storeSourceButtonSize,
              child: Center(
                child: SizedBox.square(
                  dimension: _storeSourceIconSize,
                  child: Center(child: picture),
                ),
              ),
            ),
          ),
        );
        if (!hasLongPressMenu) {
          return iconButton;
        }
        return GestureDetector(
          onLongPressStart: (LongPressStartDetails details) {
            unawaited(
              _showAlternateStoreSwapMenu(
                menuContext: iconBuilderContext,
                globalPosition: details.globalPosition,
                storeName: swappableStoreName,
                trackedListingKey: trackedListingKey,
                url: url,
              ),
            );
          },
          child: iconButton,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    context.select<SettingsProvider, int>(appPageSettingsRebuildToken);
    context.select<AppsProvider, int>(
      (AppsProvider provider) =>
          appPageAppsRebuildToken(provider, widget.appId),
    );
    final ({String? title, String message})? persistentPageError = context
        .select<AppsProvider, ({String? title, String message})?>(
          (AppsProvider provider) => provider.appPageErrors[widget.appId],
        );

    final AppsProvider appsProvider = Provider.of<AppsProvider>(
      context,
      listen: false,
    );
    final SettingsProvider settingsProvider = Provider.of<SettingsProvider>(
      context,
      listen: false,
    );

    final bool useIconPageColors = settingsProvider.matchAppPageToIconColors;
    // Webpage mode is a full-screen WebView plus an info FAB. Edit always uses
    // the normal details page, including swipe-to-edit.
    final bool showAppWebpageFinal =
        !widget.openInEditMode &&
        !_editMode &&
        ((settingsProvider.showAppWebpage &&
                !widget.showOppositeOfPreferredView) ||
            (!settingsProvider.showAppWebpage &&
                widget.showOppositeOfPreferredView));
    final bool areDownloadsRunning = appsProvider.areDownloadsRunning();
    final AppInMemory? app = appsProvider.apps[widget.appId];
    final List<String> loadedCertificateHashes =
        app?.certificateHashes ?? const <String>[];
    if (app?.installedInfo != null && loadedCertificateHashes.isEmpty) {
      final String signingCertificateLoadKey =
          '${app!.app.id}:${app.installedInfo?.lastUpdateTime ?? 0}';
      if (_signingCertificateLoadKey != signingCertificateLoadKey) {
        _signingCertificateLoadKey = signingCertificateLoadKey;
        _signingCertificateInfoFuture =
            BulkImportService.getSigningCertificates(app.app.id);
      }
    } else if (app?.installedInfo == null) {
      _signingCertificateLoadKey = null;
      _signingCertificateInfoFuture = null;
    }
    if (!_requestedMissingIconLoad && app != null && app.icon == null) {
      _requestedMissingIconLoad = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Provider.of<AppsProvider>(
          context,
          listen: false,
        ).updateAppIcon(widget.appId, ignoreCache: false);
        // updateAppIcon only falls back to an already-set App.iconUrl - it
        // doesn't go looking for one. Without this, a freshly-added app whose
        // source publishes no icon stays iconless until the user manually
        // pulls to refresh (which is what actually resolves iconUrl via the
        // other stores below).
        unawaited(_maybeCheckAndCacheAllStores(widget.appId));
      });
    }
    if (widget.openInEditMode &&
        !_scheduledOpenInEditMode &&
        app != null &&
        !_editMode) {
      _scheduledOpenInEditMode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final AppInMemory? freshApp = Provider.of<AppsProvider>(
          context,
          listen: false,
        ).apps[widget.appId];
        if (freshApp != null) {
          _startEdit(freshApp, appsProvider);
        }
      });
    }
    AppSource? source;
    if (app != null) {
      final String sourceKey = '${app.app.url} ${app.app.overrideSource ?? ''}';
      if (sourceKey != _cachedSourceKey) {
        _cachedSource = _sourceProvider.getSource(
          app.app.url,
          overrideSource: app.app.overrideSource,
        );
        _cachedSourceKey = sourceKey;
      }
      source = _cachedSource;
    }
    final String? buildVerificationPersistentPageError =
        app != null &&
            source != null &&
            buildVerificationEnforcementBlocksInstall(
              app.app,
              source,
              settingsProvider,
            )
        ? buildVerificationEnforcedBlockedMessage(
            app.app,
            source,
            settingsProvider,
          )
        : null;
    final String? effectivePersistentPageError =
        buildVerificationPersistentPageError ?? persistentPageError?.message;
    final String? effectivePersistentPageErrorTitle =
        buildVerificationPersistentPageError ?? persistentPageError?.title;

    final Uint8List? iconBytes = app?.icon;
    final Brightness themeBrightness = Theme.of(context).brightness;
    if (useIconPageColors && iconBytes != null) {
      final String iconSchemeCacheKey =
          '${identityHashCode(iconBytes)}_${themeBrightness.name}';
      final ColorScheme? cachedScheme = getCachedColorScheme(
        iconBytes,
        themeBrightness,
      );
      if (cachedScheme != null) {
        _iconDerivedColorScheme = cachedScheme;
        _iconSchemeCacheKey = iconSchemeCacheKey;
      } else if (_iconSchemeCacheKey != iconSchemeCacheKey &&
          _iconSchemeLoadingForKey != iconSchemeCacheKey &&
          _iconSchemeFailedCacheKey != iconSchemeCacheKey) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _startIconSchemeLoadIfNeeded(iconBytes, iconSchemeCacheKey);
        });
      }
    } else {
      if (_iconDerivedColorScheme != null ||
          _iconSchemeCacheKey != null ||
          _iconSchemeLoadingForKey != null ||
          _iconSchemeFailedCacheKey != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _iconDerivedColorScheme = null;
            _iconSchemeCacheKey = null;
            _iconSchemeLoadingForKey = null;
            _iconSchemeFailedCacheKey = null;
          });
        });
      }
    }

    final ThemeData parentThemeForPage = Theme.of(context);
    final bool applyIconDerivedPageTheming =
        useIconPageColors && _iconDerivedColorScheme != null;
    final ColorScheme themedPageColorScheme = !applyIconDerivedPageTheming
        ? parentThemeForPage.colorScheme
        : darkenIconPageSchemeInDarkMode(
            appPageSurfacesWithVisibleAccent(_iconDerivedColorScheme!),
          );
    final bool applyBlackPageTheme = settingsProvider.blackThemeActive;
    final ColorScheme pageColorSchemeForPage = applyBlackPageTheme
        ? themedPageColorScheme.withPureBlackBackgrounds()
        : themedPageColorScheme;
    final ColorScheme sharedPageBackgroundColorScheme = pageColorSchemeForPage;
    // ThemeData.copyWith() is expensive — cache it and recompute only when the
    // icon scheme, parent brightness, or active black state actually changes.
    final String pageThemeKey =
        '${_iconSchemeCacheKey ?? "none"}_${themeBrightness.name}_${applyBlackPageTheme ? "black" : "standard"}';
    if (_cachedPageThemeKey != pageThemeKey || _cachedPageTheme == null) {
      _cachedPageThemeKey = pageThemeKey;
      _cachedPageTheme = buildAppPageThemedData(
        parentThemeForPage,
        pageColorSchemeForPage,
      );
    }
    final ThemeData pageThemeForPage = _cachedPageTheme!;

    if (!_scheduledDetailPageRefresh &&
        app != null &&
        settingsProvider.checkUpdateOnDetailPage &&
        app.app.additionalSettings['onDemandOnly'] != true &&
        !areDownloadsRunning &&
        appsProvider.tryBeginDetailPageAutoCheck(
          appId: app.listingKey,
          now: DateTime.now(),
          cooldown: _detailPageAutoCheckCooldown,
          lastUpdateCheckAt: app.app.lastUpdateCheck,
        )) {
      _scheduledDetailPageRefresh = true;
      final String refreshAppId = app.listingKey;
      _pendingDetailPageAutoCheckAppId = refreshAppId;
      _pendingDetailPageAutoCheckAppsProvider = appsProvider;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.appId != refreshAppId) {
          appsProvider.finishDetailPageAutoCheck(refreshAppId);
          _pendingDetailPageAutoCheckAppId = null;
          _pendingDetailPageAutoCheckAppsProvider = null;
          return;
        }
        // Let the push transition start before network + notifyListeners churn.
        _detailPageAutoCheckDelayTimer = Timer(
          const Duration(milliseconds: 750),
          () => _startScheduledDetailPageAutoCheck(refreshAppId, appsProvider),
        );
      });
    }
    final trackOnly = app?.app.additionalSettings['trackOnly'] == true;

    // Defaults to true when there is no app yet, as the old inline chain did
    // (its `== null` arm matched a null app).
    final bool isVersionDetectionStandard =
        app?.app.usesStandardVersionDetection ?? true;

    if (showAppWebpageFinal) {
      _ensureWebViewController();
      if (app != null && !_webViewUrlLoaded) {
        _webViewUrlLoaded = true;
        _webViewLoading = true;
        final String webUrl = app.app.url;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _webViewController?.loadRequest(Uri.parse(webUrl));
          }
        });
      }
      return Theme(
        data: pageThemeForPage,
        child: Builder(
          builder: (BuildContext themedPageContext) {
            return _buildSourceWebpageScaffold(
              themedPageContext: themedPageContext,
              pageTheme: pageThemeForPage,
              pageColorScheme: pageColorSchemeForPage,
              settingsProvider: settingsProvider,
              app: app,
              persistentPageError: effectivePersistentPageError,
              persistentPageErrorTitle: effectivePersistentPageErrorTitle,
            );
          },
        ),
      );
    }

    String formatDateTimeToMinute(DateTime dateTime) {
      final local = dateTime.toLocal();
      final year = local.year.toString();
      final month = local.month.toString().padLeft(2, '0');
      final day = local.day.toString().padLeft(2, '0');
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '$year-$month-$day $hour:$minute';
    }

    String formatCheckedAtTimestamp(BuildContext ctx, DateTime dateTime) {
      final local = dateTime.toLocal();
      final materialLocalizations = MaterialLocalizations.of(ctx);
      final date = formatDeviceOrderedNumericDate(ctx, local);
      final time = materialLocalizations.formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat:
            _uses24HourFormat ?? MediaQuery.alwaysUse24HourFormatOf(ctx),
      );
      return '$date $time';
    }

    Widget detailRow(
      BuildContext ctx,
      String label,
      String value, {
      TextStyle? valueStyle,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: valueStyle ?? Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    Widget versionRow(
      BuildContext ctx,
      String label,
      String value, {
      bool pseudoVersion = false,
      bool versionCode = false,
      String? osInstalledVersion,
    }) {
      Widget versionChip(String text) {
        final ColorScheme scheme = Theme.of(ctx).colorScheme;
        return AppSmoothRoundedSurface(
          backgroundColor: Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.12),
            scheme.surfaceContainerHighest,
          ),
          borderColor: null,
          borderRadius: 999,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            text,
            style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: _versionRowLabelWidth,
              child: Text(
                label,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  SelectableText(
                    value,
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      fontStyle: pseudoVersion ? FontStyle.italic : null,
                    ),
                  ),
                  if (pseudoVersion) versionChip(tr('pseudoVersion')),
                  if (versionCode) versionChip(tr('versionCode')),
                  if (pseudoVersion &&
                      osInstalledVersion != null &&
                      osInstalledVersion.isNotEmpty)
                    SelectableText(
                      '${tr('osInstalledVersion')}: $osInstalledVersion',
                      style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget versionLatestRow(
      BuildContext ctx,
      String value, {
      required bool skipActive,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: _versionRowLabelWidth,
              child: Text(
                tr('latest'),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  SelectableText(
                    value,
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  if (skipActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        tr('latestVersionSkipped'),
                        style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget versionRowWithLink(
      BuildContext ctx,
      String label,
      String value,
      VoidCallback? onTap,
    ) {
      final linkStyle = Theme.of(ctx).textTheme.bodySmall?.copyWith(
        color: Theme.of(ctx).colorScheme.primary,
        decoration: onTap != null ? TextDecoration.underline : null,
        fontWeight: FontWeight.w500,
        fontSize: 14,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: _versionRowLabelWidth,
              child: Text(
                label,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: onTap,
                child: Text(value, style: linkStyle),
              ),
            ),
          ],
        ),
      );
    }

    Widget buildAboutBlock(BuildContext themeContext) {
      if (app?.app.additionalSettings['about'] is! String ||
          (app?.app.additionalSettings['about'] as String).isEmpty) {
        return const SizedBox.shrink();
      }
      final String aboutRaw = app?.app.additionalSettings['about'] as String;
      // GFM collapses single newlines; two spaces before newline = hard break so
      // multi-line notes match what was typed in the editor.
      final String aboutForMarkdown = aboutRaw
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .replaceAll('\n', '  \n');
      return GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: aboutRaw));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr('copiedToClipboard')),
              duration: const Duration(seconds: 4),
            ),
          );
        },
        child: Markdown(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          styleSheet: MarkdownStyleSheet(
            blockquoteDecoration: BoxDecoration(
              color: Theme.of(themeContext).cardColor,
            ),
            textAlign: WrapAlignment.center,
          ),
          data: aboutForMarkdown,
          onTapLink: (text, href, title) {
            if (href != null) {
              launchUrlString(href, mode: LaunchMode.externalApplication);
            }
          },
          extensionSet: md.ExtensionSet(
            md.ExtensionSet.gitHubFlavored.blockSyntaxes,
            [
              md.EmojiSyntax(),
              ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
            ],
          ),
        ),
      );
    }

    Future<dynamic> showMarkUpdatedDialog() {
      return _showPageDialog(
        hostContext: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            title: Text(tr('alreadyUpToDateQuestion')),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: Text(tr('no')),
              ),
              TextButton(
                onPressed: () {
                  hapticSelection();
                  App? updatedApp = app?.app.deepCopy();
                  if (updatedApp != null) {
                    updatedApp = acknowledgeSourceRelease(updatedApp);
                    updatedApp.additionalSettings.remove(
                      'skippedLatestVersion',
                    );
                    updatedApp.additionalSettings.remove(installStatusResetKey);
                    appsProvider.saveApps(
                      [updatedApp],
                      attemptToCorrectInstallStatus: false,
                      updateInstalledInfo: false,
                    );
                  }
                  Navigator.of(context).pop();
                },
                child: Text(tr('yesMarkUpdated')),
              ),
            ],
          );
        },
      );
    }

    Widget getBottomCenterActions(
      BuildContext themeContext,
      AppInMemory? app, {
      required AppSource? source,
      required bool trackOnly,
      required bool isVersionDetectionStandard,
      required bool areDownloadsRunning,
    }) {
      final ThemeData actionTheme = Theme.of(themeContext);
      const double expressiveRadius = 26;
      const EdgeInsets expressivePadding = EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      );
      const Size expressiveMinimumSize = Size(48, 52);
      final RoundedRectangleBorder expressiveShape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(expressiveRadius),
      );
      const Size expressiveMaximumSize = Size(double.infinity, 52);
      final ButtonStyle expressiveFilled = FilledButton.styleFrom(
        minimumSize: expressiveMinimumSize,
        maximumSize: expressiveMaximumSize,
        padding: expressivePadding,
        shape: expressiveShape,
        elevation: 1,
        shadowColor: actionTheme.colorScheme.shadow,
        backgroundColor: actionTheme.colorScheme.primary,
        foregroundColor: actionTheme.colorScheme.onPrimary,
        disabledBackgroundColor: actionTheme.colorScheme.onSurface.withAlpha(
          31,
        ),
        disabledForegroundColor: actionTheme.colorScheme.onSurface.withAlpha(
          97,
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

      if (_editMode) {
        return const SizedBox.shrink();
      }

      // Update label shows size when known from the source metadata.
      final int? knownApkSizeBytes = app?.app.apkSizeBytes;
      // Appends "· 43 MB" to install/update labels when size is known.
      String sizeAnnotated(String base) {
        if (knownApkSizeBytes == null) {
          return base;
        }
        return '$base · ${formatBytesForDisplay(knownApkSizeBytes)}';
      }

      final String updateLabel = sizeAnnotated(tr('update'));
      final String installLabel = sizeAnnotated(tr('install'));
      final String markInstalledLabel = sizeAnnotated(tr('markInstalled'));
      final String markUpdatedLabel = sizeAnnotated(tr('markUpdated'));

      // #2 — inline progress button replaces the action button while
      // downloading/installing. The live bar is its own widget so the ~4 Hz
      // progress ticks don't rebuild the whole page (see [_DownloadProgressAction]
      // and the note in [appPageAppsRebuildToken]).
      if (app?.downloadProgress != null) {
        return _DownloadProgressAction(
          appId: app!.listingKey,
          actionTheme: actionTheme,
          expressiveRadius: expressiveRadius,
        );
      }

      // Opening a track-only release, acknowledging it, or skipping it does
      // not use the download queue. Only this page's refresh blocks them.
      final bool actionBlocked = app == null || updating;
      final bool buildVerificationBlocked =
          !trackOnly &&
          app != null &&
          source != null &&
          buildVerificationEnforcementBlocksInstall(
            app.app,
            source,
            settingsProvider,
          );
      final String? buildVerificationBlockedMessage = buildVerificationBlocked
          ? buildVerificationEnforcedBlockedMessage(
              app.app,
              source,
              settingsProvider,
            )
          : null;
      final bool installActionBlocked =
          actionBlocked ||
          (!trackOnly && areDownloadsRunning) ||
          buildVerificationBlocked;
      final installedVersion = app?.app.installedVersion;
      final bool installedVersionIsNull = installedVersion == null;
      final bool actionableUpdate =
          app != null && appHasActionableUpdate(app.app);
      final bool uncertainUpdate =
          app != null && versionOrderUncertainUpdate(app.app);
      final bool skipActive =
          app != null && isSkipActiveForCurrentLatest(app.app);
      final bool trackOnlyHasVersionUpdate =
          trackOnly && (actionableUpdate || uncertainUpdate);
      final bool nonStandardVersionBehind =
          !trackOnly &&
          !isVersionDetectionStandard &&
          (actionableUpdate || uncertainUpdate);
      final bool hasResetStatus =
          installedVersionIsNull &&
          app != null &&
          (app.app.additionalSettings[installStatusResetKey] != null ||
              app.installedInfo != null);
      // Non-tracked installs with unknown order keep the manual Update/Skip
      // choice. Track-only apps can always acknowledge a source release.
      final bool uncertainOnly =
          uncertainUpdate &&
          versionDecisionForApp(app.app).relation !=
              VersionRelation.sourceChanged;
      final bool primaryActionEnabled =
          !installActionBlocked &&
          (installedVersionIsNull ||
              ((actionableUpdate || uncertainUpdate) && !skipActive));
      final bool trackedFromApkMirror =
          Uri.tryParse(app?.app.url ?? '')?.host.contains('apkmirror.com') ==
          true;
      if (trackedFromApkMirror) {
        _logApkMirrorSizeDebugFromAppPage(
          'button id=${app?.app.id ?? "<null>"} url=${app?.app.url ?? "<null>"} size=${knownApkSizeBytes?.toString() ?? "<null>"} trackOnly=$trackOnly installed=${installedVersion ?? "<null>"} latest=${app?.app.latestVersion ?? "<null>"} actionable=$actionableUpdate uncertain=$uncertainUpdate skip=$skipActive trackOnlyHasVersionUpdate=$trackOnlyHasVersionUpdate installedVersionIsNull=$installedVersionIsNull primaryActionEnabled=$primaryActionEnabled updateLabel="$updateLabel" markUpdatedLabel="$markUpdatedLabel"',
        );
      }

      Widget wrapPrimaryBarWithSkip(Widget primaryBar) {
        final App? appForSkip = app?.app;
        if (appForSkip == null || appForSkip.installedVersion == null) {
          return primaryBar;
        }
        final bool showSkipToggle =
            appHasActionableUpdate(appForSkip) ||
            versionOrderUncertainUpdate(appForSkip) ||
            isSkipActiveForCurrentLatest(appForSkip);
        if (!showSkipToggle) {
          return primaryBar;
        }
        Future<void> toggleSkipVersion() async {
          if (app == null) return;
          final App copy = app.app.deepCopy();
          if (isSkipActiveForCurrentLatest(copy)) {
            copy.additionalSettings.remove('skippedLatestVersion');
          } else {
            copy.additionalSettings['skippedLatestVersion'] =
                copy.latestVersion;
          }
          await appsProvider.saveApps([copy], updateInstalledInfo: false);
          if (mounted) {
            setState(() {});
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            primaryBar,
            Center(
              child: TextButton(
                onPressed: actionBlocked ? null : () => toggleSkipVersion(),
                child: Text(
                  isSkipActiveForCurrentLatest(appForSkip)
                      ? tr('unskipVersion')
                      : tr('skipVersion'),
                ),
              ),
            ),
          ],
        );
      }

      Future<void> runInstallOrMarkUpdated() async {
        if (buildVerificationBlocked) {
          _showPageError(
            ObtainiumError(buildVerificationBlockedMessage!),
            title: tr('errorInstallingUpdate'),
          );
          return;
        }
        try {
          final successMessage = installedVersionIsNull
              ? tr('installed')
              : tr('appsUpdated');
          hapticHeavyImpact();
          final res = await appsProvider.downloadAndInstallLatestApps(
            app != null ? [app.listingKey] : [],
            themeContext,
            dialogTheme: _cachedPageTheme,
          );
          if (res.isNotEmpty && !trackOnly && themeContext.mounted) {
            _showPageMessage(successMessage);
          }
        } catch (e) {
          if (themeContext.mounted) {
            _showPageError(e, title: tr('errorInstallingUpdate'));
          }
        }
      }

      void openTrackOnlyReleasePage() {
        if (app == null) return;
        launchUrlString(
          trackOnlyDownloadPageUrl(app.app),
          mode: LaunchMode.externalApplication,
        );
      }

      if (hasResetStatus) {
        const double dualButtonBarHeight = 52;
        final bool markUpdatedActionBlocked =
            updating || app.downloadProgress != null;
        return wrapPrimaryBarWithSkip(
          SizedBox(
            height: dualButtonBarHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: installActionBlocked
                        ? null
                        : runInstallOrMarkUpdated,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        installLabel,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: markUpdatedActionBlocked
                        ? null
                        : showMarkUpdatedDialog,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        tr('markUpdated'),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      if (trackOnlyHasVersionUpdate) {
        // Outer Row is in a Column with unbounded max height. A nested Row of
        // two horizontal Expanded children + stretch can get infinite cross-axis
        // extent and break layout (blank page). Fixed height bounds the inner Row.
        const double dualButtonBarHeight = 52;
        return wrapPrimaryBarWithSkip(
          SizedBox(
            height: dualButtonBarHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: installActionBlocked || skipActive
                        ? null
                        : openTrackOnlyReleasePage,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        updateLabel,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: installActionBlocked
                        ? null
                        : runInstallOrMarkUpdated,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        tr('markUpdated'),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      if (nonStandardVersionBehind && !uncertainOnly) {
        const double dualButtonBarHeight = 52;
        final bool markUpdatedActionBlocked =
            updating || app.downloadProgress != null;
        return wrapPrimaryBarWithSkip(
          SizedBox(
            height: dualButtonBarHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: installActionBlocked || skipActive
                        ? null
                        : runInstallOrMarkUpdated,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        updateLabel,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: expressiveFilled,
                    onPressed: markUpdatedActionBlocked
                        ? null
                        : showMarkUpdatedDialog,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: Text(
                        tr('markUpdated'),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      if (nonStandardVersionBehind && uncertainOnly) {
        return wrapPrimaryBarWithSkip(
          FilledButton(
            style: expressiveFilled,
            onPressed: installActionBlocked || skipActive
                ? null
                : runInstallOrMarkUpdated,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Text(
                updateLabel,
                maxLines: 1,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }

      final Widget singlePrimaryButton = FilledButton(
        style: expressiveFilled,
        onPressed: primaryActionEnabled ? runInstallOrMarkUpdated : null,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Text(
            installedVersionIsNull
                ? (!trackOnly ? installLabel : markInstalledLabel)
                : (!trackOnly ? updateLabel : markUpdatedLabel),
            maxLines: 1,
            textAlign: TextAlign.center,
          ),
        ),
      );
      return wrapPrimaryBarWithSkip(
        buildVerificationBlocked
            ? Tooltip(
                message: buildVerificationBlockedMessage!,
                child: singlePrimaryButton,
              )
            : skipActive
            ? Tooltip(
                message: tr('updateDisabledWhileVersionSkipped'),
                child: singlePrimaryButton,
              )
            : singlePrimaryButton,
      );
    }

    Column getInfoColumn(
      BuildContext pageThemeContext,
      AppInMemory? app, {
      bool small = false,
    }) {
      final ThemeData pageTheme = Theme.of(pageThemeContext);
      AppSource? source;
      if (app != null) {
        final String sourceKey =
            '${app.app.url} ${app.app.overrideSource ?? ''}';
        if (sourceKey != _cachedSourceKey) {
          _cachedSource = _sourceProvider.getSource(
            app.app.url,
            overrideSource: app.app.overrideSource,
          );
          _cachedSourceKey = sourceKey;
        }
        source = _cachedSource;
      }
      final bool trackOnly = app?.app.additionalSettings['trackOnly'] == true;
      final bool isVersionDetectionStandard =
          app?.app.additionalSettings['versionDetection'] == 'auto' ||
          app?.app.additionalSettings['versionDetection'] == 'standard' ||
          app?.app.additionalSettings['versionDetection'] == 'versionCode' ||
          app?.app.additionalSettings['versionDetection'] == true ||
          app?.app.additionalSettings['versionDetection'] == null;
      final bool areDownloadsRunning = appsProvider.areDownloadsRunning();
      final undeterminedTrackOnlyInstalled =
          trackOnly &&
          app?.app.additionalSettings['trackOnlyUndeterminedInstalledVersion'] ==
              true &&
          app?.app.installedVersion == null;
      final bool installed = app?.app.installedVersion != null;
      final String latestVerStr = app?.app.latestVersion ?? '';
      final versionVerdict = appVersionVerdictForDisplay(app?.app);
      final changeLogFn = app != null
          ? getChangeLogFn(pageThemeContext, app.app)
          : null;

      final lastUpdateCheckValue = app?.app.lastUpdateCheck == null
          ? tr('never')
          : formatCheckedAtTimestamp(
              pageThemeContext,
              app!.app.lastUpdateCheck!,
            );

      Future<void> markTrackOnlyAsNotInstalledOnDevice() async {
        if (app == null) return;
        setState(() {
          updating = true;
        });
        try {
          final App appToSave = app.app.deepCopy();
          appToSave
                  .additionalSettings['trackOnlyUndeterminedInstalledVersion'] =
              false;
          await appsProvider.saveApps([appToSave], updateInstalledInfo: false);
        } catch (err) {
          if (context.mounted) {
            _showPageError(err);
          }
        } finally {
          if (context.mounted) {
            setState(() {
              updating = false;
            });
          }
        }
      }

      Future<void> openFixTrackOnlyPackageIdSheet() async {
        if (app == null) return;
        String packageIdInput = app.app.id;
        final ThemeData? pageTheme = _cachedPageTheme;
        final submittedPackageId = await showAppModalSheet<String>(
          context: context,
          backgroundColor: pageTheme?.colorScheme.surface,
          builder: (BuildContext sheetContext) {
            final Widget sheet = Builder(
              builder: (BuildContext themedContext) {
                final ThemeData theme = Theme.of(themedContext);
                return AppSheetContent(
                  children: [
                    Text(
                      tr('fixPackageId'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr('fixPackageIdExplanation'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      initialValue: packageIdInput,
                      onChanged: (String value) => packageIdInput = value,
                      decoration: appPageOutlinedInputDecoration(
                        themedContext,
                        labelText: tr('package'),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: updating
                              ? null
                              : () => Navigator.pop(sheetContext),
                          child: Text(tr('cancel')),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: updating
                              ? null
                              : () => Navigator.pop(
                                  sheetContext,
                                  packageIdInput.trim(),
                                ),
                          child: Text(tr('ok')),
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
            return pageTheme == null
                ? sheet
                : Theme(data: pageTheme, child: sheet);
          },
        );
        if (!context.mounted) return;
        if (submittedPackageId == null || submittedPackageId.isEmpty) return;
        final AppInMemory? listingBeforeRename =
            appsProvider.apps[widget.appId];
        if (listingBeforeRename == null ||
            submittedPackageId == listingBeforeRename.app.id) {
          return;
        }
        // A listing keyed by its package ID moves key along with the rename;
        // one carrying its own listing ID (a package tracked from two stores)
        // keeps the key it already has.
        final String renamedListingKey =
            listingBeforeRename.app.listingId ?? submittedPackageId;
        try {
          setState(() {
            updating = true;
          });
          await appsProvider.changeTrackOnlyAppPackageId(
            widget.appId,
            submittedPackageId,
          );
          if (!context.mounted) return;
          await appsProvider.checkUpdate(renamedListingKey);
          if (!context.mounted) return;
          unawaited(
            Navigator.of(context).pushReplacement(
              heroFriendlyAppPageRoute<void>(
                (ctx) => AppPage(appId: renamedListingKey),
              ),
            ),
          );
        } catch (err) {
          if (context.mounted) {
            _showPageError(err);
          }
        } finally {
          if (context.mounted) {
            setState(() {
              updating = false;
            });
          }
        }
      }

      // #1 — verdict stripe (A: trailing icon, B: card watermark).
      Widget? verdictStripe;
      Widget? verdictWatermark;
      final double verdictStripeTopRadius = settingsProvider
          .cardCornerRadiusFor(SettingsProvider.baseCardRadius);
      if (!undeterminedTrackOnlyInstalled) {
        Color? stripeColor;
        Color? stripeTextColor;
        String? stripeLabel;
        IconData? verdictIcon;
        if (versionVerdict == AppVersionDisplayVerdict.effectivelyEqual) {
          stripeColor = pageTheme.colorScheme.surfaceContainerHigh;
          stripeTextColor = pageTheme.colorScheme.onSurfaceVariant;
          stripeLabel = tr(
            versionDecisionTitleKey(versionDecisionForApp(app!.app)),
          );
          verdictIcon = Icons.balance;
        } else if (versionVerdict == AppVersionDisplayVerdict.uncertain) {
          stripeColor = pageTheme.colorScheme.surfaceContainerHighest;
          stripeTextColor = pageTheme.colorScheme.onSurfaceVariant;
          stripeLabel = tr(
            versionDecisionTitleKey(versionDecisionForApp(app!.app)),
          );
          verdictIcon = Icons.help_outline_rounded;
        } else if (versionVerdict == AppVersionDisplayVerdict.newerOnDevice) {
          stripeColor = pageTheme.colorScheme.primaryContainer;
          stripeTextColor = pageTheme.colorScheme.onPrimaryContainer;
          stripeLabel = tr('newerOnDevice');
          verdictIcon = Icons.phone_android_rounded;
        } else if (versionVerdict == AppVersionDisplayVerdict.sameVersion) {
          stripeColor = pageTheme.brightness == Brightness.dark
              ? const Color(0xFF2E7D32).withAlpha(60)
              : const Color(0xFFC8E6C9);
          stripeTextColor = pageTheme.brightness == Brightness.dark
              ? const Color(0xFFA5D6A7)
              : const Color(0xFF1B5E20);
          stripeLabel = tr('sameVersion');
          verdictIcon = Icons.verified_rounded;
        } else if (installed) {
          stripeColor = pageTheme.colorScheme.secondaryContainer;
          stripeTextColor = pageTheme.colorScheme.onSecondaryContainer;
          stripeLabel = tr('updateAvailable');
          verdictIcon = Icons.new_releases_rounded;
        } else if (!installed) {
          stripeColor = pageTheme.colorScheme.surfaceContainerHighest;
          stripeTextColor = pageTheme.colorScheme.onSurfaceVariant;
          stripeLabel = tr('notInstalled');
          verdictIcon = Icons.install_mobile_rounded;
        }
        if (stripeLabel != null && verdictIcon != null) {
          // A — trailing icon in the stripe.
          // Match the parent card's top corners so no card fill bleeds through.
          verdictStripe = Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: stripeColor,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(verdictStripeTopRadius),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        stripeLabel,
                        style: pageTheme.textTheme.labelMedium?.copyWith(
                          color: stripeTextColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (app != null &&
                          (versionVerdict ==
                                  AppVersionDisplayVerdict.uncertain ||
                              versionDecisionForApp(app.app).reason ==
                                  'sourceCommitAncestry'))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            tr(
                              versionDecisionDetailKey(
                                versionDecisionForApp(app.app),
                              ),
                            ),
                            style: pageTheme.textTheme.bodySmall?.copyWith(
                              color: stripeTextColor?.withAlpha(210),
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(verdictIcon, size: 15, color: stripeTextColor),
              ],
            ),
          );
          // B — large faded watermark at bottom-right of the card body.
          verdictWatermark = Icon(
            verdictIcon,
            size: 52,
            color: stripeTextColor?.withAlpha(28),
          );
        }
      }

      final Widget lastCheckedHeader = Text(
        tr('lastUpdateCheckX', args: [lastUpdateCheckValue]),
        maxLines: 1,
        softWrap: false,
        textAlign: TextAlign.right,
        style: pageTheme.textTheme.labelSmall?.copyWith(
          color: pageTheme.colorScheme.onSurfaceVariant.withAlpha(130),
          fontSize: 11,
        ),
      );

      final versionCardChildren = <Widget>[];
      if (undeterminedTrackOnlyInstalled) {
        versionCardChildren.add(
          versionRow(pageThemeContext, tr('installed'), tr('unknown')),
        );
        versionCardChildren.add(
          versionRow(
            pageThemeContext,
            tr('latest'),
            app?.app.latestVersion ?? '-',
          ),
        );
        if (changeLogFn != null || app?.app.releaseDate != null) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('changelog'),
              app?.app.releaseDate == null
                  ? tr('changes')
                  : formatDateTimeToMinute(app!.app.releaseDate!),
              changeLogFn,
            ),
          );
        }
        if ((app?.app.apkUrls.length ?? 0) > 0) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('assets'),
              app!.app.apkUrls.length == 1
                  ? app.app.apkUrls[0].key
                  : plural('apk', app.app.apkUrls.length),
              updating
                  ? null
                  : () async {
                      try {
                        await appsProvider.downloadAppAssets([
                          app.listingKey,
                        ], dialogTheme: pageTheme);
                      } catch (e) {
                        if (!context.mounted) return;
                        _showPageError(e, title: tr('errorDownloadingAssets'));
                      }
                    },
            ),
          );
        }
      } else {
        if (installed) {
          versionCardChildren.add(
            versionRow(
              pageThemeContext,
              tr('installed'),
              app?.app.installedVersion ?? '',
              pseudoVersion:
                  app != null && isInstalledVersionPseudoForDisplay(app),
              versionCode: app != null && app.app.usesVersionCodeAsOsVersion,
              osInstalledVersion: app == null
                  ? null
                  : _realOsInstalledVersion(app),
            ),
          );
        } else {
          versionCardChildren.add(
            versionRow(pageThemeContext, tr('installed'), tr('none')),
          );
        }
        versionCardChildren.add(
          versionLatestRow(
            pageThemeContext,
            latestVerStr.isEmpty ? '-' : latestVerStr,
            skipActive: app != null && isSkipActiveForCurrentLatest(app.app),
          ),
        );
        if (changeLogFn != null || app?.app.releaseDate != null) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('changelog'),
              app?.app.releaseDate == null
                  ? tr('changes')
                  : formatDateTimeToMinute(app!.app.releaseDate!),
              changeLogFn,
            ),
          );
        }
        if ((app?.app.apkUrls.length ?? 0) > 0) {
          versionCardChildren.add(
            versionRowWithLink(
              pageThemeContext,
              tr('assets'),
              app!.app.apkUrls.length == 1
                  ? app.app.apkUrls[0].key
                  : plural('apk', app.app.apkUrls.length),
              updating
                  ? null
                  : () async {
                      try {
                        await appsProvider.downloadAppAssets([
                          app.listingKey,
                        ], dialogTheme: pageTheme);
                      } catch (e) {
                        if (!context.mounted) return;
                        _showPageError(e, title: tr('errorDownloadingAssets'));
                      }
                    },
            ),
          );
        }
      }

      final bool freezeSecurityCardDuringSwap =
          _swappingTrackedSource && _swapSecurityAppSnapshot != null;
      final App? securityApp = freezeSecurityCardDuringSwap
          ? _swapSecurityAppSnapshot
          : app?.app;
      final AppSource? securitySource = freezeSecurityCardDuringSwap
          ? _swapSecuritySourceSnapshot
          : source;
      final List<String> securityCertificateHashes =
          freezeSecurityCardDuringSwap &&
              _swapSecurityCertificateHashesSnapshot != null
          ? _swapSecurityCertificateHashesSnapshot!
          : loadedCertificateHashes;
      final bool securityHasMultipleSigners =
          freezeSecurityCardDuringSwap &&
              _swapSecurityHasMultipleSignersSnapshot != null
          ? _swapSecurityHasMultipleSignersSnapshot!
          : app?.hasMultipleSigners == true;

      final bool reproducibleBuildExpected =
          securitySource != null &&
          reproducibleBuildVerificationApplies(securitySource);
      final String? reproducibleBuildStatus =
          securityApp?.latestReproducibleStatus ??
          (securityApp?.latestIsReproducible != null
              ? reproducibleBuildStatusFromBool(
                  securityApp!.latestIsReproducible,
                )
              : null);
      final bool reproducibleBuildVerified =
          reproducibleBuildExpected &&
          reproducibleBuildStatus == reproducibleBuildStatusVerified;
      final bool reproducibleBuildNotReproducible =
          reproducibleBuildExpected &&
          reproducibleBuildStatus == reproducibleBuildStatusNotReproducible;
      final bool reproducibleBuildNoData =
          reproducibleBuildExpected &&
          reproducibleBuildStatus == reproducibleBuildStatusNoData;
      final bool reproducibleBuildUnknown =
          reproducibleBuildExpected &&
          (reproducibleBuildStatus == reproducibleBuildStatusError ||
              reproducibleBuildStatus == null);
      final bool reproducibleBuildBlocked =
          securityApp != null &&
          securitySource != null &&
          reproducibleBuildEnforcementBlocksInstall(
            securityApp,
            securitySource,
          );
      final bool reproducibleBuildHasDisplayStatus =
          reproducibleBuildVerified ||
          reproducibleBuildNotReproducible ||
          reproducibleBuildNoData ||
          reproducibleBuildUnknown;
      final bool githubAttestationExpected =
          securitySource is GitHub &&
          securitySource.shouldVerifyAttestations(
            securityApp?.additionalSettings ?? <String, dynamic>{},
            settingsProvider,
          );
      final String? githubAttestationStatus =
          securityApp?.latestAttestationStatus;
      final bool githubAttestationBlocked =
          securityApp != null &&
          securitySource != null &&
          githubAttestationEnforcementBlocksInstall(
            securityApp,
            securitySource,
            settingsProvider,
          );
      final bool githubAttestationVerified =
          githubAttestationExpected &&
          githubAttestationStatus == githubAttestationStatusVerified;
      final bool githubAttestationUnsupported =
          githubAttestationExpected &&
          githubAttestationStatus == githubAttestationStatusUnsupported;
      final bool githubAttestationCantCheck =
          githubAttestationExpected &&
          (githubAttestationStatus == githubAttestationStatusError ||
              githubAttestationStatus == null);
      final bool githubAttestationHasStatus =
          githubAttestationVerified ||
          githubAttestationUnsupported ||
          githubAttestationCantCheck;
      final String? malwareScanStatus = securityApp?.latestMalwareScanStatus;
      final bool malwareScanFlagged =
          malwareScanStatus == malwareScanStatusFlagged;
      final bool malwareScanError = malwareScanStatus == malwareScanStatusError;
      final bool malwareScanClean = malwareScanStatus == malwareScanStatusClean;
      final bool malwareScanHasStatus =
          malwareScanFlagged || malwareScanError || malwareScanClean;
      final bool reproducibleBuildUsesErrorColors =
          reproducibleBuildBlocked && reproducibleBuildNotReproducible;
      final Color reproducibleBuildProblemContainerColor =
          reproducibleBuildUnknown
          ? Colors.orange.withValues(alpha: 0.16)
          : reproducibleBuildUsesErrorColors
          ? Theme.of(
              pageThemeContext,
            ).colorScheme.errorContainer.withValues(alpha: 0.55)
          : Theme.of(
              pageThemeContext,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.75);
      final Color reproducibleBuildProblemBorderColor = reproducibleBuildUnknown
          ? Colors.orange.withValues(alpha: 0.55)
          : reproducibleBuildUsesErrorColors
          ? Theme.of(pageThemeContext).colorScheme.error.withValues(alpha: 0.55)
          : Theme.of(
              pageThemeContext,
            ).colorScheme.outline.withValues(alpha: 0.45);
      final Color reproducibleBuildProblemContentColor =
          reproducibleBuildUnknown
          ? Colors.orange.shade800
          : reproducibleBuildUsesErrorColors
          ? Theme.of(pageThemeContext).colorScheme.onErrorContainer
          : Theme.of(pageThemeContext).colorScheme.onSurfaceVariant;
      Widget statusBadge({
        required Color backgroundColor,
        required Color? borderColor,
        required Color contentColor,
        required IconData icon,
        required String label,
        VoidCallback? onTap,
        String? tooltip,
      }) {
        final Color resolvedBackgroundColor = borderColor == null
            ? backgroundColor
            : Color.alphaBlend(
                borderColor.withValues(alpha: 0.10),
                backgroundColor,
              );
        return AppSmoothRoundedSurface(
          backgroundColor: resolvedBackgroundColor,
          borderColor: null,
          borderRadius: 8,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          onTap: onTap,
          tooltip: tooltip,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: contentColor),
              const SizedBox(width: 4),
              Text(
                label,
                style: Theme.of(pageThemeContext).textTheme.labelSmall
                    ?.copyWith(
                      color: contentColor,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        );
      }

      final securityCardChildren = <Widget>[];
      if (securityApp != null &&
          (reproducibleBuildHasDisplayStatus ||
              githubAttestationHasStatus ||
              githubAttestationBlocked ||
              malwareScanHasStatus)) {
        securityCardChildren.add(
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (reproducibleBuildVerified)
                statusBadge(
                  backgroundColor: Colors.green.withValues(alpha: 0.15),
                  borderColor: Colors.green.withValues(alpha: 0.5),
                  contentColor: Colors.green,
                  icon: Icons.verified_outlined,
                  label: tr('reproducibleBuild'),
                ),
              if (githubAttestationVerified)
                statusBadge(
                  backgroundColor: Colors.blue.withValues(alpha: 0.15),
                  borderColor: Colors.blue.withValues(alpha: 0.5),
                  contentColor: Colors.blue,
                  icon: Icons.shield_outlined,
                  label: tr('verifiedBuild'),
                ),
              if (reproducibleBuildNotReproducible ||
                  reproducibleBuildNoData ||
                  reproducibleBuildUnknown)
                statusBadge(
                  backgroundColor: reproducibleBuildProblemContainerColor,
                  borderColor: reproducibleBuildProblemBorderColor,
                  contentColor: reproducibleBuildProblemContentColor,
                  icon: reproducibleBuildUnknown
                      ? Icons.warning_amber_rounded
                      : reproducibleBuildNoData
                      ? Icons.shield_outlined
                      : Icons.gpp_bad_outlined,
                  label: tr(
                    reproducibleBuildUnknown
                        ? 'verificationCantCheck'
                        : reproducibleBuildNoData
                        ? 'verificationNoData'
                        : 'notReproducibleBuild',
                  ),
                ),
              if (githubAttestationUnsupported || githubAttestationCantCheck)
                statusBadge(
                  backgroundColor: githubAttestationCantCheck
                      ? Colors.orange.withValues(alpha: 0.16)
                      : githubAttestationUnsupported
                      ? Theme.of(pageThemeContext)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.75)
                      : Colors.transparent,
                  borderColor: githubAttestationCantCheck
                      ? Colors.orange.withValues(alpha: 0.55)
                      : githubAttestationUnsupported
                      ? Theme.of(
                          pageThemeContext,
                        ).colorScheme.outline.withValues(alpha: 0.45)
                      : null,
                  contentColor: githubAttestationCantCheck
                      ? Colors.orange.shade800
                      : Theme.of(pageThemeContext).colorScheme.onSurfaceVariant,
                  icon: githubAttestationCantCheck
                      ? Icons.warning_amber_rounded
                      : Icons.shield_outlined,
                  label: tr(
                    githubAttestationCantCheck
                        ? 'verificationCantCheck'
                        : 'unverifiedBuild',
                  ),
                ),
              if (malwareScanHasStatus)
                statusBadge(
                  backgroundColor: malwareScanFlagged
                      ? Theme.of(
                          pageThemeContext,
                        ).colorScheme.errorContainer.withValues(alpha: 0.55)
                      : malwareScanError
                      ? Colors.orange.withValues(alpha: 0.16)
                      : Colors.green.withValues(alpha: 0.15),
                  borderColor: malwareScanFlagged
                      ? Theme.of(
                          pageThemeContext,
                        ).colorScheme.error.withValues(alpha: 0.55)
                      : malwareScanError
                      ? Colors.orange.withValues(alpha: 0.55)
                      : Colors.green.withValues(alpha: 0.5),
                  contentColor: malwareScanFlagged
                      ? Theme.of(pageThemeContext).colorScheme.onErrorContainer
                      : malwareScanError
                      ? Colors.orange.shade800
                      : Colors.green,
                  icon: malwareScanFlagged
                      ? Icons.gpp_bad_outlined
                      : malwareScanError
                      ? Icons.warning_amber_rounded
                      : Icons.verified_outlined,
                  label: tr(
                    malwareScanFlagged
                        ? 'malwareScanFlaggedChip'
                        : malwareScanError
                        ? 'malwareScanErrorChip'
                        : 'malwareScanCleanChip',
                  ),
                  onTap: securityApp.latestMalwareScanReportUrl == null
                      ? null
                      : () => launchUrlString(
                          securityApp.latestMalwareScanReportUrl!,
                          mode: LaunchMode.externalApplication,
                        ),
                  tooltip: securityApp.latestMalwareScanDetail,
                ),
            ],
          ),
        );
      }

      Widget buildCertificateHashRow(
        List<String> certificateHashes,
        bool hasMultipleSigners,
      ) {
        Future<void> copyCertificateHash(String hash) async {
          await Clipboard.setData(ClipboardData(text: hash));
          if (!pageThemeContext.mounted) return;
          ScaffoldMessenger.of(pageThemeContext).showSnackBar(
            SnackBar(content: Text(tr('certificateHashCopiedToClipboard'))),
          );
        }

        String truncateHashToWidth(
          String hash,
          TextStyle style,
          double maxWidth,
        ) {
          if (!maxWidth.isFinite || maxWidth <= 0) return hash;

          bool fits(String value) {
            final painter = TextPainter(
              text: TextSpan(text: value, style: style),
              maxLines: 1,
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(pageThemeContext),
            )..layout();
            return painter.width <= maxWidth;
          }

          if (fits(hash)) return hash;

          const ellipsis = '....';
          if (!fits(ellipsis)) return ellipsis;

          var minimumVisibleCharacters = 0;
          var maximumVisibleCharacters = hash.length;
          var truncatedHash = ellipsis;
          while (minimumVisibleCharacters <= maximumVisibleCharacters) {
            final visibleCharacters =
                (minimumVisibleCharacters + maximumVisibleCharacters) ~/ 2;
            final leadingCharacters = (visibleCharacters + 1) ~/ 2;
            final trailingCharacters = visibleCharacters ~/ 2;
            final candidate =
                '${hash.substring(0, leadingCharacters)}$ellipsis'
                '${hash.substring(hash.length - trailingCharacters)}';
            if (fits(candidate)) {
              truncatedHash = candidate;
              minimumVisibleCharacters = visibleCharacters + 1;
            } else {
              maximumVisibleCharacters = visibleCharacters - 1;
            }
          }
          return truncatedHash;
        }

        final String certificateHashLabel =
            '${plural('certificateHash', certificateHashes.length)}'
            '${hasMultipleSigners ? ' (${tr('multipleSigners')})' : ''}';
        final TextStyle hashStyle =
            pageTheme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 12,
            ) ??
            const TextStyle(fontFamily: 'monospace', fontSize: 12);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                certificateHashLabel,
                style: pageTheme.textTheme.bodySmall?.copyWith(
                  color: pageTheme.colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: Column(
                spacing: 4,
                children: certificateHashes.map((hash) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPress: () =>
                              unawaited(copyCertificateHash(hash)),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return Text(
                                truncateHashToWidth(
                                  hash,
                                  hashStyle,
                                  constraints.maxWidth,
                                ),
                                maxLines: 1,
                                textDirection: TextDirection.ltr,
                                style: hashStyle,
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: tr('copyToClipboard'),
                        child: SizedBox.square(
                          dimension: 18,
                          child: InkResponse(
                            onTap: () => unawaited(copyCertificateHash(hash)),
                            radius: 10,
                            child: const Icon(Icons.copy_rounded, size: 14),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        );
      }

      if (securityCertificateHashes.isNotEmpty) {
        if (securityCardChildren.isNotEmpty) {
          securityCardChildren.add(const SizedBox(height: 16));
        }
        securityCardChildren.add(
          buildCertificateHashRow(
            securityCertificateHashes,
            securityHasMultipleSigners,
          ),
        );
      } else if (!freezeSecurityCardDuringSwap &&
          app?.installedInfo != null &&
          _signingCertificateInfoFuture != null) {
        if (securityCardChildren.isNotEmpty) {
          securityCardChildren.add(const SizedBox(height: 16));
        }
        securityCardChildren.add(
          FutureBuilder<SigningCertificateInfo?>(
            future: _signingCertificateInfoFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return SizedBox(
                  height: 64,
                  child: Center(
                    child: ExpressiveLoadingIndicator(
                      color: pageTheme.colorScheme.primary,
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                );
              }
              final SigningCertificateInfo? certificateInfo = snapshot.data;
              final List<String> certificateHashes = certificateInfo == null
                  ? const <String>[]
                  : certificateHashesFromSignatures(certificateInfo.signatures);
              if (certificateHashes.isEmpty) {
                return detailRow(
                  pageThemeContext,
                  plural('certificateHash', 1),
                  tr('none'),
                );
              }
              return buildCertificateHashRow(
                certificateHashes,
                certificateInfo!.hasMultipleSigners,
              );
            },
          ),
        );
      }

      final versionCard = _materialAppPageSectionCard(
        pageThemeContext,
        tr('version'),
        versionCardChildren,
        sectionHeaderTrailing: lastCheckedHeader,
        headerStripe: verdictStripe,
        cardWatermark: verdictWatermark,
      );
      final Widget? securityCard = securityCardChildren.isEmpty
          ? null
          : _materialAppPageSectionCard(
              pageThemeContext,
              tr('security'),
              securityCardChildren,
            );

      final bool trackOnlyUsesTemporaryPackageId =
          app?.app.additionalSettings['trackOnlyTemporaryPackageId'] == true;
      final Widget? trackOnlyInstalledErrorCard = undeterminedTrackOnlyInstalled
          ? _materialAppPageSectionCard(
              pageThemeContext,
              tr('error'),
              [
                SelectableText(
                  trackOnlyUsesTemporaryPackageId
                      ? tr('trackOnlyTempPackageIdInstalledVersion')
                      : tr('trackOnlyUndeterminedInstalledVersion'),
                  style: pageTheme.textTheme.bodySmall?.copyWith(
                    color: pageTheme.colorScheme.onErrorContainer,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: updating || app == null
                          ? null
                          : openFixTrackOnlyPackageIdSheet,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      label: Text(tr('fixPackageId')),
                    ),
                    FilledButton.tonal(
                      onPressed: updating || app == null
                          ? null
                          : markTrackOnlyAsNotInstalledOnDevice,
                      child: Text(tr('itsNotInstalled')),
                    ),
                  ],
                ),
              ],
              sectionBackgroundColor: pageTheme.colorScheme.errorContainer,
              sectionTitleColor: pageTheme.colorScheme.onErrorContainer,
            )
          : null;

      final detailsValueStyle = pageTheme.textTheme.bodySmall!.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      );
      final detailsMonoValueStyle = detailsValueStyle.copyWith(
        fontFamily: 'monospace',
      );

      final String? alternateStoresPackageId = app?.app.id;
      final String? alternateStoresTrackedUrl = app?.app.url;
      // Every other listing of this same Android package is an alternate source
      // in its own right, and its URL is known-good. Without this the row can
      // only show what a package-ID store scan can guess, which is why a
      // package tracked on both GitHub and F-Droid showed GitHub as an
      // alternate on the GitHub-derived side only - no scan can turn a package
      // ID into a GitHub repo URL.
      final Map<String, String> siblingListingUrlsByStore = <String, String>{};
      final List<AppInMemory> siblingListingsWithoutStoreSlot = <AppInMemory>[];
      if (app != null) {
        for (final AppInMemory sibling in appsProvider.apps.listingsForPackage(
          app.app.id,
        )) {
          if (sibling.listingKey == app.listingKey || sibling.app.url.isEmpty) {
            continue;
          }
          final String? slotName = _storeSlotNameForUrl(sibling.app.url);
          if (slotName == null) {
            siblingListingsWithoutStoreSlot.add(sibling);
          } else {
            siblingListingUrlsByStore[slotName] = sibling.app.url;
          }
        }
      }

      final detailsChildren = <Widget>[
        if (app?.app.id != null && app!.app.id.isNotEmpty)
          detailRow(
            pageThemeContext,
            tr('package'),
            app.app.id,
            valueStyle: detailsMonoValueStyle,
          ),
        if (app?.installedInfo != null)
          () {
            final appType = classifyAppType(app!);
            final (
              IconData typeIcon,
              Color typeColor,
              String typeLabel,
            ) = switch (appType) {
              AppTypeGroup.user => (
                Icons.person_rounded,
                Colors.green,
                tr('appTypeUser'),
              ),
              AppTypeGroup.system => (
                Icons.android_rounded,
                Colors.grey,
                tr('appTypeSystem'),
              ),
              AppTypeGroup.privileged => (
                Icons.security_rounded,
                Colors.grey.shade600,
                tr('appTypePrivileged'),
              ),
            };
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(
                      tr('appType'),
                      style: Theme.of(pageThemeContext).textTheme.bodySmall
                          ?.copyWith(
                            color: Theme.of(
                              pageThemeContext,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                    ),
                  ),
                  Icon(typeIcon, size: 14, color: typeColor),
                  const SizedBox(width: 4),
                  Text(
                    typeLabel,
                    style: Theme.of(pageThemeContext).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          }(),
        if (alternateStoresTrackedUrl != null &&
            alternateStoresTrackedUrl.isNotEmpty)
          FutureBuilder<Map<String, String>?>(
            future:
                alternateStoresPackageId == null ||
                    alternateStoresPackageId.isEmpty
                ? null
                : _storeAvailabilityCacheFuture,
            builder: (context, snapshot) {
              final storeData = snapshot.data;
              final pid = alternateStoresPackageId;
              final trackedUrl = alternateStoresTrackedUrl;
              final alternateSourceIcons = <Widget>[];
              if (pid != null && pid.isNotEmpty) {
                // Play Store: only show when confirmed present in cache.
                // Populated by _maybeCheckAndCachePlayStore on pull-to-refresh.
                final playStoreUrl = _resolveStoreUrl(
                  storeData: storeData,
                  storeName: 'PlayStore',
                  fallbackUrl: null,
                  alreadyTracked: _trackedUrlIsFromHost(
                    trackedUrl,
                    'play.google.com',
                  ),
                );
                final fdroidUrl = _resolveStoreUrl(
                  storeData: storeData,
                  storeName: 'F-Droid',
                  fallbackUrl: 'https://f-droid.org/packages/$pid/',
                  alreadyTracked: _trackedUrlIsFromHost(
                    trackedUrl,
                    'f-droid.org',
                  ),
                  siblingListingUrl: siblingListingUrlsByStore['F-Droid'],
                );
                final apkpureUrl = _resolveStoreUrl(
                  storeData: storeData,
                  storeName: 'APKPure',
                  fallbackUrl: null,
                  alreadyTracked: _trackedUrlIsFromHost(trackedUrl, 'apkpure.'),
                  siblingListingUrl: siblingListingUrlsByStore['APKPure'],
                );
                final apkmirrorUrl = _resolveStoreUrl(
                  storeData: storeData,
                  storeName: 'APKMirror',
                  fallbackUrl:
                      'https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=${Uri.encodeComponent(pid)}',
                  alreadyTracked: _trackedUrlIsFromHost(
                    trackedUrl,
                    'apkmirror.com',
                  ),
                  siblingListingUrl: siblingListingUrlsByStore['APKMirror'],
                );
                final githubUrl = _resolveStoreUrl(
                  storeData: storeData,
                  storeName: 'GitHub',
                  fallbackUrl: null,
                  alreadyTracked: _trackedUrlIsFromHost(
                    trackedUrl,
                    'github.com',
                  ),
                  siblingListingUrl: siblingListingUrlsByStore['GitHub'],
                );
                // Alternate icon order: Play Store, GitHub, F-Droid, APKPure,
                // APKMirror (tracked source is always shown first, separately).
                if (playStoreUrl != null) {
                  alternateSourceIcons.add(
                    _buildStoreSourceLaunchIcon(
                      iconContext: pageThemeContext,
                      url: playStoreUrl,
                      assetPath: StoreSourceIconPaths.playStore,
                    ),
                  );
                }
                if (githubUrl != null) {
                  alternateSourceIcons.add(
                    _buildStoreSourceLaunchIcon(
                      iconContext: pageThemeContext,
                      url: githubUrl,
                      assetPath: StoreSourceIconPaths.github,
                      swapStoreName: 'GitHub',
                    ),
                  );
                }
                if (fdroidUrl != null) {
                  alternateSourceIcons.add(
                    _buildStoreSourceLaunchIcon(
                      iconContext: pageThemeContext,
                      url: fdroidUrl,
                      assetPath: StoreSourceIconPaths.fdroid,
                      swapStoreName: 'F-Droid',
                    ),
                  );
                }
                if (apkpureUrl != null) {
                  alternateSourceIcons.add(
                    _buildStoreSourceLaunchIcon(
                      iconContext: pageThemeContext,
                      url: apkpureUrl,
                      assetPath: StoreSourceIconPaths.apkpure,
                      swapStoreName: 'APKPure',
                    ),
                  );
                }
                if (apkmirrorUrl != null) {
                  alternateSourceIcons.add(
                    _buildStoreSourceLaunchIcon(
                      iconContext: pageThemeContext,
                      url: apkmirrorUrl,
                      assetPath: StoreSourceIconPaths.apkmirror,
                      swapStoreName: 'APKMirror',
                    ),
                  );
                }
                // Listings on sources no store scan covers (GitLab, Codeberg, a
                // plain APK link, ...) still belong here - the package really
                // is tracked there, so the row would otherwise hide a source
                // the user set up themselves.
                for (final AppInMemory sibling
                    in siblingListingsWithoutStoreSlot) {
                  alternateSourceIcons.add(
                    _buildStoreSourceLaunchIcon(
                      iconContext: pageThemeContext,
                      url: sibling.app.url,
                      assetPath: storeSourceAssetPathForUrl(sibling.app.url),
                      trackedListingKey: sibling.listingKey,
                    ),
                  );
                }
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width:
                          100 -
                          (_storeSourceButtonSize - _storeSourceIconSize) / 2,
                      child: Text(
                        tr('sources'),
                        style: pageTheme.textTheme.bodySmall?.copyWith(
                          color: pageTheme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 8,
                          children: [
                            _buildStoreSourceLaunchIcon(
                              iconContext: pageThemeContext,
                              url: trackedUrl,
                              assetPath: storeSourceAssetPathForUrl(trackedUrl),
                            ),
                            if (alternateSourceIcons.isNotEmpty)
                              Container(
                                width: 1,
                                height: 24,
                                color: pageTheme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ...alternateSourceIcons,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 100,
                child: Text(
                  tr('categories'),
                  style: pageTheme.textTheme.bodySmall?.copyWith(
                    color: pageTheme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: (app?.app.categories ?? []).isEmpty
                    ? Text(tr('none'), style: detailsValueStyle)
                    : CategoryActionChipGroup(
                        alignment: WrapAlignment.start,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ...(app?.app.categories ?? []).map((categoryName) {
                            final colorArgb =
                                settingsProvider.categories[categoryName];
                            return CategoryActionChip(
                              label: categoryName,
                              color: Color(
                                colorArgb ?? Colors.grey.shade500.toARGB32(),
                              ),
                              state: CategoryActionChipState.plain,
                              outerPadding: const EdgeInsetsDirectional.only(
                                end: 8,
                                top: 4,
                                bottom: 4,
                              ),
                            );
                          }),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ];
      final detailsCard = _materialAppPageSectionCard(
        pageThemeContext,
        tr('details'),
        detailsChildren,
      );

      final bool buttonsAtTop = settingsProvider.updateButtonsAtTopOfAppPage;
      final Widget? actionButtonsWidget = _editMode
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: getBottomCenterActions(
                pageThemeContext,
                app,
                source: source,
                trackOnly: trackOnly,
                isVersionDetectionStandard: isVersionDetectionStandard,
                areDownloadsRunning: areDownloadsRunning,
              ),
            );

      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          ?trackOnlyInstalledErrorCard,
          if (buttonsAtTop && actionButtonsWidget != null) actionButtonsWidget,
          versionCard,
          ?securityCard,
          detailsCard,
          if (app?.app.additionalSettings['about'] is String &&
              app?.app.additionalSettings['about'].isNotEmpty)
            _materialAppPageSectionCard(pageThemeContext, tr('notes'), [
              buildAboutBlock(pageThemeContext),
            ]),
          if (!buttonsAtTop && actionButtonsWidget != null) actionButtonsWidget,
        ],
      );
    }

    Widget buildDetailHeroContent(BuildContext themeContext) {
      const double heroScale = 1.2;
      const heroIconSize = 58.0;
      const scaledIconSize = heroIconSize * heroScale;
      final titleStyle = Theme.of(themeContext).textTheme.titleLarge;
      final bylineStyle = Theme.of(themeContext).textTheme.bodySmall;
      final String listHeroTag = widget.appsListHeroFolderId != null
          ? 'folder-${widget.appsListHeroFolderId}-icon-${widget.appId}'
          : 'app-icon-${widget.appId}';
      final iconWidget = _tappableAppIconDisplay(
        themeContext: themeContext,
        appInMemory: app,
        size: scaledIconSize,
        borderRadius: 16,
        heroTag: listHeroTag,
        iconMemoryBytes: _heroIconMemoryOverrideForEdit(app),
        exclusiveIconMemoryBytes: _editStagedClearOverride,
        onTap: _editMode
            ? null
            : (app?.installedInfo != null
                  ? () => packageManager.openApp(app!.app.id)
                  : null),
        emptyPlaceholder: Container(
          height: scaledIconSize,
          width: scaledIconSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Theme.of(themeContext).colorScheme.primary,
                Theme.of(themeContext).colorScheme.primary.withAlpha(200),
              ],
            ),
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                iconWidget,
                const SizedBox(width: 12 * heroScale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_editMode)
                        ListenableBuilder(
                          listenable: _nameController,
                          builder: (BuildContext context, Widget? child) {
                            final ColorScheme heroScheme = Theme.of(
                              themeContext,
                            ).colorScheme;
                            final String previewText =
                                _nameController.text.isEmpty
                                ? tr('app')
                                : _nameController.text;
                            return Text(
                              previewText,
                              style: titleStyle?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize:
                                    (titleStyle.fontSize ?? 22) *
                                    heroScale *
                                    1.06,
                                color: _nameController.text.isEmpty
                                    ? heroScheme.onSurfaceVariant
                                    : null,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        )
                      else
                        Text(
                          app?.name ?? tr('app'),
                          style: titleStyle?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize:
                                (titleStyle.fontSize ?? 22) * heroScale * 1.06,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 2 * heroScale),
                      Text(
                        tr('byX', args: [app?.author ?? tr('unknown')]),
                        style: bylineStyle?.copyWith(
                          color: Theme.of(
                            themeContext,
                          ).colorScheme.onSurfaceVariant,
                          fontSize:
                              (bylineStyle.fontSize ?? 12) * heroScale * 1.08,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!_editMode && app?.app.hasPendingRepoRename == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _buildRepoRenameWarning(
                  app: app,
                  appsProvider: appsProvider,
                  onUpdate: (String listingKey) async {
                    await _runCheckUpdate(listingKey);
                  },
                ),
              ),
          ],
        ),
      );
    }

    Widget getBottomActionBar(BuildContext themeContext) {
      final bool gestureNavigationActive =
          MediaQuery.systemGestureInsetsOf(themeContext).bottom > 0;
      final bool isLandscapeEmbedded =
          widget.isEmbedded &&
          MediaQuery.orientationOf(themeContext) == Orientation.landscape;
      String? actionBarTooltip(String message) =>
          widget.isEmbedded ? null : message;
      Widget actionBarContent = Padding(
        padding: isLandscapeEmbedded
            ? const EdgeInsets.fromLTRB(16, 6, 16, 6)
            : const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(
              builder: (BuildContext _) {
                final List<Widget> bottomBarActions = <Widget>[];
                if (app != null && app.installedInfo != null) {
                  bottomBarActions.add(
                    IconButton(
                      color: Theme.of(themeContext).colorScheme.primary,
                      iconSize: 24,
                      onPressed: () {
                        appsProvider.openAppSettings(app.app.id);
                      },
                      icon: const Icon(Icons.info_outline),
                      tooltip: actionBarTooltip(tr('appPageAppInfo')),
                    ),
                  );
                }
                if (app != null && !_editMode && app.downloadProgress == null) {
                  bottomBarActions.add(
                    IconButton(
                      color: Theme.of(themeContext).colorScheme.primary,
                      iconSize: 24,
                      onPressed: () => _startEdit(app, appsProvider),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: actionBarTooltip(tr('editAppInfo')),
                    ),
                  );
                }
                if (source != null) {
                  bottomBarActions.add(
                    IconButton(
                      color: Theme.of(themeContext).colorScheme.primary,
                      iconSize: 24,
                      onPressed: app?.downloadProgress != null || updating
                          ? null
                          : () async {
                              final bool? versionDetectionJustEnabled =
                                  await Navigator.push<bool>(
                                    context,
                                    slideUpPageRoute(
                                      (_) => AdditionalOptionsPage(
                                        appId: widget.appId,
                                      ),
                                    ),
                                  );
                              if (versionDetectionJustEnabled != null) {
                                await _runCheckUpdate(
                                  widget.appId,
                                  resetVersion: versionDetectionJustEnabled,
                                );
                              }
                            },
                      tooltip: actionBarTooltip(tr('appOptions')),
                      icon: const Icon(Icons.tune),
                    ),
                  );
                }
                if ((!isVersionDetectionStandard || trackOnly) &&
                    app?.app.installedVersion != null) {
                  final decision = versionDecisionForApp(app!.app);
                  final bool showResetInstall =
                      decision.relation == VersionRelation.same ||
                      decision.relation == VersionRelation.newer;
                  if (showResetInstall) {
                    bottomBarActions.add(
                      IconButton(
                        color: Theme.of(themeContext).colorScheme.primary,
                        iconSize: 24,
                        onPressed: updating
                            ? null
                            : () {
                                appsProvider.saveApps([
                                  resetInstallStatusToDeviceVersion(
                                    app.app,
                                    app.installedInfo,
                                  ),
                                ], attemptToCorrectInstallStatus: false);
                              },
                        icon: const Icon(Icons.restore_rounded),
                        tooltip: actionBarTooltip(tr('resetInstallStatus')),
                      ),
                    );
                  }
                }
                bottomBarActions.add(
                  IconButton(
                    color: Theme.of(themeContext).colorScheme.primary,
                    iconSize: 24,
                    onPressed: app?.downloadProgress != null
                        ? null
                        : () async {
                            final ScaffoldMessengerState? messenger =
                                scaffoldMessengerKey.currentState;
                            final AppInMemory? appRow = app;
                            if (appRow == null) return;
                            final RemoveAppsWithModalResult removeResult =
                                await appsProvider.removeAppsWithModal(
                                  themeContext,
                                  [appRow.app],
                                );
                            if (removeResult.shouldShowSnackBar &&
                                messenger != null) {
                              final Set<String> undoAppIds =
                                  removeResult.deferredUndoAppIds;
                              messenger
                                ..clearSnackBars()
                                ..showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      tr('xAppsRemoved', args: ['1']),
                                    ),
                                    persist: false,
                                    duration: const Duration(seconds: 5),
                                    behavior: SnackBarBehavior.floating,
                                    action: undoAppIds.isNotEmpty
                                        ? SnackBarAction(
                                            label: tr('undo'),
                                            onPressed: () => appsProvider
                                                .undoDeferredObtainiumRemovals(
                                                  undoAppIds,
                                                ),
                                          )
                                        : null,
                                  ),
                                );
                            }
                            if (removeResult.obtainiumEntryRemovedOrScheduled &&
                                themeContext.mounted) {
                              Navigator.of(themeContext).pop();
                            }
                          },
                    tooltip: actionBarTooltip(tr('remove')),
                    icon: const Icon(Icons.delete_outline),
                  ),
                );
                return Row(
                  children: [
                    for (final Widget actionWidget in bottomBarActions)
                      Expanded(child: Center(child: actionWidget)),
                  ],
                );
              },
            ),
          ],
        ),
      );
      if (isLandscapeEmbedded) {
        actionBarContent = IconButtonTheme(
          data: IconButtonThemeData(
            style: ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: WidgetStateProperty.all(const Size(36, 36)),
              padding: WidgetStateProperty.all(const EdgeInsets.all(4)),
            ),
          ),
          child: actionBarContent,
        );
      }
      if (gestureNavigationActive || widget.isEmbedded) {
        actionBarContent = SafeArea(top: false, child: actionBarContent);
      }
      final Widget actionBarSurface = Container(
        decoration: BoxDecoration(
          color: Theme.of(themeContext).brightness == Brightness.dark
              ? Theme.of(themeContext).colorScheme.surfaceContainerHigh
              : Theme.of(themeContext).colorScheme.surfaceContainerHighest,
          borderRadius: isLandscapeEmbedded
              ? const BorderRadius.vertical(top: Radius.circular(16))
              : const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(
              color: Theme.of(themeContext).brightness == Brightness.dark
                  ? Theme.of(
                      themeContext,
                    ).colorScheme.outlineVariant.withAlpha(140)
                  : Theme.of(
                      themeContext,
                    ).colorScheme.outlineVariant.withAlpha(70),
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(themeContext).colorScheme.shadow.withAlpha(
                Theme.of(themeContext).brightness == Brightness.dark ? 130 : 40,
              ),
              blurRadius: Theme.of(themeContext).brightness == Brightness.dark
                  ? 18
                  : 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: actionBarContent,
      );
      if (widget.isEmbedded) {
        return actionBarSurface;
      }
      if (gestureNavigationActive) {
        return actionBarSurface;
      }
      return SafeArea(top: false, child: actionBarSurface);
    }

    return Theme(
      data: pageThemeForPage,
      child: Builder(
        builder: (BuildContext themedPageContext) {
          return PopScope(
            canPop: !_editMode,
            onPopInvokedWithResult: (bool didPop, dynamic result) async {
              if (didPop) return;
              // If canPop was false, we're in edit mode.
              // Handle unsaved changes before allowing a pop.
              final AppInMemory? freshApp = Provider.of<AppsProvider>(
                themedPageContext,
                listen: false,
              ).apps[widget.appId];

              // If not dirty, just exit/pop without a dialog.
              if (!_isEditDirty(freshApp)) {
                if (widget.openInEditMode && mounted) {
                  Navigator.of(themedPageContext).pop();
                } else {
                  _exitEditWithoutSaving();
                }
                return;
              }

              // If dirty, show the dialog
              final _UnsavedAction? action = await _showUnsavedChangesDialog(
                themedPageContext,
                pageThemeForPage,
                canSave: !updating && freshApp?.downloadProgress == null,
              );

              if (!themedPageContext.mounted || freshApp == null) return;

              bool shouldPopPage = false;

              switch (action) {
                case _UnsavedAction.discard:
                  _exitEditWithoutSaving();
                  if (widget.openInEditMode) {
                    shouldPopPage = true;
                  }
                  break;
                case _UnsavedAction.saveAndExit:
                  if (freshApp.downloadProgress != null || updating) {
                    break;
                  }
                  final appsProvider = Provider.of<AppsProvider>(
                    themedPageContext,
                    listen: false,
                  );
                  await _saveEdit(freshApp, appsProvider);
                  if (widget.openInEditMode) {
                    shouldPopPage = true;
                  }
                  break;
                case _UnsavedAction.keepEditing:
                default:
                  // Do nothing, stay on the page in edit mode.
                  break;
              }

              if (shouldPopPage && themedPageContext.mounted) {
                Navigator.of(themedPageContext).pop();
              }
            },
            child: Scaffold(
              extendBody: true,
              resizeToAvoidBottomInset: true,
              backgroundColor: settingsProvider.useGradientBackground
                  ? Colors.transparent
                  : sharedPageBackgroundColorScheme.surface,
              floatingActionButton: _editModeFloatingActionButtons(
                themedPageContext,
                app,
                appsProvider,
                pageThemeForPage,
              ),
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.endFloat,
              floatingActionButtonAnimator:
                  FloatingActionButtonAnimator.noAnimation,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  RefreshIndicator(
                    displacement: 20,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (settingsProvider.useGradientBackground)
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: sharedPageBackgroundColorScheme
                                    .schemePageBackgroundGradient,
                              ),
                            ),
                          ),
                        CustomScrollView(
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            1600,
                          ),
                          controller: _appPageScrollController,
                          physics:
                              _swappingTrackedSource ||
                                  _trackingAdditionalSource
                              ? const NeverScrollableScrollPhysics()
                              : const AlwaysScrollableScrollPhysics(
                                  parent: ClampingScrollPhysics(),
                                ),
                          slivers: [
                            SliverToBoxAdapter(
                              child: SafeArea(
                                top: true,
                                bottom: false,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          if (!widget.isEmbedded)
                                            IconButton(
                                              icon: const Icon(
                                                Icons.arrow_back,
                                              ),
                                              color: pageThemeForPage
                                                  .colorScheme
                                                  .primary,
                                              onPressed: updating
                                                  ? null
                                                  : () => Navigator.of(
                                                      themedPageContext,
                                                    ).maybePop(),
                                              tooltip: MaterialLocalizations.of(
                                                themedPageContext,
                                              ).backButtonTooltip,
                                            ),
                                          if (widget.isEmbedded)
                                            const SizedBox(width: 16),
                                          Expanded(
                                            child: buildDetailHeroContent(
                                              themedPageContext,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (_editMode && app != null)
                                        _buildEditMetadataSection(
                                          themedPageContext,
                                          app,
                                          appsProvider,
                                          settingsProvider,
                                        )
                                      else ...[
                                        _buildPersistentPageError(
                                          themedPageContext,
                                          pageThemeForPage,
                                          effectivePersistentPageError,
                                          title:
                                              effectivePersistentPageErrorTitle,
                                        ),
                                        getInfoColumn(
                                          themedPageContext,
                                          app,
                                          small: false,
                                        ),
                                      ],
                                      if (_editMode)
                                        SizedBox(
                                          height: _editModeBottomSpacerHeight,
                                        )
                                      else
                                        SizedBox(
                                          height: _bottomActionBarHeight > 0
                                              ? _bottomActionBarHeight
                                              : 80,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    onRefresh: () async {
                      if (_editMode ||
                          _swappingTrackedSource ||
                          _trackingAdditionalSource) {
                        return;
                      }
                      if (app != null) {
                        await _runCheckUpdate(app.listingKey);
                      }
                    },
                  ),
                  if (_swappingTrackedSource || _trackingAdditionalSource)
                    Positioned.fill(
                      child: AbsorbPointer(
                        child: ColoredBox(
                          color: pageColorSchemeForPage.surface.withValues(
                            alpha: 0.72,
                          ),
                          child: Center(
                            child: ExpressiveLoadingIndicator(
                              color: pageColorSchemeForPage.primary,
                              constraints: const BoxConstraints.tightFor(
                                width: 64,
                                height: 64,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.isEmbedded)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _ScrollLinkedAppPageFooter(
                        key: ValueKey<bool>(_editMode),
                        scrollController: _appPageScrollController,
                        child: _MeasureSize(
                          onChange: _handleBottomActionBarSizeChanged,
                          child: getBottomActionBar(themedPageContext),
                        ),
                      ),
                    ),
                ],
              ),
              bottomNavigationBar: widget.isEmbedded
                  ? null
                  : _MeasureSize(
                      onChange: _handleBottomActionBarSizeChanged,
                      child: getBottomActionBar(themedPageContext),
                    ),
            ),
          );
        },
      ),
    );
  }
}

class _ScrollLinkedAppPageFooter extends StatefulWidget {
  const _ScrollLinkedAppPageFooter({
    super.key,
    required this.scrollController,
    required this.child,
  });

  final ScrollController scrollController;
  final Widget child;

  @override
  State<_ScrollLinkedAppPageFooter> createState() =>
      _ScrollLinkedAppPageFooterState();
}

class _ScrollLinkedAppPageFooterState
    extends State<_ScrollLinkedAppPageFooter> {
  bool _footerExpanded = true;
  double _previousOffset = 0;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _ScrollLinkedAppPageFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final ScrollController controller = widget.scrollController;
    if (!controller.hasClients) {
      return;
    }
    final double currentOffset = controller.offset;
    final double delta = currentOffset - _previousOffset;
    _previousOffset = currentOffset;
    if (currentOffset <= 24) {
      if (!_footerExpanded) {
        setState(() {
          _footerExpanded = true;
        });
      }
      return;
    }
    const double scrollSensitivity = 10;
    if (delta > scrollSensitivity) {
      if (_footerExpanded) {
        setState(() {
          _footerExpanded = false;
        });
      }
    } else if (delta < -scrollSensitivity) {
      if (!_footerExpanded) {
        setState(() {
          _footerExpanded = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: _footerExpanded ? Offset.zero : const Offset(0, 1.0),
      duration: const Duration(milliseconds: 240),
      curve: Curves.fastOutSlowIn,
      child: widget.child,
    );
  }
}
