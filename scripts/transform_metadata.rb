#!/usr/bin/env ruby

require "json"
require "fileutils"

JSONC_FIELD_MAP = {
  "name" => "name.txt",
  "subtitle" => "subtitle.txt",
  "keywords" => "keywords.txt",
  "promotionalText" => "promotional_text.txt",
  "marketingUrl" => "marketing_url.txt",
  "supportUrl" => "support_url.txt",
  "privacyUrl" => "privacy_url.txt"
}.freeze

# Apple's published character limits for App Store metadata fields.
# Source: https://developer.apple.com/help/app-store-connect/reference/app-information
FIELD_LIMITS = {
  "name"            => 30,
  "subtitle"        => 30,
  "keywords"        => 100,
  "promotionalText" => 170,
  "marketingUrl"    => 255,
  "supportUrl"      => 255,
  "privacyUrl"      => 255,
  "description"     => 4000,
  "whatsNew"        => 4000
}.freeze

def fail_with(errors)
  errors.each { |error| warn("ERROR: #{error}") }
  exit(1)
end

def parse_jsonc(path)
  return {} unless File.file?(path)

  raw = File.read(path)
  raw = raw.delete_prefix("\xEF\xBB\xBF") # Strip UTF-8 BOM (common with Windows editors)
  return {} if raw.strip.empty?

  lines = raw.lines.map do |line|
    # Remove full-line comments (optional leading whitespace + //)
    next "" if line.match?(/\A\s*\/\//)

    # Remove trailing comments only outside of quoted strings.
    # Walk the line tracking whether we are inside a string.
    in_string = false
    escape = false
    comment_start = nil
    line.each_char.with_index do |char, idx|
      if escape
        escape = false
        next
      end
      if in_string && char == '\\'
        escape = true
        next
      end
      if char == '"'
        in_string = !in_string
        next
      end
      next if in_string

      if char == "/" && idx + 1 < line.length && line[idx + 1] == "/"
        comment_start = idx
        break
      end
    end
    comment_start ? line[0...comment_start].rstrip + "\n" : line
  end
  stripped = lines.join

  # Strip trailing commas (common JSONC pattern, invalid in strict JSON)
  stripped = stripped.gsub(/,\s*([}\]])/, '\1')

  JSON.parse(stripped)
rescue JSON::ParserError => e
  fail_with(["Failed to parse JSONC file '#{path}': #{e.message}"])
end

def read_text_file(path)
  return nil unless File.file?(path)

  File.read(path)
end

def parse_cli_args(argv)
  args = {}
  i = 0
  while i < argv.length
    case argv[i]
    when "--input"
      args[:input] = argv[i + 1]
      i += 2
    when "--output"
      args[:output] = argv[i + 1]
      i += 2
    when "--locales"
      args[:locales] = argv[i + 1]
      i += 2
    when "--update-whatsnew-only"
      args[:update_whatsnew_only] = argv[i + 1] == "true"
      i += 2
    when "--update-promotional-text-only"
      args[:update_promotional_text_only] = argv[i + 1] == "true"
      i += 2
    when "--skip-screenshots"
      args[:skip_screenshots] = argv[i + 1] == "true"
      i += 2
    else
      fail_with(["Unknown argument: #{argv[i]}"])
    end
  end

  errors = []
  errors << "--input is required" unless args[:input]
  errors << "--output is required" unless args[:output]
  fail_with(errors) unless errors.empty?

  args[:update_whatsnew_only] = true if args[:update_whatsnew_only].nil?
  args[:update_promotional_text_only] = false if args[:update_promotional_text_only].nil?
  args[:skip_screenshots] = true if args[:skip_screenshots].nil?

  args
end

args = parse_cli_args(ARGV)

input_dir = File.expand_path(args[:input])
output_dir = File.expand_path(args[:output])
update_whatsnew_only = args[:update_whatsnew_only]
update_promotional_text_only = args[:update_promotional_text_only]
skip_screenshots = args[:skip_screenshots]
full_mode = !update_whatsnew_only && !update_promotional_text_only

text_dir = File.join(input_dir, "Text")
unless File.directory?(text_dir)
  fail_with(["Text directory not found at '#{text_dir}'. Expected metadata/Text/ in the input path."])
end

defaults_dir = File.join(text_dir, "defaults")

# Determine target locales: from --locales flag (ASC query) or from filesystem
if args[:locales] && !args[:locales].empty?
  locales = args[:locales].split(",").map(&:strip).reject(&:empty?).sort
  puts(":: Using #{locales.size} locale(s) from App Store Connect: #{locales.join(', ')}")
else
  # Fallback: discover from filesystem (locale folders under Text/)
  locales = Dir.children(text_dir)
    .select { |entry| File.directory?(File.join(text_dir, entry)) && entry != "defaults" }
    .sort

  if locales.empty?
    fail_with(["No locales available. Pass --locales or create locale directories under '#{text_dir}'."])
  end
  puts(":: Using #{locales.size} locale(s) from filesystem: #{locales.join(', ')}")
end

defaults_info = parse_jsonc(File.join(defaults_dir, "info.jsonc"))
defaults_description = read_text_file(File.join(defaults_dir, "description.txt"))
defaults_whats_new = read_text_file(File.join(defaults_dir, "whatsNew.txt"))

metadata_output = File.join(output_dir, "metadata")

if full_mode
  puts(":: Mode: full metadata (all fields from defaults + locale will be uploaded)")
else
  selected = []
  selected << "whatsNew" if update_whatsnew_only
  selected << "promotionalText" if update_promotional_text_only
  puts(":: Mode: partial — #{selected.join(' + ')} only (no other metadata fields will be uploaded)")
end

# Phase 1: Collect per-locale data (don't write yet — validate first)
locale_data = []

locales.each do |locale|
  locale_path = File.join(text_dir, locale)
  has_locale_dir = File.directory?(locale_path)

  # whatsNew → release_notes.txt (locale overrides defaults)
  locale_whats_new = has_locale_dir ? read_text_file(File.join(locale_path, "whatsNew.txt")) : nil
  whats_new = locale_whats_new || defaults_whats_new

  entry = {
    locale: locale,
    has_locale_dir: has_locale_dir,
    fields: {}  # jsonc_key => value (or "description" / "whatsNew" for long text)
  }

  if (full_mode || update_whatsnew_only) && whats_new && !whats_new.strip.empty?
    entry[:fields]["whatsNew"] = whats_new
  end

  if full_mode
    # Merge info: defaults + locale overrides (if locale dir exists)
    locale_info = has_locale_dir ? parse_jsonc(File.join(locale_path, "info.jsonc")) : {}
    merged_info = defaults_info.merge(locale_info)

    JSONC_FIELD_MAP.each_key do |json_key|
      value = merged_info[json_key]
      next if value.nil? || value.to_s.strip.empty?

      entry[:fields][json_key] = value
    end

    # description: locale overrides defaults
    locale_description = has_locale_dir ? read_text_file(File.join(locale_path, "description.txt")) : nil
    description = locale_description || defaults_description
    if description && !description.strip.empty?
      entry[:fields]["description"] = description
    end
  elsif update_promotional_text_only
    locale_info = has_locale_dir ? parse_jsonc(File.join(locale_path, "info.jsonc")) : {}
    merged_info = defaults_info.merge(locale_info)
    promo = merged_info["promotionalText"]
    if promo && !promo.to_s.strip.empty?
      entry[:fields]["promotionalText"] = promo
    end
  end

  locale_data << entry
end

# Phase 2: Validate all fields against Apple's published limits. Collect all
# errors, then fail with a full report if any exist (don't stop at first).
validation_errors = []

locale_data.each do |entry|
  entry[:fields].each do |field, value|
    limit = FIELD_LIMITS[field]
    next unless limit

    stripped = value.strip
    if stripped.length > limit
      validation_errors << {
        locale: entry[:locale],
        field: field,
        actual: stripped.length,
        limit: limit,
        preview: stripped[0, 40].gsub(/\s+/, " ") + (stripped.length > 40 ? "…" : "")
      }
    end
  end
end

unless validation_errors.empty?
  message = "Metadata validation failed:\n\n"
  validation_errors.each do |err|
    message += "  #{err[:locale]}/#{err[:field]}\n"
    message += "    Limit:   #{err[:limit]} characters\n"
    message += "    Actual:  #{err[:actual]} characters\n"
    message += "    Value:   #{err[:preview].inspect}\n\n"
  end
  message += "#{validation_errors.length} error(s) found. Fix metadata before uploading."
  abort(message)
end

# Phase 3: Write the output (validation passed)
locale_data.each do |entry|
  locale = entry[:locale]
  next if entry[:fields].empty?

  deliver_locale_dir = File.join(metadata_output, locale)
  FileUtils.mkdir_p(deliver_locale_dir)

  entry[:fields].each do |field, value|
    filename =
      case field
      when "description" then "description.txt"
      when "whatsNew"    then "release_notes.txt"
      else JSONC_FIELD_MAP[field]
      end
    File.write(File.join(deliver_locale_dir, filename), value)
  end

  source = entry[:has_locale_dir] ? "locale + defaults" : "defaults only"
  puts(":: #{locale}: #{entry[:fields].size} field(s) written (#{source})")
end

unless skip_screenshots
  screenshots_dir = File.join(input_dir, "Screenshots")
  screenshots_output = File.join(output_dir, "screenshots")
  unless File.directory?(screenshots_dir)
    fail_with([
      "skip_screenshots is false but no Screenshots/ directory found in '#{input_dir}'.",
      "Uploading with an empty screenshots folder would DELETE all existing screenshots on App Store Connect.",
      "Either set skip_screenshots=true, or add a Screenshots/ directory with screenshots to upload.",
    ])
  end
  require_relative "transform_screenshots"
  process_screenshots(screenshots_dir, screenshots_output)
end

puts(":: Transform complete — #{locales.length} locale(s) processed")
