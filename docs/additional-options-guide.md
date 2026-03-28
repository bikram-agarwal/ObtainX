# Additional options (per app) – what each setting does

This screen controls how **this one app** is tracked, how ObtainX figures out its version, and which APK or download link it picks. **Not every option appears for every app.** The list depends on **which source** the app uses (GitHub, F-Droid, a custom web page, and so on). Options for that source usually appear **at the top**; the shared sections below them apply to most apps.

Each option below has an **example** in plain language. Regex examples are illustrative; you may need small tweaks for a real app.

---

## Tracking behavior

These settings affect **whether** the app is checked, **how often**, and **whether** it clutters your main list.

| Option | What it does | Example |
|--------|----------------|---------|
| **Track-only** | ObtainX checks for updates and can show version info, but **will not download or install** the app for you. | You added **ObtainX itself** from GitHub but install updates from another store; you still want a “new version available” hint. |
| **On-Demand Only** | Hides the app from the main apps list. Update checks run when **you** open the On-Demand Only screen, pull to refresh there, or open **this app’s detail page** – not as part of the normal “all apps” flow. | You track **20 rarely used tools** and do not want them in the main grid; once a month you open On-Demand and refresh. |
| **Exempt from background updates (if enabled)** | If background updating is on globally, this app is **skipped** in the background. You can still check or update it manually. | A **large game** you only update on Wi‑Fi at home; you exempt it so background checks do not run for it. |
| **Skip update notifications** | You will **not** get notifications when this app has an update (other apps are unchanged). | A **beta app** that releases daily; you still see it in the list but your phone does not ping every day. |

---

## Version & detection

These control **what counts as “the version”** and **how it compares** to what Android reports as installed.

### Trim version string with RegEx

**What it does:** A **regular expression** is run on the version text ObtainX gets from the source (tag, title, page text, and so on). The regex must **match** somewhere in that text. ObtainX then builds the final version string using the match and your **match group** setting (next row).

**You don't need to write the regex yourself.** Tap the helper button next to this field and the dialog does it for you:
1. It pre-fills the raw version string ObtainX last fetched from the source.
2. It parses it and suggests the most useful substrings as a list — strips "v" prefixes, letter-only words, extracts semver patterns, and more.
3. Pick the one you want (or type a custom value), tap Apply, and it writes the regex and match group into the fields automatically.

If it can't build a pattern, it says so and leaves the fields unchanged — you can still type manually.

**Example (manual):** The source gives `release-v12.4.0-final`. You only want `12.4.0`. You set trim regex `v(\d+\.\d+\.\d+)` so the pattern finds a `v` followed by three version numbers. You set match group to `$1` (see below) so the stored version is `12.4.0`, not the whole `release-v12.4.0-final`.

**Example (helper):** Same tag. The helper suggests `12.4.0` as a candidate. You select it, tap Apply — done. The helper writes `(\d+\.\d+\.\d+)` and `$1` for you.

---

### Match group to use for “Trim version string with RegEx”

**What it does:** After the trim regex matches, this field says **which part of the match** becomes the version string.

- **`$0`** – the **entire** text that the regex matched (all of it, including prefixes you may have kept inside the pattern).
- **`$1`, `$2`, …** – the **1st, 2nd, … parenthesized** `(...)` **capturing group** in your regex.  
- You can **combine** groups, e.g. **`$1.$2`** to glue two pieces together.
- A **plain number** like **`1`** (without `$`) is treated like **`$1`**.

**Examples:**

| Raw text from source | Trim regex | Match group | Resulting version |
|----------------------|------------|-------------|-------------------|
| `version 3.8.2 (64-bit)` | `(\d+\.\d+\.\d+)` | `$1` or `1` | `3.8.2` |
| `version 3.8.2 (64-bit)` | `version (\d+\.\d+\.\d+)` | `$0` | `version 3.8.2` (whole match) |
| `version 3.8.2 (64-bit)` | `version (\d+\.\d+\.\d+)` | `$1` | `3.8.2` |
| Tag `app-2-10-0` | `(\d+)-(\d+)-(\d+)` | `$1.$2.$3` | `2.10.0` |

If the regex has **no** parentheses, usually **`$0`** is enough (the whole match is the version). If you use parentheses to **isolate** the version numbers, use **`$1`** (or `$2`, etc.) so you drop surrounding junk.

---

| Option | What it does | Example |
|--------|----------------|---------|
| **Reconcile version string with version detected from OS** | When **on**, ObtainX compares the source’s version string with the **version Android reports** for the installed app and tries to keep them consistent. Turn **off** when the source’s version format does not match what Android shows. | Source says **`2024.12.1`** but Android shows **`1.2.3`** (different scheme); reconciliation may confuse things – you turn **off** and rely on one side. |
| **Use release date as version string (pseudo-version)** | *(Some sources only.)* Uses the **release date** as a stand-in “version” when normal version detection is unreliable but a date is available. | A site only shows **“Posted 2025-03-01”** and no semver; pseudo-version lets update checks compare “newer” by date. |
| **Use app versionCode as OS-detected version** | Treats the APK’s **versionCode** (integer inside the APK) as what the OS “sees” for installed vs latest. | Source labels are messy, but **`versionCode` always increases**; you want comparisons based on that number. |

---

## APK selection

These narrow **which APK file** ObtainX picks when several builds exist (split APKs, per-architecture, multiple files in a release, and so on).

| Option | What it does | Example |
|--------|----------------|---------|
| **Filter APKs by regular expression** | Only APKs whose **name or URL** matches the pattern are considered. Tap the helper button to pick from the actual filenames ObtainX found — it generates the regex from your selection. | Release contains `app-arm64.apk`, `app-x86.apk`, `app-universal.apk`; tap helper → select `arm64` → Apply. |
| **Invert regular expression** | **Flips** the filter: APKs that **do not** match the regex are kept. | Regex `debug` with invert **on** drops any file with “debug” in the name and keeps **release** builds. |
| **Attempt to filter APKs by CPU architecture if possible** | Tries to prefer an APK that matches your device’s **CPU architecture** when the source lists several. | Your phone is **arm64-v8a**; the source offers `armeabi-v7a` and `arm64-v8a`; ObtainX prefers the arm64 file. |
| **Include ZIP files** | *(Sources that support it.)* Treats **ZIP** downloads like other assets so you can pick an APK inside. | Release uploads **`MyApp-2.0.zip`** containing one APK and readme; you enable ZIP handling for that source pattern. |
| **Filter APKs inside ZIP** | Regex to choose the **right APK inside a ZIP** when ZIPs are included. | ZIP contains `base.apk` and `config.en.apk`; regex `base\.apk` picks the main package. |

---

## Network, background & automation

| Option | What it does | Example |
|--------|----------------|---------|
| **Set Google Play as the installation source (if Shizuku is used)** | With **Shizuku / Dhizuku / Sui**, installs can be recorded as coming from **Google Play** for apps that check install source. | A banking app **refuses** “unknown source”; with Shizuku installs, this option can satisfy its check (device and policy dependent). |
| **Allow insecure HTTP requests** | Allows **`http://`** URLs for this app, not only **`https://`**. Less secure. | An old **internal server** only serves APKs over plain HTTP. |
| **Refresh app details before download** | Fetches **fresh metadata** from the source immediately before download. | A project **reuses the same file name** for each release; refresh reduces the chance of caching an old file. |

---

## Source-specific options (examples)

The following appear **only** (or mainly) for apps using that kind of source. Wording in the app may match these titles.

### GitHub and Codeberg

| Option | What it does | Example |
|--------|----------------|---------|
| **Include prereleases** | Treats **pre-releases** (beta, RC, etc.) like normal releases when picking the newest. | You want **nightly** or **beta** tags, not only stable. |
| **Fallback to older releases** | If the newest matching release has **no usable APK**, ObtainX tries **older** releases. | Latest release is **source-only**; the previous one has the APK – fallback finds it. |
| **Filter release titles by regular expression** | Only releases whose **title** matches are considered. Tap the helper button — it lists actual release titles from this repo and generates the regex from whichever you pick. | Titles include `v2.0 (stable)` and `v2.1-beta`; tap helper → select the stable title → Apply. |
| **Filter release notes by regular expression** | Same, but scans **release notes / body**. | Notes must contain **`[playstore]`** to count as a consumer build. |
| **Verify the ‘latest’ tag** | Uses GitHub’s **`/latest`** API so the “latest” release is not missed when list order is odd. | Repo maintains **`latest`** correctly but API list order is not chronological. |
| **Sort method** | How releases are **ordered** before ObtainX walks them (date, smart name parsing, raw name, API order, or hybrid). | Many assets share similar names; **Release date** picks strictly by publish time. |
| **Use latest asset upload as release date** | Uses **newest file upload time** on the release as the date (not only publish time). | Maintainer **re-uploads** a fixed asset; upload time reflects the real change. |
| **Use release title as version string** | The **release title** becomes the version string ObtainX shows and compares. | Tag is `build-4902` but title is **`2.4.0 – hotfix`**; you want `2.4.0` visible. |

### GitLab

| Option | What it does | Example |
|--------|----------------|---------|
| **Fallback to older releases** | Same idea as GitHub: try **older** GitLab releases if the newest has no suitable asset. | Latest milestone has only **Docker**; older tag still has the **APK**. |

*(GitLab credentials live under **Settings**, not per-app Additional options.)*

### HTML / custom page / “track from a website”

| Option | What it does | Example |
|--------|----------------|---------|
| **Intermediate link** | **One or more** pages to open in order, following links until the page with real APK links. | Home page → **“Downloads”** page → **“Android”** page with `.apk` links. |
| **Custom APK link filter (regex)** | On the **final** page, which URLs count as APKs (often something like `.apk$`). | Page has `.apk` and `.sha256` links; regex `\.apk$` ignores checksum files. |
| **Filter links by link text** | Uses visible **link text**, not only URL, when deciding matches. | Many links say **“Download APK”** with different URLs; you filter text containing **APK**. |
| **Match links outside &lt;a&gt; tags** | Also picks up URLs **not** wrapped in normal HTML links. | Page prints a raw URL in a `<div>` without `<a href>`. |
| **Skip sorting** | Does not reorder found links (uses whatever order the scraper got). | Order on page is already **newest first**. |
| **Take first link** | After filtering/sorting rules, the **first** matching link wins. | You know the layout: first APK link is always the main build. |
| **Sort by only the last segment of the link** | Sort key is the **last path segment** of the URL (often the file name). | URLs differ only by **`app-1.2.apk`** vs **`app-1.3.apk`**. |
| **Attempt to filter links by CPU architecture** | On intermediate steps, prefers links that mention your **architecture**. | Folder lists **`…-arm64.apk`** and **`…-x86.apk`**. |
| **Apply version string extraction Regex to entire page** | Runs your **trim version** regex on the **full HTML** of the page. | Version **`1.4.2`** only appears inside a **script** or hidden block, not near the link. |
| **Request header** | Sends extra **HTTP headers** (e.g. **User-Agent**) so the server returns a normal browser page. | Site returns **403** to default clients; a desktop Chrome User-Agent works. |
| **Default pseudo-versioning method** | How ObtainX invents a **synthetic version** when there is no real one: **partial APK hash**, **APK link hash**, or **ETag**. | Direct link **no version in URL**; hash changes when the file changes, so updates are still detectable. |

### Direct APK link

**What it does:** For a **single fixed `.apk` URL**, many version/APK fields are **hidden** because there is nothing to choose.

**Example:** You track `https://example.org/app/latest.apk` that the server overwrites in place; pseudo-versioning and headers still help detect changes.

### F-Droid (official repo)

| Option | What it does | Example |
|--------|----------------|---------|
| **Filter versions by regular expression** | Only **indexed versions** matching the pattern are considered. | Repo lists **`1.0`, `1.1-beta`, `1.2`**; regex `^\d+\.\d+$` skips the beta label if you write the pattern that way. |
| **Try selecting suggested versionCode APK** | Prefer the APK F-Droid **marks** as suggested for common devices when metadata exists. | F-Droid shows a **recommended** variant for your ABI. |
| **Auto-select highest versionCode APK** | Among candidates, pick the **highest versionCode**. | Same version label but **split APKs** with different codes; highest wins. |

### F-Droid third-party repo

| Option | What it does | Example |
|--------|----------------|---------|
| **App ID or name** | Tells ObtainX **which app** in a multi-app repo you mean when the URL alone is ambiguous. | Repo URL is `https://fdroid.example.org/repo` and hosts **50 apps**; you enter **`org.myapp`**. |
| **Auto-select highest versionCode APK** | Same as official F-Droid when several APKs exist. | *(See F-Droid example above.)* |
| **Try selecting suggested versionCode APK** | Same as official F-Droid. | *(See F-Droid example above.)* |

### APKMirror

| Option | What it does | Example |
|--------|----------------|---------|
| **Fallback to older releases** | Tries **older** APKMirror uploads if the newest fails your filters. | New upload is **bundles only**; older upload has a **standalone APK**. |
| **Filter release titles by regular expression** | Only **upload titles** matching the pattern count. | You only want **“Stable”** builds in the title, not **“Beta”**. |

*(APKMirror apps are **track-only** at the source level: ObtainX does not install from APKMirror itself.)*

### APKPure

| Option | What it does | Example |
|--------|----------------|---------|
| **Fallback to older releases** | Tries **older** listings if the newest is not usable. | Latest page is **region-blocked**; previous version still loads. |
| **Stay one version behind latest** | Installs the **second-newest** on purpose. | **v5** is buggy; you stay on **v4** until v5.1 exists. |
| **Auto-select first of multiple APKs** | When several APKs match, take the **first** in list order. | List order is **stable**; first row is always the variant you want. |

### SourceHut

| Option | What it does | Example |
|--------|----------------|---------|
| **Fallback to older releases** | Tries **older** RSS / ref items if the newest is not suitable. | Newest ref has **no APK** artifact; an older ref does. |

### Farsroid

| Option | What it does | Example |
|--------|----------------|---------|
| **Auto-select first of multiple APKs** | When several files exist for one version, pick the **first**. | Same as APKPure-style “first row wins.” |
| **Use release title as version string** | **Release title** is shown and compared as the version. | Title shows **`5.0.1`** clearly; tag is an internal code. |

---

## Quick tips

- **Use the regex helper first** — Tap the helper button next to any regex field before writing a pattern manually. It reads what the source actually returned, suggests the part you likely want, and generates the regex for you. Only write one manually if the helper can't build it.
- **Regex (manual fallback):** Start simple (one clear pattern), **save**, then **check for updates** and see the version ObtainX shows. If it fails, widen the pattern or fix the match group.
- **Match group:** If unsure, try **`$1`** when you have **one pair** of parentheses around the version; try **`$0`** when there are **no** parentheses and the whole match should be the version.
- After changes, **save**, then refresh **this app** or pull to refresh the list.
- When debugging, turn **off** filters and turn **on** **fallback to older releases** one step at a time.

---

*This guide describes ObtainX behavior in everyday terms. Exact labels in the app follow your language settings and may differ slightly from the titles above.*
