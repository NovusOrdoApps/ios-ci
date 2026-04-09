# ios-ci

Shared iOS CI/CD infrastructure for NovusOrdo app repositories. App repos keep a tiny caller workflow, while this repo handles signing, building, TestFlight upload, and optional ad-hoc distribution.

The CI is low-config on the GitHub side, but not magic on the Xcode side: every app repo must expose its release identity through `.xcconfig` files so CI can publish using your organization-owned team and bundle IDs without opening Xcode.

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
4. Detects whether it's a Flutter or native project
5. Auto-detects the workspace, scheme, targets, bundle IDs, and team ID
6. Validates that the chosen release configuration is xcconfig-driven and resolves your org-owned team and bundle IDs
7. Generates `ExportOptions.plist` dynamically from detected bundle IDs
8. Signs all targets via fastlane match
9. Builds the IPA and uploads to TestFlight
10. Optionally builds an ad-hoc IPA and uploads to Diawi

## Mandatory project convention

Every app repo that uses `ios-ci` must follow this release contract:

1. The shipping Xcode configuration must reference one or more `.xcconfig` files.
2. Release signing identity must come from those `.xcconfig` files, not from hardcoded values in the `.pbxproj`.
3. The chosen configuration must resolve `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` for every signable target.
4. If values are generated, the repo must create them in `scripts/prepare.sh` before CI detection runs.

This is what lets a freelancer work with their own local setup while your CI publishes with your organization-owned identifiers.

### Recommended separation: local Debug, CI Release

The cleanest pattern is:

- local development writes `Config/Local.Debug.generated.xcconfig`
- CI writes `Config/CI.Release.generated.xcconfig`
- Debug includes the local file
- Release includes the CI file

That keeps org release identifiers out of local machines while still letting CI validate and ship Release builds.
Developers run `Debug` locally; CI alone generates the real Release identity in its ephemeral workspace.

Example:

```xcconfig
// Config/Base.xcconfig
DEVELOPMENT_TEAM = $(APPLE_TEAM_ID)
PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID)
```

```xcconfig
// Config/Debug.xcconfig
#include "Base.xcconfig"
#include? "Local.Debug.generated.xcconfig"
```

```xcconfig
// Config/Release.xcconfig
#include "Base.xcconfig"
#include? "CI.Release.generated.xcconfig"
```

### Recommended pattern

In the committed Xcode project, wire targets to variables:

```xcconfig
DEVELOPMENT_TEAM = $(APPLE_TEAM_ID)
PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID)
```

For extensions, use a separate variable:

```xcconfig
PRODUCT_BUNDLE_IDENTIFIER = $(APP_EXTENSION_BUNDLE_ID)
```

Then generate the real org-owned Release values in CI:

```xcconfig
APPLE_TEAM_ID = ABCDE12345
APP_BUNDLE_ID = com.novusordo.myapp
APP_EXTENSION_BUNDLE_ID = com.novusordo.myapp.widget
```

The workflow now validates this contract before any signing or build steps. It fails early with a clear error if:

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
| Team ID | From the first target's `DEVELOPMENT_TEAM` build setting |
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

### Organization secrets (set once in NovusOrdoApps org settings)

| Secret | Purpose |
|---|---|
| `CHECKOUT_PAT` | GitHub PAT for cloning repos and private submodules |
| `MATCH_PASSWORD` | Encryption passphrase for the shared certificate repo |
| `MATCH_GIT_URL` | HTTPS URL of the private certificate repo |
| `MATCH_GIT_PAT` | PAT with read/write access to the certificate repo |
| `DIAWI_TOKEN` | Diawi API token (only needed for ad-hoc builds) |
| `TG_WORKER_API_KEY` | Telegram notification worker API key (only needed for ad-hoc builds) |

### Per-repo secrets (set in each app repo)

| Secret | Purpose |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Content of the .p8 API key file |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect Issuer ID |

> If all apps share the same Apple Developer account, these 3 can also be moved to org-level secrets.
>
> CI does not need separate workflow inputs for bundle ID or team ID. Those must come from the app repo's xcconfig-driven release configuration.

### GitHub Actions variables for CI-generated release config

If you do not want release identifiers committed to the repo, store them as GitHub Actions configuration variables and let `scripts/prepare.sh` generate the release xcconfig from them.

Standard variable names exposed by `ios-ci` to `scripts/prepare.sh`:

| Variable | Purpose |
|---|---|
| `IOS_RELEASE_TEAM_ID` | Apple team ID for Release / TestFlight builds |
| `IOS_RELEASE_APP_BUNDLE_ID` | Main app bundle ID for Release / TestFlight builds |
| `IOS_RELEASE_EXTENSION_BUNDLE_ID` | Optional extension bundle ID |

For apps with more identifiers than these defaults cover, keep using `scripts/prepare.sh` and extend it with app-specific variables.

## Optional inputs

The caller workflow can override these defaults:

| Input | Default | Description |
|---|---|---|
| `adhoc` | `false` | Also build ad-hoc IPA and upload to Diawi |
| `macos_runner` | `macos-15` | GitHub Actions runner label |
| `ruby_version` | `3.2` | Ruby version for fastlane |
| `scheme` | auto-detect | Required when the repo has multiple app schemes; for Flutter this is also used as the `--flavor` value |
| `configuration` | `Release` | Xcode configuration used for validation, detection, and native builds. Flutter currently supports only `Release`. |

## Prepare script

If your app needs custom steps before the build, create `scripts/prepare.sh` in your app repo. This is the right place to generate CI-only release xcconfig files from GitHub variables, copy release secrets into config files, or run code generators before CI validates the project contract.

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Generate a CI-only release xcconfig from GitHub Actions variables
cat > Config/CI.Release.generated.xcconfig <<EOF
APPLE_TEAM_ID = ${IOS_RELEASE_TEAM_ID}
APP_BUNDLE_ID = ${IOS_RELEASE_APP_BUNDLE_ID}
APP_EXTENSION_BUNDLE_ID = ${IOS_RELEASE_EXTENSION_BUNDLE_ID}
EOF
```

## Files in this repo

```
ios-ci/
├── .github/workflows/
│   └── ios-release.yml             # Reusable workflow (all build logic)
├── fastlane/
│   ├── Fastfile                    # Generic lanes: signing, building, uploading
│   ├── Matchfile                   # Points to MATCH_GIT_URL from env
│   └── Appfile                     # Empty (all values are dynamic)
├── Gemfile                         # fastlane dependency
└── scripts/
    ├── detect-project.sh           # Auto-detects workspace, scheme, targets, bundle IDs
    ├── validate-project-contract.rb # Enforces the xcconfig-driven release contract
    └── generate-export-options.sh  # Builds ExportOptions.plist dynamically
```

## Updating

Changes to this repo take effect immediately for all app repos if they reference `@main`. To pin a stable version, change the caller to reference a tag:

```yaml
uses: NovusOrdoApps/ios-ci/.github/workflows/ios-release.yml@v1
```
