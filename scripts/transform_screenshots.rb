require "fileutils"
require "open3"

DEVICE_DIMENSIONS = {
  "APP_IPHONE_67" => [1290, 2796],
  "APP_IPHONE_65" => [1284, 2778],
  "APP_IPHONE_55" => [1242, 2208],
  "APP_IPAD_129"  => [2048, 2732],
  "APP_IPAD_110"  => [1668, 2388]
}.freeze

DIMENSION_TOLERANCE = 20

def sips_dimensions(path)
  output, _ = Open3.capture2("sips", "-g", "pixelWidth", "-g", "pixelHeight", path)
  width = output[/pixelWidth:\s*(\d+)/, 1]&.to_i
  height = output[/pixelHeight:\s*(\d+)/, 1]&.to_i
  [width || 0, height || 0]
end

def process_screenshots(screenshots_dir, output_dir)
  errors = []
  screenshots = []

  Dir.glob(File.join(screenshots_dir, "*", "*", "*.png")).sort.each do |png_path|
    relative = png_path.sub("#{screenshots_dir}/", "")
    parts = relative.split("/")
    locale = parts[0]
    device_folder = parts[1]
    filename = parts[2]

    target = DEVICE_DIMENSIONS[device_folder]
    unless target
      known = DEVICE_DIMENSIONS.keys.join(", ")
      errors << { path: relative, message: "Unknown screenshot device folder '#{device_folder}'. Expected: #{known}." }
      next
    end

    actual_w, actual_h = sips_dimensions(png_path)

    if actual_w == 0 || actual_h == 0
      errors << { path: relative, message: "Failed to read image dimensions — file may be corrupted or not a valid PNG." }
      next
    end

    landscape = actual_w > actual_h

    target_w, target_h = target
    if landscape
      target_w, target_h = target_h, target_w
    end

    orientation = landscape ? "landscape" : "portrait"

    diff_w = (actual_w - target_w).abs
    diff_h = (actual_h - target_h).abs

    if diff_w > DIMENSION_TOLERANCE || diff_h > DIMENSION_TOLERANCE
      errors << {
        path: relative,
        message: "Expected: #{target_w} x #{target_h} (#{orientation})\n" \
                 "    Actual:   #{actual_w} x #{actual_h}\n" \
                 "    Diff:     #{diff_w} x #{diff_h} — exceeds #{DIMENSION_TOLERANCE}px tolerance"
      }
      next
    end

    screenshots << {
      source: png_path,
      locale: locale,
      device_folder: device_folder,
      filename: filename,
      target_w: target_w,
      target_h: target_h
    }
  end

  unless errors.empty?
    message = "Screenshot validation failed:\n\n"
    errors.each do |err|
      message += "  #{err[:path]}\n"
      message += "    #{err[:message]}\n\n"
    end
    message += "#{errors.length} error(s) found. Fix screenshots before uploading."
    abort(message)
  end

  screenshots.each do |s|
    locale_output = File.join(output_dir, s[:locale])
    FileUtils.mkdir_p(locale_output)

    out_name = "#{s[:device_folder]}_#{s[:filename]}"
    out_path = File.join(locale_output, out_name)

    FileUtils.cp(s[:source], out_path)

    # Strip alpha channel via JPEG roundtrip at max quality.
    # sips -s hasAlpha false does not work on PNGs, and TIFF roundtrip preserves alpha.
    # JPEG at quality 100 is visually lossless for App Store screenshots — same approach
    # used by fastlane's frameit and other ecosystem tools.
    jpeg_tmp = out_path.sub(/\.png$/i, ".jpg")
    unless system("sips", "-s", "format", "jpeg", "-s", "formatOptions", "100", out_path, "--out", jpeg_tmp, out: File::NULL, err: File::NULL)
      abort("ERROR: Failed to convert #{out_name} to JPEG for alpha removal.")
    end
    unless system("sips", "-s", "format", "png", jpeg_tmp, "--out", out_path, out: File::NULL, err: File::NULL)
      abort("ERROR: Failed to convert #{out_name} back to PNG after alpha removal.")
    end
    FileUtils.rm_f(jpeg_tmp)

    # Scale to exact Apple dimensions
    unless system("sips", "-z", s[:target_h].to_s, s[:target_w].to_s, out_path, out: File::NULL, err: File::NULL)
      abort("ERROR: Failed to resize #{out_name} to #{s[:target_w]}x#{s[:target_h]}.")
    end

    puts(":: Processed screenshot #{s[:locale]}/#{out_name}")
  end
end
