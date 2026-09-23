**ObtainX version comparison regression report - 12 September 2026**

My version-comparison changes introduced real regressions. I made the normal parser too restrictive and, separately, made track-only apps bypass version ordering altogether. The result is both unnecessary "Version order unclear" messages and confident "Update available" messages for older or equivalent releases.

The first fix should be to remove the assumption that different text means a newer version. Cross-Device Services proves this is necessary even when both versions have exactly the same format.

This report examines the current checkout, `109a3b5d`, including the version overhaul in `29d292f3`. Application code was not changed during this investigation.

**What went wrong in the code**

1. **Track-only became a shortcut around comparison.** APKMirror forces `trackOnly = true`. The central decision function checks that setting before parsing versions or examining package codes. If the installed and latest strings differ, it returns "installed is older." This explains the six APKMirror screenshots, including Cross-Device Services. Track-only controls how the app is obtained; it should not prevent comparison with a package installed on the device. Explicit pseudo-version tracking also uses this shortcut. [APKMirror source](/D:/git/MyProjects/ObtainX/lib/app_sources/apkmirror.dart:537), [decision shortcut](/D:/git/MyProjects/ObtainX/lib/version/app_version.dart:214).

2. **The parser rejects useful comparisons too early.** It checks whether suffixes match before comparing the numeric release. Consequently, `6.12.36` versus `6.1.0-huawei` becomes "unclear" even though the release numbers can be ordered. It also lacks suitable handling for the Google labels containing underscores, bracketed metadata and product prefixes. For Android System Intelligence, its generic extraction can start inside `pixel9.961955194`, losing the meaning of the original label. [Parsing](/D:/git/MyProjects/ObtainX/lib/version/version_comparison.dart:109), [suffix check before numeric comparison](/D:/git/MyProjects/ObtainX/lib/version/version_comparison.dart:292).

3. **Source information is lost or insufficiently qualified.** APKMirror extracts its version starting at the first digit in a release title. This can drop prefixes present in the installed version, as with Satellite Gateway. It normally chooses the first feed item, while APKPure walks version groups in API order. Neither operation proves that the chosen release is newer than the installed app or belongs to the same device variant. The comparison layer must reconcile those differences instead of interpreting the selected source item as an upgrade automatically. [APKMirror selection and extraction](/D:/git/MyProjects/ObtainX/lib/app_sources/apkmirror.dart:665), [APKPure selection](/D:/git/MyProjects/ObtainX/lib/app_sources/apkpure.dart:306).

4. **A package code can override conflicting release information without checking the build variant.** The code correctly binds a store version code to a selected asset and a device observation, but does not establish that both belong to the same distribution or device variant. This matters for inshorts' Huawei release. A higher code is valuable evidence, but should not silently settle a conflict between different variants. Android distinguishes display names from internal version codes and permits separate code ranges for multiple APKs. [Current code precedence](/D:/git/MyProjects/ObtainX/lib/version/app_version.dart:224), [Android versioning documentation](https://developer.android.com/studio/publish/versioning).

5. **Installed state and source acknowledgement still share one field.** For track-only apps, reconciliation can observe a newer installed package but retain an old `installedVersion` label unless the device version compares equal to the selected source release. The central decision then ignores the fresh observation because of the shortcut above. A separate diagnostic reproduced this stale-state problem. [Reconciliation](/D:/git/MyProjects/ObtainX/lib/providers/apps_provider_lifecycle.dart:160).

The centralization itself is useful: the details page, update badges, filters and background checks now share a decision. But that also spreads a wrong decision across all of them. This is more than a misleading status banner. For APKMirror, the Update button opens the source page; these screenshots do not demonstrate an automatic downgrade installation. [Display mapping](/D:/git/MyProjects/ObtainX/lib/pages/app.dart:56), [update predicates](/D:/git/MyProjects/ObtainX/lib/providers/apps_provider_updates.dart:52), [background consumers](/D:/git/MyProjects/ObtainX/lib/providers/apps_provider.dart:1797), [APKMirror button behavior](/D:/git/MyProjects/ObtainX/lib/pages/app.dart:3042).

**Findings for all nine screenshots**

1. **Cross-Device Services - definite false update**

   Installed: `1.0.1283.978582931`  
   Store: `1.0.1219.947788260`

   The numeric comparator already correctly returns "installed is newer." The app-level track-only shortcut reverses the outcome to "Update available." Fix: allow the real device comparison for track-only apps. Expected result: **Newer on device**, excluded from normal update counts and notifications.

2. **Google Play Store - definite false update**

   Installed: `53.0.27-34 [0] [PR] 973951861`  
   Store: `52.9.22`

   The installed release is `53.0.27`, ahead of `52.9.22`. The parser rejects the bracketed suffix; track-only then treats the unequal strings as an update. Fix: recognize the Play Store release core and retain its revision/build metadata separately. Expected result: **Newer on device**. Within the same release core, meaningful build revisions must still be compared.

3. **Meet - definite false update for the displayed releases**

   Installed: `376.0.977329897.public_beta.duo.android_20260907.02_p0`  
   Store: `375.0.976439154.duo.android_20260831.02_p4.t`

   Release `376` is ahead of `375`; the installed label also contains a later build/date. The generic parser rejects this format, and track-only turns the difference into an update. Fix: parse the release/build fields and channel separately. Expected result: **Newer on device**. A deliberate beta-to-stable switch should be represented as a channel change, not advertised as a newer release merely because the labels differ.

4. **Satellite Gateway - definite equivalent-version mismatch**

   Installed: `stargate.android_20260817_00_RC00.release_dynamic_universal`  
   Store: `20260817_00_RC00.release_dynamic_universal`

   The entire build identifier matches; the installed label has an extra product prefix. The parser cannot establish equality and track-only reports an update. Fix: recognize this prefix for this version family, preserving the complete date, revision and variant. Expected result: **Same version / equivalent format**, with no update.

5. **Image Toolbox - release tag compared against an APK flavor**

   Installed: `4.2.0-foss`  
   Store: `4.2.0`

   The parser stops at `differentVariants`. Upstream's actual `4.2.0` release includes FOSS and non-FOSS APKs, including `image-toolbox-4.2.0-foss-arm64-v8a.apk`. The tag identifies the release; the selected asset identifies the flavor. Fix: compare release `4.2.0` and match the installed FOSS flavor to its asset. Expected result: **Same release** when tracking the matching FOSS build. If the selected asset is another flavor, identify that change separately. The screenshot's "2 APKs" does not establish which asset is selected. [Release assets](https://github.com/T8RIN/ImageToolbox/releases/expanded_assets/4.2.0).

6. **inshorts - release-number conflict, with an additional decision path to verify**

   Installed: `6.12.36`  
   Store: `6.1.0-huawei`

   The installed release number is ahead. With these strings and ordinary auto detection alone, current code returns **unclear**, not the screenshot's **Update available**. Therefore parser strictness alone does not explain this screenshot.

   APKPure supplies a `version_code`, also used in the displayed asset name (`5197713`). The app prioritizes that code over the label comparison. I reproduced "Update available" when using that source code and a lower, synthetic installed code. Pseudo mode can also produce the screenshot's status. The real installed code and saved mode are not visible in the screenshot, so the exact branch remains unconfirmed. Fix: inspect those recorded values, retain the selected asset's distribution, and surface contradictory evidence instead of silently promoting an older Huawei-labelled release to a normal update. [APKPure metadata extraction](/D:/git/MyProjects/ObtainX/lib/app_sources/apkpure.dart:81).

7. **Google Play Protect Service - unsupported variant comparison presented as certain**

   Installed: `C.6.odad-stub.948481320`  
   Store: `6.playstore.pixel3.945720966`

   Track-only produces "Update available" without establishing any ordering. The installed trailing build number is higher, but `odad-stub` and `pixel3` also indicate different variants. Fix: identify the appropriate variant and only compare build identifiers within a verified common version scheme. Expected result from the available evidence: **No confirmed newer compatible update**. If the variants are comparable, the displayed trailing numbers point toward the installed build being newer; that comparability must not be assumed.

8. **Android System Intelligence - device variants conflated with release order**

   Installed: `C.6.playstore.pixel9.961955194`  
   Store: `28.playstore.oemfull.969713662`

   Track-only again reports an update without comparing. The string parser also misidentifies the schemes. `pixel9` and `oemfull` need distinct treatment; neither `28 > 6` nor the larger final number establishes a compatible update by itself. Fix: preserve the product/device branch and select a suitable source candidate before ordering its build. Expected result: **A verified update for the matching variant, or a specific variant mismatch**, rather than an unconditional Update banner.

9. **Wa Enhancer - different builds need repository evidence**

   Installed: `1.5.5 (4D91B33C)`  
   Store: `1.5.5-ced5040c`

   These contain different commit hashes, not just different punctuation. The current comparator already recognizes `1.5.5 (CED5040C)` and `1.5.5-ced5040c` as equal; I verified that separately. Its missing capability is resolving the order of two different builds of the same release.

   Upstream's build configuration confirms that it embeds an eight-character Git hash in `versionName`. Fix: resolve both hashes in the tracked GitHub repository and use commit ancestry or an established source build sequence. If the store commit descends from the installed one, report **Update available**; reverse ancestry means **Newer on device**. Keep a specific unresolved-build status only when that evidence is unavailable or the histories diverge. Do not sort hashes numerically or discard them and declare both builds equal. I could not retrieve the exact two commits during this audit, so their order is not confirmed here. [Upstream build configuration](https://raw.githubusercontent.com/Dev4Mod/WaEnhancer/master/app/build.gradle.kts).

**How I would fix this, in order**

1. **Correct the update decision and its tests first.** Separate "the tracked source changed" from "a newer compatible app is available." Remove the unconditional unequal-string shortcut for tracked apps with real device observations. Preserve source-change tracking for opaque identifiers without calling every change a newer app. Keep one central decision for the UI, counts, filtering and background behavior.

2. **Repair normalization without throwing away meaningful information.** Parse release number, build revision, prerelease/channel, flavor and commit identity as distinct facts. Handle known harmless wrappers such as the Satellite Gateway prefix and Play Store annotations. Compare a recognized numeric release before allowing a packaging suffix to erase that information. Keep compatibility as a separate question: identifying a newer release does not authorize switching flavors. Preserve the existing alpha/beta/RC ordering and numeric-overflow protection.

3. **Use source and selected-asset context.** Preserve the original selected release title. Reconcile GitHub tags with APK flavors, and use targeted, tested rules for the Google version families in these screenshots. Validate APKPure's selected variant and code/name conflicts. Respect user-selected channels, filters and "stay one version behind" settings. A feed's first item is a candidate, not proof of an upgrade.

4. **Resolve same-release builds when possible.** Use source-bound package metadata and GitHub commit relationships where relevant. Equal version codes alone must not erase independently established different-build evidence. Cache metadata by repository/release/asset identity and perform lookups only for unresolved comparisons; avoid downloading APKs or adding a network request per app on every refresh.

5. **Repair existing saved state.** Store the real device version separately from the source release that the user acknowledged or installed. Update real observations after external installs. Preserve Skip, explicit detection preferences and confirmed install records. Legacy `false`/pseudo settings do not record whether they originated from an automatic fallback or a user choice, so do not blindly switch all such apps to another mode or discard their tracking history. Recompute verdicts from the preserved evidence after migration.

6. **Verify behavior across the app before another rollout.** Use the nine screenshots as acceptance fixtures, including source settings and metadata, not merely string pairs. Verify each result in details, list badges, up-to-date filters, notifications and Update All eligibility. Also cover reverse ordering, a genuinely newer release, same-hash formatting differences, different hashes, FOSS/non-FOSS selection, Pixel/OEM/stub selection, conflicting codes, external installs, Skip, Mark updated and reload after migration. Unresolved cases must not silently become automatic updates.

This is a repair of the centralized design. Restoring the old "extract every number" approach wholesale would reintroduce mistakes involving digits inside commit hashes, architecture names and product labels.

**Why the previous tests missed this**

The test suite did more than miss real examples: I added a test that explicitly expects installed `2.0` versus store `1.0` to be actionable in pseudo and track-only modes. That is the wrong expectation for a normal newer-version verdict. The overhaul also replaced broad equality handling with stricter parsing without preserving enough real-world equivalence cases. Passing tests demonstrated agreement with those assumptions, not correct behavior for your installed apps. [Incorrect track-only expectation](/D:/git/MyProjects/ObtainX/test/version_engine_test.dart:121).

**What was verified during this investigation**

I ran 13 local diagnostic tests against production functions, with all nine version pairs transcribed from the screenshots. Six APKMirror fixtures used the source-enforced track-only setting; the remaining three used ordinary auto detection. Eight screenshot statuses reproduced under those settings. The inshorts mismatch was isolated and its code-override behavior reproduced with explicitly synthetic device codes. Additional checks confirmed same-hash normalization and stale track-only reconciliation.

Those 13 checks pass because they document the current behavior, including its faults. They are not evidence that the regressions are fixed. The phone's saved settings, installed codes, selected assets and exact Wa Enhancer commit relationship remain the evidence gaps described above.

The scratch [diagnostic fixture](/D:/git/MyProjects/ObtainX/.buildlog/version-misfires-report_test.dart) and [run log](/D:/git/MyProjects/ObtainX/.buildlog/version-misfires-report.log) are retained under `.buildlog`. Production application files and emulator settings were unchanged.
