# ios-ci

Shared iOS CI/CD infrastructure for your app repositories. App repos keep a tiny caller workflow, while this repo handles signing, building, TestFlight upload, and optional ad-hoc distribution.

By default, app repos do not need release xcconfig wiring. `ios-ci` patches the chosen Xcode configuration inside the GitHub Actions runner so CI can publish using your organization-owned team and bundle IDs without changing the delivered project by hand.

## How it works

```
Your App Repo                          This Repo (ios-ci)
.github/workflows/release.yml         .github/workflows/ios-release.yml
  (30-line caller, copy-paste)    -->    (full build pipeline)
                                       fastlane/  (signing, profiles, upload)
                                       scripts/   (auto-detection, export options)
```

When a GitHub Release is created in any app repo, the thin caller workflow invokes the reusable workflow here. The reusable workflow:

1. Checks out the app repo and this `ios-ci` repo
2. Runs `scripts/prepare.sh` if it exists in the app repo
3. Locates the Xcode project structure and installs CocoaPods dependencies if a `Podfile` is present
4. Resolves the app version from the Git tag and the build number from `GITHUB_RUN_NUMBER`
5. Detects whether it's a Flutter or native project
6. Pre-detects the workspace, scheme, and signable targets from the delivered project
7. Stamps the chosen configuration with the resolved version/build number
8. In the default `managed` mode, patches the chosen configuration in CI with your release team ID and bundle IDs
9. Re-detects the final bundle IDs and team ID after patching
10. Generates `ExportOptions.plist` dynamically from detected bundle IDs
11. Signs all targets via fastlane match
12. Builds the IPA and uploads to TestFlight
13. Optionally builds an ad-hoc IPA and uploads to Diawi

## Default consumer contract

For a standard app repo, the default setup is just:

1. Copy the `.github/workflows/release.yml` caller file
2. Add 3 App Store Connect secrets
3. Add 2 GitHub Actions variables

In this default `managed` mode, `ios-ci` uses `xcodeproj` in CI to patch the selected Xcode configuration:

- `DEVELOPMENT_TEAM` -> `IOS_RELEASE_TEAM_ID`
- the main application target `PRODUCT_BUNDLE_IDENTIFIER` -> `IOS_RELEASE_APP_BUNDLE_ID`
- extension bundle IDs are derived automatically when they share the main app bundle prefix

This means the delivered Xcode project can stay mostly as-is for CI release automation.

## Versioning

By default, `ios-ci` uses:

- app version (`MARKETING_VERSION`) = Git tag version
- build number (`CURRENT_PROJECT_VERSION`) = `GITHUB_RUN_NUMBER`

Supported tag formats:

- `v1.2.3`
- `1.2.3`

On release/tag builds, `ios-ci` strips a leading `v` and stamps the app to that version in CI before building.

On manual runs without a tag, `ios-ci` keeps the app's existing marketing version and only auto-increments the build number.

### Required repo variables

| Variable | Purpose |
|---|---|
| `IOS_RELEASE_TEAM_ID` | Apple team ID for Release / TestFlight builds |
| `IOS_RELEASE_APP_BUNDLE_ID` | Main app bundle ID for Release / TestFlight builds |

### Optional advanced variables

Most apps do not need these. They are only for projects whose secondary targets cannot be derived from the main bundle ID automatically.

| Variable | Purpose |
|---|---|
| `IOS_RELEASE_EXTENSION_BUNDLE_ID` | Optional exact bundle ID when there is exactly one extension target |
| `IOS_RELEASE_TARGET_BUNDLE_IDS_JSON` | Optional JSON map of target name -> bundle ID for complex apps |
| `MATCH_GIT_BRANCH` | Optional match git branch override. By default, certs are stored on a `team-<IOS_RELEASE_TEAM_ID>` branch (auto-isolated per Apple team — match doesn't support multi-team in a single branch). |

Example:

```json
{"WidgetExtension":"com.example.myapp.widget","NotificationService":"com.example.myapp.notification-service"}
```

If a secondary target's delivered bundle ID does not share the main app prefix, `ios-ci` fails early and tells you to use one of these overrides or the advanced xcconfig mode below.

## Advanced: xcconfig-managed mode

If you want the app repo itself to define release identity through `.xcconfig` files, `ios-ci` still supports that. Set `release_identity_mode: "xcconfig"` in the caller workflow.

Use this mode when:

- you want the project to be fully self-describing for release identity
- you want a clean local Debug / CI Release split in the app repo
- your target IDs or entitlements are too custom for CI-managed derivation

In `xcconfig` mode, the app repo must follow this contract:

1. The shipping Xcode configuration must reference one or more `.xcconfig` files.
2. Release signing identity must come from those `.xcconfig` files, not from hardcoded values in the `.pbxproj`.
3. The chosen configuration must resolve `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` for every signable target.
4. If values are generated, the repo must create them in `scripts/prepare.sh` before CI detection runs.

The workflow validates this contract before any signing or build steps. It fails early with a clear error if:

- no `.xcconfig` is referenced for the chosen configuration
- the referenced `.xcconfig` file does not exist
- team ID or bundle IDs are still hardcoded in the project file
- the xcconfig chain does not resolve `DEVELOPMENT_TEAM` or `PRODUCT_BUNDLE_IDENTIFIER`

## Auto-detection

The workflow automatically discovers:

| What | How |
|---|---|
| Flutter vs native | Checks for `pubspec.yaml` at repo root |
| .xcworkspace / .xcodeproj | Searches root, then `ios/`, then any first-level subdirectory |
| Scheme | `xcodebuild -list`, filters out Pods/Tests/Widget schemes |
| Targets + bundle IDs | `xcodebuild -showBuildSettings` for the selected scheme/configuration |
| Release identity in default mode | Patched in CI with `xcodeproj` before the final detection pass |
| Versioning | Tag version -> `MARKETING_VERSION`, `GITHUB_RUN_NUMBER` -> `CURRENT_PROJECT_VERSION` |
| Team ID | From the final detected `DEVELOPMENT_TEAM` build setting after patching |
| CocoaPods | Runs `pod install` before validation if a Podfile exists |
| Crashlytics dSYMs | Uploads if `upload-symbols` and `GoogleService-Info.plist` are found |

If multiple candidate app schemes exist, CI stops and asks you to pass `scheme` explicitly. It no longer guesses by taking the first one.

## Supported project structures

```
# Native app at root
MyApp.xcodeproj/
MyApp/

# Native app with CocoaPods
MyApp.xcworkspace/
MyApp.xcodeproj/
Podfile

# Flutter app (standard structure)
pubspec.yaml
lib/
ios/
  Runner.xcworkspace/
  Runner.xcodeproj/

# Native app in a subdirectory
SomeFolder/
  MyApp.xcodeproj/
```

## Secrets

### Organization secrets (set once in your GitHub org settings)

| Secret | Purpose |
|---|---|
| `CHECKOUT_PAT` | GitHub PAT for cloning repos and private submodules |
| `MATCH_PASSWORD` | Encryption passphrase for the shared certificate repo |
| `MATCH_GIT_URL` | HTTPS URL of the private certificate repo |
| `MATCH_GIT_PAT` | PAT with read/write access to the certificate repo |
| `DIAWI_TOKEN` | Diawi API token (only needed for ad-hoc builds) |
| `TG_WORKER_API_KEY` | Telegram notification worker API key (only needed for ad-hoc builds) |
| `TG_WORKER_URL` | Telegram notification worker URL (only needed for ad-hoc builds) |

### Per-repo secrets (set in each app repo)

| Secret | Purpose |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Content of the .p8 API key file |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect Issuer ID |

> If all apps share the same Apple Developer account, these 3 can also be moved to org-level secrets.

## Optional inputs

The caller workflow can override these defaults:

| Input | Default | Description |
|---|---|---|
| `adhoc` | `false` | Also build ad-hoc IPA and upload to Diawi |
| `macos_runner` | `macos-15` | GitHub Actions runner label |
| `ruby_version` | `3.2` | Ruby version for fastlane |
| `scheme` | auto-detect | Required when the repo has multiple app schemes; for Flutter this is also used as the `--flavor` value |
| `configuration` | `Release` | Xcode configuration used for validation, detection, and native builds. Flutter currently supports only `Release`. |
| `release_identity_mode` | `managed` | `managed` patches the project in CI from GitHub variables. `xcconfig` expects the app repo to provide release identity itself. |

## Prepare script

`scripts/prepare.sh` is optional. In the default `managed` mode, you do not need it just to provide team ID and bundle ID.

Create `scripts/prepare.sh` only when the app needs custom pre-build steps such as:

- code generation
- copying config files
- running repo-specific setup before CocoaPods or Xcode detection
- generating xcconfig files for the advanced `xcconfig` mode

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Example: repo-specific prebuild setup
swift package plugin generate-code
```

## App Store Metadata

A second reusable workflow uploads App Store metadata (descriptions, keywords, screenshots, etc.) via fastlane `deliver`. Completely independent from the release workflow — no Xcode project or signing needed.

### Metadata folder convention

The caller repo provides metadata in a translator-friendly format:

```
metadata/
├── Text/
│   ├── defaults/
│   │   ├── info.jsonc          # Shared fields (URLs, etc.)
│   │   ├── description.txt     # Optional base description
│   │   └── whatsNew.txt        # Shared release notes
│   ├── en/
│   │   ├── info.jsonc          # Locale-specific overrides
│   │   ├── description.txt     # Plain text, real line breaks
│   │   └── whatsNew.txt        # Optional localized release notes
│   └── ru/
│       └── ...
└── Screenshots/
    └── en/
        ├── APP_IPHONE_67/      # 1290x2796
        ├── APP_IPHONE_65/      # 1284x2778
        ├── APP_IPHONE_55/      # 1242x2208
        ├── APP_IPAD_129/       # 2048x2732
        └── APP_IPAD_110/       # 1668x2388
```

**info.jsonc** supports comments and maps these fields to App Store Connect:

| Key | ASC field |
|---|---|
| `name` | App name |
| `subtitle` | Subtitle |
| `keywords` | Keywords (comma-separated) |
| `promotionalText` | Promotional text |
| `marketingUrl` | Marketing URL |
| `supportUrl` | Support URL |
| `privacyUrl` | Privacy URL |

**Merge logic:** `defaults/` provides base values; per-locale files override them. This applies consistently to `info.jsonc`, `description.txt`, and `whatsNew.txt`.

**Two modes of operation** (controlled by `update_whatsnew_only` input):

- `update_whatsnew_only: true` (default) — Only release notes are uploaded. All other metadata (name, subtitle, description, URLs, etc.) is left untouched on App Store Connect. Perfect for the common release-notes-only update.
- `update_whatsnew_only: false` — All fields from `defaults/` + locale folders are uploaded. Use this for initial setup or full metadata refresh.

**Screenshots:** Must be PNG, within 20px of the target device dimensions. The workflow automatically scales to exact dimensions and strips the alpha channel.

### Metadata workflow inputs

| Input | Default | Description |
|---|---|---|
| `app_version` | `""` | Target app version. Empty = update current draft |
| `skip_screenshots` | `true` | Skip screenshot upload |
| `update_whatsnew_only` | `true` | Only update release notes. All other metadata is left untouched on ASC |

### Metadata caller workflow

```yaml
name: Update App Store Metadata

on:
  workflow_dispatch:
    inputs:
      app_version:
        description: 'Target app version (leave empty for current draft)'
        required: false
        default: ''
      skip_screenshots:
        description: 'Skip screenshot upload'
        required: false
        type: boolean
        default: true
      update_whatsnew_only:
        description: 'Only update release notes (leave all other metadata untouched on ASC)'
        required: false
        type: boolean
        default: true

jobs:
  metadata:
    uses: your-org/ios-ci/.github/workflows/ios-metadata.yml@main
    with:
      app_version: ${{ inputs.app_version }}
      skip_screenshots: ${{ inputs.skip_screenshots }}
      update_whatsnew_only: ${{ inputs.update_whatsnew_only }}
    secrets: inherit
```

Uses the same App Store Connect secrets as the release workflow. Also requires the `IOS_RELEASE_APP_BUNDLE_ID` variable.

## In-App Purchases

A reusable workflow pair (`ios-iap.yml` + `ios-iap-sync.yml`) creates and updates consumable and non-consumable in-app purchases on App Store Connect, including localizations, price tier, and review screenshots. Re-running is safe — products are matched by `product_id`, created if missing, updated if present.

### IAP folder convention

```
metadata/InAppPurchases/
├── com.example.app.remove_ads/
│   ├── product.jsonc            # type, reference_name, price_tier, family_shareable
│   ├── review_screenshot.png    # optional (required only for first review submission)
│   └── Text/
│       ├── defaults/
│       │   └── info.jsonc       # optional shared { name, description }
│       ├── en/
│       │   └── info.jsonc       # { name, description } per-locale override
│       └── ru/
│           └── info.jsonc
└── com.example.app.coins_100/
    └── ...
```

Each product folder is named after the App Store Connect `product_id`. `product.jsonc` looks like:

```jsonc
{
  // "consumable" or "non_consumable"
  "type": "non_consumable",
  // Internal-only name (max 64 chars, must be unique within the app)
  "reference_name": "Remove Ads",
  // Apple price tier 0–87 (USA dollar value; Apple derives other territories)
  "price_tier": 1,
  // Only meaningful for non-consumable products
  "family_shareable": false
}
```

`Text/{locale}/info.jsonc` looks like:

```jsonc
{
  "name": "Remove Ads",                // max 30 chars
  "description": "Remove all ads."     // max 45 chars
}
```

Field limits are enforced before upload — the transform script collects all violations across all products and locales and fails with a single report.

### IAP push caller workflow

```yaml
name: Update In-App Purchases

on:
  workflow_dispatch:

jobs:
  iap:
    uses: your-org/ios-ci/.github/workflows/ios-iap.yml@main
    secrets: inherit
```

After upload, ios-ci attempts to transition each product to "Ready to Submit" so it ships with the next app version review. Products that don't qualify (e.g. missing review screenshot on first creation) emit a warning but don't fail the workflow.

### IAP sync caller workflow

```yaml
name: Sync In-App Purchases

on:
  workflow_dispatch:

jobs:
  iap-sync:
    uses: your-org/ios-ci/.github/workflows/ios-iap-sync.yml@main
    secrets: inherit
```

Pulls current consumable + non-consumable products from App Store Connect into `metadata/InAppPurchases/` and opens a PR if anything changed. Like the metadata sync, fields shared across all locales are hoisted into `Text/defaults/info.jsonc`.

Uses the same App Store Connect secrets as the release workflow. Also requires the `IOS_RELEASE_APP_BUNDLE_ID` variable.

## Submit for Review

A third reusable workflow submits the current editable version for App Store review.

**What it does automatically:**
- Finds the current editable version on App Store Connect
- Picks the latest build uploaded to TestFlight
- Submits for review with `automatic_release: true`

### Required file: `metadata/submission.jsonc`

Answers to Apple's review questions. Customize once per app:

```jsonc
{
  "add_id_info_uses_idfa": false,
  "export_compliance_uses_encryption": true,
  "export_compliance_is_exempt": true,
  "export_compliance_encryption_updated": false,
  "export_compliance_contains_third_party_cryptography": false,
  "export_compliance_contains_proprietary_cryptography": false,
  "export_compliance_available_on_french_store": true,
  "content_rights_has_rights": true,
  "content_rights_contains_third_party_content": false
}
```

### Caller workflow

```yaml
name: Submit for Review

on:
  workflow_dispatch:

jobs:
  submit:
    uses: your-org/ios-ci/.github/workflows/ios-submit-for-review.yml@main
    secrets: inherit
```

## Files in this repo

```
ios-ci/
├── .github/workflows/
│   ├── ios-release.yml             # Reusable workflow (build + release)
│   ├── ios-metadata.yml            # Reusable workflow (push metadata + screenshots)
│   ├── ios-metadata-sync.yml       # Reusable workflow (pull metadata from ASC → PR)
│   ├── ios-iap.yml                 # Reusable workflow (push in-app purchases)
│   ├── ios-iap-sync.yml            # Reusable workflow (pull in-app purchases from ASC → PR)
│   └── ios-submit-for-review.yml   # Reusable workflow (submit current version for review)
├── fastlane/
│   ├── Fastfile                    # Lanes: signing, building, uploading, metadata
│   ├── Matchfile                   # Points to MATCH_GIT_URL from env
│   └── Appfile                     # Empty (all values are dynamic)
├── Gemfile                         # fastlane dependency
└── scripts/
    ├── detect-project.sh           # Auto-detects workspace, scheme, targets, bundle IDs
    ├── manage-release-identity.rb  # Patches Release identity in CI with xcodeproj
    ├── stamp-build-version.rb      # Stamps app version/build number in CI with xcodeproj
    ├── validate-project-contract.rb # Enforces the xcconfig-driven release contract
    ├── generate-export-options.sh  # Builds ExportOptions.plist dynamically
    ├── transform_metadata.rb       # Transforms custom metadata format to deliver format
    ├── transform_screenshots.rb    # Validates and processes screenshots for App Store
    ├── reverse_transform_metadata.rb  # Converts deliver format to custom metadata format (for sync)
    ├── transform_iap.rb            # Validates IAP source folder, emits normalized JSON
    └── reverse_transform_iap.rb    # Converts ASC IAP dump back into the source layout
```

## Updating

Changes to this repo take effect immediately for all app repos if they reference `@main`. To pin a stable version, change the caller to reference a tag:

```yaml
uses: your-org/ios-ci/.github/workflows/ios-release.yml@v1
```
