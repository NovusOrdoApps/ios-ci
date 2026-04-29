#!/usr/bin/env ruby

# reverse_transform_iap.rb
#
# Converts the dump produced by `fastlane fetch_iap` into the custom
# translator-friendly source layout. Used to pull existing IAPs from App Store
# Connect into the repo convention.
#
# Per-product: identifies fields shared across ALL locales (name + description)
# and moves them into Text/defaults/info.jsonc; per-locale folders only keep
# fields that differ from the defaults.
#
# Usage:
#   ruby reverse_transform_iap.rb \
#     --input  /tmp/iap-dump \
#     --output /path/to/repo/metadata/InAppPurchases

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

args = parse_args(ARGV)
input_dir  = File.expand_path(args[:input])
output_dir = File.expand_path(args[:output])

unless File.directory?(input_dir)
  fail_with("Input directory not found: #{input_dir}")
end

product_dirs = Dir.children(input_dir)
  .select { |entry| File.directory?(File.join(input_dir, entry)) }
  .reject { |entry| entry.start_with?(".") }
  .sort

if product_dirs.empty?
  fail_with("No product directories found in #{input_dir}")
end

puts(":: Found #{product_dirs.size} product(s): #{product_dirs.join(', ')}")

FileUtils.mkdir_p(output_dir)

product_dirs.each do |product_id|
  src_product = File.join(input_dir, product_id)
  dest_product = File.join(output_dir, product_id)
  FileUtils.mkdir_p(dest_product)

  meta_src = File.join(src_product, "product.json")
  if File.file?(meta_src)
    meta = JSON.parse(File.read(meta_src))
    write_jsonc(File.join(dest_product, "product.jsonc"), meta)
  else
    warn(":: #{product_id}: no product.json in dump (skipping product.jsonc)")
  end

  src_screenshot = File.join(src_product, "review_screenshot.png")
  if File.file?(src_screenshot)
    FileUtils.cp(src_screenshot, File.join(dest_product, "review_screenshot.png"))
  end

  src_text = File.join(src_product, "Text")
  unless File.directory?(src_text)
    puts(":: #{product_id}: no localizations in dump")
    next
  end

  locales = Dir.children(src_text)
    .select { |entry| File.directory?(File.join(src_text, entry)) }
    .reject { |entry| entry.start_with?(".") }
    .sort

  if locales.empty?
    puts(":: #{product_id}: no locale folders in dump")
    next
  end

  per_locale = {}
  locales.each do |locale|
    info_path = File.join(src_text, locale, "info.json")
    if File.file?(info_path)
      per_locale[locale] = JSON.parse(File.read(info_path))
    else
      warn(":: WARNING: #{product_id}/#{locale}: missing info.json in dump — locale will be omitted from the source layout")
      per_locale[locale] = {}
    end
  end

  defaults = {}
  %w[name description].each do |key|
    values = per_locale.values.map { |info| info[key] }.compact
    if values.size == locales.size && values.uniq.size == 1
      defaults[key] = values.first
    end
  end

  dest_text = File.join(dest_product, "Text")
  FileUtils.mkdir_p(dest_text)

  if defaults.any?
    defaults_dir = File.join(dest_text, "defaults")
    FileUtils.mkdir_p(defaults_dir)
    write_jsonc(File.join(defaults_dir, "info.jsonc"), defaults)
    puts(":: #{product_id}: defaults written (#{defaults.size} field(s) shared across all locales)")
  end

  written_locales = 0
  per_locale.each do |locale, info|
    overrides = {}
    %w[name description].each do |key|
      value = info[key]
      next if value.nil?
      overrides[key] = value unless defaults[key] == value
    end

    next if overrides.empty?

    locale_dir = File.join(dest_text, locale)
    FileUtils.mkdir_p(locale_dir)
    write_jsonc(File.join(locale_dir, "info.jsonc"), overrides)
    written_locales += 1
  end

  puts(":: #{product_id}: #{written_locales} locale-specific override(s) written")
end

puts(":: Reverse transform complete — #{product_dirs.size} product(s) processed")
