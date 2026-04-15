require "fileutils"

DEVICE_DIMENSIONS = {
  "APP_IPHONE_67" => [1290, 2796],
  "APP_IPHONE_65" => [1284, 2778],
  "APP_IPHONE_55" => [1242, 2208],
  "APP_IPAD_129"  => [2048, 2732],
  "APP_IPAD_110"  => [1668, 2388]
}.freeze unless defined?(DEVICE_DIMENSIONS)

DIMENSION_TOLERANCE = 20 unless defined?(DIMENSION_TOLERANCE)

def sips_dimensions(path)
  output = `sips -g pixelWidth -g pixelHeight "#{path}" 2>/dev/null`
  width = output[/pixelWidth:\s*(\d+)/, 1].to_i
  height = output[/pixelHeight:\s*(\d+)/, 1].to_i
  [width, height]
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

    system("sips", "-s", "hasAlpha", "false", out_path, out: File::NULL, err: File::NULL)
    system("sips", "-z", s[:target_h].to_s, s[:target_w].to_s, out_path, out: File::NULL, err: File::NULL)

    puts(":: Processed screenshot #{s[:locale]}/#{out_name}")
  end
end
