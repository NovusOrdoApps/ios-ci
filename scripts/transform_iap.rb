#!/usr/bin/env ruby

# transform_iap.rb
#
# Reads metadata/InAppPurchases/ source folders and writes a normalized JSON
# document that the update_iap fastlane lane consumes. Validates everything
# before writing — collects all errors and fails with a single report.
#
# Usage:
#   ruby transform_iap.rb \
#     --input  /path/to/repo/metadata/InAppPurchases \
#     --output /tmp/iap-normalized.json
#
# Source layout (per product):
#   <product_id>/
#     product.jsonc              # type, reference_name, price_tier, family_shareable
#     review_screenshot.png      # optional (required only for first review submission)
#     Text/
#       defaults/info.jsonc      # optional shared { name, description }
#       <locale>/info.jsonc      # per-locale { name, description } overrides

require "json"
require "fileutils"

# Apple's published character limits for IAP fields.
# Source: https://developer.apple.com/help/app-store-connect/reference/in-app-purchase-information
FIELD_LIMITS = {
  "name"           => 30,
  "description"    => 45,
  "reference_name" => 64,
  "product_id"     => 255,
}.freeze

VALID_TYPES = %w[consumable non_consumable].freeze

def fail_with(errors)
  errors.each { |e| warn("ERROR: #{e}") }
  exit(1)
end

# JSONC parser: strips // comments outside strings and trailing commas.
# Same logic as transform_metadata.rb — kept inline so each script is
# independent and a change here won't ripple.
def parse_jsonc(path)
  return {} unless File.file?(path)

  raw = File.read(path)
  raw = raw.delete_prefix("\xEF\xBB\xBF")
  return {} if raw.strip.empty?

  lines = raw.lines.map do |line|
    next "" if line.match?(/\A\s*\/\//)

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
  stripped = lines.join.gsub(/,\s*([}\]])/, '\1')

  JSON.parse(stripped)
rescue JSON::ParserError => e
  fail_with(["Failed to parse JSONC file '#{path}': #{e.message}"])
end

def parse_args(argv)
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
    else
      fail_with(["Unknown argument: #{argv[i]}"])
    end
  end

  errors = []
  errors << "--input is required" unless args[:input]
  errors << "--output is required" unless args[:output]
  fail_with(errors) unless errors.empty?

  args
end

args = parse_args(ARGV)
input_dir   = File.expand_path(args[:input])
output_path = File.expand_path(args[:output])

unless File.directory?(input_dir)
  fail_with(["Input directory not found: #{input_dir}"])
end

product_dirs = Dir.children(input_dir)
  .select { |entry| File.directory?(File.join(input_dir, entry)) }
  .reject { |entry| entry.start_with?(".") }
  .sort

if product_dirs.empty?
  fail_with(["No product folders found in #{input_dir}. Each in-app purchase needs its own folder named after its product_id."])
end

errors = []
products = []

product_dirs.each do |product_id|
  product_path = File.join(input_dir, product_id)
  meta_path = File.join(product_path, "product.jsonc")
  meta = parse_jsonc(meta_path)

  if meta.empty?
    errors << "#{product_id}: missing or empty product.jsonc"
    next
  end

  type = meta["type"].to_s
  unless VALID_TYPES.include?(type)
    errors << "#{product_id}: invalid type '#{type}' (allowed: #{VALID_TYPES.join(', ')})"
  end

  reference_name = meta["reference_name"].to_s.strip
  if reference_name.empty?
    errors << "#{product_id}: reference_name is required in product.jsonc"
  elsif reference_name.length > FIELD_LIMITS["reference_name"]
    errors << "#{product_id}: reference_name exceeds #{FIELD_LIMITS['reference_name']} chars (got #{reference_name.length})"
  end

  if product_id.length > FIELD_LIMITS["product_id"]
    errors << "#{product_id}: product_id exceeds #{FIELD_LIMITS['product_id']} chars"
  end

  price_tier = meta["price_tier"]
  unless price_tier.is_a?(Integer) && price_tier >= 0 && price_tier <= 87
    errors << "#{product_id}: price_tier must be an integer 0-87 (got #{price_tier.inspect})"
  end

  family_shareable = meta.fetch("family_shareable", false)
  unless [true, false].include?(family_shareable)
    errors << "#{product_id}: family_shareable must be true or false (got #{family_shareable.inspect})"
  end

  if family_shareable && type == "consumable"
    errors << "#{product_id}: family_shareable is only valid for non_consumable products"
  end

  text_dir = File.join(product_path, "Text")
  unless File.directory?(text_dir)
    errors << "#{product_id}: missing Text/ folder with at least one locale"
    next
  end

  defaults_info = parse_jsonc(File.join(text_dir, "defaults", "info.jsonc"))
  locale_dirs = Dir.children(text_dir)
    .select { |entry| File.directory?(File.join(text_dir, entry)) && entry != "defaults" && !entry.start_with?(".") }
    .sort

  if locale_dirs.empty?
    errors << "#{product_id}: no locale folders under Text/"
    next
  end

  localizations = {}
  locale_dirs.each do |locale|
    locale_info = parse_jsonc(File.join(text_dir, locale, "info.jsonc"))
    merged = defaults_info.merge(locale_info)

    name = merged["name"].to_s.strip
    description = merged["description"].to_s.strip

    if name.empty?
      errors << "#{product_id}/#{locale}: name is required"
    elsif name.length > FIELD_LIMITS["name"]
      errors << "#{product_id}/#{locale}: name exceeds #{FIELD_LIMITS['name']} chars (got #{name.length})"
    end

    if description.empty?
      errors << "#{product_id}/#{locale}: description is required"
    elsif description.length > FIELD_LIMITS["description"]
      errors << "#{product_id}/#{locale}: description exceeds #{FIELD_LIMITS['description']} chars (got #{description.length})"
    end

    localizations[locale] = { "name" => name, "description" => description }
  end

  screenshot_path = File.join(product_path, "review_screenshot.png")
  screenshot_path = nil unless File.file?(screenshot_path)

  products << {
    "product_id"        => product_id,
    "type"              => type,
    "reference_name"    => reference_name,
    "price_tier"        => price_tier,
    "family_shareable"  => family_shareable,
    "review_screenshot" => screenshot_path,
    "localizations"     => localizations,
  }
end

unless errors.empty?
  message = "IAP source validation failed:\n\n"
  errors.each { |e| message += "  #{e}\n" }
  message += "\n#{errors.length} error(s) found. Fix the source before uploading."
  abort(message)
end

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate({ "products" => products }))

puts(":: Validated #{products.length} product(s)")
products.each do |p|
  shot = p["review_screenshot"] ? "screenshot=yes" : "screenshot=no"
  puts(":: #{p['product_id']}  type=#{p['type']}  tier=#{p['price_tier']}  locales=#{p['localizations'].keys.join(',')}  #{shot}")
end
puts(":: Wrote normalized IAP JSON to #{output_path}")
