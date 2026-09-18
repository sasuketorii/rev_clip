#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface RCLinkPreviewAssets : NSObject
@property (nonatomic, readonly, nullable) NSImage *image;
@property (nonatomic, readonly, nullable) NSImage *favicon;
@end
typedef NS_ENUM(NSInteger, RCLinkPreviewMode) {
    RCLinkPreviewModeDisabled = 0,
    RCLinkPreviewModeManual = 1,
    RCLinkPreviewModeAutomatic = 2,
};
FOUNDATION_EXPORT NSString * const RCLinkPreviewModeKey;
/// Main-thread API. One bounded metadata request supplies both menu and hover art.
@interface RCLinkPreviewService : NSObject
+ (instancetype)shared;
@property (nonatomic) RCLinkPreviewMode previewMode;
- (void)assetsForURL:(NSURL *)url userInitiated:(BOOL)userInitiated completion:(void (^)(RCLinkPreviewAssets *assets))completion;
+ (nullable NSURL *)URLForText:(nullable NSString *)text;
- (nullable NSImage *)cachedFaviconForURL:(NSURL *)url;
- (void)assetsForURL:(NSURL *)url completion:(void (^)(RCLinkPreviewAssets *assets))completion;
- (void)imageForURL:(NSURL *)url completion:(void (^)(NSImage * _Nullable image))completion;
- (void)removeURLs:(NSArray<NSURL *> *)urls;
- (void)clearCache;
@end
NS_ASSUME_NONNULL_END
