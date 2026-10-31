# Prepare only the checked-out CI workspace; do not apply signing to Pods/tests.
require 'xcodeproj'
require 'rexml/document'
require 'fileutils'

abort 'Run from repository root' unless File.exist?('ios/Runner.xcodeproj/project.pbxproj')
team = ENV.fetch('APPLE_TEAM_ID')
bundle = ENV.fetch('APPLE_BUNDLE_ID')
profile = ENV.fetch('PROFILE_NAME')
identity = ENV.fetch('SIGNING_CERT_SHA1')
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
runner = project.targets.find { |t| t.name == 'Runner' }
abort 'Runner target not found' unless runner

# Flutter's default flavor is cloud, so provide matching Xcode configurations.
([project] + project.targets).each do |owner|
  %w[Debug Profile Release].each do |mode|
    next if owner.build_configurations.any? { |c| c.name == "#{mode}-cloud" }
    original = owner.build_configurations.find { |c| c.name == mode }
    abort "Missing #{mode} configuration" unless original
    config = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    config.name = "#{mode}-cloud"
    config.build_settings = Marshal.load(Marshal.dump(original.build_settings))
    config.base_configuration_reference = original.base_configuration_reference
    owner.build_configuration_list.build_configurations << config
  end
end

sdk_library = runner.frameworks_build_phase.files.map(&:file_ref).compact.find { |f| File.basename(f.path.to_s) == 'libPNote.a' }
abort 'libPNote.a is missing from Runner link phase' unless sdk_library
abort "Missing SoniNote static library: #{sdk_library.real_path}" unless File.file?(sdk_library.real_path)
runner.build_configurations.each do |config|
  paths = Array(config.build_settings['LIBRARY_SEARCH_PATHS'])
  abort "Missing SoniNote library search path in #{config.name}" unless paths.include?('$(SRCROOT)/Runner/SoniNote')
  abort "Missing inherited library paths in #{config.name}" unless paths.include?('$(inherited)')
end

flutter_group = project.main_group.find_subpath('Flutter', false)
abort 'Flutter group not found' unless flutter_group
%w[Debug Profile Release].each do |mode|
  filename = "#{mode}-cloud.xcconfig"
  File.write("ios/Flutter/#{filename}",
    "#include? \"Pods/Target Support Files/Pods-Runner/Pods-Runner.#{mode.downcase}-cloud.xcconfig\"\n" \
    "#include \"Generated.xcconfig\"\n")
  # The existing Flutter PBXGroup has a display name but no filesystem path.
  # Resolve explicitly from ios/, rather than treating the group as ios/Flutter/.
  reference = flutter_group.files.find { |f| File.basename(f.path.to_s) == filename } || flutter_group.new_file("Flutter/#{filename}")
  reference.path = "Flutter/#{filename}"
  reference.source_tree = 'SOURCE_ROOT'
  expected_path = File.expand_path("ios/Flutter/#{filename}")
  abort "Invalid #{filename} reference: #{reference.real_path}" unless reference.real_path.to_s == expected_path
  abort "Missing generated config: #{expected_path}" unless File.file?(reference.real_path)
  runner.build_configurations.find { |c| c.name == "#{mode}-cloud" }.base_configuration_reference = reference
end

release = runner.build_configurations.find { |c| c.name == 'Release-cloud' }
release.build_settings.merge!({
  'CODE_SIGN_STYLE' => 'Manual', 'DEVELOPMENT_TEAM' => team,
  'PRODUCT_BUNDLE_IDENTIFIER' => bundle,
  'PROVISIONING_PROFILE_SPECIFIER' => profile,
  'CODE_SIGN_IDENTITY[sdk=iphoneos*]' => identity,
})
extension = project.targets.find { |t| t.name == 'AgenoteRecordingActivity' }
abort 'Recording Live Activity target missing' unless extension
extension.build_configurations.each do |config|
  next unless config.name == 'Release-cloud'
  config.build_settings.merge!({
    'CODE_SIGN_STYLE' => 'Manual', 'DEVELOPMENT_TEAM' => team,
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{bundle}.RecordingActivity",
    'PROVISIONING_PROFILE_SPECIFIER' => ENV.fetch('RECORDING_PROFILE_NAME'),
    'CODE_SIGN_IDENTITY[sdk=iphoneos*]' => identity,
  })
end
project.save

scheme = REXML::Document.new(File.read('ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme'))
REXML::XPath.each(scheme, '//*[@buildConfiguration]') do |node|
  mode = node.attributes['buildConfiguration']
  node.attributes['buildConfiguration'] = "#{mode}-cloud" unless mode.end_with?('-cloud')
end
File.open('ios/Runner.xcodeproj/xcshareddata/xcschemes/cloud.xcscheme', 'w') do |file|
  scheme.write(file)
end
puts 'Prepared cloud scheme and Runner Release-cloud manual distribution signing'
