# ObtainX Developer Guide

ObtainX is a reworked fork of [Obtainium](https://github.com/ImranR98/Obtainium): a
Flutter app for Android that installs and updates Android apps **directly from their
release sources** (GitHub, GitLab, Codeberg/Forgejo, F-Droid and third-party repos, app
stores, HTML pages, direct APK links). It queries each source for the latest release,
downloads the APK (or split-APK container / archive), and installs it, optionally silently
in the background. For product differences, see
[`Difference_with_Obtainium.md`](Difference_with_Obtainium.md).

**Internal names deliberately keep `obtainium`:** the Dart package (`package:obtainium/...`),
`ObtainiumError`, `buildObtainiumTheme`, the root widget `Obtainium` / `_ObtainiumState`, the
`dev.imranr.obtainium/*` MethodChannels and Android namespace, and the `obtainium://` link
scheme. They keep upstream merges small and Obtainium links and backups working; don't
rename them. The application ID is `dev.bikram.obtainx`.

---

## 1. Tech stack & entry points

| Concern | Choice |
| --- | --- |
| UI | Flutter on `package:material_ui`, **Material 3 "Expressive"** (`useMaterial3: true`) |
| State management | `provider` (`ChangeNotifier`) |
| Persistence | One JSON file per tracked listing + `SharedPreferences` for settings (credentials included) + `sqflite` for logs and last-check times |
| Localization | `easy_localization` (`assets/translations/*.json`, key-based `tr()` / `plural()`) |
| Background work | A `workmanager` periodic task, or a `flutter_foreground_task` foreground service if the user picks it |
| HTTP | `dart:io` `HttpClient` behind `HttpService` (`lib/services/http_service.dart`); upstream's Cronet stack is deliberately not used |
| Installation | `Installer` strategies (stock, Shizuku, Dhizuku, external, root) backed by `android_package_installer`, `shizuku_apk_installer`, native MethodChannels and `su` |

**`material_ui`.** The app imports `package:material_ui/material_ui.dart`, not the
framework's `package:flutter/material.dart` (deprecated from Flutter 3.50, the minimum in
`pubspec.yaml`). Their `Theme` classes differ, so a package widget still on
`flutter/material` (e.g. `flutter_markdown_plus`) would paint with framework defaults:
wrap it in `LegacyMaterialBridge` (`lib/components/legacy_material_bridge.dart`, the only
file importing `flutter/material`), which maps the nearest material_ui theme into a
framework one (`MaterialApp.builder` also wraps the whole app as a fallback), or pass it
explicit colours, as the `expressive_refresh` and `progress_indicator_m3e` call sites do.

### Entry point: `lib/main.dart`

- `main()` installs error logging (`installDiagnosticErrorLogging()`), initializes
  `EasyLocalization`, `SettingsProvider`, `NotificationsProvider` and
  `Workmanager().initialize(callbackDispatcher)` concurrently, enables edge-to-edge system
  UI (SDK ≥ 29), and constructs `AppsProvider` before `runApp` so the initial `loadApps()`
  overlaps the first frame. The `MultiProvider` holds `AppsProvider`, `SettingsProvider`,
  `NotificationsProvider` and `LogsProvider`. `SourceProvider` is a plain singleton, not a
  provider; background runs build their own `AppsProvider(isBg: true)`.
- `buildObtainiumTheme()` (`lib/theme.dart`) builds the base Material 3 Expressive
  `ThemeData` (superellipse cards/dialogs/fields, stadium pill buttons and chips,
  `FadeForwardsPageTransitionsBuilder`). `_ObtainiumState._buildAppThemeData` layers the
  sub-themes from `lib/theme/` and memoizes the result per colour scheme and font; schemes
  come from `colorSchemeForAccentSettings` (`lib/theme/app_theme_accent.dart`). Extend the
  theme; don't re-style per widget.
- `_ObtainiumState.initState` asks, post-frame, for the notification permission and shows
  the battery-optimization warning. Its `build()` reconciles background work with the
  settings it selects: no update interval stops everything, `useFGService` starts the
  foreground service, otherwise `_scheduleWorkManager()` runs, which re-registers only
  when the requested constraints change. First-run handling (`checkAndFlipFirstRun()`, true
  once) adds ObtainX itself to the list, except in the F-Droid flavour.
- `callbackDispatcher()` (`@pragma('vm:entry-point')`) is the headless WorkManager entry
  point. It calls `bgUpdateCheck()`; on a crash it logs it and returns `false`.
  `startCallback()` / `MyTaskHandler` are the foreground-service equivalent.

`lib/main_fdroid.dart` sets `AppDistribution.fdroid = true` (`lib/app_distribution.dart`)
and calls `main()`. In that flavour ObtainX doesn't add itself to the app list (F-Droid
updates it), the DuckDuckGo favicon fallback is off, and promo links open F-Droid.

---

## 2. Directory layout

```
lib/
├─ main.dart                      Bootstrap, root widget, background scheduling and entry points
├─ main_fdroid.dart               F-Droid flavour entry point
├─ theme.dart                     buildObtainiumTheme(), positionalTileRadius, ExpressiveMotion
├─ custom_errors.dart             ObtainiumError + typed errors, showMessage/showError
├─ app_sources/                   app_source.dart (AppSource base), one file per source (30 in 29 files), helpers
├─ components/                    Reusable widgets: form engine, sheets, app bar, dialogs
├─ core/logging/app_logger.dart   Static AppLogger API over LogsProvider (upstream-compatible)
├─ folders/app_folder.dart        Folders and smart-folder rules
├─ http/                          User agent, per-check SourceRequestSession, response byte limits
├─ installers/                    Installer strategies (installer.dart + one file per mode)
├─ models/                        App, APKDetails, AppNames (app.dart); TypedSettings
├─ pages/                         Screens
│  ├─ home.dart                   Navigation shell + deeplink/share routing
│  ├─ apps.dart                   Apps list, the app row, view options, changelog dialog
│  ├─ app.dart                    App details page
│  ├─ add_app.dart                Add app (URL, search, bulk add)
│  ├─ import_export.dart          Backup tab
│  ├─ import_from_url_list.dart   Import from URL list
│  └─ settings.dart               Settings sections + LogsSheet
├─ providers/
│  ├─ apps_provider.dart          AppsProvider core, AppInMemory/AppListings, downloads, bgUpdateCheck, NativeFeatures
│  ├─ apps_provider_*.dart        Extensions: lifecycle (load/save/remove, icons), updates, install, import/export, icon backup
│  ├─ app_json_migration.dart     appJSONCompatibilityModifiers (legacy JSON migrations)
│  ├─ source_provider.dart        SourceProvider; re-exports AppSource, models, HttpService, version API
│  ├─ settings_provider.dart      Typed getters/setters over SharedPreferences
│  ├─ logs_provider.dart          sqflite-backed logs
│  └─ notifications_provider.dart Local notifications
├─ services/                      HttpService, APK filtering, file picking, check-time store, host request gate, …
├─ theme/                         Sub-themes, accent and colour schemes, M3E grouped-list helpers
├─ utils/                         Background guards, TranslationLoader, colour/URL/string helpers, update health
├─ version/                       The version engine (§6)
└─ widgets/                       Toasts/snackbars, HelpHintIcon, edge blur overlays
```

---

## 3. State management & data model

### Providers
State lives in `ChangeNotifier` providers exposed through `provider`. **Read providers
narrowly** to avoid rebuild amplification:

- `context.read<T>()` — one-off access (event handlers, `initState`).
- `context.select<T, R>((p) => p.field)` — rebuild **only** when `field` changes.
- `context.watch<T>()` — rebuild on **any** change. Avoid for big providers like
  `AppsProvider`; prefer `select`. The root widget, `HomePageState` and
  `SettingsPageState` select a hash of just the fields they read for this reason.

### The `App` model (`lib/models/app.dart`)

`App` is the persisted unit. Key fields: `id` (Android package ID, or a temporary hash until
the real one is known; see `isTempId`), `listingId` (set only on a further listing of a
package tracked from another store, e.g. `com.example.app@FDroid`), `url`, `author`, `name`,
`installedVersion`, `latestVersion`, `apkUrls` (`List<MapEntry<name, url>>`),
`preferredApkIndex`, `additionalSettings` (per-app source options, also readable through the
typed `settings` getter), `categories`, `pinned`, `overrideSource`, `pendingRepoRenameUrl`,
and `allowIdChange`. `listingKey` (`listingId ?? id`) identifies the listing in memory and
on disk.

- `App.toJson()` / `App.fromJson()` serialize to/from disk.
- `App.fromJson()` runs **`appJSONCompatibilityModifiers()`**
  (`lib/providers/app_json_migration.dart`) — a chain of idempotent schema migrations
  (legacy → current) that runs on every load. If it throws, the app loads from the
  unmigrated JSON and the error is logged, so a bad migration can't lose an app.
- `App` is **immutable** — use `App.copyWith(...)` to create a modified copy.

### `AppInMemory` (`apps_provider.dart`)

Runtime wrapper around `App` that also holds a `DownloadState` (progress `ValueNotifier`,
shared by reference so per-row listeners survive `saveApps` replacing the wrapper),
`installedInfo` (`PackageInfo` from the OS), the cached `icon` bytes, and `sourceType`.
`AppsProvider.apps` is an `AppListings` map keyed by `listingKey`; a bare package ID also
resolves while the package has only one listing.

### Persistence rules (`apps_provider_lifecycle.dart`)

- Each listing is `app_data/<listingKey>.json`. Writes go to a uniquely named
  `<listingKey>.json.tmp_…` file that is renamed over the record — **atomic write**, never a
  partially written file. Invalid JSON on load is renamed to `*.corrupt` and skipped.
- A save that changes only the last-check time can record it in `app_checks.db`
  (`AppCheckStore`) instead, bound to the record's revision.
- `loadApps()` calls are serialized through `appsLoadingCompleter` (not a busy-wait); await
  `waitForAppsToLoad()`, or `waitForInitialLoad()` from UI that can run on a cold start.
- `saveApps()` reconciles install status (unless `attemptToCorrectInstallStatus: false`),
  updates in-memory state, notifies, and schedules a debounced auto-export.
- Icons are cached as PNG in an `icons/` cache dir (user-set and deduced icons in
  `user_icons/` and `deduced_icons/`); removing a package's last listing deletes its cached
  and deduced icons.

---

## 4. The Source system (the core extensibility model)

This is the heart of ObtainX. **To add support for a new app source, add one file in
`lib/app_sources/` and add its constructor to `SourceProvider._sourceFactories`.**

### `AppSource` (abstract, in `lib/app_sources/app_source.dart`)

A source subclasses `AppSource`. Flags are set in the constructor; form items are
overridden getters:

```dart
class MySource extends AppSource {
  MySource() {
    hosts = ['example.com'];          // domains this source matches
    name = 'MySource';                // defaults to the runtime type name
    canSearch = true;                 // supports search()
    showReleaseDateAsVersionToggle = true;
    allowIncludeZips = true;
  }

  @override // per-app options shown in the add/edit form
  List<List<GeneratedFormItem>> get additionalSourceAppSpecificSettingFormItems => [
    [GeneratedFormSwitch('myOption', label: tr('myOption'))],
  ];

  @override // source-wide options stored in SettingsProvider (e.g. an API token)
  List<GeneratedFormItem> get sourceConfigSettingFormItems => [
    GeneratedFormTextField('example-creds', label: tr('token'), password: true, required: false),
  ];
}
```

Override the contract methods you need:

| Method | Responsibility |
| --- | --- |
| `sourceSpecificStandardizeURL(url, {forSelection})` | Validate + normalize a URL to a canonical form, or throw `InvalidURLError`. Used for both selection and storage. |
| `getLatestAPKDetails(standardUrl, additionalSettings)` | **The main job:** fetch the latest release and return `APKDetails(version, apkUrls, names, releaseDate:, changeLog:, allAssetUrls:, …)`. |
| `tryInferringAppId(standardUrl, {additionalSettings})` | Best-effort detect the Android package ID (optional). |
| `search(query, {querySettings})` | Return `{url: [name, description]}` (only if `canSearch`). |
| `getRequestHeaders(additionalSettings, url, {forAPKDownload})` | Provide auth/format headers. |
| `getSourceNote()` | Markdown note shown in the UI (e.g. "add a token to avoid rate limits"). |
| `changeLogPageFromStandardUrl(url)` | URL of the changelog page, or set `changeLogPageIsStandardUrl = true` if it is the standard URL. |
| `postProcessApp(app)` | Transform the `App` after all other processing (e.g. F-Droid repos add an `appId` query parameter). |
| `resolveVersionComparison(app)` | Optional async last step recording source-side evidence of how the installed build relates to the latest (GitHub's compare API). |

### Helpers you should reuse (don't reinvent)

- **`standardizeUrlWithRegex(url, subdomainPrefix:, pathPattern:)`** — the common
  "regex against host + path, return match or throw `InvalidURLError`" pattern.
- **`AppSource.isApkOrContainerFile(name, {includeArchives, includeTarballs})`**
  (`ApkFilterService`) — the **single source of truth** for "is this file an installable
  container?" (`.apk/.xapk/.apkm/.apks`, plus `.zip` and tarballs when asked). Don't
  hand-roll `.endsWith('.apk')`.
- `sourceRequest(url, additionalSettings, {followRedirects, postBody})` — the base HTTP
  method: merges per-app settings with source config, applies `generalReqPrefetchModifier`
  and `getRequestHeaders`, and sends through `HttpService` (redirect cap, certificate
  pinning when enabled). Within an update check (`SourceRequestSession`) requests share a
  client and identical repository index fetches run once. **Use this**, not `http.get`.
- `filterApks`, `filterApksByArch`, `getApkUrlsFromUrls` (`apk_filter_service.dart`),
  `extractVersion`, `findStandardFormatsForVersion` (`lib/version/version_strings.dart`),
  `grabLinksCommon` / `getLinksInLines` (`html.dart`), `parseHtmlOffIsolate`.

### `SourceProvider` (the service, `lib/providers/source_provider.dart`)

- **Singleton** (`factory SourceProvider() => _instance`).
- `_sourceFactories` lists every source constructor: host-based sources alphabetically by
  display name (the order source pickers show), then `DirectAPKLink` and `HTML`.
- `sourceTemplates` / `getSourceTemplate(url)` return one cached instance per source for
  **read-only** use. `getSource(url, overrideSource:)` and `sources` construct **fresh**
  instances, which callers may mutate (an override rewrites `hosts`).
- `getSource(url)`: tries host-regex matching against sources with `hosts`, then host-less
  sources (except `neverAutoSelect`) via `sourceSpecificStandardizeURL(url,
  forSelection: true)` — **`HTML()` is always last**. Non-matching sources are skipped
  silently, on purpose; no match throws `UnsupportedURLError`. Matches are cached per URL.
- `getApp(...)`: orchestrates `getLatestAPKDetails` → minimum update age (adds only) →
  version extraction (per-app or global regex) → `releaseDateAsVersion` → APK filter
  (per-app or global) → `autoApkFilterByArch` → app-ID resolution (existing, explicit
  `appId`, known to the source, `tryInferringAppId`, else temporary) → `postProcessApp` →
  `resolveVersionComparison`. `getAppByURLNaive(url)` uses the source's defaults.

---

## 5. UI layer & component conventions

### Navigation shell (`pages/home.dart`)

`HomePage` has **four tabs**, all kept mounted: Apps, Add app, Backup (`ImportExportPage`),
and Settings.
- Compact screens: a floating pill navigation bar (`_floatingHomeNavigationBar`), hidden
  while the keyboard is open. On the Apps tab it carries an update-all button and a
  view-options or selection-actions button.
- Wide screens (`width >= kLargeScreenWidthBreakpoint`, 720, unless "always use phone
  layout" is on): a `NavigationRail`, and the Apps tab shows list + detail (except on TV).
  The Apps icon's badge is `AppsProvider.pendingUpdateCount` (via `context.select`), built
  on `findExistingUpdates(...)` — the same verdict the app list renders, not a raw
  `installedVersion != latestVersion` compare.
- Back from another tab returns to Apps rather than retracing the tabs visited.

### Deeplink routing (`pages/home.dart`)

`HomePageState.initDeepLinks()` wires up links and shares; `interpretLink(Uri uri)`
dispatches `add`, `app` and `apps`, reading the URI host as the **action**:

| Action (`uri.host`) | Data source | Behaviour |
| --- | --- | --- |
| `add` | `uri.queryParameters['url']` or the decoded path | Standardizes the URL; opens the listing already tracked under it, or Add app with the URL filled in |
| `app` / `apps` | URI-encoded JSON in the path | Adds the link's apps exactly as Import from URL list adds what's typed into it (`importUrlListEntries`, below). A link for one app that's already tracked opens that app instead; a single app added opens its page |
| `refresh` | optional `?id=` (package ID or listing key) | Checks every app, or the matching listings, without leaving the current screen (`refreshFromLink`) |

**Import from URL list** takes URLs, `app` / `apps` links (including ones wrapped in the
"Share app configuration" redirect page), the JSON a link carries, or an export's JSON (its
apps, but not its ObtainX-wide `settings` block), and adds them all the same way.
`urlImportEntriesIn` turns the box's text into `UrlImportEntry`s: a URL, or a URL plus the
app a link or JSON described (its `seed`). The sheet then fetches every entry with
`fetchUrlImportEntry`, which does what `getAppByURLNaive` does for a typed URL. The
package ID is looked up, and a seed fills in what Add app's fields would: its settings over
the source's defaults, its package ID as the custom App ID unless it's temporary, a forced
source, and categories. Its folder memberships are dropped, since they name folders on
another phone, and a link can't set an app's install method. An entry that can't be fetched
shows why and isn't added. Everything chosen is saved by `addFetchedApps` through Add app's
own `addNewListing`. `importUrlListEntries` is that whole flow, and links another app sends
go through it too (`urlImportEntriesFromLink`). Nothing adds apps through the backup
`import()`, which overwrites on purpose.

Its **Import from file** button imports the picked file on its own, straight to the same
sheet; the box is left alone, and the two are never combined. It picks the file as backup
import and restore do (`pickTextFile`, opening in the export folder). `urlListTextInFile`
turns the file into text the box could hold, which then goes the box's way. A file that
could have been typed in (app JSON or an export, links, or a list with a URL or link on each
line) is taken as it is. From any other file (an OPML feed list, say) it picks out app links
and only the addresses a host-based source takes, standardized. `getSource` alone can't
filter them: the HTML source is a catch-all that takes any address with a dot in it.

Inbound links arrive via `app_links` (`AppLinks`); the `obtainium://` scheme is a `VIEW`
intent filter in `AndroidManifest.xml`. `getInitialLink()` (cold start) and
`uriLinkStream` (warm start) both go through `interpretIncomingLink`, with a guard so the
initial link isn't processed twice. The **share sheet** (`ACTION_SEND`, `text/*`):
`MainActivity.kt` passes the shared text over the `dev.imranr.obtainium/share` channel to
`SharedUrlReceiver`, and its first `http(s)` URL is handled exactly like an `add` link.

### Reusable components

Prefer these over bespoke widgets:

- **`lib/theme.dart`** — `positionalTileRadius({isFirst, isLast})`, `ExpressiveMotion`
  motion tokens. **`lib/theme/m3e_expressive_list.dart`** — grouped ("connected") rows:
  `M3eExpressiveSettingsCard`, `m3eListGroupItemRadius`, `kM3e*` radii and gaps. Scale radii
  with `SettingsProvider.cardCornerRadiusFor` (the user's card-corner setting), not
  `theme.dart`'s upstream `AppRadii` tokens.
- **`components/ui_widgets.dart`** — `AppIcon` (superellipse-clipped, glyph fallback,
  excluded from semantics), `ActionListTile`, `EmptyState`, `LinkText`
  (`Semantics(link: true)`), `AppSwitch` / `AppSwitchListTile` (platform tap feedback),
  `ExplainedWhenOff` (§7), `DownloadCancelButton`, `copyToClipboard`, `showConfirmDialog`.
- **`custom_errors.dart`** — `showMessage(e, {isError, theme, scaffoldHasBottomBar})` logs
  via `LogsProvider` and shows a snackbar (strings, expected `ObtainiumError`s) or a
  copyable dialog (unexpected errors); `showError(e)` sets `isError`. Both use the global
  `scaffoldMessengerKey` / `globalNavigatorKey`, so they take no `BuildContext`.
- **`widgets/app_toast.dart`** — `buildAppSnackBar`, `showAppToast`. On a page whose
  `Scaffold` has its own bottom bar, pass `scaffoldHasBottomBar: true`.
- **`components/custom_app_bar.dart`** — `CustomAppBar` (a `SliverAppBar` with optional
  inline search and progressive blur); **`widgets/help_hint_icon.dart`** — `HelpHintIcon`.
- **`components/app_bottom_sheet.dart`** — `showAppModalSheet` with `AppSheetContent` /
  `AppSheetScaffold`, which own sheet chrome, height cap, scrolling and insets.
- **`components/generated_form_renderer.dart`** — `GeneratedForm` and `GeneratedFormModal`
  (a `GeneratedForm` inside an `AlertDialog`; the standard way to ask for structured input).
- **`pages/apps.dart`** — the app row: `_AppListItem` (selects its own download progress,
  so only that row rebuilds) inside `_SwipeableListItem` (configurable `SwipeAction`s);
  changelog helpers `showChangeLogDialog` / `getChangeLogFn`.
- **`components/app_detail_widgets.dart`** — `AppFilePicker` (choose among APK/asset URLs),
  `APKOriginWarningDialog`, `MalwareScanWarningDialog`, `SigningCertMismatchDialog`.
- Categories — `CategoryEditorFields` (`generated_form_renderer.dart`),
  `CategoryEditorSelector` (`pages/settings.dart`), `BulkCategoryEditorSheet`,
  `CategoryActionChip`. `LogsSheet` is in `pages/settings.dart`, its only user.

### The form engine (`generated_form_model.dart`)

Forms throughout the app (per-app settings, source config, search filters, dialogs) are
**data-driven**. You describe fields as `List<List<GeneratedFormItem>>` (rows of fields)
and `GeneratedForm` (in `generated_form_renderer.dart`) renders + validates them:

- `GeneratedFormTextField` (autocomplete, password, multi-line via `max`, validators, help
  URL, inline assist action)
- `GeneratedFormSwitch` (supports `disabled`, and `turnsOffKeys` for exclusive switches)
- `GeneratedFormDropdown` (`opts`, `disabledOptKeys`), `GeneratedFormSlider`
  (`opts`). Both take `globalValue` for a per-app override of a global
  setting: `''` follows the global value and is labelled "Global (<value>)".
  Every value is listed besides it, so an app can be pinned to the current
  global value. A dropdown's `opts` keep their `''` entry; a slider's hold only
  the real values, and the renderer adds the `''` stop in front,
  `GeneratedFormTagInput` (chips, e.g. categories)
- `GeneratedFormSubForm` (nested repeatable groups, e.g. HTML intermediate links)
- `GeneratedFormSectionHeader` (section cards with `wrapFormSectionsInCards`)

It reports changes via `onValueChanges(values, valid, isBuilding)`. Each
`GeneratedFormItem` has `ensureType()` (coerce stored value) and `clone()` (deep copy).
**Form items are cloned (`cloneFormItems`) before values are pre-filled**, so one app's
values never touch a shared source template. `tileMode` exists for upstream API parity but
doesn't change the layout.

---

## 6. Background updates & installation

### Background task architecture

1. `_scheduleWorkManager()` (called from `_ObtainiumState.build()`) registers the periodic
   task `obtainiumBgUpdateCheck` every **15 minutes** (WorkManager's minimum) whatever the
   update interval. A guard set to "nothing" becomes a constraint (unmetered network,
   charging). With `useFGService`, a foreground service repeats on the same period instead.
2. WorkManager invokes **`callbackDispatcher()`**, which calls
   **`bgUpdateCheck(taskId, params)`** (`lib/providers/apps_provider.dart`), headless with
   its own `AppsProvider(isBg: true)`. Retries are one-off tasks `retry_<taskId>_<n>` with an
   `initialDelay` and the apps in `inputData['toCheck']`.

### `bgUpdateCheck` behaviour

1. Returns at once if nothing is due (`SettingsProvider.bgNextCheckDue`) and the run isn't
   explicit (manual, or a retry). Otherwise it loads translations manually
   (`TranslationLoader.load()`, `lib/utils/translation_loader.dart`; no `BuildContext`).
2. Bails on no network and applies the background guards (`evaluateBgGuards`,
   `lib/utils/bg_update_guards.dart`): off Wi-Fi or unplugged, "nothing" skips the run and
   "checks only" allows no installs. It also bails if the update interval is 0. A manual run
   only checks.
3. **Checks** the due apps (or the retry list) with `checkUpdates()`, retrying failures up to
   `_bgUpdateMaxAttempts` times; a rate limit is waited out in full, other waits are capped.
4. Filters found updates through `appUpdateIsUserVisible`, the verdict the app list uses.
   Ones that `canInstallSilentlyInBackground` are queued for install; the rest get grouped
   notifications, and errors left after retries get one error notification.
5. **Installs**, when allowed and background updates are on: adds pending updates from
   earlier runs, then installs silently via `downloadAndInstallLatestApps`, postponing while
   the screen is on. ObtainX itself is always installed **last**.
6. Records the next due time and posts on `AppsProvider`'s static save-event stream. When
   the app returns to the foreground, `refreshAppsOnResume()` reloads records that changed
   on disk, which picks up background writes.

### Update checking (`apps_provider_updates.dart`)

- **`fetchUpdate(appId)`** fetches new metadata **without saving**;
  **`checkUpdate(appId)`** fetches and saves.
- **`checkUpdates()`** never overlaps another check: a call waits for the running one, then
  checks its own IDs. It runs `maxParallelUpdateChecksForDevice()` workers in one
  `SourceRequestSession` — **8**, or 4 with ≤ 6 GB RAM, or 2 on low-RAM devices or with
  ≤ 3 GB — and saves results in batches at most every 3 seconds instead of once per app.
- App-level verdicts live here too: `appHasActionableUpdate`, `appUpdateIsUserVisible`,
  `findExistingUpdates`.

### The version engine (`lib/version/`)

Version semantics live only in `lib/version/`: `version_strings.dart` (extraction,
"standard format" matching, reconciliation, ordering), `version_comparison.dart`
(`compareVersionStrings` → `VersionDecision`), `version_detection_mode.dart` (the parsed
`versionDetection` setting, read via `App.versionDetectionMode`), `app_version.dart` (device
observations, install receipts, `versionDecisionForApp`) and `partial_download_version.dart`.
Build on these; don't add another comparison elsewhere.

### Installation (`apps_provider_install.dart`)

`AppsProviderInstall` extension handles the full pipeline:
- `downloadAndInstallLatestApps(appIds, context, ...)` is the orchestrator used by both UI
  and background (a `null` context means no user interaction).
- `downloadApp(...)` → a `DownloadedApk`, or a `DownloadedDir` for XAPK / ZIP / tarball
  containers (extracted; tarballs off the UI isolate) and multi-URL split-APK sets.
- `installApk` / `installApkDir` run the shared pre-install checks and hand off to
  `getInstaller(app)`. `canInstallSilently(app)` decides whether the prompt can be skipped;
  `canInstallSilentlyInBackground(app)` adds the background-updates setting and exemption.
- `moveObbFile` uses SAF (`shared_storage`) for `Android/obb` on Android 11+, and storage
  permission on older versions.
- The stock and external installers need an activity on screen, so outside the foreground
  `waitForUserToReturnToForeground` posts a "complete installation" notification and waits.

### Installer abstraction (`lib/installers/`)

The abstract `Installer` class (`installer.dart`) defines:

```dart
abstract class Installer {
  Installer(this.settingsProvider); // final SettingsProvider settingsProvider
  String get modeKey; // 'system', 'shizuku', 'dhizuku', 'external' or 'root'
  bool get wantsContainerHandoff => false;
  Future<bool> canInstallSilently(App app);
  Future<bool> checkPermission();
  Future<void> ensurePermission({ThemeData? toastTheme});
  Future<InstallResult> installApk(
    List<String> apkFilePaths, {
    required String appId,
    Map<String, dynamic> installOptions = const {},
  });
  Future<void> releaseStalledInstall() async {}
}
```

`InstallResult` is `success`, `cancelled`, `handedOff` (reached an installer that reports
no result) or `error(code)`. Five concrete implementations:

| Installer | Backend | Use case |
| --- | --- | --- |
| `StockInstaller` | `android_package_installer` (PackageInstaller sessions) | Default. Silent only for an installed app whose installer of record is ObtainX, on Android 12+, with a recent enough target SDK; never for ObtainX itself |
| `ShizukuInstaller` | `shizuku_apk_installer`, every call serialized by `shizuku_plugin.dart` (the plugin's mode is global state) | Silent elevated installs via Shizuku/Sui |
| `DhizukuInstaller` | `shizuku_apk_installer` (Dhizuku mode), same serialization | Silent elevated installs via the Dhizuku Device Owner binder |
| `ExternalInstaller` | Native channels: `installApkViaThirdParty` (`installer_provider.dart`), `ExternalInstallerBridge` (`external_install_bridge.dart`) | Hands the original container to a third-party installer the user picked; never silent. Completion comes from the package broadcast watched in `MainActivity.kt`, not a result from the installer (intentional divergence from upstream) |
| `RootInstaller` | `su` + `pm install` | Installs for the Android user ObtainX runs as (so it works under multi-user); a granted `su` check is reused for two minutes |

`getInstaller([App? app])` (`apps_provider_install.dart`) uses the app's own install method
if set, else the global `installerMode` (`shizuku`, `dhizuku`, `external`, `root`; anything
else is `StockInstaller`). Pass the app wherever one is known.

### Credentials

Source credentials (`github-creds`, `gitlab-creds`, `forgejo-creds`) are source-config
items stored as plain `SharedPreferences` strings, not encrypted; a non-blank per-app value
overrides the global one. `isSecretSettingKey` (`apps_provider_import_export.dart`) keeps
them, and the token fingerprints, out of an export made without secrets.

---

## 7. Conventions & patterns to follow

**State / lifecycle**
- Put side effects in `initState`, post-frame callbacks or listeners. Anything `build()`
  has to trigger must be idempotent, like `_ObtainiumState`'s scheduling.
- Prefer `context.select` over `context.watch` for large providers.
- Guard every `setState`/`Navigator`/`ScaffoldMessenger` call after an `await` with
  `if (!context.mounted) return;` (the `use_build_context_synchronously` lint is on).
- Identify an app by `listingKey` wherever a listing is meant: a package ID picks the wrong
  listing when the package is tracked from more than one store.
- `App` is immutable: build changes with `App.copyWith(...)` and persist them with
  `saveApps`; never mutate provider-owned objects in place.

**Errors / robustness**
- Throw `ObtainiumError` (or a typed subclass in `custom_errors.dart`) rather than raw
  `String`s. Key types: `RateLimitError` (with remaining minutes), `InvalidURLError`,
  `NoReleasesError`, `NoAPKError`, `NoVersionError`, `DowngradeError`, `InstallError`,
  `IDChangedError`, `RepositoryRenamedError`.
- In source files, wrap the main fetch logic:

  ```dart
  try {
    // ... fetch and parse ...
  } catch (e, stack) {
    rethrowOrWrapError(e, stack: stack);
  }
  ```

  `rethrowOrWrapError()` from `custom_errors.dart` passes through existing
  `ObtainiumError`s unchanged and wraps (and logs) raw exceptions with a stack trace.
- In pages, use the helper functions:

  ```dart
  try {
    await appsProvider.downloadAndInstallLatestApps([app.listingKey], context);
  } catch (e) {
    showError(e); // logs + snackbar, or a dialog for unexpected errors
  }
  ```

- Errors use **deferred localization**: the code is set at construction time (e.g.
  `RateLimitError(5)`) but the user-facing message is resolved via `localizeErrorCode()`
  only when `message` is read, so errors can be created in background tasks where no
  translation context is available.
- `MultiAppMultiError` bundles multiple per-app errors for batch operations; use
  `errors.add(appId, error, appName:)` to collect them.
- Don't swallow exceptions without a reason. Log them with `LogsProvider().add(...)` or the
  static `AppLogger.debug/info/warn/error` API over it (kept so upstream call sites compile
  unchanged). Where a catch deliberately ignores an error, say why.

**Categories & colour coding**
- Categories are stored as `Map<String, int>` (name → ARGB colour), as JSON in the
  `categories` preference.
- `generateRandomLightColor()` in `lib/utils/color_utils.dart` produces pastel colours in
  the HPLuv colour space with golden-angle hue distribution.
- `addMissingCategories()` in `apps_provider_lifecycle.dart` adds categories found in stored
  apps but missing from the map; `reconcileAppCategories()` strips deleted ones from records.

**Resources**
- Always `close()` an `HttpClient`/`IOClient` (use `finally`). Dispose
  `TextEditingController`s, stream subscriptions, and timers.

**UI / a11y / i18n**
- Use the theme; don't hardcode colors/shapes. Pull colors from
  `Theme.of(context).colorScheme`.
- All user-facing strings go through `tr()` / `plural()` with a key in
  `assets/translations/en.json`, the reference set. Other locales may lack a key (English
  is the fallback), but where one has it, its shape (string or plural object) must match;
  `test/translation_shape_test.dart` checks this.
- Reuse `M3eExpressiveSettingsCard` / `m3eListGroupItemRadius` / `positionalTileRadius` for
  grouped tiles instead of hand-rolling `Material(shape: ...)`.
- A button or switch that can't do anything right now is off (`onPressed`/`onChanged` null),
  so it looks muted, and still says why when tapped: wrap it in `ExplainedWhenOff`
  (`components/ui_widgets.dart`) with the reason, as Settings' switches do. Don't leave a
  control that looks on but does nothing, and don't hard-code a style's colours for every
  state (`WidgetStateProperty.all`), which hides that it's off.
- Pick files with `pickFile` (`lib/services/pick_file.dart`), or `pickTextFile` for text
  opened in the export folder. It's Android's document picker for backups, Import from
  URL list, app icons and fonts alike; only the MIME type passed differs. It takes a single
  type, so a kind of file with no type every phone agrees on (JSON, fonts) is picked as any
  file and checked once read.

---

## 8. Building, running, testing

```bash
flutter pub get
flutter analyze                    # must report no issues, infos included
flutter test                       # unit and widget tests in test/
flutter run --flavor normal        # or: --flavor fdroid -t lib/main_fdroid.dart
cd android
./gradlew assembleNormalDebug      # gradlew.bat on Windows
./gradlew assembleFdroidDebug -Ptarget=lib/main_fdroid.dart
```

- **Flavours** (`android/app/build.gradle.kts`): `normal` (GitHub releases, `lib/main.dart`)
  and `fdroid` (`lib/main_fdroid.dart`), both with application ID `dev.bikram.obtainx`
  (debug builds add `.debug`). Pass `--flavor` to `flutter run` / `flutter build`, as
  `.vscode/launch.json` does. The Flutter Gradle plugin builds `lib/main.dart` unless told
  otherwise, so `assembleFdroidDebug` builds the fdroid variant with the normal entry
  point; add `-Ptarget=lib/main_fdroid.dart` for the real thing.
- **Tests:** `test/` is a large suite of unit and widget tests (goldens in `test/goldens/`).
  `test/flutter_test_config.dart` loads `en.json` for every suite, and `sqflite_common_ffi`
  lets tests build providers that open SQLite. Run one file with `flutter test <path>`.
- **Before a PR:** analyze clean, tests passing, both flavours building. Format new code
  with `dart format`, but don't reformat untouched code: the fork periodically merges from
  upstream, and churn becomes merge conflicts. Target the current working branch if one
  exists, otherwise `main` (`.github/pull_request_template.md`).
- **Releases:** `.github/workflows/build.yml` (manual) pins Flutter 3.50.1 to match the
  fdroiddata recipe and builds both flavours per ABI (versionCode `× 10 + 1/2/3` for
  x86_64 / armeabi-v7a / arm64-v8a), signing the fdroid APKs so F-Droid's reproducible
  build can reuse the signature.
- Several dependencies are **git-pinned to commit SHAs** in `pubspec.yaml`
  (`android_package_installer`, `android_package_manager`, `shared_storage`,
  `shizuku_apk_installer`) — keep them pinned; don't switch to `ref: main`/`ref: master`.
- `build.sh`, `sign.sh` (prompts for the keystore password) and
  `.github/workflows/release.yml` are inherited from upstream; `build.sh` and
  `docker/builder.sh` expect a `.flutter` submodule this repository doesn't contain.

---

## 9. Where to start for common tasks

| Task | Start here |
| --- | --- |
| Add a new app source | New file in `app_sources/`; add its constructor to `SourceProvider._sourceFactories` in display-name order (`DirectAPKLink` and `HTML` stay last) |
| Add a per-app option | The source's `additionalSourceAppSpecificSettingFormItems` (or the base `_commonAppSettingFormItems`; both reach the form via `combinedAppSpecificSettingFormItems`) |
| Add a global setting | A typed getter/setter in `settings_provider.dart` + a control in the matching section widget in `pages/settings.dart` (`_UpdatesSection`, `_AppearanceSection`, `_WarningsSection`, …). Integrations holds the installer and third-party tools; warning and show/hide toggles go in Warnings. |
| Change update logic | `apps_provider_updates.dart` (foreground) / `bgUpdateCheck` in `apps_provider.dart` (background) |
| Change version comparison | `lib/version/` |
| Change install behaviour | `apps_provider_install.dart`, `lib/installers/` |
| Change the app list row | `_AppListItem` / `_SwipeableListItem` in `pages/apps.dart` |
| Add a link action | `initDeepLinks()` / `interpretLink` in `pages/home.dart` |
| Add a reusable widget/dialog | `components/ui_widgets.dart` (or a dedicated file in `components/` or `widgets/`) |
| Theme/shape/motion tweaks | `buildObtainiumTheme()` in `lib/theme.dart`; sub-themes and colour schemes in `lib/theme/`, applied by `_ObtainiumState._buildAppThemeData` |
