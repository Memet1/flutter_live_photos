Pod::Spec.new do |s|
  s.name             = 'live_photos_plus'
  s.version          = '1.0.0'
  s.summary          = 'iOS-wallpaper-compatible Live Photo generator for Flutter'
  s.description      = <<-DESC
  Generates Live Photos (HEIC + MOV) from video files or URLs with proper Apple
  metadata for use as iOS Live Wallpapers. Supports passthrough video, silent audio
  synthesis, and HEIC output with MakerNote linkage.
  DESC
  s.homepage         = 'https://github.com/YuheiNakasaka/flutter_live_photos'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Memet' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'

  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
