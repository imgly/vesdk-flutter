#import "VideoEditorSDKPlugin.h"
#if __has_include(<video_editor_sdk/video_editor_sdk-Swift.h>)
#import <video_editor_sdk/video_editor_sdk-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "video_editor_sdk-Swift.h"
#endif

@implementation VideoEditorSDKPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [FlutterVESDK registerWithRegistrar:registrar];
}
@end
