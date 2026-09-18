#import "RCLinkPreviewService.h"
@import LinkPresentation;
NSString * const RCLinkPreviewModeKey = @"RCLinkPreviewMode";

static const NSUInteger RCLinkMaxActive = 2;
static const NSUInteger RCLinkMaxPending = 32;
static const NSUInteger RCLinkBitmapCost = (640*360 + 32*32)*4;
static const NSTimeInterval RCLinkSuccessTTL = 24*60*60;
static const NSTimeInterval RCLinkFailureTTL = 60;

@interface RCLinkPreviewAssets ()
@property (nonatomic) NSImage *image;
@property (nonatomic) NSImage *favicon;
@end
@implementation RCLinkPreviewAssets
@end
@interface RCLinkPreviewEntry : NSObject
@property RCLinkPreviewAssets *assets;
@property NSTimeInterval expires;
@end
@implementation RCLinkPreviewEntry
@end
@interface RCLinkPreviewWork : NSObject
@property NSURL *url;
@property LPMetadataProvider *provider;
@property RCLinkPreviewAssets *assets;
@property NSMutableArray *callbacks;
@property NSMutableArray<NSProgress *> *loads;
@property NSUInteger remaining;
@property (copy) dispatch_block_t deadline;
@end
@implementation RCLinkPreviewWork
@end
@interface RCLinkPreviewService ()
@property NSCache<NSString *, RCLinkPreviewEntry *> *cache;
@property NSMutableDictionary<NSString *, RCLinkPreviewWork *> *pending;
@property NSMutableArray<RCLinkPreviewWork *> *queue;
@property NSUInteger activeCount;
@property RCLinkPreviewMode observedMode;
@property dispatch_queue_t renderQueue;
@property (copy) LPMetadataProvider *(^providerFactory)(void);
@end
@implementation RCLinkPreviewService
+ (instancetype)shared {
    static RCLinkPreviewService *service; static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [self new]; }); return service;
}
- (instancetype)init {
    return [self initWithProviderFactory:^{ return [LPMetadataProvider new]; }];
}
- (instancetype)initWithProviderFactory:(LPMetadataProvider *(^)(void))factory {
    if ((self = [super init])) {
        _cache = [NSCache new]; _cache.countLimit = 32; _cache.totalCostLimit = 32*1024*1024;
        _pending = [NSMutableDictionary dictionary]; _queue = [NSMutableArray array];
        _observedMode = self.previewMode;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
        _providerFactory = [factory copy];
        _renderQueue = dispatch_queue_create("com.revclip.link-art", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    } return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (NSUserDefaults *)preferences { return NSUserDefaults.standardUserDefaults; }
- (RCLinkPreviewMode)previewMode {
    id value = [self.preferences objectForKey:RCLinkPreviewModeKey];
    if (!value) return RCLinkPreviewModeManual;
    if (![value isKindOfClass:NSNumber.class]) return RCLinkPreviewModeDisabled;
    NSInteger mode = [value integerValue];
    return mode >= RCLinkPreviewModeDisabled && mode <= RCLinkPreviewModeAutomatic &&
        [value isEqualToNumber:@(mode)] ? mode : RCLinkPreviewModeDisabled;
}
- (void)setPreviewMode:(RCLinkPreviewMode)mode {
    NSAssert(NSThread.isMainThread, @"Main-thread link policy");
    if (mode < RCLinkPreviewModeDisabled || mode > RCLinkPreviewModeAutomatic) mode = RCLinkPreviewModeDisabled;
    [self.preferences setInteger:mode forKey:RCLinkPreviewModeKey];
    [self preferencesChanged:nil];
}
- (void)preferencesChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self preferencesChanged:nil]; });
        return;
    }
    RCLinkPreviewMode mode = self.previewMode;
    if (mode == self.observedMode) return;
    self.observedMode = mode;
    // Revoking permission cancels work and discards cache before callbacks run.
    [self clearCache];
}
- (NSTimeInterval)now { return NSProcessInfo.processInfo.systemUptime; }
+ (NSURL *)URLForText:(NSString *)text {
    NSString *value = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length || value.length > 2048 || [value containsString:@"@"] ||
        [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
    static NSDataDetector *detector; static dispatch_once_t once;
    dispatch_once(&once, ^{ detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil]; });
    NSTextCheckingResult *match = [detector firstMatchInString:value options:0 range:NSMakeRange(0,value.length)];
    if (!match.URL || !NSEqualRanges(match.range,NSMakeRange(0,value.length)) ||
        ![@[@"http",@"https"] containsObject:match.URL.scheme.lowercaseString]) return nil;
    BOOL explicitScheme = [value.lowercaseString hasPrefix:@"http://"] || [value.lowercaseString hasPrefix:@"https://"];
    NSURLComponents *parts = [NSURLComponents componentsWithString:explicitScheme ? value : [@"https://" stringByAppendingString:value]];
    if (!parts.host.length || parts.user || parts.password) return nil;
    parts.fragment = nil;
    return parts.URL;
}
- (RCLinkPreviewEntry *)entryForURL:(NSURL *)url {
    RCLinkPreviewEntry *entry = [self.cache objectForKey:url.absoluteString];
    if (entry && entry.expires <= self.now) { [self.cache removeObjectForKey:url.absoluteString]; return nil; }
    return entry;
}
- (NSImage *)cachedFaviconForURL:(NSURL *)url {
    NSAssert(NSThread.isMainThread,@"Main-thread link cache");
    return self.previewMode == RCLinkPreviewModeDisabled ? nil : [self entryForURL:url].assets.favicon;
}
- (void)imageForURL:(NSURL *)url completion:(void (^)(NSImage *))completion {
    [self assetsForURL:url completion:^(RCLinkPreviewAssets *assets) { completion(assets.image); }];
}
- (void)assetsForURL:(NSURL *)url completion:(void (^)(RCLinkPreviewAssets *))completion {
    [self assetsForURL:url userInitiated:NO completion:completion];
}
- (void)assetsForURL:(NSURL *)url userInitiated:(BOOL)userInitiated completion:(void (^)(RCLinkPreviewAssets *))completion {
    NSAssert(NSThread.isMainThread,@"Main-thread link cache");
    [self preferencesChanged:nil];
    RCLinkPreviewMode mode = self.previewMode;
    if (mode == RCLinkPreviewModeDisabled || ![RCLinkPreviewService URLForText:url.absoluteString]) {
        completion([RCLinkPreviewAssets new]); return;
    }
    RCLinkPreviewEntry *entry = [self entryForURL:url];
    if (entry) { completion(entry.assets); return; }
    if (mode == RCLinkPreviewModeManual && !userInitiated) {
        completion([RCLinkPreviewAssets new]); return;
    }
    RCLinkPreviewWork *work = self.pending[url.absoluteString];
    if (work) {
        if (work.callbacks.count < RCLinkMaxPending) [work.callbacks addObject:[completion copy]];
        else completion([RCLinkPreviewAssets new]);
        return;
    }
    if (self.pending.count >= RCLinkMaxPending) { completion([RCLinkPreviewAssets new]); return; }
    work = [RCLinkPreviewWork new]; work.url = url; work.assets = [RCLinkPreviewAssets new];
    work.callbacks = [NSMutableArray arrayWithObject:[completion copy]]; work.loads = [NSMutableArray array];
    self.pending[url.absoluteString] = work;
    [self.queue addObject:work]; [self drainQueue];
}
- (void)drainQueue {
    while (self.activeCount < RCLinkMaxActive && self.queue.count) {
        RCLinkPreviewWork *work = self.queue.firstObject; [self.queue removeObjectAtIndex:0];
        self.activeCount++; [self startWork:work];
    }
}
- (void)finishWork:(RCLinkPreviewWork *)work {
    if (self.pending[work.url.absoluteString] != work) return;
    if (work.deadline) { dispatch_block_cancel(work.deadline); work.deadline = nil; }
    for (NSProgress *load in work.loads) [load cancel];
    RCLinkPreviewEntry *entry = [RCLinkPreviewEntry new]; entry.assets = work.assets;
    BOOL hasArt = work.assets.image || work.assets.favicon;
    entry.expires = self.now + (hasArt ? RCLinkSuccessTTL : RCLinkFailureTTL);
    [self.cache setObject:entry forKey:work.url.absoluteString cost:hasArt ? RCLinkBitmapCost : 1];
    [self.pending removeObjectForKey:work.url.absoluteString]; self.activeCount--;
    work.provider = nil;
    NSArray *callbacks = [work.callbacks copy]; [work.callbacks removeAllObjects];
    [self drainQueue];
    for (void (^callback)(RCLinkPreviewAssets *) in callbacks) callback(work.assets);
}
// Rendering is shared by preview art and favicons and always runs off the UI thread.
- (NSImage *)renderImage:(NSImage *)source pixels:(NSSize)pixels points:(NSSize)points {
    if (!isfinite(source.size.width) || !isfinite(source.size.height) || source.size.width <= 0 || source.size.height <= 0) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixels.width pixelsHigh:pixels.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (!rep) return nil;
    memset(rep.bitmapData,0,rep.bytesPerRow*rep.pixelsHigh);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGFloat scale = MIN(pixels.width/source.size.width,pixels.height/source.size.height);
    NSSize size = NSMakeSize(source.size.width*scale,source.size.height*scale);
    [source drawInRect:NSMakeRect((pixels.width-size.width)/2,(pixels.height-size.height)/2,size.width,size.height) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    NSImage *result = [[NSImage alloc] initWithSize:points]; [result addRepresentation:rep];
    result.template = NO; return result;
}
- (void)loadArt:(NSItemProvider *)provider icon:(BOOL)icon work:(RCLinkPreviewWork *)work {
    void (^complete)(NSImage *) = ^(NSImage *image) {
        if (self.pending[work.url.absoluteString] != work) return;
        if (icon) work.assets.favicon = image; else work.assets.image = image;
        if (--work.remaining == 0) [self finishWork:work];
    };
    if (![provider canLoadObjectOfClass:NSImage.class]) { complete(nil); return; }
    NSProgress *load = [provider loadObjectOfClass:NSImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        // Check request identity before expensive work, including callbacks after cancellation.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pending[work.url.absoluteString] != work) return;
            dispatch_async(self.renderQueue, ^{
                @autoreleasepool {
                    NSImage *source = [object isKindOfClass:NSImage.class] ? (NSImage *)object : nil;
                    NSImage *image = [self renderImage:source pixels:icon ? NSMakeSize(32,32) : NSMakeSize(640,360) points:icon ? NSMakeSize(16,16) : NSMakeSize(640,360)];
                    dispatch_async(dispatch_get_main_queue(), ^{ complete(image); });
                }
            });
        });
    }];
    if (load) [work.loads addObject:load];
}
- (void)startWork:(RCLinkPreviewWork *)work {
    LPMetadataProvider *provider = self.providerFactory(); work.provider = provider; provider.timeout = 6;
    __weak RCLinkPreviewWork *weakWork = work;
    work.deadline = dispatch_block_create(0, ^{
        RCLinkPreviewWork *active = weakWork;
        if (!active || self.pending[active.url.absoluteString] != active) return;
        [active.provider cancel]; [self finishWork:active];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),work.deadline);
    [provider startFetchingMetadataForURL:work.url completionHandler:^(LPLinkMetadata *metadata, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.pending[work.url.absoluteString] != work) return;
            work.remaining = 2;
            [self loadArt:metadata.imageProvider icon:NO work:work];
            [self loadArt:metadata.iconProvider icon:YES work:work];
        });
    }];
}
- (void)removeURLs:(NSArray<NSURL *> *)urls {
    NSAssert(NSThread.isMainThread,@"Main-thread link cache");
    NSMutableArray *removed = [NSMutableArray array];
    for (NSURL *url in urls) {
        [self.cache removeObjectForKey:url.absoluteString];
        RCLinkPreviewWork *work = self.pending[url.absoluteString];
        if (!work) continue;
        if ([self.queue containsObject:work]) [self.queue removeObject:work];
        else self.activeCount--;
        [self.pending removeObjectForKey:url.absoluteString];
        [work.provider cancel]; work.provider = nil;
        if (work.deadline) dispatch_block_cancel(work.deadline); work.deadline = nil;
        for (NSProgress *load in work.loads) [load cancel];
        [removed addObject:work];
    }
    [self drainQueue];
    for (RCLinkPreviewWork *work in removed) {
        NSArray *callbacks = [work.callbacks copy]; [work.callbacks removeAllObjects];
        for (void (^callback)(RCLinkPreviewAssets *) in callbacks) callback([RCLinkPreviewAssets new]);
    }
}
- (void)clearCache {
    NSAssert(NSThread.isMainThread,@"Main-thread link cache");
    NSArray<RCLinkPreviewWork *> *work = self.pending.allValues;
    [self.pending removeAllObjects]; [self.queue removeAllObjects]; [self.cache removeAllObjects]; self.activeCount = 0;
    for (RCLinkPreviewWork *item in work) {
        [item.provider cancel]; item.provider = nil; if (item.deadline) dispatch_block_cancel(item.deadline); item.deadline = nil;
        for (NSProgress *load in item.loads) [load cancel];
        NSArray *callbacks = [item.callbacks copy]; [item.callbacks removeAllObjects];
        for (void (^callback)(RCLinkPreviewAssets *) in callbacks) callback([RCLinkPreviewAssets new]);
    }
}
@end
