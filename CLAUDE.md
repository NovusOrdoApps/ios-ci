# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not an application** — it's a toolbox of GitHub Actions reusable workflows + supporting scripts that other iOS app repos consume. App repos add a thin caller workflow (`uses: NovusOrdoApps/ios-ci/.github/workflows/...`); this repo handles signing, building, TestFlight upload, ad-hoc distribution, App Store metadata, screenshots, and submit-for-review.

There is no compiled output. Code lives in three places:
- `.github/workflows/ios-*.yml` — seven reusable workflows (release, metadata push, metadata sync, screenshots sync, IAP push, IAP sync, submit-for-review)
- `fastlane/Fastfile` — every fastlane lane is invoked by the workflows; `Appfile` is intentionally empty and `Matchfile` reads `MATCH_GIT_URL` from env
- `scripts/` — bash + Ruby scripts called by the workflows for project detection, project patching, ExportOptions generation, and metadata transformation

When you run anything in this repo on a developer machine, you are simulating what a GitHub Actions runner would do.

## Commands

```bash
bundle install                                            # install fastlane + xcodeproj gems
bundle exec fastlane lanes                                # list all lanes
bundle exec fastlane <lane> key:value key2:value2         # invoke a lane (positional kwargs, not flags)
ruby scripts/<name>.rb <args>                             # most ruby scripts can be run standalone
bash scripts/detect-project.sh <app_root> "" Release locate-only   # detect against an app repo checkout
```

There is no test suite, lint, or build step. `tests/fixtures/metadata/` is sample input data for the metadata transformer, not a test runner. To validate changes, run the script against `tests/fixtures/metadata` and inspect the output:

```bash
ruby scripts/transform_metadata.rb \
  --input tests/fixtures/metadata --output /tmp/out \
  --locales en,ru --update-whatsnew-only false \
  --update-promotional-text-only false --skip-screenshots true
```

## Architecture

### Data flow inside `ios-release.yml`

The release workflow is the most complex piece. It runs **detection → patch → re-detection** because patching the project changes what `xcodebuild -showBuildSettings` reports:

1. `detect-project.sh ... locate-only` — find `.xcworkspace` / `.xcodeproj` only (no scheme yet)
2. `pod install` if a Podfile exists
3. `detect-project.sh ... prepatch` — discover scheme + signable targets (team ID may be missing here, that's allowed)
4. `stamp-build-version.rb` — write `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` into the pbxproj
5. `manage-release-identity.rb` (managed mode) — patch `DEVELOPMENT_TEAM` and per-target `PRODUCT_BUNDLE_IDENTIFIER` and **delete any conditional variants like `PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*]`** so the base value wins
6. `detect-project.sh ... full` — re-read settings, this time team_id must resolve
7. Validate: in `xcconfig` mode, `validate-project-contract.rb` enforces that release identity comes through xcconfig files (not hardcoded). In `managed` mode, sanity-check that the patched values came back out of xcodebuild
8. `generate-export-options.sh` — emit `ExportOptions.plist` for AppStore and AdHoc, mapping each detected `bundle_id → "match {AppStore|AdHoc} {bundle_id}"`
9. `fastlane install_profiles` → `set_signing` → `build_native` (or Flutter `build ipa`) → upload

Build numbers use `GITHUB_RUN_NUMBER * 100 + GITHUB_RUN_ATTEMPT` so re-runs of a workflow whose first attempt already uploaded to TestFlight don't collide on "bundle version already used."

### Project detection contract

`detect-project.sh` is the source of truth that all later steps key off. It writes these `GITHUB_OUTPUT` keys: `workspace`, `project`, `ios_dir`, `is_flutter`, `scheme`, `configuration`, `targets_json`, `app_identifiers`, `team_id`. It runs in three modes (4th arg): `locate-only` (just file paths), `prepatch` (pre-patching, allows missing team_id), `full` (everything resolved).

Critical scheme-detection invariant: it filters out `Pods-*`, `*Tests`, `*UITests`, `*Testing`, `*Watch`, `*Widget`. If multiple candidate app schemes survive, it errors and demands the caller pass `scheme:` explicitly — it deliberately does not guess. When editing this script, be aware that under `set -euo pipefail` an unmatched `grep` (exit 1) silently kills the script — use `awk` for build-setting extraction.

### Two release-identity modes

- **`managed` (default):** `manage-release-identity.rb` rewrites the project file in CI. Bundle ID derivation order per signable target: explicit `IOS_RELEASE_TARGET_BUNDLE_IDS_JSON` mapping → primary app target gets `IOS_RELEASE_APP_BUNDLE_ID` → single-extension override `IOS_RELEASE_EXTENSION_BUNDLE_ID` → prefix-derived (`<old_prefix>.x.y` → `<release_bundle_id>.x.y`). If none of these resolve, it errors and tells the caller to add an override or switch modes.
- **`xcconfig`:** `validate-project-contract.rb` walks the `.xcconfig` chain (target config → project config → referenced xcconfigs, recursively following `$(VAR)` / `${VAR}` references) and rejects builds where `DEVELOPMENT_TEAM` or `PRODUCT_BUNDLE_IDENTIFIER` is hardcoded in the pbxproj or resolves through a target/project setting instead of the xcconfig.

### match branch isolation

`fastlane/Fastfile install_profiles` defaults `git_branch` to `team-<IOS_RELEASE_TEAM_ID>` (overridable via `MATCH_GIT_BRANCH`). This is required, not cosmetic: fastlane match's cert verification treats every cert in the working folder as belonging to the current team and errors when it sees one from another team. One Apple team per branch.

### IAP pipeline

Mirrors the metadata pipeline (push + pull), with one wrinkle: `deliver` does not manage in-app purchases at all, so both `update_iap` and `fetch_iap` go directly through `Spaceship::ConnectAPI::InAppPurchaseV2`. Source layout is `metadata/InAppPurchases/<product_id>/{product.jsonc, review_screenshot.png?, Text/{defaults,locale}/info.jsonc}`. The push lane is idempotent (matches by `product_id`, creates-or-updates), and after each upload it best-effort transitions the IAP to "Ready to Submit" — failures here are logged as warnings rather than aborting, since first-time products often lack a required review screenshot. Price syncing uses the V2 price-point lookup (USA territory at the requested tier) and lets Apple derive equivalent prices for other territories. Field limits enforced by `transform_iap.rb`: name 30, description 45, reference_name 64, product_id 255.

### Metadata pipeline

The metadata workflow does not feed `deliver` directly. App repos use a translator-friendly `metadata/Text/{defaults,en,ru,...}/{info.jsonc,description.txt,whatsNew.txt}` layout. `transform_metadata.rb` merges defaults + locale overrides, validates against Apple's published per-field character limits (in `FIELD_LIMITS`), and writes deliver's flat `{locale}/{field}.txt` format to a temp dir, which `update_metadata` then uploads. The reverse direction (`reverse_transform_metadata.rb`, `fetch_metadata`) is used by the sync workflows to pull current ASC content back into the repo convention by extracting fields shared across all locales into `defaults/` and only keeping per-locale overrides.

The transform supports three modes: full (everything), `update_whatsnew_only` (just release notes), `update_promotional_text_only` (just promo text). The last two can stack — the workflow input `update_promotional_text_only` is *additive* with `update_whatsnew_only`.

The promotional-text-only path has a special case in `Fastfile update_metadata`: if there's no editable version on App Store Connect and the user wants to update only `promotional_text`, the lane bypasses `deliver` entirely and writes directly through Spaceship's `live_version.get_app_store_version_localizations` API. `deliver` hangs on `fetch_edit_app_info` for Ready-for-Sale-only apps even with `edit_live: true`, so it's not usable for that case. Apple does allow promotional_text edits on the live version's localizations — but only that one field.

### JSONC parser

Both `transform_metadata.rb` and `Fastfile submit_for_review` parse JSONC by hand: strip UTF-8 BOM, walk character-by-character to skip `//` outside quoted strings, then strip trailing commas via regex. Ruby has no built-in JSONC. If you change the parser in one place, change it in both.

### Screenshot processing

`transform_screenshots.rb` validates dimensions with a 20px tolerance against `DEVICE_DIMENSIONS` (Apple's accepted sizes per display type — note that `APP_IPHONE_65` accepts 6.7" sizes too; this overlap is intentional). Alpha is stripped via a JPEG-quality-100 round-trip because `sips -s hasAlpha false` doesn't work on PNGs and TIFF round-tripping preserves alpha. Final scaling is `sips -z`. macOS-only because of `sips`.

## Conventions

- Workflow log lines use a leading `:: ` prefix. Keep new logs consistent.
- Ruby scripts that take complex input (targets list, configuration, project path) accept positional args, not flags. Only the metadata transformers use `--flag value`.
- All lanes pass values through env or positional kwargs (`fastlane <lane> key:value`); `Appfile` is intentionally empty.
- Caller-repo path is always the GitHub Actions checkout root; this repo is checked out into `_ci/` alongside it. When testing scripts locally against an app repo, mimic that layout by passing the app repo as `app_root` and running scripts via `bundle exec` from the `ios-ci` checkout.
- The repo is consumed by callers referencing `@main` by default; breaking changes to workflow inputs or script CLIs need to be coordinated with caller repos or pinned via tags.
