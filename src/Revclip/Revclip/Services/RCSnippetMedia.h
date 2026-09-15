#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
// Embedded image payloads are independent of the original file location.
@interface RCSnippetMedia : NSObject
+ (BOOL)isValidImageData:(NSData *)data;
+ (nullable NSImage *)thumbnailForData:(NSData *)data size:(CGFloat)size;
// History archives may contain full-resolution TIFFs larger than template imports.
+ (nullable NSImage *)historyThumbnailForData:(NSData *)data size:(CGFloat)size;
+ (nullable NSData *)pasteboardTIFFForData:(NSData *)data;
+ (nullable NSData *)readImageAtURL:(NSURL *)url error:(NSError **)error;
+ (NSString *)digestForData:(NSData *)data;
@end
NS_ASSUME_NONNULL_END
