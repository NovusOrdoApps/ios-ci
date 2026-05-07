#!/usr/bin/env ruby

# transform_subscription.rb
#
# Reads metadata/Subscriptions/ source folders and writes a normalized JSON
# document that the update_subscription fastlane lane consumes. Validates
# everything before writing — collects all errors and fails with a single report.
#
# Usage:
#   ruby transform_subscription.rb \
#     --input  /path/to/repo/metadata/Subscriptions \
#     --output /tmp/sub-normalized.json
#
# Source layout (per group):
#   <group_folder>/
#     group.jsonc                   # { reference_name }
#     Text/defaults/info.jsonc      # shared { name, custom_app_name }
#     Text/<locale>/info.jsonc      # per-locale overrides
#     <product_id>/
#       subscription.jsonc          # period, group_level, customer_price,
#                                   # territories, family_shareable, ...
#       review_screenshot.png       # optional but rec'd (640×920)
#       Text/defaults/info.jsonc    # shared { name, description }
#       Text/<locale>/info.jsonc    # per-locale overrides

require "json"
require "fileutils"

# Apple's published character limits.
# Source: developer.apple.com/help/app-store-connect/reference/subscription-information
FIELD_LIMITS = {
  "name"            => 30,    # subscription localization name (user-facing)
  "description"     => 45,    # subscription localization description
  "group_name"      => 30,    # subscription group localization name
  "custom_app_name" => 30,    # group localization customAppName (override)
  "reference_name"  => 64,
  "product_id"      => 255,
  "review_note"     => 500,
}.freeze

VALID_PERIODS = %w[ONE_WEEK ONE_MONTH TWO_MONTHS THREE_MONTHS SIX_MONTHS ONE_YEAR].freeze

def fail_with(errors)
  errors.each { |e| warn("ERROR: #{e}") }
  exit(1)
end

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
    when "--input"  then args[:input]  = argv[i + 1]; i += 2
    when "--output" then args[:output] = argv[i + 1]; i += 2
    else fail_with(["Unknown argument: #{argv[i]}"])
    end
  end

  errors = []
  errors << "--input is required" unless args[:input]
  errors << "--output is required" unless args[:output]
  fail_with(errors) unless errors.empty?
  args
end

def collect_localizations(text_dir, fields, errors:, label:)
  return {} unless File.directory?(text_dir)

  defaults_info = parse_jsonc(File.join(text_dir, "defaults", "info.jsonc"))
  locale_dirs = Dir.children(text_dir)
    .select { |entry| File.directory?(File.join(text_dir, entry)) && entry != "defaults" && !entry.start_with?(".") }
    .sort

  out = {}
  locale_dirs.each do |locale|
    locale_info = parse_jsonc(File.join(text_dir, locale, "info.jsonc"))
    merged = defaults_info.merge(locale_info)

    locale_data = {}
    fields.each do |key, required|
      val = merged[key].to_s
      val = val.strip
      limit_key = key == "name" && label.include?("group") ? "group_name" : key
      if val.empty?
        errors << "#{label}/#{locale}: #{key} is required" if required
      elsif FIELD_LIMITS[limit_key] && val.length > FIELD_LIMITS[limit_key]
        errors << "#{label}/#{locale}: #{key} exceeds #{FIELD_LIMITS[limit_key]} chars (got #{val.length})"
      end
      locale_data[key] = val unless val.empty?
    end
    out[locale] = locale_data
  end
  out
end

args = parse_args(ARGV)
input_dir   = File.expand_path(args[:input])
output_path = File.expand_path(args[:output])

unless File.directory?(input_dir)
  fail_with(["Input directory not found: #{input_dir}"])
end

group_dirs = Dir.children(input_dir)
  .select { |e| File.directory?(File.join(input_dir, e)) }
  .reject { |e| e.start_with?(".") }
  .sort

if group_dirs.empty?
  fail_with(["No subscription groups in #{input_dir}. Each subscription group needs its own folder."])
end

errors = []
groups = []

group_dirs.each do |group_folder|
  group_path = File.join(input_dir, group_folder)
  meta_path  = File.join(group_path, "group.jsonc")
  meta = parse_jsonc(meta_path)

  if meta.empty?
    errors << "#{group_folder}: missing or empty group.jsonc"
    next
  end

  reference_name = meta["reference_name"].to_s.strip
  if reference_name.empty?
    errors << "#{group_folder}: reference_name is required in group.jsonc"
  elsif reference_name.length > FIELD_LIMITS["reference_name"]
    errors << "#{group_folder}: group reference_name exceeds #{FIELD_LIMITS['reference_name']} chars"
  end

  group_text_dir = File.join(group_path, "Text")
  group_localizations = collect_localizations(
    group_text_dir,
    { "name" => true, "custom_app_name" => false },
    errors: errors, label: "group '#{reference_name}'"
  )

  if group_localizations.empty?
    errors << "#{group_folder}: no locale folders under Text/"
  end

  sub_dirs = Dir.children(group_path)
    .select { |e| File.directory?(File.join(group_path, e)) && e != "Text" && !e.start_with?(".") }
    .sort

  if sub_dirs.empty?
    errors << "#{group_folder}: no subscription subfolders (each named after its product_id)"
    next
  end

  subscriptions = []
  sub_dirs.each do |product_id|
    sub_path = File.join(group_path, product_id)
    sub_meta = parse_jsonc(File.join(sub_path, "subscription.jsonc"))

    if sub_meta.empty?
      errors << "#{group_folder}/#{product_id}: missing or empty subscription.jsonc"
      next
    end

    sub_ref = sub_meta["reference_name"].to_s.strip
    if sub_ref.empty?
      errors << "#{group_folder}/#{product_id}: reference_name is required"
    elsif sub_ref.length > FIELD_LIMITS["reference_name"]
      errors << "#{group_folder}/#{product_id}: reference_name exceeds #{FIELD_LIMITS['reference_name']} chars"
    end

    if product_id.length > FIELD_LIMITS["product_id"]
      errors << "#{group_folder}/#{product_id}: product_id exceeds #{FIELD_LIMITS['product_id']} chars"
    end

    period = sub_meta["subscription_period"].to_s
    unless VALID_PERIODS.include?(period)
      errors << "#{group_folder}/#{product_id}: subscription_period must be one of #{VALID_PERIODS} (got #{period.inspect})"
    end

    group_level = sub_meta["group_level"]
    unless group_level.is_a?(Integer) && group_level >= 1
      errors << "#{group_folder}/#{product_id}: group_level must be a positive integer (got #{group_level.inspect})"
    end

    family_sharable = sub_meta.fetch("family_shareable", true)
    unless [true, false].include?(family_sharable)
      errors << "#{group_folder}/#{product_id}: family_shareable must be true or false"
    end

    customer_price = sub_meta["customer_price"]
    unless customer_price.is_a?(String) && customer_price.match?(/\A\d+(\.\d{1,2})?\z/)
      errors << "#{group_folder}/#{product_id}: customer_price must be a USD-price string (e.g. \"4.99\"), got #{customer_price.inspect}"
    end

    territories = sub_meta["territories"]
    if territories.is_a?(String)
      if territories != "ALL"
        errors << "#{group_folder}/#{product_id}: territories string must be \"ALL\" (or use a non-empty array)"
      end
    elsif territories.nil? || !territories.is_a?(Array) || territories.empty?
      errors << "#{group_folder}/#{product_id}: territories must be \"ALL\" or a non-empty array of ISO 3166-1 alpha-3 codes"
    elsif territories.is_a?(Array) && territories.any? { |t| !t.is_a?(String) || !t.match?(/\A[A-Z]{3}\z/) }
      errors << "#{group_folder}/#{product_id}: every territory must be an ISO 3166-1 alpha-3 code; got #{territories.inspect}"
    end

    available_in_new_territories = sub_meta.fetch("available_in_new_territories", true)
    unless [true, false].include?(available_in_new_territories)
      errors << "#{group_folder}/#{product_id}: available_in_new_territories must be true or false"
    end

    review_note = sub_meta["review_note"].to_s
    if !review_note.empty? && review_note.length > FIELD_LIMITS["review_note"]
      errors << "#{group_folder}/#{product_id}: review_note exceeds #{FIELD_LIMITS['review_note']} chars"
    end

    sub_localizations = collect_localizations(
      File.join(sub_path, "Text"),
      { "name" => true, "description" => true },
      errors: errors, label: "#{group_folder}/#{product_id}"
    )

    if sub_localizations.empty?
      errors << "#{group_folder}/#{product_id}: no locale folders under Text/"
    end

    screenshot_path = File.join(sub_path, "review_screenshot.png")
    screenshot_path = nil unless File.file?(screenshot_path)

    subscriptions << {
      "product_id"                   => product_id,
      "reference_name"               => sub_ref,
      "subscription_period"          => period,
      "group_level"                  => group_level,
      "family_shareable"             => family_sharable,
      "review_note"                  => review_note.empty? ? nil : review_note,
      "customer_price"               => customer_price,
      "territories"                  => territories,
      "available_in_new_territories" => available_in_new_territories,
      "review_screenshot"            => screenshot_path,
      "localizations"                => sub_localizations,
    }
  end

  groups << {
    "reference_name" => reference_name,
    "localizations"  => group_localizations,
    "subscriptions"  => subscriptions,
  }
end

unless errors.empty?
  message = "Subscription source validation failed:\n\n"
  errors.each { |e| message += "  #{e}\n" }
  message += "\n#{errors.length} error(s) found. Fix the source before uploading."
  abort(message)
end

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate({ "groups" => groups }))

puts(":: Validated #{groups.length} group(s)")
groups.each do |g|
  puts(":: group '#{g['reference_name']}'  locales=#{g['localizations'].keys.join(',')}  subscriptions=#{g['subscriptions'].size}")
  g["subscriptions"].each do |s|
    terr = s["territories"]
    terr_summary = terr.is_a?(Array) ? terr.size.to_s : terr.to_s
    shot = s["review_screenshot"] ? "screenshot=yes" : "screenshot=no"
    puts(":   - #{s['product_id']}  period=#{s['subscription_period']}  level=#{s['group_level']}  price=$#{s['customer_price']}  territories=#{terr_summary}  locales=#{s['localizations'].keys.join(',')}  #{shot}")
  end
end
puts(":: Wrote normalized subscription JSON to #{output_path}")
