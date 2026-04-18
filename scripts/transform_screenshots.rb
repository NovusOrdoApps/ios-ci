require "fileutils"
require "open3"

# Device folder names match Apple's App Store Connect display type constants
# (see fastlane's AppScreenshotSet::DisplayType). Each entry lists all
# portrait pixel dimensions Apple accepts for that display type.
# Source: https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/
DEVICE_DIMENSIONS = {
  "APP_IPHONE_67"         => [[1290, 2796], [1284, 2778]],  # iPhone 6.7"
  "APP_IPHONE_65"         => [[1242, 2688]],                # iPhone 6.5"
  "APP_IPHONE_61"         => [[1179, 2556], [1170, 2532], [1125, 2436]],  # iPhone 6.1"
  "APP_IPHONE_58"         => [[1125, 2436]],                # iPhone 5.8"
  "APP_IPHONE_55"         => [[1242, 2208]],                # iPhone 5.5"
  "APP_IPHONE_47"         => [[750, 1334]],                 # iPhone 4.7"
  "APP_IPAD_PRO_3GEN_129" => [[2048, 2732], [2064, 2752]],  # iPad Pro 12.9" 3rd gen+
  "APP_IPAD_PRO_129"      => [[2048, 2732]],                # iPad Pro 12.9" 2nd gen
  "APP_IPAD_PRO_3GEN_11"  => [[1668, 2388], [1668, 2420], [1488, 2266]],  # iPad Pro 11"
  "APP_IPAD_105"          => [[1668, 2224]],                # iPad 10.5"
  "APP_IPAD_97"           => [[1536, 2048]]                 # iPad 9.7"
}.freeze

DIMENSION_TOLERANCE = 20

def sips_dimensions(path)
  output, _ = Open3.capture2("sips", "-g", "pixelWidth", "-g", "pixelHeight", path)
  width = output[/pixelWidth:\s*(\d+)/, 1]&.to_i
  height = output[/pixelHeight:\s*(\d+)/, 1]&.to_i
  [width || 0, height || 0]
end

def closest_target(accepted_sizes, actual_w, actual_h, landscape)
  # accepted_sizes is array of [portrait_w, portrait_h] pairs.
  # Orient each to match the actual image, then find the one with minimum diff.
  best = nil
  best_diff = nil
  accepted_sizes.each do |pw, ph|
    tw, th = landscape ? [ph, pw] : [pw, ph]
    diff = (actual_w - tw).abs + (actual_h - th).abs
    if best.nil? || diff < best_diff
      best = [tw, th]
      best_diff = diff
    end
  end
  best
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

    accepted = DEVICE_DIMENSIONS[device_folder]
    unless accepted
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
    orientation = landscape ? "landscape" : "portrait"

    target_w, target_h = closest_target(accepted, actual_w, actual_h, landscape)

    diff_w = (actual_w - target_w).abs
    diff_h = (actual_h - target_h).abs

    if diff_w > DIMENSION_TOLERANCE || diff_h > DIMENSION_TOLERANCE
      accepted_str = accepted.map { |w, h| landscape ? "#{h}x#{w}" : "#{w}x#{h}" }.join(", ")
      errors << {
        path: relative,
        message: "Accepted (#{orientation}): #{accepted_str}\n" \
                 "    Closest:  #{target_w} x #{target_h}\n" \
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
