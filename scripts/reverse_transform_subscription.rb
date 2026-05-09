#!/usr/bin/env ruby

# reverse_transform_subscription.rb
#
# Converts the dump produced by `fastlane fetch_subscription` into the
# translator-friendly source layout. Used to pull existing subscription
# groups + subscriptions from App Store Connect into the repo convention.
#
# Per-group + per-subscription: identifies fields shared across ALL locales
# and moves them into Text/defaults/info.jsonc; per-locale folders only
# keep fields that differ from the defaults.
#
# Usage:
#   ruby reverse_transform_subscription.rb \
#     --input  /tmp/sub-dump \
#     --output /path/to/repo/metadata/Subscriptions

require "json"
require "fileutils"

def fail_with(msg)
  warn("ERROR: #{msg}")
  exit(1)
end

def parse_args(argv)
  args = {}
  i = 0
  while i < argv.length
    case argv[i]
    when "--input"  then args[:input]  = argv[i + 1]; i += 2
    when "--output" then args[:output] = argv[i + 1]; i += 2
    else fail_with("Unknown argument: #{argv[i]}")
    end
  end
  fail_with("--input is required")  unless args[:input]
  fail_with("--output is required") unless args[:output]
  args
end

def write_jsonc(path, data)
  lines = ["{"]
  entries = data.to_a
  entries.each_with_index do |(key, value), idx|
    comma = idx < entries.size - 1 ? "," : ""
    if value.is_a?(String)
      escaped = value.gsub('\\', '\\\\').gsub('"', '\\"').gsub("\n", '\\n')
      lines << "  \"#{key}\": \"#{escaped}\"#{comma}"
    else
      lines << "  \"#{key}\": #{value.to_json}#{comma}"
    end
  end
  lines << "}"
  File.write(path, lines.join("\n") + "\n")
end

# Extract fields shared across all locales into defaults/, write
# per-locale overrides only when they differ. Mirrors IAP/metadata
# reverse-transform pattern.
def write_localizations(text_dir, per_locale, fields)
  defaults = {}
  fields.each do |key|
    values = per_locale.values.map { |info| info[key] }.compact
    if values.size == per_locale.size && values.uniq.size == 1
      defaults[key] = values.first
    end
  end

  if defaults.any?
    defaults_dir = File.join(text_dir, "defaults")
    FileUtils.mkdir_p(defaults_dir)
    write_jsonc(File.join(defaults_dir, "info.jsonc"), defaults)
  end

  written = 0
  per_locale.each do |locale, info|
    overrides = {}
    fields.each do |key|
      value = info[key]
      next if value.nil?
      overrides[key] = value unless defaults[key] == value
    end
    next if overrides.empty?

    locale_dir = File.join(text_dir, locale)
    FileUtils.mkdir_p(locale_dir)
    write_jsonc(File.join(locale_dir, "info.jsonc"), overrides)
    written += 1
  end
  { defaults_count: defaults.size, locale_overrides: written }
end

args = parse_args(ARGV)
input_dir  = File.expand_path(args[:input])
output_dir = File.expand_path(args[:output])

unless File.directory?(input_dir)
  fail_with("Input directory not found: #{input_dir}")
end

group_dirs = Dir.children(input_dir)
  .select { |e| File.directory?(File.join(input_dir, e)) }
  .reject { |e| e.start_with?(".") }
  .sort

if group_dirs.empty?
  # App has no subscription groups configured — clean no-op, not a failure.
  puts(":: No subscription group directories in #{input_dir} — app has no subscriptions on Apple. Nothing to sync.")
  exit(0)
end

puts(":: Found #{group_dirs.size} group(s): #{group_dirs.join(', ')}")
FileUtils.mkdir_p(output_dir)

group_dirs.each do |group_folder|
  src_group  = File.join(input_dir, group_folder)
  dest_group = File.join(output_dir, group_folder)
  FileUtils.mkdir_p(dest_group)

  group_meta_src = File.join(src_group, "group.json")
  if File.file?(group_meta_src)
    write_jsonc(File.join(dest_group, "group.jsonc"), JSON.parse(File.read(group_meta_src)))
  else
    warn(":: #{group_folder}: no group.json in dump (skipping group.jsonc)")
  end

  src_text = File.join(src_group, "Text")
  if File.directory?(src_text)
    locales = Dir.children(src_text)
      .select { |e| File.directory?(File.join(src_text, e)) }
      .reject { |e| e.start_with?(".") }
      .sort

    per_locale = {}
    locales.each do |locale|
      info_path = File.join(src_text, locale, "info.json")
      per_locale[locale] = File.file?(info_path) ? JSON.parse(File.read(info_path)) : {}
    end

    if per_locale.any?
      stats = write_localizations(File.join(dest_group, "Text"), per_locale, %w[name custom_app_name])
      puts(":: group '#{group_folder}': #{stats[:defaults_count]} defaults, #{stats[:locale_overrides]} per-locale override(s)")
    end
  end

  sub_dirs = Dir.children(src_group)
    .select { |e| File.directory?(File.join(src_group, e)) && e != "Text" && !e.start_with?(".") }
    .sort

  sub_dirs.each do |product_id|
    src_sub  = File.join(src_group, product_id)
    dest_sub = File.join(dest_group, product_id)
    FileUtils.mkdir_p(dest_sub)

    sub_meta_src = File.join(src_sub, "subscription.json")
    if File.file?(sub_meta_src)
      write_jsonc(File.join(dest_sub, "subscription.jsonc"), JSON.parse(File.read(sub_meta_src)))
    else
      warn(":: #{group_folder}/#{product_id}: no subscription.json in dump")
    end

    src_screenshot = File.join(src_sub, "review_screenshot.png")
    if File.file?(src_screenshot)
      FileUtils.cp(src_screenshot, File.join(dest_sub, "review_screenshot.png"))
    end

    sub_text = File.join(src_sub, "Text")
    next unless File.directory?(sub_text)

    locales = Dir.children(sub_text)
      .select { |e| File.directory?(File.join(sub_text, e)) }
      .reject { |e| e.start_with?(".") }
      .sort

    per_locale = {}
    locales.each do |locale|
      info_path = File.join(sub_text, locale, "info.json")
      per_locale[locale] = File.file?(info_path) ? JSON.parse(File.read(info_path)) : {}
    end

    next if per_locale.empty?

    stats = write_localizations(File.join(dest_sub, "Text"), per_locale, %w[name description])
    puts(":: #{group_folder}/#{product_id}: #{stats[:defaults_count]} defaults, #{stats[:locale_overrides]} per-locale override(s)")
  end
end

puts(":: Reverse transform complete — #{group_dirs.size} group(s) processed")
