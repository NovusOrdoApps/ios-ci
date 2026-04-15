# App Store Metadata Management — Design Spec

## Overview

Extend ios-ci with a reusable GitHub Actions workflow that uploads App Store metadata (text, screenshots) via fastlane `deliver`. Completely independent from the release workflow — no Xcode project, signing, or IPA needed.

Caller repos can be metadata-only repos (just text + screenshots) or app repos with metadata alongside the project.

## Caller Repo Convention

### Directory Structure

```
metadata/
├── Text/
│   ├── defaults/
│   │   ├── info.jsonc          # shared fields (URLs, etc.)
│   │   ├── description.txt     # optional — base description
│   │   └── whatsNew.txt        # optional — shared release notes
│   ├── en/
│   │   ├── info.jsonc          # locale-specific overrides
│   │   ├── description.txt     # plain text, real line breaks
│   │   └── whatsNew.txt        # optional — localized release notes
│   ├── ru/
│   │   ├── info.jsonc
│   │   ├── description.txt
│   │   └── whatsNew.txt
│   └── {locale}/
│       └── ...
└── Screenshots/
    ├── en/
    │   ├── APP_IPHONE_67/
    │   │   ├── frame1.png
    │   │   ├── frame2.png
    │   │   └── frame3.png
    │   ├── APP_IPHONE_65/
    │   │   └── ...
    │   ├── APP_IPHONE_55/
    │   │   └── ...
    │   ├── APP_IPAD_129/
    │   │   └── ...
    │   └── APP_IPAD_110/
    │       └── ...
    ├── ru/
    │   └── ...
    └── {locale}/
        └── ...
```

### info.jsonc Format

JSONC (JSON with comments) for translator convenience.

```jsonc
{
  // Max 30 characters
  "name": "App Title",
  // Max 30 characters
  "subtitle": "App Subtitle",
  // Comma-separated, max 100 chars total
  "keywords": "keyword1,keyword2,keyword3",
  "promotionalText": "Try our new feature!",
  "marketingUrl": "https://example.com",
  "supportUrl": "https://example.com/support",
  "privacyUrl": "https://example.com/privacy"
}
```

All fields are optional — only include what you want to update. `deliver` only updates fields that have corresponding files in the output, so partial updates are safe. Fields not present in the metadata are left untouched on App Store Connect.

### Metadata Directory Location

The workflow expects `metadata/` at the root of the caller repo. This is a convention, not configurable — keeps things simple.

### Text File Merge Logic

For each locale, the transform script merges defaults with locale-specific values:

**info.jsonc:** Load `defaults/info.jsonc`, then merge locale's `info.jsonc` on top. Locale wins on conflicts.

**description.txt:** Use locale's file if it exists, otherwise fall back to `defaults/description.txt`.

**whatsNew.txt:** Controlled by the `use_default_whats_new` workflow input:
- `use_default_whats_new: true` (default) — use `defaults/whatsNew.txt` for all locales, ignore per-locale files.
- `use_default_whats_new: false` — use locale's `whatsNew.txt` if it exists, otherwise fall back to `defaults/whatsNew.txt`.

Rationale: whatsNew changes every release. Per-locale files from a previous release would go stale and silently override the new default. The flag makes the common case safe (one shared whatsNew) while still allowing localized release notes when needed.

### Locale Codes

Must use Apple's exact locale codes as folder names. Examples: `en`, `en-US`, `ru`, `uk`, `fr-FR`, `de-DE`, `ca`, `pt-BR`.

`deliver` automatically creates localizations on App Store Connect if they don't exist yet.

### JSON-to-deliver Field Mapping

| info.jsonc key    | deliver file           |
|-------------------|------------------------|
| `name`            | `name.txt`             |
| `subtitle`        | `subtitle.txt`         |
| `keywords`        | `keywords.txt`         |
| `promotionalText` | `promotional_text.txt` |
| `marketingUrl`    | `marketing_url.txt`    |
| `supportUrl`      | `support_url.txt`      |
| `privacyUrl`      | `privacy_url.txt`      |

Text files map directly:

| Source file      | deliver file         |
|------------------|----------------------|
| `description.txt`| `description.txt`    |
| `whatsNew.txt`   | `release_notes.txt`  |

## Screenshot Processing

### Device Folder to Dimensions Mapping

| Folder           | Portrait      | Landscape     |
|------------------|---------------|---------------|
| `APP_IPHONE_67`  | 1290 x 2796   | 2796 x 1290   |
| `APP_IPHONE_65`  | 1284 x 2778   | 2778 x 1284   |
| `APP_IPHONE_55`  | 1242 x 2208   | 2208 x 1242   |
| `APP_IPAD_129`   | 2048 x 2732   | 2732 x 2048   |
| `APP_IPAD_110`   | 1668 x 2388   | 2388 x 1668   |

### Processing Pipeline

**Phase 1 — Validate all screenshots (fail fast):**
1. Read actual pixel dimensions of every PNG.
2. Detect orientation: `width > height` = landscape, otherwise portrait.
3. Look up target dimensions from the device folder name.
4. Compare actual vs target. If either dimension differs by more than the tolerance threshold (default 20px), record the error.
5. After scanning ALL screenshots, if any errors exist, print a full report and fail:

```
Screenshot validation failed:

  ru/APP_IPHONE_65/frame2.png
    Expected: 1284 x 2778 (portrait)
    Actual:   1250 x 2700
    Diff:     34 x 78 — exceeds 20px tolerance

  uk/APP_IPAD_129/frame1.png
    Expected: 2732 x 2048 (landscape)
    Actual:   2500 x 2048
    Diff:     232 x 0 — exceeds 20px tolerance

2 errors found. Fix screenshots before uploading.
```

**Phase 2 — Transform (only runs if validation passes):**
1. Scale each image to exact Apple dimensions using `sips -z`.
2. Strip alpha channel using `sips -s hasAlpha false`.
3. Output to deliver's flat `screenshots/{locale}/` structure. Files are named to preserve ordering (e.g., `01_frame1.png`, `02_frame2.png`).

`sips` is built into macOS — zero external dependencies needed on GitHub Actions macOS runners.

## App Version Logic

The `app_version` workflow input controls which App Store Connect version receives the metadata:

| Scenario | Behavior |
|----------|----------|
| No version input + editable version exists on ASC | Update that editable version |
| No version input + no editable version exists | **Fail:** "No editable app version found on App Store Connect. Provide an explicit version to create one." |
| Version provided + doesn't exist on ASC | Create it, upload metadata |
| Version provided + exists as editable draft | Update it |
| Version provided + exists but not editable (live/in review) | **Fail:** "Version X.Y.Z is not editable (status: In Review). Create a new version or wait." |

## Reusable Workflow

### Trigger

Manual only (`workflow_dispatch`).

### Inputs

| Input                  | Required | Default | Description                                         |
|------------------------|----------|---------|-----------------------------------------------------|
| `app_version`          | no       | `""`    | Target version. Empty = update current draft         |
| `skip_screenshots`     | no       | `true`  | Skip screenshot upload                               |
| `use_default_whats_new`| no       | `true`  | Ignore per-locale whatsNew, use defaults only        |

### Required Secrets (same as release workflow)

Per-repo:
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

Org-level:
- `CHECKOUT_PAT`

### Required Variables

Per-repo:
- `IOS_RELEASE_APP_BUNDLE_ID` — app identifier for deliver

### Pipeline Steps

1. Checkout caller repo + ios-ci tooling
2. Setup Ruby (with bundler cache from ios-ci)
3. Write App Store Connect API key to temp file
4. Run `transform-metadata.rb`:
   - Load `defaults/` base
   - Merge each locale's overrides
   - Apply `use_default_whats_new` logic for whatsNew
   - If `skip_screenshots` is false: validate all screenshots (fail fast on errors), then process (scale + strip alpha)
   - Output deliver-formatted directory to a temp path
5. Run `update_metadata` fastlane lane — calls `deliver` with the temp dir
6. Cleanup (remove API key)

## New Files in ios-ci

| File | Purpose |
|------|---------|
| `.github/workflows/ios-metadata.yml` | Reusable workflow |
| `scripts/transform-metadata.rb` | Validates screenshots, transforms custom format to deliver format |
| `fastlane/Fastfile` (modified) | Add `update_metadata` lane |

### Fastlane Lane

```ruby
lane :update_metadata do |options|
  api_key = app_store_connect_api_key(
    key_id: ENV.fetch("APP_STORE_CONNECT_KEY_ID"),
    issuer_id: ENV.fetch("APP_STORE_CONNECT_ISSUER_ID"),
    key_filepath: ENV.fetch("ASC_KEY_P8_PATH"),
  )

  deliver_opts = {
    api_key: api_key,
    app_identifier: ENV.fetch("APP_BUNDLE_ID"),
    metadata_path: options[:metadata_path],
    skip_binary_upload: true,
    force: true,
    precheck_include_in_app_purchases: false,
  }

  deliver_opts[:app_version] = options[:app_version] unless options[:app_version].to_s.empty?
  deliver_opts[:skip_screenshots] = options[:skip_screenshots] == "true"
  deliver_opts[:screenshots_path] = options[:screenshots_path] unless options[:skip_screenshots] == "true"

  deliver(deliver_opts)
end
```

### Example Caller Workflow

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
      use_default_whats_new:
        description: 'Use defaults/whatsNew.txt for all locales'
        required: false
        type: boolean
        default: true

jobs:
  metadata:
    uses: NovusOrdoApps/ios-ci/.github/workflows/ios-metadata.yml@main
    with:
      app_version: ${{ inputs.app_version }}
      skip_screenshots: ${{ inputs.skip_screenshots }}
      use_default_whats_new: ${{ inputs.use_default_whats_new }}
    secrets: inherit
```

## Error Handling

All errors should be clear and actionable:

- **Unknown device folder:** "Unknown screenshot device folder 'APP_IPHONE_99' in ru/. Expected: APP_IPHONE_67, APP_IPHONE_65, APP_IPHONE_55, APP_IPAD_129, APP_IPAD_110."
- **Invalid locale code:** Delegated to `deliver` — it will fail with Apple's error if the locale isn't supported.
- **Missing defaults/whatsNew.txt when use_default_whats_new is true:** "use_default_whats_new is enabled but defaults/whatsNew.txt not found."
- **No metadata directory found:** "Expected metadata/Text/ directory at {path}. See ios-ci README for the expected structure."
- **JSONC parse error:** "Failed to parse {locale}/info.jsonc: {error message} at line {N}."
- **Screenshot dimension mismatch:** Full report listing all failures (see Screenshot Processing section).
- **No editable app version:** "No editable app version found on App Store Connect. Provide an explicit version to create one."
- **Version not editable:** "Version X.Y.Z exists but is not editable (status: {status})."
