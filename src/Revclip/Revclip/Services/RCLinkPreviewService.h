#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface RCLinkPreviewAssets : NSObject
@property (nonatomic, readonly, nullable) NSImage *image;
@property (nonatomic, readonly, nullable) NSImage *favicon;
@end
/// Main-thread API. One bounded metadata request supplies both menu and hover art.
@interface RCLinkPreviewService : NSObject
+ (instancetype)shared;
+ (nullable NSURL *)URLForText:(nullable NSString *)text;
- (nullable NSImage *)cachedFaviconForURL:(NSURL *)url;
- (void)assetsForURL:(NSURL *)url completion:(void (^)(RCLinkPreviewAssets *assets))completion;
- (void)imageForURL:(NSURL *)url completion:(void (^)(NSImage * _Nullable image))completion;
- (void)clearCache;
@end
NS_ASSUME_NONNULL_END
