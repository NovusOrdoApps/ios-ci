#!/usr/bin/env ruby
# transform_creative_assets.rb
#   --input   metadata/CreativeAssets
#   --output  <dir>
#   --locales en-US,ru,...        (the App Store locales of the version)
#
# Resolves which creative asset applies to which App Store locale, validates
# and normalises the images, and writes what the Fastfile lane
# update_creative_assets uploads and places:
#
#   <output>/files/<sha256>.png   one processed file per distinct image
#   <output>/manifest.json        assets, their placement type and locales
#
# Repo layout (mirrors metadata/Text: defaults apply everywhere, a locale
# folder overrides):
#   metadata/CreativeAssets/defaults/product_page_header.png   3840x1646
#   metadata/CreativeAssets/defaults/search_results.png        3:2, 1920x1280..3840x2560
#   metadata/CreativeAssets/<locale>/product_page_header.png   override for one locale
#
# Validation: file names must be a known kind (see creative_assets_catalog.rb);
# the header must be 3840x1646 within 20px and is scaled to exact; search
# results must be 3:2 inside Apple's range. Alpha is stripped with the same
# JPEG round-trip screenshots use (Apple rejects an alpha channel). macOS only
# because of sips.
require "json"
require "fileutils"
require "open3"
require "digest"
require "optparse"
require "time"
require_relative "creative_assets_catalog"

options = { locales: "" }
OptionParser.new do |o|
  o.on("--input DIR") { |v| options[:input] = v }
  o.on("--output DIR") { |v| options[:output] = v }
  o.on("--locales LIST") { |v| options[:locales] = v }
end.parse!

input = options[:input].to_s
output = options[:output].to_s
abort("ERROR: --input and --output are required") if input.empty? || output.empty?
unless File.directory?(input)
  abort("ERROR: #{input} not found. Add metadata/CreativeAssets/defaults/product_page_header.png " \
        "(3840x1646, no alpha) or run the Metadata workflow with skip_creative_assets: true.")
end
locales = options[:locales].split(",").map(&:strip).reject(&:empty?).uniq.sort
abort("ERROR: --locales is empty; the version has no localizations to place assets on.") if locales.empty?

def sips_dimensions(path)
  out, _ = Open3.capture2("sips", "-g", "pixelWidth", "-g", "pixelHeight", path)
  [out[/pixelWidth:\s*(\d+)/, 1].to_i, out[/pixelHeight:\s*(\d+)/, 1].to_i]
end

errors = []
warnings = []

# ── inventory: every file must be a known kind, every folder a locale or defaults
folders = Dir.children(input).select { |e| File.directory?(File.join(input, e)) }.sort
folders.each do |folder|
  if folder != CreativeAssetsCatalog::DEFAULTS_DIR && !locales.include?(folder)
    warnings << "#{folder}/: not a locale on App Store Connect (active: #{locales.join(', ')}); ignored"
  end
  Dir.children(File.join(input, folder)).sort.each do |f|
    next if f.start_with?(".")
    path = File.join(input, folder, f)
    next unless File.file?(path)
    next if CreativeAssetsCatalog.kind_for_filename(f)
    allowed = CreativeAssetsCatalog::KINDS.keys.map { |k| "#{k}.{#{CreativeAssetsCatalog::EXTENSIONS.join(',')}}" }.join(", ")
    errors << "#{folder}/#{f}: unknown creative asset file. Allowed: #{allowed}"
  end
end
Dir.children(input).each do |e|
  errors << "#{e}: files belong in defaults/ or <locale>/, not at the top level" if File.file?(File.join(input, e)) && !e.start_with?(".")
end

# ── resolve: <locale>/<kind>.* beats defaults/<kind>.*
def find_kind_file(dir, kind)
  return nil unless File.directory?(dir)
  CreativeAssetsCatalog::EXTENSIONS.each do |ext|
    Dir.children(dir).each do |f|
      return File.join(dir, f) if f.downcase == "#{kind}.#{ext}"
    end
  end
  nil
end

resolved = {} # [locale, kind] => source path
locales.each do |locale|
  CreativeAssetsCatalog::KINDS.each_key do |kind|
    src = find_kind_file(File.join(input, locale), kind) || find_kind_file(File.join(input, CreativeAssetsCatalog::DEFAULTS_DIR), kind)
    resolved[[locale, kind]] = src if src
  end
end

# ── process each distinct source once
files_dir = File.join(output, "files")
FileUtils.mkdir_p(files_dir)
processed = {} # source path => { reference_name:, file:, width:, height: }

resolved.values.uniq.sort.each do |src|
  kind = CreativeAssetsCatalog.kind_for_filename(File.basename(src))
  rel = src.sub("#{input}/", "")
  w, h = sips_dimensions(src)
  if w.zero? || h.zero?
    errors << "#{rel}: cannot read image dimensions (corrupt or not an image)"
    next
  end
  check = CreativeAssetsCatalog.check_dimensions(kind, w, h)
  unless check[:ok]
    errors << "#{rel}: #{check[:message]}"
    next
  end
  tw, th = check[:target]

  tmp = File.join(files_dir, ".tmp-#{Digest::SHA256.hexdigest(src)}.png")
  jpeg_tmp = tmp.sub(/\.png\z/, ".jpg")
  FileUtils.cp(src, tmp)
  # Strip alpha: JPEG round-trip at quality 100 (sips -s hasAlpha false is a
  # no-op on PNGs; TIFF keeps alpha). Then back to PNG.
  unless system("sips", "-s", "format", "jpeg", "-s", "formatOptions", "100", tmp, "--out", jpeg_tmp, out: File::NULL, err: File::NULL)
    errors << "#{rel}: sips could not convert to JPEG (alpha strip)"
    next
  end
  unless system("sips", "-s", "format", "png", jpeg_tmp, "--out", tmp, out: File::NULL, err: File::NULL)
    errors << "#{rel}: sips could not convert back to PNG"
    next
  end
  FileUtils.rm_f(jpeg_tmp)
  if [w, h] != [tw, th]
    unless system("sips", "-z", th.to_s, tw.to_s, tmp, out: File::NULL, err: File::NULL)
      errors << "#{rel}: sips could not scale to #{tw}x#{th}"
      next
    end
  end

  bytes = File.binread(tmp)
  sha = Digest::SHA256.hexdigest(bytes)
  final = File.join(files_dir, "#{sha}.png")
  FileUtils.mv(tmp, final, force: true)
  processed[src] = { reference_name: "sha256:#{sha}", file: "files/#{sha}.png", width: tw, height: th, source: rel, kind: kind }
end

unless errors.empty?
  msg = "Creative asset validation failed:\n\n"
  errors.each { |e| msg += "  #{e}\n" }
  msg += "\n#{errors.length} error(s) found. Fix the files under #{input} before uploading."
  abort(msg)
end
warnings.each { |wmsg| warn("WARNING: #{wmsg}") }

# ── manifest: one entry per distinct processed file, with the locales it serves
assets = {}
resolved.sort.each do |(locale, kind), src|
  p = processed[src]
  next unless p
  entry = (assets[p[:reference_name]] ||= {
    "reference_name" => p[:reference_name],
    "file" => p[:file],
    "kind" => kind,
    "placement_type" => CreativeAssetsCatalog::KINDS.fetch(kind)[:placement_type],
    "width" => p[:width],
    "height" => p[:height],
    "source" => p[:source],
    "locales" => [],
  })
  entry["locales"] << locale
  puts(":: #{locale}/#{kind} <- #{p[:source]} (#{p[:width]}x#{p[:height]})")
end

manifest = {
  "version" => 1,
  "generated_at" => Time.now.utc.iso8601,
  "locales" => locales,
  "placement_types" => CreativeAssetsCatalog.placement_types,
  "assets" => assets.values.each { |a| a["locales"] = a["locales"].uniq.sort },
}
File.write(File.join(output, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

locales.each do |locale|
  CreativeAssetsCatalog::KINDS.each_key do |kind|
    puts(":: #{locale}/#{kind}: no file (placements of this type will be removed for this locale)") unless resolved[[locale, kind]]
  end
end
puts(":: Wrote #{assets.size} distinct asset(s) for #{locales.size} locale(s) to #{output}/manifest.json")
