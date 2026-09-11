#import "RCLocalization.h"
//
//  RCClipData.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCClipData.h"

#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>
#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

#import "RCUtilities.h"
#import "Revclip-Swift.h"

static NSString * const kRCClipDataStringValueKey = @"stringValue";
static NSString * const kRCClipDataRTFDataKey = @"RTFData";
static NSString * const kRCClipDataRTFDDataKey = @"RTFDData";
static NSString * const kRCClipDataPDFDataKey = @"PDFData";
static NSString * const kRCClipDataFileNamesKey = @"fileNames";
static NSString * const kRCClipDataFileURLsKey = @"fileURLs";
static NSString * const kRCClipDataURLStringKey = @"URLString";
static NSString * const kRCClipDataTIFFDataKey = @"TIFFData";
static NSString * const kRCClipDataPrimaryTypeKey = @"primaryType";
static NSUInteger const kRCClipDataMaximumCollectionCount = 10000;

static os_log_t RCClipDataLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCClipData");
    });
    return logger;
}

@interface RCClipData ()

+ (NSString *)sha256HexForDigest:(const unsigned char *)digest;
+ (BOOL)updateHashContext:(CC_SHA256_CTX *)context withData:(nullable NSData *)source;
+ (BOOL)updateHashContext:(CC_SHA256_CTX *)context withString:(nullable NSString *)string;
+ (NSString *)truncateString:(NSString *)string length:(NSUInteger)length;
+ (NSString *)clipStorageDirectory;
+ (NSString *)standardizedPath:(NSString *)path;
+ (NSString *)resolvedClipStoragePath:(NSString *)path;
+ (NSString *)validatedClipStoragePath:(NSString *)path;
+ (BOOL)isValidArray:(nullable id)value elementClass:(Class)elementClass;
+ (BOOL)isValidDecodedClipData:(nullable id)clipData;

@end

@implementation RCClipData

#pragma mark - Create

+ (instancetype)clipDataFromPasteboard:(NSPasteboard *)pasteboard {
    RCClipData *clipData = [[self alloc] init];

    if (pasteboard == nil) {
        return clipData;
    }

    void (^setPrimaryTypeIfNeeded)(NSString *) = ^(NSString *type) {
        if (clipData.primaryType.length == 0) {
            clipData.primaryType = type;
        }
    };

    NSString *stringValue = [pasteboard stringForType:NSPasteboardTypeString];
    if (stringValue != nil) {
        clipData.stringValue = stringValue;
        setPrimaryTypeIfNeeded(NSPasteboardTypeString);
    }

    NSData *RTFData = [pasteboard dataForType:NSPasteboardTypeRTF];
    if (RTFData != nil) {
        clipData.RTFData = RTFData;
        setPrimaryTypeIfNeeded(NSPasteboardTypeRTF);
    }

    NSData *RTFDData = [pasteboard dataForType:NSPasteboardTypeRTFD];
    if (RTFDData != nil) {
        clipData.RTFDData = RTFDData;
        setPrimaryTypeIfNeeded(NSPasteboardTypeRTFD);
    }

    NSData *PDFData = [pasteboard dataForType:NSPasteboardTypePDF];
    if (PDFData != nil) {
        clipData.PDFData = PDFData;
        setPrimaryTypeIfNeeded(NSPasteboardTypePDF);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    id rawFileNames = [pasteboard propertyListForType:NSFilenamesPboardType];
#pragma clang diagnostic pop
    if ([rawFileNames isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *fileNames = [NSMutableArray array];
        for (id value in (NSArray *)rawFileNames) {
            if ([value isKindOfClass:[NSString class]]) {
                [fileNames addObject:value];
            }
        }
        clipData.fileNames = [fileNames copy];
        if (fileNames.count > 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            setPrimaryTypeIfNeeded(NSFilenamesPboardType);
#pragma clang diagnostic pop
        }
    }

    NSArray *readObjects = [pasteboard readObjectsForClasses:@[[NSURL class]] options:nil];
    if (readObjects.count > 0) {
        NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
        for (id object in readObjects) {
            if ([object isKindOfClass:[NSURL class]] && [(NSURL *)object isFileURL]) {
                [fileURLs addObject:object];
            }
        }
        if (fileURLs.count > 0) {
            clipData.fileURLs = [fileURLs copy];
            setPrimaryTypeIfNeeded(NSPasteboardTypeFileURL);
        }
    }

    NSString *URLString = [pasteboard stringForType:NSPasteboardTypeURL];
    if (URLString != nil) {
        clipData.URLString = URLString;
        setPrimaryTypeIfNeeded(NSPasteboardTypeURL);
    }

    NSData *TIFFData = [pasteboard dataForType:NSPasteboardTypeTIFF];
    if (TIFFData != nil) {
        clipData.TIFFData = TIFFData;
        setPrimaryTypeIfNeeded(NSPasteboardTypeTIFF);
    }

    return clipData;
}

#pragma mark - Hash / Title

- (NSString *)dataHash {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);

    BOOL didUpdate = NO;
    didUpdate = [[self class] updateHashContext:&context withString:self.stringValue] || didUpdate;
    didUpdate = [[self class] updateHashContext:&context withData:self.RTFData] || didUpdate;
    didUpdate = [[self class] updateHashContext:&context withData:self.RTFDData] || didUpdate;
    didUpdate = [[self class] updateHashContext:&context withData:self.PDFData] || didUpdate;
    didUpdate = [[self class] updateHashContext:&context withData:self.TIFFData] || didUpdate;
    for (NSString *fileName in self.fileNames) {
        didUpdate = [[self class] updateHashContext:&context withString:fileName] || didUpdate;
    }
    for (NSURL *fileURL in self.fileURLs) {
        didUpdate = [[self class] updateHashContext:&context withString:fileURL.absoluteString] || didUpdate;
    }
    didUpdate = [[self class] updateHashContext:&context withString:self.URLString] || didUpdate;
    // Include primaryType in hash to differentiate items with identical data but different primary types
    didUpdate = [[self class] updateHashContext:&context withString:self.primaryType] || didUpdate;

    if (!didUpdate) {
        return @"";
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return [[self class] sha256HexForDigest:digest];
}

- (NSString *)title {
    if (self.stringValue.length > 0) {
        return [[self class] truncateString:self.stringValue length:50];
    }

    if (self.URLString.length > 0) {
        return self.URLString;
    }

    if (self.fileNames.count > 0) {
        NSString *firstName = self.fileNames.firstObject;
        NSString *fileName = firstName.lastPathComponent;
        return fileName.length > 0 ? fileName : (firstName ?: @"");
    }

    if (self.fileURLs.count > 0) {
        NSURL *firstURL = self.fileURLs.firstObject;
        NSString *fileName = firstURL.lastPathComponent;
        return fileName.length > 0 ? fileName : (firstURL.absoluteString ?: @"");
    }

    BOOL hasNonImageData = self.RTFData.length > 0
        || self.RTFDData.length > 0
        || self.PDFData.length > 0
        || self.fileNames.count > 0
        || self.fileURLs.count > 0
        || self.URLString.length > 0;
    if (self.TIFFData.length > 0 && !hasNonImageData) {
        return RCLocalizedString(@"(Image)", @"Title for image-only clipboard data");
    }

    return @"";
}

#pragma mark - Equality

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[RCClipData class]]) {
        return NO;
    }
    RCClipData *other = (RCClipData *)object;
    return [[self dataHash] isEqualToString:[other dataHash]];
}

- (NSUInteger)hash {
    return [[self dataHash] hash];
}

#pragma mark - Write

- (BOOL)writeToPasteboard:(NSPasteboard *)pasteboard {
    if (pasteboard == nil) {
        return NO;
    }

    [pasteboard clearContents];

    BOOL didAttemptWrite = NO;
    BOOL didWriteAny = NO;

    // File URLs conform to NSPasteboardWriting, so use writeObjects: for them.
    // Other data types (NSData, NSString for specific UTIs) do not conform to
    // NSPasteboardWriting and must be set individually via setData:/setString:.
    // clearContents above ensures the pasteboard is fresh before writing.
    if (self.fileURLs.count > 0) {
        didAttemptWrite = YES;
        didWriteAny = [pasteboard writeObjects:self.fileURLs] || didWriteAny;
    }

    if (self.stringValue != nil) {
        didAttemptWrite = YES;
        didWriteAny = [pasteboard setString:self.stringValue forType:NSPasteboardTypeString] || didWriteAny;
    }
    if (self.RTFData != nil) {
        didAttemptWrite = YES;
        didWriteAny = [pasteboard setData:self.RTFData forType:NSPasteboardTypeRTF] || didWriteAny;
    }
    if (self.RTFDData != nil) {
        didAttemptWrite = YES;
        didWriteAny = [pasteboard setData:self.RTFDData forType:NSPasteboardTypeRTFD] || didWriteAny;
    }
    if (self.PDFData != nil) {
        didAttemptWrite = YES;
        didWriteAny = [pasteboard setData:self.PDFData forType:NSPasteboardTypePDF] || didWriteAny;
    }
    if (self.fileNames.count > 0) {
        didAttemptWrite = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        didWriteAny = [pasteboard setPropertyList:self.fileNames forType:NSFilenamesPboardType] || didWriteAny;
#pragma clang diagnostic pop
    }
    if (self.URLString != nil) {
        didAttemptWrite = YES;
        didWriteAny = [pasteboard setString:self.URLString forType:NSPasteboardTypeURL] || didWriteAny;
    }
    if (self.TIFFData != nil) {
        didAttemptWrite = YES;
        didWriteAny = [pasteboard setData:self.TIFFData forType:NSPasteboardTypeTIFF] || didWriteAny;
    }

    if (!didAttemptWrite) {
        NSLog(@"[RCClipData] No data to write to pasteboard.");
        return NO;
    }

    if (!didWriteAny) {
        NSLog(@"[RCClipData] Failed to write any clipboard payload to pasteboard.");
    }

    return didWriteAny;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.stringValue forKey:kRCClipDataStringValueKey];
    [coder encodeObject:self.RTFData forKey:kRCClipDataRTFDataKey];
    [coder encodeObject:self.RTFDData forKey:kRCClipDataRTFDDataKey];
    [coder encodeObject:self.PDFData forKey:kRCClipDataPDFDataKey];
    [coder encodeObject:self.fileNames forKey:kRCClipDataFileNamesKey];
    [coder encodeObject:self.fileURLs forKey:kRCClipDataFileURLsKey];
    [coder encodeObject:self.URLString forKey:kRCClipDataURLStringKey];
    [coder encodeObject:self.TIFFData forKey:kRCClipDataTIFFDataKey];
    [coder encodeObject:self.primaryType forKey:kRCClipDataPrimaryTypeKey];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        NSSet<Class> *stringArrayClasses = [NSSet setWithArray:@[[NSArray class], [NSString class]]];
        NSSet<Class> *urlArrayClasses = [NSSet setWithArray:@[[NSArray class], [NSURL class]]];

        self.stringValue = [coder decodeObjectOfClass:[NSString class] forKey:kRCClipDataStringValueKey];
        self.RTFData = [coder decodeObjectOfClass:[NSData class] forKey:kRCClipDataRTFDataKey];
        self.RTFDData = [coder decodeObjectOfClass:[NSData class] forKey:kRCClipDataRTFDDataKey];
        self.PDFData = [coder decodeObjectOfClass:[NSData class] forKey:kRCClipDataPDFDataKey];
        self.fileNames = [coder decodeObjectOfClasses:stringArrayClasses forKey:kRCClipDataFileNamesKey];
        self.fileURLs = [coder decodeObjectOfClasses:urlArrayClasses forKey:kRCClipDataFileURLsKey];
        self.URLString = [coder decodeObjectOfClass:[NSString class] forKey:kRCClipDataURLStringKey];
        self.TIFFData = [coder decodeObjectOfClass:[NSData class] forKey:kRCClipDataTIFFDataKey];
        self.primaryType = [coder decodeObjectOfClass:[NSString class] forKey:kRCClipDataPrimaryTypeKey];
    }
    return self;
}

#pragma mark - File

- (BOOL)saveToPath:(NSString *)path {
    return [self saveToPath:path maximumArchiveSize:NSUIntegerMax];
}

- (BOOL)saveToPath:(NSString *)path maximumArchiveSize:(NSUInteger)maximumArchiveSize {
    if (path.length == 0) {
        return NO;
    }

    NSString *resolvedPath = [[self class] validatedClipStoragePath:path];
    if (resolvedPath.length == 0) {
        return NO;
    }

    NSError *archiveError = nil;
    NSData *archiveData = [NSKeyedArchiver archivedDataWithRootObject:self
                                                 requiringSecureCoding:YES
                                                                 error:&archiveError];
    if (archiveData == nil) {
        return NO;
    }

    if (archiveData.length > maximumArchiveSize) {
        return NO;
    }

    NSError *writeError = nil;
    BOOL wrote = [[RCStorageCipher shared] writeData:archiveData
                                              toPath:resolvedPath
                                               error:&writeError];
    if (!wrote) {
        os_log_error(RCClipDataLog(), "Failed to save encrypted clip data");
        return NO;
    }
    return YES;
}

+ (nullable instancetype)clipDataFromPath:(NSString *)path {
    if (path.length == 0) {
        return nil;
    }

    NSString *resolvedPath = [[self class] validatedClipStoragePath:path];
    if (resolvedPath.length == 0) {
        return nil;
    }

    NSData *archiveData = [[RCStorageCipher shared] readDataAtPath:resolvedPath
                                                      allowPlaintext:NO
                                                               error:NULL];
    if (archiveData == nil) {
        return nil;
    }

    RCClipData *decodedObject = nil;
    BOOL decodedSafely = NO;
    @try {
        NSError *unarchiveError = nil;
        decodedObject = [NSKeyedUnarchiver unarchivedObjectOfClass:[RCClipData class]
                                                           fromData:archiveData
                                                              error:&unarchiveError];
        decodedSafely = (decodedObject != nil && unarchiveError == nil)
            && [[self class] isValidDecodedClipData:decodedObject];
    } @catch (NSException *exception) {
        (void)exception;
        decodedSafely = NO;
    }
    return decodedSafely ? decodedObject : nil;
}

#pragma mark - Helpers

+ (NSString *)sha256HexForDigest:(const unsigned char *)digest {
    NSMutableString *hexString = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hexString appendFormat:@"%02x", digest[index]];
    }
    return [hexString copy];
}

+ (BOOL)updateHashContext:(CC_SHA256_CTX *)context withData:(nullable NSData *)source {
    if (source.length == 0) {
        return NO;
    }

    NSAssert(source.length <= UINT32_MAX, @"Source data length %lu exceeds uint32_t maximum", (unsigned long)source.length);
    uint32_t length = CFSwapInt32HostToBig((uint32_t)source.length);
    CC_SHA256_Update(context, &length, (CC_LONG)sizeof(length));
    CC_SHA256_Update(context, source.bytes, (CC_LONG)source.length);
    return YES;
}

+ (BOOL)updateHashContext:(CC_SHA256_CTX *)context withString:(nullable NSString *)string {
    if (string.length == 0) {
        return NO;
    }
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    return [self updateHashContext:context withData:data];
}

+ (NSString *)standardizedPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    return [[path stringByExpandingTildeInPath] stringByStandardizingPath];
}

+ (NSString *)resolvedClipStoragePath:(NSString *)path {
    NSString *standardizedPath = [self standardizedPath:path];
    if (standardizedPath.length == 0) {
        return @"";
    }

    if (standardizedPath.isAbsolutePath) {
        return standardizedPath;
    }

    NSString *clipDirectoryPath = [self standardizedPath:[self clipStorageDirectory]];
    if (clipDirectoryPath.length == 0) {
        return @"";
    }

    NSString *resolvedPath = [clipDirectoryPath stringByAppendingPathComponent:standardizedPath];
    return [resolvedPath stringByStandardizingPath];
}

+ (NSString *)clipStorageDirectory {
    return [RCUtilities clipDataDirectoryPath];
}

+ (NSString *)validatedClipStoragePath:(NSString *)path {
    NSString *storageDirectory = [self standardizedPath:[self clipStorageDirectory]];
    if (storageDirectory.length == 0) {
        return @"";
    }

    struct stat storageDirectoryStat;
    if (lstat(storageDirectory.fileSystemRepresentation, &storageDirectoryStat) != 0
        || !S_ISDIR(storageDirectoryStat.st_mode)) {
        return @"";
    }

    NSString *resolvedPath = [self resolvedClipStoragePath:path];
    if (resolvedPath.length == 0) {
        return @"";
    }

    // Clip files are UUID-named files directly under the protected root. This
    // rejects traversal, sibling prefixes, nested directories, and the root
    // directory itself before the cipher touches the filesystem.
    NSString *parentDirectory = [resolvedPath stringByDeletingLastPathComponent];
    if (![parentDirectory isEqualToString:storageDirectory]) {
        return @"";
    }

    NSString *fileName = resolvedPath.lastPathComponent;
    if (fileName.length == 0 || [fileName isEqualToString:@"."] || [fileName isEqualToString:@".."]) {
        return @"";
    }

    struct stat destinationStat;
    if (lstat(resolvedPath.fileSystemRepresentation, &destinationStat) == 0) {
        if (!S_ISREG(destinationStat.st_mode)) {
            return @"";
        }
    } else if (errno != ENOENT) {
        return @"";
    }

    return resolvedPath;
}

+ (BOOL)isValidArray:(nullable id)value elementClass:(Class)elementClass {
    if (value == nil) {
        return YES;
    }
    if (![value isKindOfClass:[NSArray class]]) {
        return NO;
    }

    NSArray *array = (NSArray *)value;
    if (array.count > kRCClipDataMaximumCollectionCount) {
        return NO;
    }
    for (id element in array) {
        if (![element isKindOfClass:elementClass]) {
            return NO;
        }
    }
    return YES;
}

+ (BOOL)isValidDecodedClipData:(nullable id)clipData {
    if (![clipData isKindOfClass:[RCClipData class]]) {
        return NO;
    }

    return [self isValidArray:[(RCClipData *)clipData fileNames] elementClass:[NSString class]]
        && [self isValidArray:[(RCClipData *)clipData fileURLs] elementClass:[NSURL class]];
}

+ (NSString *)truncateString:(NSString *)string length:(NSUInteger)length {
    if (string.length <= length) {
        return string;
    }
    NSRange range = [string rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, length)];
    return [string substringWithRange:range];
}

@end
