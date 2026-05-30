# ObtainX Performance Audit — UI Freezing & Jank

**Date:** 2026-05-29

**Architecture note:** ObtainX is a **Flutter** app (Dart). The "main thread" is Flutter's
**main UI isolate**. All findings reference Dart/Flutter patterns.

---

## CRITICAL

### C1. Every foreground event re-runs full app load on the UI isolate
**File:** `lib/providers/apps_provider.dart:1337–1343`

Every time the user unlocks the screen or returns from another app, `loadApps()` is called.
This is the direct cause of the longest freezes. `loadApps()` does, on the main isolate:

- `getAllInstalledInfo()` — calls `pm.getInstalledPackages(flags: {getSigningCertificates})`
  across the platform channel, enumerating **every installed package on the device with signing
  certificates**. This is the single most expensive operation in the app.
- `getAppsDir().listSync()` (line 2823) — synchronous directory listing on UI isolate.
- `jsonDecode(await File(...).readAsString())` per tracked app (lines 2831–2833) — JSON
  parsing for each app.
- `getCorrectedInstallStatusAppIfPossible` reconciliation for every app, plus two
  `notifyListeners()` calls (lines 2815, 2915) forcing full rebuilds.

The "touch events register at the wrong time" symptom is the classic signature of queued
gestures flushing all at once when the blocked event loop unblocks.

**Fixes:**
- Debounce/throttle the foreground `loadApps()` — skip if run within the last N seconds.
- Don't request `getSigningCertificates` for the quick foreground refresh (certs are only
  needed at install/verify time).
- Move JSON decode and reconciliation into `Isolate.run` (the pattern already exists at
  line 3928 and in `services/html_parse_isolate.dart`).

---

### C2. Tab pages are fully destroyed and rebuilt on every switch — no `IndexedStack`
**File:** `lib/pages/home.dart:536–565`

The body uses `PageTransitionSwitcher` with only one page widget in the tree at a time. Every
tab switch **fully disposes the old page and rebuilds the new one from scratch**. For the Apps
tab this means re-running the entire filter→sort→group pass (`apps.dart:2304–2503`) and
reconstructing the whole sliver list. This is the direct cause of the Settings ↔ App list
freeze.

Note: `home.dart:436` has a comment mentioning "IndexedStack child" but the code does **not**
actually use `IndexedStack` — pages are not kept alive.

**Fix:** Use `IndexedStack` (keeps all four pages mounted, switching is just a paint operation)
or wrap pages in `AutomaticKeepAlive`. Fixing this also eliminates the busy-wait in M4.

---

### C3. Settings page watches the entire `SettingsProvider` — full page rebuild on any setting change
**Files:** `lib/pages/settings.dart:346`, `settings.dart:1847`

```dart
SettingsProvider settingsProvider = context.watch<SettingsProvider>();
```

`SettingsProvider` calls `notifyListeners()` from **every single setter** (dozens of them).
Because the Settings page watches the entire provider, the very large Settings page rebuilds on
any setting toggle. Combined with C2 (full rebuild on tab entry), this compounds the Settings
tab freeze. Same anti-pattern at `apps.dart:1135`, `apps.dart:5026`, `import_export.dart:67`.

The fix is already correctly applied in `main.dart:310`, `home.dart:437`, `apps.dart:2092`,
and `custom_app_bar.dart:143` — narrow `context.select` reads for only the fields each subtree
needs.

---

## HIGH

### H1. `SharedPreferences` getters do synchronous JSON decoding on every call, inside `build()`
**File:** `lib/providers/settings_provider.dart`

- `categories` getter → `jsonDecode(prefs.getString('categories'))` every call (lines 752–759)
- `appFolders` getter → `jsonDecode` + maps to `AppFolder.fromJson` every call (lines 808–814)
- Per-folder view getters → `jsonDecode(prefs.getString('folderView_$id'))` every call
  (lines 836–840)

These getters are called repeatedly in hot build paths. In `apps.dart:2513`,
`settingsProvider.appFolders` is read in build and again inside two map-comprehensions
(lines 2514–2536). Every tab entry / rebuild re-parses these JSON blobs synchronously on the
UI isolate.

`_categoriesMemory` memoization already exists at lines 752–754 — the same pattern needs to be
extended to `appFolders` and folder-view settings.

---

### H2. Constructor does synchronous file I/O on main isolate at startup
**File:** `lib/providers/apps_provider.dart:1344–1385`

- `userAppIconsDir.existsSync()` / `createSync` (lines 1351–1352)
- `iconsCacheDir.existsSync()/createSync` (lines 1357–1368)
- `_migrateUserIconsFromLegacyCacheDir()` → `iconsCacheDir.listSync()` + per-file
  `existsSync/copySync/deleteSync` (lines 2958–2982)
- `apkDir.listSync().where(... statSync().modified ...)` to delete stale APKs (lines 1376–1383)

This all runs during app construction, blocking the first frames. `statSync()` per file is
particularly costly. These should be deferred post-first-frame or moved into `Isolate.run`.

---

### H3. Full-resolution app icons held in memory for every app
**Files:** `lib/providers/apps_provider.dart:3043`, `3051`, `3209`;
`lib/pages/apps.dart:297–313`

Icons come from `applicationInfo.getAppIcon()` (full-resolution adaptive-icon PNG, often
192–432px). They are cached to disk and held in memory as `Uint8List` per app
(`AppInMemory.icon`). They are rendered at 40dp via `Image.memory` with `cacheWidth/cacheHeight`
(good for GPU texture) but the full-size decoded `Uint8List` is retained in the `apps` map for
every tracked app. On a large app list this is significant heap pressure and contributes to GC
pauses during scroll and tab switches.

**Fix:** Downscale icons to display size before caching (decode + resize in `Isolate.run`), or
apply an LRU bound on in-memory icons.

---

### H4. `notifyListeners()` called excessively during refresh
**File:** `lib/providers/apps_provider.dart` — lines 1408, 1470, 2815, 2915, 3026, 3069, etc.

The app already does substantial work to narrow listeners via `context.select` and per-row
`_AppIconWidget`/`_AppListItem` subscriptions (well done). But the two `notifyListeners()`
inside `loadApps()` (C1) still trigger full home + page rebuilds on every foreground event,
amplifying C1 and C2.

**Fix:** Only notify when app data actually changed; coalesce the load-start/load-end
notifications.

---

## MEDIUM

### M1. "Reduce visual effects" toggle is incompletely wired
**File:** `lib/providers/settings_provider.dart:450–460`

`reduceVisualEffects` correctly forces `progressiveBlurEnabled` off, but does **not** gate:
- `useGradientBackground` in `apps.dart:4278`, `settings.dart:701`,
  `import_export.dart:652`, `add_app.dart:1271`, `custom_app_bar.dart` — gradient painting
  continues.
- The `PageTransitionSwitcher` animation on tab switches — a separate `disablePageTransitions`
  setting controls this, but `reduceVisualEffects` does not force it on.

This means a user enabling "reduce visual effects" to fix jank still pays for gradients and tab
transitions. This directly contradicts user expectations and explains the report: *"I have the
option enabled but still freezing."*

---

### M2. `BackdropFilter` blur runs every frame when progressive blur is enabled
**Files:** `lib/widgets/progressive_top_edge_overlay.dart:50–56`, `123–129`;
`home.dart:575–580`

`BackdropFilter` is one of the most expensive Flutter operations. It's correctly default-off
for new installs (lines 432–435) but migrated **on** for existing users (lines 87–103). Users
upgrading inherit the expensive path without realizing it. Not a root cause for the specific
reported symptoms, but the dominant per-frame GPU cost when enabled.

---

### M3. Update count computed inside `context.select` on every qualifying rebuild
**File:** `lib/pages/home.dart:425–430`

`findExistingUpdates(...)` iterates all tracked apps inside a `context.select` lambda. The
`select` correctly limits when this runs, but the full iteration happens on each qualifying
rebuild. Low priority given the gating, but worth memoizing.

---

### M4. Tab switch busy-waits with 1-microsecond spin loop
**File:** `lib/pages/home.dart:378–382`

```dart
while ((pages[0].widget.key as GlobalKey<AppsPageState>).currentState != null) {
  await Future.delayed(const Duration(microseconds: 1));
}
```

This spins the event loop waiting for `AppsPage` `State` to unmount before clearing history
(to avoid a duplicate-`GlobalKey` crash). This only exists *because* pages are torn down on
switch (C2). Fixing C2 with `IndexedStack` removes the key hazard entirely and this busy-wait
with it.

---

## Priority Order for Fixes

| Priority | Issue | User-visible impact |
|---|---|---|
| 1 | **C1** — foreground `loadApps` + `getInstalledPackages` on UI isolate | Fixes lock/unlock and app-switch freezes |
| 2 | **C2** — IndexedStack for tabs | Fixes tab-switch freeze, removes M4 busy-wait |
| 3 | **C3 + H1** — narrow Settings subscriptions + memoize JSON getters | Fixes Settings-tab jank |
| 4 | **M1** — complete the "reduce visual effects" escape hatch | Makes user's existing mitigation actually work |
| 5 | **H2 + H3** — startup sync I/O + icon memory | Reduces GC pauses and startup latency |

---

## What Is Already Done Well

- HTML parsing is offloaded to isolates everywhere (`services/html_parse_isolate.dart`) —
  keep this pattern.
- Per-row icon (`_AppIconWidget`, `apps.dart:285`) and per-row download progress use isolated
  `context.select` subscriptions — only the affected row rebuilds.
- The apps-page rebuild token excludes `lastUpdateCheck` and icon fields (`apps.dart:178–215`)
  preventing 4Hz full-list rebuilds during refresh.
- Download-progress notifications are debounced (`_progressNotifyTimer`).
- `main.dart`, `custom_app_bar.dart`, `home.dart`, and the apps-page `SettingsProvider` reads
  all use correct narrow `context.select` — apply the same pattern in Settings page.

The `MainActivity.kt` native side is not implicated in any of the three reported symptoms.
