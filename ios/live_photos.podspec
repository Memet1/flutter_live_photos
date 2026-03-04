Pod::Spec.new do |s|
  s.name             = 'live_photos'
  s.version          = '1.0.0'
  s.summary          = 'Wallpaper-compatible Live Photo generator'
  s.description      = 'Generates Live Photos using native Passthrough for iOS 17 compatibility.'
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Memet' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  
  # ПІДНІМАЄМО ДО 11.0 ДЛЯ ПІДТРИМКИ HEVC ТА MDTA
  s.platform = :ios, '11.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
