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
    when "--use-default-whats-new"
      args[:use_default_whats_new] = argv[i + 1] == "true"
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

  args[:use_default_whats_new] = true if args[:use_default_whats_new].nil?
  args[:skip_screenshots] = true if args[:skip_screenshots].nil?

  args
end

args = parse_cli_args(ARGV)

input_dir = File.expand_path(args[:input])
output_dir = File.expand_path(args[:output])
use_default_whats_new = args[:use_default_whats_new]
skip_screenshots = args[:skip_screenshots]

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

if use_default_whats_new && defaults_whats_new.nil?
  fail_with(["--use-default-whats-new is true but defaults/whatsNew.txt does not exist at '#{defaults_dir}'."])
end

metadata_output = File.join(output_dir, "metadata")

locales.each do |locale|
  locale_path = File.join(text_dir, locale)
  has_locale_dir = File.directory?(locale_path)
  deliver_locale_dir = File.join(metadata_output, locale)

  # Merge info: defaults + locale overrides (if locale dir exists)
  locale_info = has_locale_dir ? parse_jsonc(File.join(locale_path, "info.jsonc")) : {}
  merged_info = defaults_info.merge(locale_info)

  # Only write fields that have non-empty values
  fields_written = 0
  JSONC_FIELD_MAP.each do |json_key, deliver_filename|
    value = merged_info[json_key]
    next if value.nil? || value.to_s.strip.empty?

    FileUtils.mkdir_p(deliver_locale_dir)
    File.write(File.join(deliver_locale_dir, deliver_filename), value)
    fields_written += 1
  end

  # description: locale overrides defaults
  locale_description = has_locale_dir ? read_text_file(File.join(locale_path, "description.txt")) : nil
  description = locale_description || defaults_description
  if description && !description.strip.empty?
    FileUtils.mkdir_p(deliver_locale_dir)
    File.write(File.join(deliver_locale_dir, "description.txt"), description)
    fields_written += 1
  end

  # whatsNew → release_notes.txt
  if use_default_whats_new
    whats_new = defaults_whats_new
  else
    locale_whats_new = has_locale_dir ? read_text_file(File.join(locale_path, "whatsNew.txt")) : nil
    whats_new = locale_whats_new || defaults_whats_new
  end

  if whats_new && !whats_new.strip.empty?
    FileUtils.mkdir_p(deliver_locale_dir)
    File.write(File.join(deliver_locale_dir, "release_notes.txt"), whats_new)
    fields_written += 1
  end

  source = has_locale_dir ? "locale + defaults" : "defaults only"
  if fields_written > 0
    puts(":: #{locale}: #{fields_written} field(s) written (#{source})")
  else
    puts(":: #{locale}: skipped (no data)")
  end
end

unless skip_screenshots
  screenshots_dir = File.join(input_dir, "Screenshots")
  screenshots_output = File.join(output_dir, "screenshots")
  if File.directory?(screenshots_dir)
    require_relative "transform_screenshots"
    process_screenshots(screenshots_dir, screenshots_output)
  else
    # Create empty dir so deliver gets a valid path (it handles empty dirs gracefully)
    FileUtils.mkdir_p(screenshots_output)
    puts(":: No Screenshots/ directory found, created empty screenshots output.")
  end
end

puts(":: Transform complete — #{locales.length} locale(s) processed")
