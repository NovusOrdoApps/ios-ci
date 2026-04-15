# App Store Metadata Management — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable GitHub Actions workflow to ios-ci that uploads App Store metadata (text + screenshots) via fastlane `deliver`, using a custom translator-friendly folder convention.

**Architecture:** A Ruby transform script converts the custom folder format (JSONC + txt + device-organized screenshots) into deliver's expected format in a temp directory. A new fastlane lane calls `deliver` with that temp directory. A reusable workflow orchestrates it all — checkout, transform, deliver, cleanup.

**Tech Stack:** Ruby (transform script), fastlane deliver (App Store upload), GitHub Actions (workflow), macOS `sips` (image processing)

**Spec:** `docs/superpowers/specs/2026-04-15-app-store-metadata-design.md`

---

### Task 1: Transform Script — JSONC Parser and Text Merge

**Files:**
- Create: `scripts/transform-metadata.rb`

This task builds the core text transformation logic. Screenshots are added in Task 2.

- [ ] **Step 1: Create the script with CLI argument parsing and JSONC helper**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# transform-metadata.rb
#
# Transforms custom metadata format into fastlane deliver format.
#
# Usage:
#   ruby transform-metadata.rb \
#     --input /path/to/metadata \
#     --output /path/to/output \
#     --use-default-whats-new true \
#     --skip-screenshots true

require "json"
require "fileutils"
require "optparse"

# ── Constants ──────────────────────────────────────

JSONC_FIELD_MAP = {
  "name"            => "name.txt",
  "subtitle"        => "subtitle.txt",
  "keywords"        => "keywords.txt",
  "promotionalText" => "promotional_text.txt",
  "marketingUrl"    => "marketing_url.txt",
  "supportUrl"      => "support_url.txt",
  "privacyUrl"      => "privacy_url.txt",
}.freeze

DEVICE_DIMENSIONS = {
  "APP_IPHONE_67" => [1290, 2796],
  "APP_IPHONE_65" => [1284, 2778],
  "APP_IPHONE_55" => [1242, 2208],
  "APP_IPAD_129"  => [2048, 2732],
  "APP_IPAD_110"  => [1668, 2388],
}.freeze

DIMENSION_TOLERANCE = 20

# ── Helpers ────────────────────────────────────────

def parse_jsonc(path)
  content = File.read(path)
  # Strip single-line comments (// ...) but not inside strings
  stripped = content.gsub(%r{^\s*//.*$}, "")        # full-line comments
                    .gsub(%r{(?<=,)\s*//.*$}, "")    # trailing comments after comma
                    .gsub(%r{(?<=\{)\s*//.*$}, "")   # trailing comments after {
                    .gsub(%r{(?<=\})\s*//.*$}, "")   # trailing comments after }
                    .gsub(%r{(?<=")\s*//.*$}, "")     # trailing comments after "
  JSON.parse(stripped)
rescue JSON::ParserError => e
  abort "Failed to parse #{path}: #{e.message}"
end

def read_text_file(path)
  return nil unless File.exist?(path)
  File.read(path)
end

# ── CLI ────────────────────────────────────────────

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: transform-metadata.rb [options]"
  opts.on("--input PATH", "Path to metadata/ directory") { |v| options[:input] = v }
  opts.on("--output PATH", "Path to output directory") { |v| options[:output] = v }
  opts.on("--use-default-whats-new BOOL", "Use defaults/whatsNew.txt for all locales") { |v| options[:use_default_whats_new] = v == "true" }
  opts.on("--skip-screenshots BOOL", "Skip screenshot processing") { |v| options[:skip_screenshots] = v == "true" }
end.parse!

input_dir  = options[:input]  || abort("Missing --input")
output_dir = options[:output] || abort("Missing --output")
use_default_whats_new = options.fetch(:use_default_whats_new, true)
skip_screenshots      = options.fetch(:skip_screenshots, true)

text_dir = File.join(input_dir, "Text")
abort "Expected metadata/Text/ directory at #{text_dir}" unless Dir.exist?(text_dir)

defaults_dir = File.join(text_dir, "defaults")
screenshots_dir = File.join(input_dir, "Screenshots")

# ── Discover locales ──────────────────────────────

locale_dirs = Dir.children(text_dir)
                 .select { |d| d != "defaults" && File.directory?(File.join(text_dir, d)) }
                 .sort

if locale_dirs.empty?
  abort "No locale directories found in #{text_dir}. Expected folders like en/, ru/, fr-FR/, etc."
end

puts ":: Found #{locale_dirs.size} locale(s): #{locale_dirs.join(', ')}"

# ── Load defaults ─────────────────────────────────

defaults_info = {}
if Dir.exist?(defaults_dir) && File.exist?(File.join(defaults_dir, "info.jsonc"))
  defaults_info = parse_jsonc(File.join(defaults_dir, "info.jsonc"))
  puts ":: Loaded defaults/info.jsonc (#{defaults_info.size} fields)"
end

defaults_description = read_text_file(File.join(defaults_dir, "description.txt")) if Dir.exist?(defaults_dir)
defaults_whats_new   = read_text_file(File.join(defaults_dir, "whatsNew.txt"))    if Dir.exist?(defaults_dir)

if use_default_whats_new && defaults_whats_new.nil?
  abort "use_default_whats_new is enabled but defaults/whatsNew.txt not found."
end

# ── Transform text per locale ─────────────────────

metadata_output = File.join(output_dir, "metadata")
FileUtils.mkdir_p(metadata_output)

locale_dirs.each do |locale|
  locale_path = File.join(text_dir, locale)
  out_locale = File.join(metadata_output, locale)
  FileUtils.mkdir_p(out_locale)

  # Merge info.jsonc: defaults + locale override
  locale_info = defaults_info.dup
  locale_jsonc = File.join(locale_path, "info.jsonc")
  if File.exist?(locale_jsonc)
    locale_overrides = parse_jsonc(locale_jsonc)
    locale_info.merge!(locale_overrides)
  end

  # Write each field to its deliver file
  locale_info.each do |key, value|
    deliver_file = JSONC_FIELD_MAP[key]
    if deliver_file.nil?
      puts "   WARNING: Unknown field '#{key}' in #{locale}/info.jsonc, skipping."
      next
    end
    File.write(File.join(out_locale, deliver_file), value)
  end

  # description.txt: locale overrides defaults
  description = read_text_file(File.join(locale_path, "description.txt")) || defaults_description
  File.write(File.join(out_locale, "description.txt"), description) if description

  # whatsNew.txt → release_notes.txt
  whats_new = if use_default_whats_new
                defaults_whats_new
              else
                read_text_file(File.join(locale_path, "whatsNew.txt")) || defaults_whats_new
              end
  File.write(File.join(out_locale, "release_notes.txt"), whats_new) if whats_new

  field_count = Dir.children(out_locale).size
  puts ":: #{locale}: #{field_count} metadata files written"
end

# ── Screenshots ───────────────────────────────────

if skip_screenshots
  puts ":: Skipping screenshots (--skip-screenshots true)"
else
  unless Dir.exist?(screenshots_dir)
    puts ":: No Screenshots/ directory found, skipping screenshots."
    # Signal to fastlane to skip screenshots too
    skip_screenshots = true
  end
end

unless skip_screenshots
  require_relative "transform_screenshots"
  process_screenshots(screenshots_dir, File.join(output_dir, "screenshots"))
end

puts ":: Transform complete. Output at #{output_dir}"
```

- [ ] **Step 2: Verify the script parses without errors**

Run:
```bash
cd /Users/arturdev/Developer/NovusOrdo/ios-ci && ruby -c scripts/transform-metadata.rb
```
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/transform-metadata.rb
git commit -m "feat: add transform-metadata.rb — text merge logic"
```

---

### Task 2: Transform Script — Screenshot Validation and Processing

**Files:**
- Create: `scripts/transform_screenshots.rb`

Separated into its own file to keep transform-metadata.rb focused. Loaded via `require_relative` when screenshots are not skipped.

- [ ] **Step 1: Create the screenshot processing module**

```ruby
# frozen_string_literal: true

# transform_screenshots.rb
#
# Validates and processes screenshots for App Store upload.
# Called from transform-metadata.rb via require_relative.

DEVICE_DIMENSIONS = {
  "APP_IPHONE_67" => [1290, 2796],
  "APP_IPHONE_65" => [1284, 2778],
  "APP_IPHONE_55" => [1242, 2208],
  "APP_IPAD_129"  => [2048, 2732],
  "APP_IPAD_110"  => [1668, 2388],
}.freeze unless defined?(DEVICE_DIMENSIONS)

DIMENSION_TOLERANCE = 20 unless defined?(DIMENSION_TOLERANCE)

VALID_DEVICE_FOLDERS = DEVICE_DIMENSIONS.keys.freeze

def get_image_dimensions(path)
  # Use sips to read pixel dimensions (built into macOS)
  output = `sips -g pixelWidth -g pixelHeight "#{path}" 2>/dev/null`
  width  = output[/pixelWidth:\s*(\d+)/, 1]&.to_i
  height = output[/pixelHeight:\s*(\d+)/, 1]&.to_i
  [width, height]
end

def target_dimensions_for(device_folder, actual_width, actual_height)
  base = DEVICE_DIMENSIONS[device_folder]
  return nil unless base

  portrait_w, portrait_h = base
  # Detect orientation from actual image
  if actual_width > actual_height
    # Landscape: swap target dimensions
    [portrait_h, portrait_w]
  else
    # Portrait (or square — treat as portrait)
    [portrait_w, portrait_h]
  end
end

def process_screenshots(screenshots_dir, output_dir)
  errors = []
  files_to_process = []

  # Discover all locale/device/image combinations
  Dir.children(screenshots_dir).sort.each do |locale|
    locale_path = File.join(screenshots_dir, locale)
    next unless File.directory?(locale_path)

    Dir.children(locale_path).sort.each do |device_folder|
      device_path = File.join(locale_path, device_folder)
      next unless File.directory?(device_path)

      unless VALID_DEVICE_FOLDERS.include?(device_folder)
        errors << {
          file: "#{locale}/#{device_folder}/",
          message: "Unknown screenshot device folder '#{device_folder}'. Expected: #{VALID_DEVICE_FOLDERS.join(', ')}.",
        }
        next
      end

      pngs = Dir.children(device_path)
                .select { |f| f.downcase.end_with?(".png") }
                .sort

      pngs.each do |png|
        full_path = File.join(device_path, png)
        actual_w, actual_h = get_image_dimensions(full_path)

        unless actual_w && actual_h
          errors << {
            file: "#{locale}/#{device_folder}/#{png}",
            message: "Could not read image dimensions.",
          }
          next
        end

        target_w, target_h = target_dimensions_for(device_folder, actual_w, actual_h)
        orientation = actual_w > actual_h ? "landscape" : "portrait"

        diff_w = (actual_w - target_w).abs
        diff_h = (actual_h - target_h).abs

        if diff_w > DIMENSION_TOLERANCE || diff_h > DIMENSION_TOLERANCE
          errors << {
            file: "#{locale}/#{device_folder}/#{png}",
            message: "Expected: #{target_w} x #{target_h} (#{orientation})\n" \
                     "    Actual:   #{actual_w} x #{actual_h}\n" \
                     "    Diff:     #{diff_w} x #{diff_h} — exceeds #{DIMENSION_TOLERANCE}px tolerance",
          }
        else
          files_to_process << {
            source: full_path,
            locale: locale,
            device_folder: device_folder,
            filename: png,
            target_w: target_w,
            target_h: target_h,
          }
        end
      end
    end
  end

  # ── Phase 1: Fail fast if any errors ──

  unless errors.empty?
    puts ""
    puts "Screenshot validation failed:"
    puts ""
    errors.each do |err|
      puts "  #{err[:file]}"
      puts "    #{err[:message]}"
      puts ""
    end
    abort "#{errors.size} error(s) found. Fix screenshots before uploading."
  end

  if files_to_process.empty?
    puts ":: No screenshots found to process."
    return
  end

  puts ":: Validated #{files_to_process.size} screenshots, all within tolerance."

  # ── Phase 2: Transform ──

  files_to_process.each_with_index do |entry, _idx|
    locale_out = File.join(output_dir, entry[:locale])
    FileUtils.mkdir_p(locale_out)

    # Prefix with device folder + original name for ordering
    # deliver auto-detects device from pixel dimensions
    out_name = "#{entry[:device_folder]}_#{entry[:filename]}"
    out_path = File.join(locale_out, out_name)

    # Copy first, then process in-place
    FileUtils.cp(entry[:source], out_path)

    # Strip alpha channel
    system("sips", "-s", "hasAlpha", "false", out_path, "--out", out_path,
           out: File::NULL, err: File::NULL)

    # Scale to exact dimensions (sips -z takes height width)
    system("sips", "-z", entry[:target_h].to_s, entry[:target_w].to_s, out_path,
           out: File::NULL, err: File::NULL)
  end

  puts ":: Processed #{files_to_process.size} screenshots to #{output_dir}"
end
```

- [ ] **Step 2: Verify the script parses without errors**

Run:
```bash
cd /Users/arturdev/Developer/NovusOrdo/ios-ci && ruby -c scripts/transform_screenshots.rb
```
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/transform_screenshots.rb
git commit -m "feat: add screenshot validation and processing"
```

---

### Task 3: Add `update_metadata` Lane to Fastfile

**Files:**
- Modify: `fastlane/Fastfile`

- [ ] **Step 1: Add the `update_metadata` lane at the end of the `platform :ios do` block**

Add before the final `end` in the Fastfile:

```ruby
  # ──────────────────────────────────────────────
  # update_metadata
  #
  # Uploads metadata and/or screenshots to App Store Connect.
  # Usage: bundle exec fastlane update_metadata \
  #          metadata_path:/tmp/deliver/metadata \
  #          screenshots_path:/tmp/deliver/screenshots \
  #          skip_screenshots:true \
  #          app_version:2.5.0
  # ──────────────────────────────────────────────
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

    if options[:skip_screenshots] == "true"
      deliver_opts[:skip_screenshots] = true
    else
      deliver_opts[:skip_screenshots] = false
      deliver_opts[:screenshots_path] = options[:screenshots_path]
    end

    deliver(deliver_opts)
  end
```

- [ ] **Step 2: Verify the Fastfile parses**

Run:
```bash
cd /Users/arturdev/Developer/NovusOrdo/ios-ci && ruby -c fastlane/Fastfile
```
Expected: `Syntax OK`

- [ ] **Step 3: Commit**

```bash
git add fastlane/Fastfile
git commit -m "feat: add update_metadata fastlane lane"
```

---

### Task 4: Reusable GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/ios-metadata.yml`

- [ ] **Step 1: Create the workflow file**

```yaml
# Reusable workflow: Update App Store metadata and screenshots.
#
# Transforms a custom translator-friendly folder convention into
# fastlane deliver format and uploads to App Store Connect.
#
# Required repo secrets:
#   APP_STORE_CONNECT_API_KEY_P8
#   APP_STORE_CONNECT_KEY_ID
#   APP_STORE_CONNECT_ISSUER_ID
#
# Required org secrets:
#   CHECKOUT_PAT
#
# Required repo variables:
#   IOS_RELEASE_APP_BUNDLE_ID

name: iOS Metadata (Reusable)

on:
  workflow_call:
    inputs:
      app_version:
        description: "Target app version. Leave empty to update the current editable version."
        required: false
        type: string
        default: ""
      skip_screenshots:
        description: "Skip screenshot upload"
        required: false
        type: boolean
        default: true
      use_default_whats_new:
        description: "Use defaults/whatsNew.txt for all locales, ignoring per-locale whatsNew files"
        required: false
        type: boolean
        default: true
      ruby_version:
        description: "Ruby version for fastlane"
        required: false
        type: string
        default: "3.2"
      macos_runner:
        description: "macOS runner label (needed for sips screenshot processing)"
        required: false
        type: string
        default: "macos-15"

concurrency:
  group: ios-metadata-${{ github.repository }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  update-metadata:
    name: Update App Store Metadata
    runs-on: ${{ inputs.macos_runner }}
    timeout-minutes: 30

    env:
      APP_STORE_CONNECT_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
      APP_STORE_CONNECT_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
      APP_BUNDLE_ID: ${{ vars.IOS_RELEASE_APP_BUNDLE_ID }}

    steps:
      - name: Checkout app/metadata repo
        uses: actions/checkout@v4
        with:
          token: ${{ secrets.CHECKOUT_PAT }}

      - name: Checkout ios-ci tooling
        uses: actions/checkout@v4
        with:
          repository: NovusOrdoApps/ios-ci
          path: _ci
          token: ${{ secrets.CHECKOUT_PAT }}

      - name: Setup Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ inputs.ruby_version }}
          bundler-cache: true
          working-directory: _ci

      - name: Write API key
        run: |
          mkdir -p "$RUNNER_TEMP/secrets"
          echo "${{ secrets.APP_STORE_CONNECT_API_KEY_P8 }}" > "$RUNNER_TEMP/secrets/AuthKey.p8"
          echo "ASC_KEY_P8_PATH=$RUNNER_TEMP/secrets/AuthKey.p8" >> "$GITHUB_ENV"

      - name: Validate inputs
        run: |
          : "${APP_BUNDLE_ID:?Missing GitHub Actions variable IOS_RELEASE_APP_BUNDLE_ID}"

          if [ ! -d "metadata/Text" ]; then
            echo "ERROR: Expected metadata/Text/ directory at the repo root." >&2
            echo "See ios-ci README for the expected metadata structure." >&2
            exit 1
          fi

          echo ":: App Bundle ID: $APP_BUNDLE_ID"
          echo ":: App Version: ${{ inputs.app_version || '(current draft)' }}"
          echo ":: Skip Screenshots: ${{ inputs.skip_screenshots }}"
          echo ":: Use Default What's New: ${{ inputs.use_default_whats_new }}"

      - name: Transform metadata
        run: |
          ruby _ci/scripts/transform-metadata.rb \
            --input "$GITHUB_WORKSPACE/metadata" \
            --output "$RUNNER_TEMP/deliver-metadata" \
            --use-default-whats-new "${{ inputs.use_default_whats_new }}" \
            --skip-screenshots "${{ inputs.skip_screenshots }}"

      - name: Upload metadata to App Store Connect
        working-directory: _ci
        run: |
          bundle exec fastlane update_metadata \
            metadata_path:"$RUNNER_TEMP/deliver-metadata/metadata" \
            screenshots_path:"$RUNNER_TEMP/deliver-metadata/screenshots" \
            skip_screenshots:"${{ inputs.skip_screenshots }}" \
            app_version:"${{ inputs.app_version }}"

      - name: Cleanup
        if: always()
        run: rm -f "$RUNNER_TEMP/secrets/AuthKey.p8"
```

- [ ] **Step 2: Validate YAML syntax**

Run:
```bash
cd /Users/arturdev/Developer/NovusOrdo/ios-ci && ruby -ryaml -e "YAML.load_file('.github/workflows/ios-metadata.yml')" && echo "YAML OK"
```
Expected: `YAML OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ios-metadata.yml
git commit -m "feat: add ios-metadata reusable workflow"
```

---

### Task 5: Test with Sample Metadata

**Files:**
- Create: `tests/fixtures/metadata/Text/defaults/info.jsonc`
- Create: `tests/fixtures/metadata/Text/defaults/whatsNew.txt`
- Create: `tests/fixtures/metadata/Text/en/info.jsonc`
- Create: `tests/fixtures/metadata/Text/en/description.txt`
- Create: `tests/fixtures/metadata/Text/ru/info.jsonc`
- Create: `tests/fixtures/metadata/Text/ru/description.txt`
- Create: `tests/fixtures/metadata/Text/ru/whatsNew.txt`

This task creates test fixtures and runs the transform script locally to verify the text merge logic end-to-end.

- [ ] **Step 1: Create test fixture files**

`tests/fixtures/metadata/Text/defaults/info.jsonc`:
```jsonc
{
  // Shared across all locales
  "marketingUrl": "https://example.com",
  "supportUrl": "https://example.com/support",
  "privacyUrl": "https://example.com/privacy"
}
```

`tests/fixtures/metadata/Text/defaults/whatsNew.txt`:
```
Bug fixes and stability improvements.
```

`tests/fixtures/metadata/Text/en/info.jsonc`:
```jsonc
{
  // Max 30 characters
  "name": "My Cool App",
  "subtitle": "The best app ever",
  "keywords": "cool,app,best"
}
```

`tests/fixtures/metadata/Text/en/description.txt`:
```
My Cool App is the best app you'll ever use.

Features:
- Feature one
- Feature two
- Feature three

Download now!
```

`tests/fixtures/metadata/Text/ru/info.jsonc`:
```jsonc
{
  "name": "Мое Приложение",
  "subtitle": "Лучшее приложение",
  "keywords": "крутое,приложение,лучшее"
}
```

`tests/fixtures/metadata/Text/ru/description.txt`:
```
Мое Приложение — лучшее приложение.

Возможности:
- Функция один
- Функция два
- Функция три
```

`tests/fixtures/metadata/Text/ru/whatsNew.txt`:
```
Исправления ошибок и улучшение стабильности.
```

- [ ] **Step 2: Run the transform with use_default_whats_new=true**

```bash
cd /Users/arturdev/Developer/NovusOrdo/ios-ci && \
  rm -rf /tmp/test-deliver-output && \
  ruby scripts/transform-metadata.rb \
    --input tests/fixtures/metadata \
    --output /tmp/test-deliver-output \
    --use-default-whats-new true \
    --skip-screenshots true
```

Expected output:
```
:: Loaded defaults/info.jsonc (3 fields)
:: Found 2 locale(s): en, ru
:: en: N metadata files written
:: ru: N metadata files written
:: Skipping screenshots (--skip-screenshots true)
:: Transform complete. Output at /tmp/test-deliver-output
```

- [ ] **Step 3: Verify the output structure and content**

```bash
# Check structure
find /tmp/test-deliver-output/metadata -type f | sort

# Verify en gets defaults URLs + locale name/subtitle/keywords
cat /tmp/test-deliver-output/metadata/en/marketing_url.txt
# Expected: https://example.com

cat /tmp/test-deliver-output/metadata/en/name.txt
# Expected: My Cool App

# Verify ru gets the DEFAULT whatsNew (not ru's own) because use_default_whats_new=true
cat /tmp/test-deliver-output/metadata/ru/release_notes.txt
# Expected: Bug fixes and stability improvements.
```

- [ ] **Step 4: Run with use_default_whats_new=false and verify ru gets its own whatsNew**

```bash
rm -rf /tmp/test-deliver-output && \
  ruby scripts/transform-metadata.rb \
    --input tests/fixtures/metadata \
    --output /tmp/test-deliver-output \
    --use-default-whats-new false \
    --skip-screenshots true

cat /tmp/test-deliver-output/metadata/ru/release_notes.txt
# Expected: Исправления ошибок и улучшение стабильности.

cat /tmp/test-deliver-output/metadata/en/release_notes.txt
# Expected: Bug fixes and stability improvements.
# (en has no whatsNew.txt, so falls back to defaults)
```

- [ ] **Step 5: Commit test fixtures**

```bash
git add tests/fixtures/
git commit -m "test: add metadata transform test fixtures"
```

---

### Task 6: Test Screenshot Validation Locally

**Files:**
- Create: `tests/fixtures/metadata/Screenshots/en/APP_IPHONE_67/frame1.png` (generated)

This task verifies screenshot validation works by creating a test PNG with known dimensions.

- [ ] **Step 1: Generate a test PNG with sips**

```bash
cd /Users/arturdev/Developer/NovusOrdo/ios-ci

# Create screenshot directory
mkdir -p tests/fixtures/metadata/Screenshots/en/APP_IPHONE_67

# Create a 1290x2796 solid color PNG (exact dimensions — should pass)
sips -z 2796 1290 -s format png /System/Library/Desktop\ Pictures/*.heic 2>/dev/null | head -1 || true

# Alternative: create with Python (more reliable for CI)
python3 -c "
from PIL import Image
img = Image.new('RGBA', (1290, 2796), (100, 150, 200, 255))
img.save('tests/fixtures/metadata/Screenshots/en/APP_IPHONE_67/frame1.png')
" 2>/dev/null || \
python3 -c "
import struct, zlib
def create_png(w, h, path):
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    raw = b''
    for _ in range(h):
        raw += b'\x00' + b'\x64\x96\xc8\xff' * w
    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw)) +
            chunk(b'IEND', b''))
open(path, 'wb').write(create_png(1290, 2796, path))
print(f'Created {path}')
" "tests/fixtures/metadata/Screenshots/en/APP_IPHONE_67/frame1.png"
```

- [ ] **Step 2: Run transform with screenshots enabled — should pass validation**

```bash
rm -rf /tmp/test-deliver-output && \
  ruby scripts/transform-metadata.rb \
    --input tests/fixtures/metadata \
    --output /tmp/test-deliver-output \
    --use-default-whats-new true \
    --skip-screenshots false
```

Expected: validation passes, screenshot processed to `/tmp/test-deliver-output/screenshots/en/`

- [ ] **Step 3: Verify the processed screenshot has no alpha and correct dimensions**

```bash
sips -g hasAlpha -g pixelWidth -g pixelHeight /tmp/test-deliver-output/screenshots/en/*.png
```

Expected: `hasAlpha: false`, `pixelWidth: 1290`, `pixelHeight: 2796`

- [ ] **Step 4: Clean up test screenshots (don't commit large PNGs)**

```bash
rm -rf tests/fixtures/metadata/Screenshots
```

Note: Screenshot fixtures are generated at test time, not committed to the repo.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test: verify screenshot validation and processing"
```

---

### Task 7: Final Review and Documentation

**Files:**
- Modify: `README.md` (add metadata workflow section)

- [ ] **Step 1: Add metadata workflow documentation to README.md**

Add a new section to the existing README documenting:
- What the metadata workflow does
- The folder convention callers should follow
- Required secrets/variables
- Example caller workflow
- Screenshot device folder names and requirements

Read the current README first to match existing style and structure.

- [ ] **Step 2: Do a full review of all new files**

Review checklist:
- `scripts/transform-metadata.rb` — verify JSONC_FIELD_MAP matches the spec exactly
- `scripts/transform_screenshots.rb` — verify DEVICE_DIMENSIONS matches the spec
- `fastlane/Fastfile` — verify the lane parameters match what the workflow passes
- `.github/workflows/ios-metadata.yml` — verify env var names match (APP_BUNDLE_ID, ASC_KEY_P8_PATH, etc.)
- Verify the workflow passes `skip_screenshots` as a string "true"/"false" to the fastlane lane (fastlane options are strings)

- [ ] **Step 3: Commit README changes**

```bash
git add README.md
git commit -m "docs: add metadata workflow documentation to README"
```
