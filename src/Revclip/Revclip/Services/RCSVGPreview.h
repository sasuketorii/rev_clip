#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Deliberately limited, standalone SVG icons. Unsupported input returns nil for text fallback.
/// Supports svg/g/path/rect/circle/ellipse/line/polyline/polygon and bounded presentation attributes.
/// Rejects declarations, comments, CSS, references, defs, text and other unsupported SVG features.
/// Input <=128 KiB UTF-8; <=512 nodes, depth <=32, total path data <=64 KiB.
/// Adjacent decimal path numbers and compact arc flags are supported; transparent paint becomes none.
/// Coordinates <=16384 in magnitude; positive viewport edges >=0.0001, area <=64M, aspect <=1024.
/// Transforms have a conservative cumulative amplification bound; this is not full SVG support.
/// Successful rasters use an LRU cache capped at 8 entries and 16 MiB of accounted memory.
/// Never modifies clipboard text. Synchronous; callers may use a bounded background queue.
/// Resolve dynamic menu colors under the intended appearance before background dispatch.
@interface RCSVGPreview : NSObject
/// Cheap rejection only, not validation. Pass the original (untruncated) code to the other APIs.
+ (BOOL)isCandidateString:(NSString *)text;
+ (nullable NSData *)validatedSVGDataForString:(NSString *)text color:(NSColor *)color;
/// size is the maximum pixel edge, clamped to 720. Returns a raster image, not a lazy SVG.
/// Cache identity includes exact code, resolved sRGB tint/alpha and rounded pixel size.
+ (nullable NSImage *)imageForString:(NSString *)text color:(NSColor *)color size:(CGFloat)size;
@end
NS_ASSUME_NONNULL_END
