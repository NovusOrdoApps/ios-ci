#!/usr/bin/env ruby

# reverse_transform_metadata.rb
#
# Converts deliver's metadata format into the custom translator-friendly format.
# Used to pull existing metadata from App Store Connect into the repo convention.
#
# Usage:
#   ruby reverse_transform_metadata.rb \
#     --input /tmp/asc-metadata/metadata \
#     --output /path/to/repo/metadata/Text

require "json"
require "fileutils"

# Reverse mapping: deliver filename → info.jsonc key
DELIVER_TO_JSONC = {
  "name.txt"             => "name",
  "subtitle.txt"         => "subtitle",
  "keywords.txt"         => "keywords",
  "promotional_text.txt" => "promotionalText",
  "marketing_url.txt"    => "marketingUrl",
  "support_url.txt"      => "supportUrl",
  "privacy_url.txt"      => "privacyUrl",
}.freeze

def fail_with(msg)
  warn("ERROR: #{msg}")
  exit(1)
end

def read_trimmed(path)
  return nil unless File.file?(path)

  content = File.read(path)
  content.strip.empty? ? nil : content
end

def write_jsonc(path, data)
  # Write as pretty JSONC with helpful comments for known fields
  lines = ["{"]
  entries = data.to_a
  entries.each_with_index do |(key, value), idx|
    comma = idx < entries.size - 1 ? "," : ""
    escaped = value.gsub('\\', '\\\\').gsub('"', '\\"')
    lines << "  \"#{key}\": \"#{escaped}\"#{comma}"
  end
  lines << "}"
  File.write(path, lines.join("\n") + "\n")
end

# ── CLI ──────────────────────────────────────────

args = {}
i = 0
while i < ARGV.length
  case ARGV[i]
  when "--input"
    args[:input] = ARGV[i + 1]
    i += 2
  when "--output"
    args[:output] = ARGV[i + 1]
    i += 2
  else
    fail_with("Unknown argument: #{ARGV[i]}")
  end
end

input_dir  = args[:input]  || fail_with("--input is required")
output_dir = args[:output] || fail_with("--output is required")

unless File.directory?(input_dir)
  fail_with("Input directory not found: #{input_dir}")
end

# ── Read all locales from deliver format ─────────

locales = Dir.children(input_dir)
  .select { |d| File.directory?(File.join(input_dir, d)) }
  .reject { |d| d.start_with?(".") }
  .sort

if locales.empty?
  fail_with("No locale directories found in #{input_dir}")
end

puts(":: Found #{locales.size} locale(s): #{locales.join(', ')}")

# Collect all data per locale
all_locale_data = {}

locales.each do |locale|
  locale_dir = File.join(input_dir, locale)

  info = {}
  DELIVER_TO_JSONC.each do |deliver_file, jsonc_key|
    value = read_trimmed(File.join(locale_dir, deliver_file))
    info[jsonc_key] = value if value
  end

  description = read_trimmed(File.join(locale_dir, "description.txt"))
  whats_new   = read_trimmed(File.join(locale_dir, "release_notes.txt"))

  all_locale_data[locale] = {
    info: info,
    description: description,
    whats_new: whats_new,
  }
end

# ── Extract defaults (values identical across ALL locales) ──

# For info.jsonc fields: find keys where every locale has the same value
all_info_keys = all_locale_data.values.flat_map { |d| d[:info].keys }.uniq

defaults_info = {}
all_info_keys.each do |key|
  values = all_locale_data.values.map { |d| d[:info][key] }.compact
  # Only move to defaults if ALL locales have this field with the same value
  if values.size == locales.size && values.uniq.size == 1
    defaults_info[key] = values.first
  end
end

# For description: check if all locales have the same description
all_descriptions = all_locale_data.values.map { |d| d[:description] }.compact
defaults_description = if all_descriptions.size == locales.size && all_descriptions.uniq.size == 1
                         all_descriptions.first
                       end

# For whatsNew: check if all locales have the same release notes
all_whats_new = all_locale_data.values.map { |d| d[:whats_new] }.compact
defaults_whats_new = if all_whats_new.size == locales.size && all_whats_new.uniq.size == 1
                       all_whats_new.first
                     end

# ── Write defaults ──────────────────────────────

defaults_dir = File.join(output_dir, "defaults")
FileUtils.mkdir_p(defaults_dir)

defaults_written = 0

if defaults_info.any?
  write_jsonc(File.join(defaults_dir, "info.jsonc"), defaults_info)
  puts(":: defaults/info.jsonc: #{defaults_info.size} field(s) (shared across all locales)")
  defaults_written += 1
end

if defaults_description
  File.write(File.join(defaults_dir, "description.txt"), defaults_description + "\n")
  puts(":: defaults/description.txt: written (identical across all locales)")
  defaults_written += 1
end

if defaults_whats_new
  File.write(File.join(defaults_dir, "whatsNew.txt"), defaults_whats_new + "\n")
  puts(":: defaults/whatsNew.txt: written (identical across all locales)")
  defaults_written += 1
end

puts(":: No shared defaults found") if defaults_written == 0

# ── Write per-locale (only fields that differ from defaults) ──

locales.each do |locale|
  data = all_locale_data[locale]
  locale_dir = File.join(output_dir, locale)

  # Info: only keep fields that are NOT in defaults (or have different values)
  locale_info = {}
  data[:info].each do |key, value|
    locale_info[key] = value unless defaults_info[key] == value
  end

  # Description: skip if identical to defaults
  locale_description = data[:description]
  locale_description = nil if locale_description == defaults_description

  # WhatsNew: skip if identical to defaults
  locale_whats_new = data[:whats_new]
  locale_whats_new = nil if locale_whats_new == defaults_whats_new

  has_content = locale_info.any? || locale_description || locale_whats_new

  unless has_content
    puts(":: #{locale}: skipped (all values in defaults)")
    next
  end

  FileUtils.mkdir_p(locale_dir)
  parts = []

  if locale_info.any?
    write_jsonc(File.join(locale_dir, "info.jsonc"), locale_info)
    parts << "#{locale_info.size} info field(s)"
  end

  if locale_description
    File.write(File.join(locale_dir, "description.txt"), locale_description + "\n")
    parts << "description"
  end

  if locale_whats_new
    File.write(File.join(locale_dir, "whatsNew.txt"), locale_whats_new + "\n")
    parts << "whatsNew"
  end

  puts(":: #{locale}: #{parts.join(', ')}")
end

puts(":: Reverse transform complete — #{locales.size} locale(s) processed")
