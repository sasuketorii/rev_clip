#import <AppKit/AppKit.h>
@class RCClipData;
NS_ASSUME_NONNULL_BEGIN
// Display-only source selection. Never changes the archived pasteboard payload.
@interface RCFileImagePreview : NSObject
+ (BOOL)hasFileReference:(RCClipData *)clip;
// Call off the main thread. Only the first file is considered; local, downloaded
// still images are bounded to 10 MiB / 16 megapixels by RCSnippetMedia.
+ (nullable NSImage *)imageForClip:(RCClipData *)clip size:(CGFloat)size;
@end
NS_ASSUME_NONNULL_END
