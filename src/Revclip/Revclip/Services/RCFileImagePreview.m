#import "RCFileImagePreview.h"
#import "RCClipData.h"
#import "RCSnippetMedia.h"

@implementation RCFileImagePreview
+ (BOOL)hasFileReference:(RCClipData *)clip {
    return clip.fileURLs.count > 0 || clip.fileNames.count > 0;
}
+ (NSImage *)imageForClip:(RCClipData *)clip size:(CGFloat)size {
    NSURL *url = clip.fileURLs.firstObject;
    if (!url && clip.fileNames.firstObject.length) {
        NSString *path = clip.fileNames.firstObject;
        if (!path.isAbsolutePath) return nil;
        url = [NSURL fileURLWithPath:path];
    }
    if (!url.isFileURL || (url.host.length && ![url.host isEqualToString:@"localhost"])) return nil;
    // Resolve links before checking the destination volume and cloud state.
    url = url.URLByResolvingSymlinksInPath;
    NSDictionary *values = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLVolumeIsLocalKey,
        NSURLIsUbiquitousItemKey, NSURLUbiquitousItemDownloadingStatusKey] error:nil];
    if (![values[NSURLIsRegularFileKey] boolValue] || ![values[NSURLVolumeIsLocalKey] boolValue]) return nil;
    if ([values[NSURLIsUbiquitousItemKey] boolValue]) {
        NSString *status = values[NSURLUbiquitousItemDownloadingStatusKey];
        if (![status isEqual:NSURLUbiquitousItemDownloadingStatusCurrent] &&
            ![status isEqual:NSURLUbiquitousItemDownloadingStatusDownloaded]) return nil;
    }
    NSData *data = [RCSnippetMedia readImageAtURL:url error:nil];
    return data ? [RCSnippetMedia thumbnailForData:data size:MIN(360, MAX(1, size))] : nil;
}
@end
