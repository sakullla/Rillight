require 'json'
Pod::Spec.new do |s|
  # Download is verified before any extraction or CocoaPods integration.
  raise 'Rillight native dependency setup failed' unless system('python3', File.join(__dir__, '../native/prepare_macos.py'))
  s.name = 'rillight_player'
  s.version = '0.1.0'
  s.summary = 'Rillight owned desktop libmpv adapter'
  s.homepage = 'https://github.com/sakullla/Rillight'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Rillight' => 'https://github.com/sakullla/Rillight' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,mm}'
  s.public_header_files = 'Classes/RillightPlayerPlugin.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '11.0'
  s.vendored_libraries = 'Libraries/*.dylib'
  s.frameworks = 'OpenGL', 'CoreVideo', 'IOSurface'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17', 'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Headers"', 'GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS' => 'NO' }
end
