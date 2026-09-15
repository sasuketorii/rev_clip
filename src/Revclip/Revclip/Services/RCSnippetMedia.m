#import "RCSnippetMedia.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import "RCLocalization.h"

@implementation RCSnippetMedia
+ (BOOL)isValidImageData:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || data.length == 0 || data.length > 10 * 1024 * 1024) return NO;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
    if (!source) return NO;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    BOOL valid = CGImageSourceGetCount(source) == 1 && width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 16000000;
    CFRelease(source);
    return valid;
}
+ (NSImage *)thumbnailForData:(NSData *)data size:(CGFloat)size {
    if (![self isValidImageData:data]) return nil;
    return [self downsampleImageData:data size:size];
}
+ (NSImage *)historyThumbnailForData:(NSData *)data size:(CGFloat)size {
    if (!data.length || data.length > 128*1024*1024) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    BOOL valid = CGImageSourceGetCount(source) == 1 && width > 0 && height > 0 && width*height <= 100000000;
    CFRelease(source);
    return valid ? [self downsampleImageData:data size:size] : nil;
}
+ (NSImage *)downsampleImageData:(NSData *)data size:(CGFloat)size {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
    if (!source) return nil;
    if (!source) return nil;
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@(MIN(8192, MAX(1, size * 2)))
    });
    CFRelease(source);
    if (!image) return nil;
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGFloat scale = size / MAX(width, height);
    NSImage *result = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(width * scale, height * scale)];
    CFRelease(image);
    return result;
}
+ (NSData *)pasteboardTIFFForData:(NSData *)data {
    if (![self isValidImageData:data]) return nil;
    // Decode only on selection; menu construction uses small ImageIO thumbnails.
    NSImage *image = [[NSImage alloc] initWithData:data];
    return image.TIFFRepresentation;
}
+ (NSData *)readImageAtURL:(NSURL *)url error:(NSError **)error {
    int fd = url.isFileURL ? open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC) : -1;
    NSMutableData *data = [NSMutableData data];
    if (fd >= 0) {
        struct stat info;
        if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size <= 10 * 1024 * 1024) {
            uint8_t buffer[65536];
            while (data.length <= 10 * 1024 * 1024) {
                ssize_t count = read(fd, buffer, MIN(sizeof(buffer), 10 * 1024 * 1024 + 1 - data.length));
                if (count < 0 && errno == EINTR) continue;
                if (count < 0) { [data setLength:0]; break; }
                if (count == 0) break;
                [data appendBytes:buffer length:(NSUInteger)count];
            }
        }
        close(fd);
    }
    if (![self isValidImageData:data]) {
        if (error) *error = [NSError errorWithDomain:@"com.revclip.snippet-media" code:1 userInfo:@{NSLocalizedDescriptionKey:RCLocalizedString(@"Choose a still image up to 10 MB and 16 megapixels.", nil)}];
        return nil;
    }
    return data;
}
+ (NSString *)digestForData:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || !data.length) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i=0; i<sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
@end
