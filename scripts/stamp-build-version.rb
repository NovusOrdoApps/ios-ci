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

app_root = File.expand_path(ARGV.fetch(0))
project_path = ARGV.fetch(1)
configuration = ARGV.fetch(2)
targets = JSON.parse(ARGV.fetch(3))

build_number = ENV.fetch("IOS_RELEASE_BUILD_NUMBER")
marketing_version = ENV["IOS_RELEASE_MARKETING_VERSION"].to_s.strip
marketing_version = nil if marketing_version.empty?

unless build_number.match?(/\A\d+\z/)
  fail_with(["IOS_RELEASE_BUILD_NUMBER must be numeric, got '#{build_number}'"])
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
  fail_with(["Could not find any signable application or extension targets to stamp"])
end

errors = []
stamped = []

signable_targets.each do |target_info|
  target_name = target_info.fetch("name")
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

  build_config.build_settings["CURRENT_PROJECT_VERSION"] = build_number
  build_config.build_settings["INFOPLIST_KEY_CFBundleVersion"] = "$(CURRENT_PROJECT_VERSION)"

  if marketing_version
    build_config.build_settings["MARKETING_VERSION"] = marketing_version
    build_config.build_settings["INFOPLIST_KEY_CFBundleShortVersionString"] = "$(MARKETING_VERSION)"
  end

  stamped << target_name
end

fail_with(errors) unless errors.empty?

project.save

version_summary = marketing_version ? "MARKETING_VERSION=#{marketing_version}" : "MARKETING_VERSION=<unchanged>"
puts(":: Stamped configuration '#{configuration}' in '#{project_path}' with #{version_summary} CURRENT_PROJECT_VERSION=#{build_number}")
stamped.each do |target_name|
  puts(":: Version stamped target '#{target_name}'")
end
