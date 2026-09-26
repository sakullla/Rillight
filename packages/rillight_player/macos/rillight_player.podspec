require 'digest'
require 'fileutils'
require 'json'

Pod::Spec.new do |s|
  prefix_name = ENV['RILLIGHT_MACOS_CORE_PREFIX']
  core_name = ENV['RILLIGHT_MACOS_CORE_DYLIB']
  expected_core_hash = ENV['RILLIGHT_MACOS_CORE_SHA256']
  if [prefix_name, core_name, expected_core_hash].any? { |value| value.nil? || value.empty? }
    raise 'Set RILLIGHT_MACOS_CORE_PREFIX, RILLIGHT_MACOS_CORE_DYLIB and RILLIGHT_MACOS_CORE_SHA256 to a verified macos-universal FFmpeg SDK and owned core build'
  end
  prefix = File.expand_path(prefix_name)
  core = File.expand_path(core_name)
  verifier = File.expand_path('../native/verify_core_dependencies.py', __dir__)
  raise 'macOS FFmpeg SDK verification failed' unless system(
    'python3', verifier, '--prefix', prefix, '--target', 'macos-universal',
    '--require-subtitles'
  )
  unless File.file?(core) && File.basename(core) == 'librillight_core.dylib' &&
         Digest::SHA256.file(core).hexdigest.casecmp?(expected_core_hash)
    raise 'Owned macOS core dylib is missing or does not match its declared SHA256'
  end
  manifest = JSON.parse(File.read(File.join(prefix, 'rillight-core-dependencies.json')))
  relatives = (manifest.fetch('libraries').keys +
               [manifest.fetch('libass').fetch('library')]).uniq
  # SDK manifests may also hash static archives. CocoaPods must ship and link
  # only runtime dylibs; each required component needs one in the manifest.
  relatives.select! { |path| File.basename(path).end_with?('.dylib') }
  required = %w[avformat avcodec avutil avfilter swresample swscale ass]
  unless required.all? { |name|
    relatives.any? { |path| File.basename(path).start_with?("lib#{name}.") }
  }
    raise 'Verified macOS SDK is missing a required runtime dylib'
  end
  sources = relatives.map { |relative| File.expand_path(relative, prefix) }
  sources << core
  if sources.any? { |path| !File.file?(path) } ||
     sources.map { |path| File.basename(path) }.uniq.length != sources.length
    raise 'macOS core dylib closure is incomplete or has duplicate names'
  end
  sources.each do |path|
    unless system('lipo', path, '-verify_arch', 'x86_64', 'arm64',
                  out: File::NULL, err: File::NULL)
      raise "macOS native library lacks x86_64/arm64 slices: #{path}"
    end
  end
  library_dir = File.join(__dir__, 'Libraries')
  FileUtils.mkdir_p(library_dir)
  wanted = sources.map { |path| File.basename(path) }
  sources.each { |path| FileUtils.cp(path, File.join(library_dir, File.basename(path))) }
  Dir.glob(File.join(library_dir, '*.dylib')).each do |path|
    FileUtils.rm_f(path) unless wanted.include?(File.basename(path))
  end

  s.name = 'rillight_player'
  s.version = '0.1.0'
  s.summary = 'Rillight owned FFmpeg player output for macOS'
  s.homepage = 'https://github.com/sakullla/Rillight'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Rillight' => 'https://github.com/sakullla/Rillight' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,mm}'
  s.public_header_files = 'Classes/RillightPlayerPlugin.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.vendored_libraries = 'Libraries/*.dylib'
  s.frameworks = 'AudioToolbox', 'CoreVideo', 'IOSurface'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Headers"',
    'OTHER_LDFLAGS' => '$(inherited) -framework FlutterMacOS -lrillight_core',
  }
end
