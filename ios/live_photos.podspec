#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint live_photos.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'live_photos'
  s.version          = '0.0.1'
  s.summary          = 'A new flutter plugin project.'
  s.description      = <<-DESC
A new flutter plugin project for generating Live Photos.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  
  # ВАЖЛИВО: Піднімаємо мінімальну версію до iOS 11.0 (або 12.0), щоб AVFoundation працював коректно
  s.platform = :ios, '11.0'

  # ВАЖЛИВО: Правильне налаштування для сучасних Mac (M1/M2) та нових Xcode
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
