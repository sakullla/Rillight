Pod::Spec.new do |s|
  preparer = File.expand_path('../native/prepare_macos.py', __dir__)
  unless system('python3', preparer)
    raise 'Verified universal macOS FFmpeg/core inputs are required; set RILLIGHT_MACOS_CORE_PREFIX, RILLIGHT_MACOS_CORE_DYLIB and RILLIGHT_MACOS_CORE_SHA256'
  end

  s.name = 'rillight_player'
  s.version = '0.1.0'
  s.summary = 'Rillight owned FFmpeg player output for macOS'
  s.homepage = 'https://github.com/sakullla/Rillight'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Rillight' => 'https://github.com/sakullla/Rillight' }
  s.source = { :path => '.' }
  s.source_files = 'rillight_player/Sources/rillight_player/**/*.{h,mm}'
  s.public_header_files = 'rillight_player/Sources/rillight_player/include/rillight_player/RillightPlayerPlugin.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.vendored_libraries = 'Libraries/*.dylib'
  s.frameworks = 'Accelerate', 'AudioToolbox', 'CoreGraphics', 'CoreVideo', 'IOSurface', 'Metal', 'QuartzCore'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Headers" "${PODS_TARGET_SRCROOT}/../native/core"',
    'OTHER_LDFLAGS' => '$(inherited) -framework FlutterMacOS -lrillight_core',
  }
end
