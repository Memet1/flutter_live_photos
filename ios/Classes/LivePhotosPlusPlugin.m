#import "LivePhotosPlusPlugin.h"
#if __has_include(<live_photos_plus/live_photos_plus-Swift.h>)
#import <live_photos_plus/live_photos_plus-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "live_photos_plus-Swift.h"
#endif

@implementation LivePhotosPlusPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [SwiftLivePhotosPlusPlugin registerWithRegistrar:registrar];
}
@end
