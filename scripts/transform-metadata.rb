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

DEVICE_DIMENSIONS = {
  "APP_IPHONE_67" => [1290, 2796],
  "APP_IPHONE_65" => [1284, 2778],
  "APP_IPHONE_55" => [1242, 2208],
  "APP_IPAD_129" => [2048, 2732],
  "APP_IPAD_110" => [1668, 2388]
}.freeze

DIMENSION_TOLERANCE = 20

def fail_with(errors)
  errors.each { |error| warn("ERROR: #{error}") }
  exit(1)
end

def parse_jsonc(path)
  return {} unless File.file?(path)

  raw = File.read(path)
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
      if char == '\\'
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

locale_dirs = Dir.children(text_dir)
  .select { |entry| File.directory?(File.join(text_dir, entry)) && entry != "defaults" }
  .sort

if locale_dirs.empty?
  fail_with(["No locale directories found under '#{text_dir}'. Expected at least one locale (e.g., en, ru)."])
end

defaults_info = parse_jsonc(File.join(defaults_dir, "info.jsonc"))
defaults_description = read_text_file(File.join(defaults_dir, "description.txt"))
defaults_whats_new = read_text_file(File.join(defaults_dir, "whatsNew.txt"))

if use_default_whats_new && defaults_whats_new.nil?
  fail_with(["--use-default-whats-new is true but defaults/whatsNew.txt does not exist at '#{defaults_dir}'."])
end

metadata_output = File.join(output_dir, "metadata")

locale_dirs.each do |locale|
  locale_path = File.join(text_dir, locale)
  deliver_locale_dir = File.join(metadata_output, locale)
  FileUtils.mkdir_p(deliver_locale_dir)

  locale_info = parse_jsonc(File.join(locale_path, "info.jsonc"))
  merged_info = defaults_info.merge(locale_info)

  JSONC_FIELD_MAP.each do |json_key, deliver_filename|
    value = merged_info[json_key]
    next unless value

    File.write(File.join(deliver_locale_dir, deliver_filename), value)
  end

  locale_description = read_text_file(File.join(locale_path, "description.txt"))
  description = locale_description || defaults_description
  if description
    File.write(File.join(deliver_locale_dir, "description.txt"), description)
  end

  if use_default_whats_new
    whats_new = defaults_whats_new
  else
    locale_whats_new = read_text_file(File.join(locale_path, "whatsNew.txt"))
    whats_new = locale_whats_new || defaults_whats_new
  end

  if whats_new
    File.write(File.join(deliver_locale_dir, "release_notes.txt"), whats_new)
  end

  puts(":: Processed locale '#{locale}'")
end

unless skip_screenshots
  screenshots_dir = File.join(input_dir, "Screenshots")
  if File.directory?(screenshots_dir)
    require_relative "transform_screenshots"
    process_screenshots(screenshots_dir, File.join(output_dir, "screenshots"))
  else
    puts(":: No Screenshots/ directory found, skipping screenshots.")
  end
end

puts(":: Transform complete — #{locale_dirs.length} locale(s) processed")
