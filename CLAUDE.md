# CLAUDE.md — firefox-bookmarks

Read this before touching anything. It captures what this repo is, how it builds, every
customization, and the non-obvious gotchas (there are several).

## What this is

A **custom Firefox for Android (Fenix) build** distributed as a sideloaded APK. It ships with:

- the **Symfony Bookmarks** WebExtension pre-installed,
- **uBlock Origin** pre-installed,
- the Symfony Bookmarks **dashboard as the home / new-tab page**,
- a custom launcher icon and the app renamed **"Firefox Bookmarks"**.

The app is built by GitHub Actions and published as a GitHub Release (one per Firefox
stable version), auto-rebuilt when a new stable Firefox appears.

## THE most important idea: this is NOT a fork of Firefox

This repo contains **only the customization** (`firelex-patch/`). There is **no Firefox
source mirrored here**. At build time the CI:

1. checks out upstream `mozilla-firefox/firefox@release` **fresh** (blob:none, fetch-depth 300),
2. checks out THIS repo into `_firelex/` (so `firelex-patch/` is available),
3. runs `firelex-patch/apply.sh "$GITHUB_WORKSPACE"` which overlays our files + patches onto
   the upstream tree,
4. builds `mach gradle fenix:assembleDebug -PbenchmarkTest` (arm64 debug APK), then publishes
   a Release.

Consequences:
- **Never** merge/mirror Firefox source here. Cloning this repo is ~5 MB.
- We **never** get merge conflicts from upstream; the only maintenance is re-basing a `.patch`
  if `release` changes a file we patch (apply.sh fails loudly → you rebase that one patch).
- The old heavy fork `github.com/aleblanc/firelex` (full mirror, multi-GB, slow git) is
  **abandoned**. Don't use it.
- To read Firefox source, **fetch from raw** (`https://raw.githubusercontent.com/mozilla-firefox/firefox/release/<path>`)
  or use searchfox.org. There is no local Firefox tree.

## Why a custom build is needed (constraints verified in the tree)

- `chrome_url_overrides.newtab` is **not honored on Android** (the home is native Compose,
  not a web page) → we must route the home to the dashboard in Fenix code.
- The WebExtension `bookmarks` API is **desktop-only** (implemented in `browser/components/extensions/`,
  absent from `mobile/shared/components/extensions/ext-android.json`). The dashboard therefore
  uses its **own store** (HTTP fetch to the Symfony server), not the bookmarks API.

## Repo layout

```
.github/workflows/build-fenix.yml   # the whole CI (check job + apk job)
firelex-patch/                      # ALL customization (dir name is legacy; keep it)
  apply.sh                          # runs in CI: copies overlay, unzips XPIs, applies patches
  debug.keystore                    # committed stable debug keystore (see Signing)
  extensions/
    ublock_origin.xpi               # uBO, downloaded from AMO, version-pinned
    symfony_bookmarks.xpi           # built from the symfony-bookmarks repo (see Related repos)
  overlay/                          # files copied verbatim into the Firefox tree at these paths
    mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components/SymfonyBuiltInExtensions.kt
    mobile/android/fenix/app/src/debug/res/drawable/ic_launcher_foreground.xml
    mobile/android/fenix/app/src/debug/res/drawable-nodpi/firelex_launcher.png
    mobile/android/fenix/app/src/debug/res/values/firelex_strings.xml
  patches/
    Core.kt.patch                   # calls SymfonyBuiltInExtensions.install(it)
    home-routing.patch              # HomeFragment.onResume → open the dashboard
  README.md
DESIGN.md, PLAN.md                  # original spec + plan (some details predate later fixes)
docs/screenshot-android-app.jpg
```

## The build pipeline (`.github/workflows/build-fenix.yml`)

Two jobs:

- **`check`** (fast, no build): on `schedule` (daily 06:00 UTC) or `workflow_dispatch`.
  Reads `browser/config/version.txt` from upstream `release` via raw. Manual run → always
  builds. Scheduled run → builds only if a Release `v<version>` does **not** already exist
  (`gh release view`). Outputs `build` + `version`.
- **`apk`** (`needs: check`, `if: build == 'true'`): free disk → checkout upstream `release`
  → checkout this repo into `_firelex` (sparse `firelex-patch`) → write mozconfig →
  `apply.sh` → **copy `debug.keystore` to `~/.android/debug.keystore`** → mach bootstrap
  (ARTIFACT MODE) → configure → `mach artifact install` → `mach build` → `mach gradle
  fenix:assembleDebug -PbenchmarkTest` → upload artifact → read version.txt → publish Release
  (`softprops/action-gh-release`, tag `v<version>`).

`permissions: contents: write` on the `apk` job (for releases). `-PbenchmarkTest` = arm64-v8a
only (Fenix's flag to emit a single ABI). Caches: `~/.mozbuild` + Gradle.

Scheduled workflows only run from the default branch (`main`), and GitHub disables cron after
60 days of repo inactivity (you get an email to re-enable).

## The customizations, explained

### Extensions (built-in install)
`overlay/.../SymfonyBuiltInExtensions.kt` (in `org.mozilla.fenix.components`) installs both
extensions via `runtime.installBuiltInWebExtension(id, "resource://android/assets/extensions/<name>/", …)`.
`Core.kt.patch` calls `SymfonyBuiltInExtensions.install(it)` next to `WebCompatFeature.install(it)`
in the `GeckoEngine(...) .also { }` block. `apply.sh` unzips the XPIs into
`mobile/android/fenix/app/src/main/assets/extensions/{ublock,symfony-bookmarks}/`.

IDs: uBO = `uBlock0@raymondhill.net`, Symfony = `sfbookmarks-sync@aleblanc`.

Built-in install **bypasses AMO signature checks** (so the unsigned Symfony XPI installs) BUT:
- built-in extensions are **hidden from the Add-ons menu** (like webcompat) — "not in the list"
  is normal, not a bug;
- they **do not auto-update** (uBO's *filter lists* still update at runtime, so ad-blocking
  stays current; the extension *code* only updates when you rebuild with a new XPI).

In `SymfonyBuiltInExtensions.install`, the Symfony `onSuccess` captures
`extension.getMetadata()?.baseUrl` and stores `dashboardUrl = baseUrl + "dashboard.html"`
(the moz-extension UUID is random per profile, so it must be resolved at runtime).

### Home = dashboard (`home-routing.patch`)
Patches `HomeFragment.onResume`. The correct chokepoint: with `homepage-as-new-tab` defaulting
false, Fenix navigates straight to the native `HomeFragment` without ever loading `about:home`
into a tab — so intercepting `about:home` (AppRequestInterceptor) or `AboutHomeBinding` does
NOT work (both were tried and abandoned). `HomeFragment.onResume` is where *every* home display
passes. It:
- returns early in private mode (`browsingModeManager.mode.isPrivate`),
- **reuses** an existing dashboard tab if present (avoids piling up duplicate tabs), else opens
  a new one, via `(requireActivity() as HomeActivity).openToBrowserAndLoad(dashboardUrl, …)`,
- is annotated `@Suppress("DEPRECATION")` because `openToBrowserAndLoad` is `@Deprecated` and
  **Fenix compiles with `-Werror`** (a deprecation warning fails the build otherwise).

### Icon + name (DEBUG variant — critical gotcha)
The build is `assembleDebug` → it uses `src/debug/` + `src/main/` resources, **NOT** `src/release/`.
A first attempt patched `src/release/` and had zero effect. The working overlay targets **debug**:
- `src/debug/res/values/firelex_strings.xml` → `app_name` = "Firefox Bookmarks" (a variant
  resource overrides main's "Firefox Fenix"; debug did not previously define app_name).
- `src/debug/res/drawable/ic_launcher_foreground.xml` → `<bitmap>` pointing at `@drawable/firelex_launcher`
  (debug's `ic_launcher.xml` and `ic_launcher_round.xml` both reference `@drawable/ic_launcher_foreground`).
- `src/debug/res/drawable-nodpi/firelex_launcher.png` → the 512×512 maskable logo (from
  symfony-bookmarks `public/icon-maskable-512.png`).

### Signing (stable key → updatable APKs)
Fenix signs both debug and release build types with `signingConfigs.debug` = the default AGP
debug keystore at `~/.android/debug.keystore` (creds `android` / `androiddebugkey` / `android`).
The CI's debug key is random per run → different signature each build → Android refuses updates.
Fix: `firelex-patch/debug.keystore` is a **committed, fixed** PKCS12 keystore with those exact
default creds (generated with `openssl`, alias `androiddebugkey`, pass `android`). A CI step
copies it to `~/.android/debug.keystore` before the build. Committing it is safe (the debug
creds are public/universal). No Gradle change needed.
- Transition note: switching from the old random key to this stable key requires **uninstalling
  once**, then installing; afterwards updates install cleanly.
- For a non-debuggable, privately-signed build you'd use a release keystore in GitHub Secrets +
  a `build.gradle` patch (Option B) — not done; only needed for wider distribution.

## Hard gotchas (read before "improving" things)

- **Artifact mode = Gecko is downloaded prebuilt.** You **cannot** bake Gecko prefs
  (editing `geckoview-prefs.js` / any pref source has NO effect — it's not recompiled).
  Privacy/telemetry/`about:config` tweaks must be set **manually in about:config on the device**
  (persists in the profile; about:config IS available since this is a debug build). The user's
  privacy toggles (telemetry/Glean, sponsored shortcuts/stories, studies, crash reports) are
  Fenix/Nimbus/Kotlin settings, **not** Gecko prefs → just uncheck them in Settings on-device.
- **`assembleDebug` uses `src/debug` + `src/main`, never `src/release`.** Target the debug
  variant for resources.
- **`-Werror`**: any deprecation/warning in patched Kotlin fails compilation. Use
  `@Suppress("DEPRECATION")` etc. as needed.
- **`getBrowserInfo().version`** (used by the extension's update banner) returns the actual
  prebuilt GeckoView version, which can **lag `version.txt`** (the Release tag) by a patch when
  the exact artifact isn't available yet → the update banner can false-positive once (throttled,
  self-heals). Known minor issue; not fixed.
- Authoring patches: you can't `git apply --check` locally (no Firefox tree). **Prefer overlay
  files over patches**; when a patch is unavoidable, author it against the exact `release` file
  fetched via raw, with correct context. Generate patches by editing a real file then
  `git diff` (do this in a throwaway checkout if you have one, or hand-author against raw).

## How to make common changes

- **Update the Symfony extension**: rebuild the XPI in the symfony-bookmarks repo
  (`web-ext build`), copy it to `firelex-patch/extensions/symfony_bookmarks.xpi`, commit. Bump
  the extension `manifest.json` version only if you also republish to AMO (AMO needs a strictly
  higher version; a bundled-only change doesn't strictly need a bump).
- **Update uBlock Origin**: re-download the current XPI from AMO, replace
  `firelex-patch/extensions/ublock_origin.xpi`, commit.
- **Add a new source tweak**: prefer an overlay file (copied verbatim); use a `patches/*.patch`
  only to modify an existing upstream file. Test on the next CI run (`apply.sh` fails loudly if
  a patch no longer applies).
- **Change build/release behavior**: edit `.github/workflows/build-fenix.yml`.
- **Force a rebuild of the current version**: Run workflow manually (updates the existing
  Release's APK in place).

## Related repos

- **symfony-bookmarks** (`../symfony-bookmarks` locally): the Symfony server + the WebExtension
  (`extension/`). The dashboard/search/sync UI lives there. The extension is MV2, built with
  `web-ext`, plain unminified JS/HTML/CSS (no build step). It feature-detects `browser.bookmarks`
  (desktop-only) and degrades on Android. Published on AMO as "Symfony Bookmarks Sync".
  - The dashboard has an **Android-only update banner** (`getPlatformInfo().os === "android"`)
    that compares `getBrowserInfo()` to the latest GitHub Release and links to the APK.

## Conventions

- Git identity for commits: name `aleblanc`, email `aleblanc@github.com` (set local repo config).
- No emoji in Firefox-tree code/comments (Mozilla style) — applies to overlay Kotlin/XML.
- Keep the `firelex-patch/` directory name (apply.sh + workflow reference it).

## Handy about:config tips (set on-device; can't be baked — artifact mode)

- Disable auto-translate: `browser.translations.automaticallyPopup` = false (or
  `browser.translations.enable` = false).
- IP Protection egress country (no picker on mobile): set
  `browser.ipProtection.egressLocation` to a country **code** (e.g. `fr`, `de`, `us`; `REC` =
  recommended/auto), using a code from `browser.ipProtection.locationListCache`, then toggle
  IP Protection off/on. Works only if the mobile connect path reads the pref (untested).
