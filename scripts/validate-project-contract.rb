#!/usr/bin/env ruby

require "json"
require "set"
require "xcodeproj"

VAR_PATTERN = /\$\(([^)]+)\)|\$\{([^}]+)\}/

def fail_with(errors)
  errors.each do |error|
    warn("ERROR: #{error}")
  end
  exit(1)
end

def config_for(owner, configuration)
  owner.build_configurations.find { |build_config| build_config.name == configuration }
end

def xcconfig_path_for(build_config)
  file_ref = build_config.base_configuration_reference
  return file_ref.real_path.to_s if file_ref

  anchor = build_config.respond_to?(:base_configuration_reference_anchor) ? build_config.base_configuration_reference_anchor : nil
  relative_path = build_config.respond_to?(:base_configuration_reference_relative_path) ? build_config.base_configuration_reference_relative_path : nil
  return nil unless anchor && relative_path

  File.expand_path(relative_path, anchor.real_path.to_s)
end

def hardcoded_in_project?(expression)
  return false if expression.nil?

  value = expression.to_s.strip
  return false if value.empty?

  !value.match?(VAR_PATTERN)
end

def variables_in(expression)
  expression.to_s.scan(VAR_PATTERN).map { |first, second| first || second }.uniq
end

def normalize_setting(value)
  case value
  when Array
    value.join(" ").strip
  else
    value.to_s.strip
  end
end

def resolved_build_setting(build_config, key, root_target = nil)
  normalize_setting(build_config.resolve_build_setting(key, root_target))
rescue StandardError => e
  raise "could not resolve #{key}: #{e.message}"
end

def xcconfig_attributes_for(paths)
  paths.reduce({}) do |merged, path|
    merged.merge(Xcodeproj::Config.new(path).to_hash)
  end
end

def ensure_identity_chain_comes_from_xcconfig!(expression:, label:, target_name:, target_settings:, project_settings:, xcconfig_settings:, seen: Set.new)
  variables_in(expression).each do |variable|
    next if variable == "inherited"
    next if seen.include?(variable)

    seen.add(variable)

    if target_settings.key?(variable)
      return "Target '#{target_name}' resolves #{label} through target build setting '#{variable}'. Move #{variable} into the referenced xcconfig."
    end

    if project_settings.key?(variable)
      return "Target '#{target_name}' resolves #{label} through project build setting '#{variable}'. Move #{variable} into the referenced xcconfig."
    end

    next unless xcconfig_settings.key?(variable)

    nested_error = ensure_identity_chain_comes_from_xcconfig!(
      expression: xcconfig_settings[variable],
      label: label,
      target_name: target_name,
      target_settings: target_settings,
      project_settings: project_settings,
      xcconfig_settings: xcconfig_settings,
      seen: seen
    )

    return nested_error if nested_error
  end

  nil
end

app_root = File.expand_path(ARGV.fetch(0))
project_path = ARGV.fetch(1)
configuration = ARGV.fetch(2)
targets = JSON.parse(ARGV.fetch(3))

project_abs = File.expand_path(project_path, app_root)
unless File.directory?(project_abs)
  fail_with(["Could not find Xcode project '#{project_abs}'"])
end

begin
  project = Xcodeproj::Project.open(project_abs)
rescue StandardError => e
  fail_with(["Could not open Xcode project '#{project_abs}': #{e.message}"])
end
project_config = config_for(project, configuration)

errors = []
validated_targets = []

targets.each do |target_info|
  target_name = target_info.fetch("name")
  target = project.native_targets.find { |candidate| candidate.name == target_name }

  unless target
    errors << "Target '#{target_name}' is signable but was not found in '#{project_abs}'"
    next
  end

  target_config = config_for(target, configuration)
  unless target_config
    errors << "Target '#{target_name}' does not define an Xcode configuration named '#{configuration}'"
    next
  end

  xcconfig_paths = [project_config, target_config].compact.map { |config| xcconfig_path_for(config) }.compact.uniq
  if xcconfig_paths.empty?
    errors << "Target '#{target_name}' configuration '#{configuration}' does not reference any .xcconfig file. CI requires xcconfig-driven release identity."
    next
  end

  missing_paths = xcconfig_paths.reject { |path| File.file?(path) }
  unless missing_paths.empty?
    missing_paths.each do |path|
      errors << "Target '#{target_name}' references xcconfig '#{path}', but the file does not exist after prepare.sh ran."
    end
    next
  end

  xcconfig_settings = xcconfig_attributes_for(xcconfig_paths)

  {
    "DEVELOPMENT_TEAM" => "team ID",
    "PRODUCT_BUNDLE_IDENTIFIER" => "bundle ID"
  }.each do |setting_name, label|
    target_expression = target_config.build_settings[setting_name]
    project_expression = project_config&.build_settings&.fetch(setting_name, nil)
    source_expression = target_expression || project_expression || xcconfig_settings[setting_name]

    if hardcoded_in_project?(target_expression)
      errors << "Target '#{target_name}' hardcodes #{label} in the project file. Move #{setting_name} into the referenced xcconfig."
      next
    end

    if target_expression.nil? && hardcoded_in_project?(project_expression)
      errors << "Target '#{target_name}' inherits a project-level hardcoded #{label}. Move #{setting_name} into the referenced xcconfig."
      next
    end

    unless source_expression
      errors << "Target '#{target_name}' does not resolve #{label} from xcconfig. Define #{setting_name} (or variables it depends on) in the referenced xcconfig."
      next
    end

    chain_error = ensure_identity_chain_comes_from_xcconfig!(
      expression: source_expression,
      label: label,
      target_name: target_name,
      target_settings: target_config.build_settings,
      project_settings: project_config&.build_settings || {},
      xcconfig_settings: xcconfig_settings
    )
    if chain_error
      errors << chain_error
      next
    end

    begin
      resolved_value = resolved_build_setting(target_config, setting_name, target)
    rescue StandardError => e
      errors << "Target '#{target_name}' #{e.message}"
      next
    end

    if resolved_value.empty?
      errors << "Target '#{target_name}' does not resolve #{label} from xcconfig. Define #{setting_name} (or variables it depends on) in the referenced xcconfig."
      next
    end

    if setting_name == "DEVELOPMENT_TEAM" && resolved_value !~ /\A[A-Z0-9]{10}\z/
      errors << "Target '#{target_name}' resolved DEVELOPMENT_TEAM='#{resolved_value}', which does not look like a valid Apple team ID."
      next
    end

    if setting_name == "PRODUCT_BUNDLE_IDENTIFIER" && resolved_value !~ /\A[A-Za-z0-9.-]+\z/
      errors << "Target '#{target_name}' resolved PRODUCT_BUNDLE_IDENTIFIER='#{resolved_value}', which does not look like a valid bundle ID."
      next
    end
  end

  next unless errors.empty? || errors.none? { |error| error.include?("Target '#{target_name}'") }

  validated_targets << {
    name: target_name,
    xcconfigs: xcconfig_paths
  }
end

fail_with(errors) unless errors.empty?

puts(":: Validated xcconfig-driven release contract for configuration '#{configuration}'")
validated_targets.each do |target|
  puts(":: Target '#{target[:name]}' uses xcconfig(s): #{target[:xcconfigs].join(', ')}")
end
