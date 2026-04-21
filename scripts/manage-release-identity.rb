#!/usr/bin/env ruby

require "json"
require "xcodeproj"

def fail_with(errors)
  errors.each { |error| warn("ERROR: #{error}") }
  exit(1)
end

def config_for(owner, configuration)
  owner.build_configurations.find { |build_config| build_config.name == configuration }
end

def signable_product_type?(product_type)
  return false if product_type.nil?

  product_type == "com.apple.product-type.application" ||
    product_type.start_with?("com.apple.product-type.app-extension")
end

def derive_bundle_id(target_info:, primary_bundle_id:, release_bundle_id:, explicit_ids:, single_extension_override:)
  target_name = target_info.fetch("name")
  current_bundle_id = target_info.fetch("bundle_id")

  return explicit_ids[target_name] if explicit_ids.key?(target_name)
  return release_bundle_id if current_bundle_id == primary_bundle_id

  if single_extension_override &&
     target_info.fetch("product_type").start_with?("com.apple.product-type.app-extension")
    return single_extension_override
  end

  return "#{release_bundle_id}#{current_bundle_id[primary_bundle_id.length..]}" if current_bundle_id.start_with?("#{primary_bundle_id}.")

  nil
end

app_root = File.expand_path(ARGV.fetch(0))
project_path = ARGV.fetch(1)
configuration = ARGV.fetch(2)
targets = JSON.parse(ARGV.fetch(3))

release_team_id = ENV.fetch("IOS_RELEASE_TEAM_ID")
release_app_bundle_id = ENV.fetch("IOS_RELEASE_APP_BUNDLE_ID")
single_extension_override = ENV["IOS_RELEASE_EXTENSION_BUNDLE_ID"].to_s.strip
single_extension_override = nil if single_extension_override.empty?

explicit_ids = {}
raw_explicit_ids = ENV["IOS_RELEASE_TARGET_BUNDLE_IDS_JSON"].to_s.strip
unless raw_explicit_ids.empty?
  begin
    explicit_ids = JSON.parse(raw_explicit_ids)
  rescue JSON::ParserError => e
    fail_with(["IOS_RELEASE_TARGET_BUNDLE_IDS_JSON is not valid JSON: #{e.message}"])
  end

  unless explicit_ids.is_a?(Hash)
    fail_with(["IOS_RELEASE_TARGET_BUNDLE_IDS_JSON must be a JSON object mapping target names to bundle IDs"])
  end
end

project_abs = File.expand_path(project_path, app_root)
unless File.directory?(project_abs)
  fail_with(["Could not find Xcode project '#{project_abs}'"])
end

begin
  project = Xcodeproj::Project.open(project_abs)
rescue StandardError => e
  fail_with(["Could not open Xcode project '#{project_abs}': #{e.message}"])
end

signable_targets = targets.select { |target| signable_product_type?(target["product_type"]) }
if signable_targets.empty?
  fail_with(["Could not find any signable application or extension targets to patch"])
end

primary_app_target = signable_targets.find { |target| target["product_type"] == "com.apple.product-type.application" }
if primary_app_target.nil?
  fail_with(["Could not find an application target in the selected scheme. ios-ci needs one primary app target to assign IOS_RELEASE_APP_BUNDLE_ID."])
end

primary_bundle_id = primary_app_target.fetch("bundle_id")
non_primary_extensions = signable_targets.count do |target|
  target["name"] != primary_app_target["name"] &&
    target["product_type"].start_with?("com.apple.product-type.app-extension")
end

if single_extension_override && non_primary_extensions != 1
  fail_with([
    "IOS_RELEASE_EXTENSION_BUNDLE_ID can only be used when exactly one app-extension target is present in the selected scheme. " \
    "Found #{non_primary_extensions} extension targets."
  ])
end

errors = []
patched = []

signable_targets.each do |target_info|
  target_name = target_info.fetch("name")
  current_bundle_id = target_info.fetch("bundle_id")
  target = project.native_targets.find { |candidate| candidate.name == target_name }

  unless target
    errors << "Target '#{target_name}' was detected from build settings but not found in '#{project_abs}'"
    next
  end

  build_config = config_for(target, configuration)
  unless build_config
    errors << "Target '#{target_name}' does not define configuration '#{configuration}'"
    next
  end

  desired_bundle_id = derive_bundle_id(
    target_info: target_info,
    primary_bundle_id: primary_bundle_id,
    release_bundle_id: release_app_bundle_id,
    explicit_ids: explicit_ids,
    single_extension_override: single_extension_override
  )

  unless desired_bundle_id
    errors << "Could not derive a release bundle ID for target '#{target_name}' from current bundle ID '#{current_bundle_id}'. " \
              "Expected it to share the app prefix '#{primary_bundle_id}'. For complex apps, provide IOS_RELEASE_TARGET_BUNDLE_IDS_JSON or switch to xcconfig-managed mode."
    next
  end

  # Set the base (unconditional) values
  build_config.build_settings["DEVELOPMENT_TEAM"] = release_team_id
  build_config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = desired_bundle_id

  # Remove any conditional variants like "DEVELOPMENT_TEAM[sdk=iphoneos*]"
  # so the base value takes effect for all build conditions.
  removed_conditionals = []
  build_config.build_settings.keys.each do |key|
    if key =~ /\A(DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER)\[/
      build_config.build_settings.delete(key)
      removed_conditionals << key
    end
  end

  patched << {
    name: target_name,
    current_bundle_id: current_bundle_id,
    desired_bundle_id: desired_bundle_id,
    removed_conditionals: removed_conditionals
  }
end

fail_with(errors) unless errors.empty?

project.save

puts(":: Patched configuration '#{configuration}' in '#{project_path}'")
patched.each do |entry|
  puts(":: #{entry[:name]}: #{entry[:current_bundle_id]} -> #{entry[:desired_bundle_id]}")
  entry[:removed_conditionals].each do |key|
    puts(":: #{entry[:name]}: removed conditional '#{key}'")
  end
end
puts(":: DEVELOPMENT_TEAM -> #{release_team_id}")
