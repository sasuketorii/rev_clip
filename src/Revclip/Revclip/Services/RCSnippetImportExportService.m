//
//  RCSnippetImportExportService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCSnippetImportExportService.h"

#import "FMDB.h"
#import "RCConstants.h"
#import "RCDatabaseManager.h"

NSErrorDomain const RCSnippetImportExportErrorDomain = @"com.revclip.snippet-import-export";

static NSString * const kRCClipyXMLRootElement = @"folders";
static NSString * const kRCClipyXMLLegacyRootElement = @"snippets";
static NSString * const kRCClipyXMLFolderElement = @"folder";
static NSString * const kRCClipyXMLFolderIdentifierElement = @"identifier";
static NSString * const kRCClipyXMLFolderTitleElement = @"title";
static NSString * const kRCClipyXMLFolderEnabledElement = @"enabled";
static NSString * const kRCClipyXMLFolderSnippetsElement = @"snippets";
static NSString * const kRCClipyXMLSnippetElement = @"snippet";
static NSString * const kRCClipyXMLSnippetIdentifierElement = @"identifier";
static NSString * const kRCClipyXMLSnippetTitleElement = @"title";
static NSString * const kRCClipyXMLSnippetContentElement = @"content";
static NSString * const kRCClipyXMLSnippetEnabledElement = @"enabled";

static NSString * const kRCRevclipPlistFormatKey = @"format";
static NSString * const kRCRevclipPlistFormatValue = @"revclip.snippets";
static NSString * const kRCRevclipPlistVersionKey = @"version";
static NSString * const kRCRevclipPlistFoldersKey = @"folders";
static NSString * const kRCRevclipPlistExportedAtKey = @"exported_at";
static NSInteger const kRCRevclipSupportedPlistVersion = 1;
static unsigned long long const kRCMaxImportFileSize = 50ULL * 1024ULL * 1024ULL;
static NSInteger const kRCMaxImportFolderCount = 100;
static NSInteger const kRCMaxImportSnippetCount = 10000;
static NSUInteger const kRCMaxImportTitleLength = 500;
static NSUInteger const kRCMaxImportContentLengthBytes = 1024 * 1024;

static NSString * const kRCImportedFolderTitle = @"Imported";

static NSStringEncoding RCStringEncodingFromXMLBOM(NSData *data) {
    if (data.length < 2) {
        return 0;
    }

    const uint8_t *bytes = data.bytes;
    if (data.length >= 4) {
        if (bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE && bytes[3] == 0xFF) {
            return NSUTF32BigEndianStringEncoding;
        }
        if (bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0x00 && bytes[3] == 0x00) {
            return NSUTF32LittleEndianStringEncoding;
        }
    }

    if (data.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        return NSUTF8StringEncoding;
    }

    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return NSUTF16BigEndianStringEncoding;
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return NSUTF16LittleEndianStringEncoding;
    }

    return 0;
}

@interface RCSnippetImportExportService ()

- (nullable NSArray<NSDictionary *> *)folderDictionariesForFullExport:(NSError **)error;
- (NSArray<NSDictionary *> *)normalizedFolderDictionariesForExport:(NSArray<NSDictionary *> *)folders;

- (nullable NSArray<NSDictionary *> *)parseFoldersFromPlistData:(NSData *)data error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)parseFoldersFromPlistRootObject:(id)rootObject error:(NSError **)error;
- (BOOL)validateRevclipPlistMetadataFromRootObject:(id)rootObject error:(NSError **)error;
- (nullable NSNumber *)plistVersionNumberFromValue:(id)value;
- (nullable NSDictionary *)parseFolderDictionaryFromPlistObject:(id)object;
- (nullable NSDictionary *)parseSnippetDictionaryFromPlistObject:(id)object;
- (BOOL)looksLikeFolderObject:(id)object;
- (BOOL)looksLikeSnippetObject:(id)object;
- (BOOL)looksLikeFolderArray:(NSArray *)objects;
- (BOOL)looksLikeSnippetArray:(NSArray *)objects;
- (BOOL)validateImportLimitsForFolders:(NSArray<NSDictionary *> *)folders error:(NSError **)error;

- (nullable NSArray<NSDictionary *> *)parseFoldersFromLegacyXMLData:(NSData *)data error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)parseFoldersFromLegacyXMLRootElement:(NSXMLElement *)rootElement error:(NSError **)error;
- (nullable NSXMLElement *)firstChildElementNamed:(NSString *)name inElement:(NSXMLElement *)element;
- (nullable NSString *)valueForElement:(NSString *)name inElement:(NSXMLElement *)element;
- (nullable NSString *)trimmedValueForElement:(NSString *)name inElement:(NSXMLElement *)element;
- (BOOL)containsDisallowedDoctypeInXMLData:(NSData *)data;

- (BOOL)persistParsedFolders:(NSArray<NSDictionary *> *)folders merge:(BOOL)merge error:(NSError **)error;
- (nullable NSError *)databaseErrorFromDatabase:(FMDatabase *)db fallbackDescription:(NSString *)description;

- (nullable id)nonNullValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys;
- (NSString *)stringValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys defaultValue:(NSString *)defaultValue;
- (NSInteger)integerValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys defaultValue:(NSInteger)defaultValue;
- (BOOL)boolValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys defaultValue:(BOOL)defaultValue;
- (NSArray *)arrayValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys;

- (BOOL)boolValueFromXMLString:(nullable NSString *)value defaultValue:(BOOL)defaultValue;
- (NSString *)trimmedString:(nullable NSString *)value;
- (NSString *)normalizedLookupString:(nullable NSString *)value;
- (NSString *)snippetSignatureWithTitle:(nullable NSString *)title content:(nullable NSString *)content;
- (NSString *)uniqueIdentifierExcludingMutableSet:(NSMutableSet<NSString *> *)reservedIdentifiers;
- (NSString *)iso8601TimestampString;

- (nullable NSError *)snippetErrorWithCode:(RCSnippetImportExportErrorCode)code
                                description:(NSString *)description
                            underlyingError:(nullable NSError *)underlyingError;
- (BOOL)assignSnippetError:(NSError **)error
                      code:(RCSnippetImportExportErrorCode)code
               description:(NSString *)description
           underlyingError:(nullable NSError *)underlyingError;

@end

@implementation RCSnippetImportExportService

+ (instancetype)shared {
    static RCSnippetImportExportService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

#pragma mark - Export

- (BOOL)exportSnippetsToURL:(NSURL *)fileURL error:(NSError **)error {
    if (![fileURL isFileURL]) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorFileWrite
                            description:NSLocalizedString(@"Export destination is invalid.", nil)
                        underlyingError:nil];
    }

    NSData *xmlData = [self exportSnippetsAsXMLData:error];
    if (xmlData == nil) {
        return NO;
    }

    NSError *writeError = nil;
    BOOL written = [xmlData writeToURL:fileURL options:NSDataWritingAtomic error:&writeError];
    if (!written) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorFileWrite
                            description:NSLocalizedString(@"Failed to write snippets file.", nil)
                        underlyingError:writeError];
    }

    return YES;
}

- (NSData *)exportSnippetsAsXMLData:(NSError **)error {
    NSArray<NSDictionary *> *folders = [self folderDictionariesForFullExport:error];
    if (folders == nil) {
        return nil;
    }

    return [self exportFoldersAsXMLData:folders error:error];
}

- (BOOL)exportFolders:(NSArray<NSDictionary *> *)folders toURL:(NSURL *)fileURL error:(NSError **)error {
    if (![fileURL isFileURL]) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorFileWrite
                            description:NSLocalizedString(@"Export destination is invalid.", nil)
                        underlyingError:nil];
    }

    NSData *xmlData = [self exportFoldersAsXMLData:folders error:error];
    if (xmlData == nil) {
        return NO;
    }

    NSError *writeError = nil;
    BOOL written = [xmlData writeToURL:fileURL options:NSDataWritingAtomic error:&writeError];
    if (!written) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorFileWrite
                            description:NSLocalizedString(@"Failed to write snippets file.", nil)
                        underlyingError:writeError];
    }

    return YES;
}

- (NSData *)exportFoldersAsXMLData:(NSArray<NSDictionary *> *)folders error:(NSError **)error {
    NSArray<NSDictionary *> *normalizedFolders = [self normalizedFolderDictionariesForExport:folders ?: @[]];
    NSDictionary *plistRoot = @{
        kRCRevclipPlistFormatKey: kRCRevclipPlistFormatValue,
        kRCRevclipPlistVersionKey: @(kRCRevclipSupportedPlistVersion),
        kRCRevclipPlistExportedAtKey: [self iso8601TimestampString],
        kRCRevclipPlistFoldersKey: normalizedFolders,
    };

    NSError *plistError = nil;
    NSData *xmlData = [NSPropertyListSerialization dataWithPropertyList:plistRoot
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&plistError];
    if (xmlData.length == 0 || plistError != nil) {
        [self assignSnippetError:error
                            code:RCSnippetImportExportErrorFileWrite
                     description:NSLocalizedString(@"Failed to build snippets XML plist data.", nil)
                 underlyingError:plistError];
        return nil;
    }

    return xmlData;
}

#pragma mark - Import

- (BOOL)importSnippetsFromURL:(NSURL *)fileURL merge:(BOOL)merge error:(NSError **)error {
    if (![fileURL isFileURL]) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorFileRead
                            description:NSLocalizedString(@"Import source is invalid.", nil)
                        underlyingError:nil];
    }

    // Guard against abnormally large files (50 MB limit)
    NSNumber *fileSize = nil;
    NSError *attrError = nil;
    if ([fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:&attrError] && fileSize != nil) {
        if (fileSize.unsignedLongLongValue > kRCMaxImportFileSize) {
            return [self assignSnippetError:error
                                       code:RCSnippetImportExportErrorFileRead
                                description:NSLocalizedString(@"Import file is too large (exceeds 50 MB limit).", nil)
                            underlyingError:nil];
        }
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:&readError];
    if (data == nil) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorFileRead
                            description:NSLocalizedString(@"Failed to read snippets file.", nil)
                        underlyingError:readError];
    }

    return [self importSnippetsFromData:data merge:merge error:error];
}

- (BOOL)importSnippetsFromData:(NSData *)data merge:(BOOL)merge error:(NSError **)error {
    if (data.length == 0) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorInvalidXMLFormat
                            description:NSLocalizedString(@"Snippets data is empty.", nil)
                        underlyingError:nil];
    }
    if ((unsigned long long)data.length > kRCMaxImportFileSize) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorFileRead
                            description:NSLocalizedString(@"Import file is too large (exceeds 50 MB limit).", nil)
                        underlyingError:nil];
    }

    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    if (![databaseManager setupDatabase]) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorDatabase
                            description:NSLocalizedString(@"Database is not ready.", nil)
                        underlyingError:nil];
    }

    NSError *plistParseError = nil;
    NSArray<NSDictionary *> *parsedFolders = [self parseFoldersFromPlistData:data error:&plistParseError];
    if (parsedFolders == nil
        && plistParseError != nil
        && [plistParseError.domain isEqualToString:RCSnippetImportExportErrorDomain]) {
        if (error != NULL) {
            *error = plistParseError;
        }
        return NO;
    }
    if (parsedFolders == nil) {
        NSError *xmlParseError = nil;
        parsedFolders = [self parseFoldersFromLegacyXMLData:data error:&xmlParseError];
        if (parsedFolders == nil && plistParseError != nil) {
            // Preserve the original parse error for diagnostics
            return [self assignSnippetError:error
                                       code:RCSnippetImportExportErrorInvalidXMLFormat
                                description:NSLocalizedString(@"Unsupported snippets file format.", nil)
                            underlyingError:plistParseError];
        }
    }
    if (parsedFolders == nil) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorInvalidXMLFormat
                            description:NSLocalizedString(@"Unsupported snippets file format.", nil)
                        underlyingError:nil];
    }
    if (![self validateImportLimitsForFolders:parsedFolders error:error]) {
        return NO;
    }

    return [self persistParsedFolders:parsedFolders merge:merge error:error];
}

#pragma mark - Private: Export Source

- (NSArray<NSDictionary *> *)folderDictionariesForFullExport:(NSError **)error {
    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    if (![databaseManager setupDatabase]) {
        [self assignSnippetError:error
                            code:RCSnippetImportExportErrorDatabase
                     description:NSLocalizedString(@"Database is not ready.", nil)
                 underlyingError:nil];
        return nil;
    }

    NSArray<NSDictionary *> *folders = [databaseManager fetchSnippetCatalog];
    if (folders == nil) {
        [self assignSnippetError:error code:RCSnippetImportExportErrorDatabase
                     description:NSLocalizedString(@"Failed to read snippets.", nil) underlyingError:nil];
        return nil;
    }
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:folders.count];

    for (NSDictionary *folder in folders) {
        NSString *folderIdentifier = [self trimmedString:[self stringValueInDictionary:folder
                                                                                   keys:@[@"identifier"]
                                                                            defaultValue:@""]];
        if (folderIdentifier.length == 0) {
            folderIdentifier = [NSUUID UUID].UUIDString;
        }

        NSArray<NSDictionary *> *snippets = [self arrayValueInDictionary:folder keys:@[@"snippets"]];
        NSMutableArray<NSDictionary *> *snippetDictionaries = [NSMutableArray arrayWithCapacity:snippets.count];

        for (NSDictionary *snippet in snippets) {
            NSString *snippetIdentifier = [self trimmedString:[self stringValueInDictionary:snippet
                                                                                        keys:@[@"identifier"]
                                                                                 defaultValue:@""]];
            if (snippetIdentifier.length == 0) {
                snippetIdentifier = [NSUUID UUID].UUIDString;
            }

            NSDictionary *snippetDictionary = @{
                @"identifier": snippetIdentifier,
                @"snippet_index": @([self integerValueInDictionary:snippet keys:@[@"snippet_index", @"snippetIndex"] defaultValue:(NSInteger)snippetDictionaries.count]),
                @"enabled": @([self boolValueInDictionary:snippet keys:@[@"enabled", @"enable"] defaultValue:YES]),
                @"title": [self stringValueInDictionary:snippet keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Snippet", nil)],
                @"content": [self stringValueInDictionary:snippet keys:@[@"content", @"text", @"value"] defaultValue:@""],
            };
            [snippetDictionaries addObject:snippetDictionary];
        }

        NSDictionary *folderDictionary = @{
            @"identifier": folderIdentifier,
            @"folder_index": @([self integerValueInDictionary:folder keys:@[@"folder_index", @"folderIndex", @"index"] defaultValue:(NSInteger)result.count]),
            @"enabled": @([self boolValueInDictionary:folder keys:@[@"enabled", @"enable"] defaultValue:YES]),
            @"title": [self stringValueInDictionary:folder keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Folder", nil)],
            @"snippets": [snippetDictionaries copy],
        };
        [result addObject:folderDictionary];
    }

    return [result copy];
}

- (NSArray<NSDictionary *> *)normalizedFolderDictionariesForExport:(NSArray<NSDictionary *> *)folders {
    NSMutableArray<NSDictionary *> *normalizedFolders = [NSMutableArray arrayWithCapacity:folders.count];
    NSMutableSet<NSString *> *folderIdentifiers = [NSMutableSet set];
    NSMutableSet<NSString *> *snippetIdentifiers = [NSMutableSet set];

    NSInteger folderIndex = 0;
    for (id folderObject in folders) {
        if (![folderObject isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSDictionary *folder = (NSDictionary *)folderObject;
        NSString *folderIdentifier = [self trimmedString:[self stringValueInDictionary:folder
                                                                                   keys:@[@"identifier", @"id", @"uuid"]
                                                                            defaultValue:@""]];
        if (folderIdentifier.length == 0 || [folderIdentifiers containsObject:folderIdentifier]) {
            folderIdentifier = [self uniqueIdentifierExcludingMutableSet:folderIdentifiers];
        } else {
            [folderIdentifiers addObject:folderIdentifier];
        }

        NSArray *snippetObjects = [self arrayValueInDictionary:folder keys:@[@"snippets", @"items", @"children"]];
        NSMutableArray<NSDictionary *> *normalizedSnippets = [NSMutableArray arrayWithCapacity:snippetObjects.count];
        NSInteger snippetIndex = 0;
        for (id snippetObject in snippetObjects) {
            if (![snippetObject isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            NSDictionary *snippet = (NSDictionary *)snippetObject;
            NSString *snippetIdentifier = [self trimmedString:[self stringValueInDictionary:snippet
                                                                                        keys:@[@"identifier", @"id", @"uuid"]
                                                                                 defaultValue:@""]];
            if (snippetIdentifier.length == 0 || [snippetIdentifiers containsObject:snippetIdentifier]) {
                snippetIdentifier = [self uniqueIdentifierExcludingMutableSet:snippetIdentifiers];
            } else {
                [snippetIdentifiers addObject:snippetIdentifier];
            }

            NSDictionary *normalizedSnippet = @{
                @"identifier": snippetIdentifier,
                @"snippet_index": @([self integerValueInDictionary:snippet keys:@[@"snippet_index", @"snippetIndex", @"index"] defaultValue:snippetIndex]),
                @"enabled": @([self boolValueInDictionary:snippet keys:@[@"enabled", @"enable"] defaultValue:YES]),
                @"title": [self stringValueInDictionary:snippet keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Snippet", nil)],
                @"content": [self stringValueInDictionary:snippet keys:@[@"content", @"text", @"value"] defaultValue:@""],
            };
            [normalizedSnippets addObject:normalizedSnippet];
            snippetIndex += 1;
        }

        NSDictionary *normalizedFolder = @{
            @"identifier": folderIdentifier,
            @"folder_index": @([self integerValueInDictionary:folder keys:@[@"folder_index", @"folderIndex", @"index"] defaultValue:folderIndex]),
            @"enabled": @([self boolValueInDictionary:folder keys:@[@"enabled", @"enable"] defaultValue:YES]),
            @"title": [self stringValueInDictionary:folder keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Folder", nil)],
            @"snippets": [normalizedSnippets copy],
        };

        [normalizedFolders addObject:normalizedFolder];
        folderIndex += 1;
    }

    return [normalizedFolders copy];
}

#pragma mark - Private: Parse (plist)

- (NSArray<NSDictionary *> *)parseFoldersFromPlistData:(NSData *)data error:(NSError **)error {
    NSError *plistError = nil;
    NSPropertyListFormat plistFormat = NSPropertyListXMLFormat_v1_0;
    id rootObject = [NSPropertyListSerialization propertyListWithData:data
                                                              options:NSPropertyListMutableContainersAndLeaves
                                                               format:&plistFormat
                                                                error:&plistError];
    if (rootObject == nil) {
        if (error != NULL) {
            *error = plistError;
        }
        return nil;
    }
    if (![self validateRevclipPlistMetadataFromRootObject:rootObject error:error]) {
        return nil;
    }

    return [self parseFoldersFromPlistRootObject:rootObject error:error];
}

- (NSArray<NSDictionary *> *)parseFoldersFromPlistRootObject:(id)rootObject error:(NSError **)error {
    NSArray *folderObjects = nil;

    if ([rootObject isKindOfClass:[NSDictionary class]]) {
        NSDictionary *rootDictionary = (NSDictionary *)rootObject;
        id foldersValue = rootDictionary[kRCRevclipPlistFoldersKey];
        if ([foldersValue isKindOfClass:[NSArray class]]) {
            folderObjects = (NSArray *)foldersValue;
        }

        if (folderObjects == nil) {
            id snippetsValue = rootDictionary[@"snippets"];
            if ([snippetsValue isKindOfClass:[NSArray class]]) {
                NSArray *snippetArray = (NSArray *)snippetsValue;
                if ([self looksLikeFolderArray:snippetArray]) {
                    folderObjects = snippetArray;
                } else if ([self looksLikeSnippetArray:snippetArray]) {
                    folderObjects = @[@{ @"title": [self stringValueInDictionary:rootDictionary keys:@[@"title", @"name"] defaultValue:kRCImportedFolderTitle],
                                         @"identifier": [self stringValueInDictionary:rootDictionary keys:@[@"identifier", @"id", @"uuid"] defaultValue:@""],
                                         @"enabled": @([self boolValueInDictionary:rootDictionary keys:@[@"enabled", @"enable"] defaultValue:YES]),
                                         @"snippets": snippetArray }];
                }
            }
        }

        if (folderObjects == nil && [self looksLikeFolderObject:rootDictionary]) {
            folderObjects = @[rootDictionary];
        }

        if (folderObjects == nil && [self looksLikeSnippetObject:rootDictionary]) {
            folderObjects = @[@{ @"title": kRCImportedFolderTitle,
                                 @"snippets": @[rootDictionary] }];
        }
    } else if ([rootObject isKindOfClass:[NSArray class]]) {
        NSArray *rootArray = (NSArray *)rootObject;
        if ([self looksLikeFolderArray:rootArray]) {
            folderObjects = rootArray;
        } else if ([self looksLikeSnippetArray:rootArray]) {
            folderObjects = @[@{ @"title": kRCImportedFolderTitle,
                                 @"snippets": rootArray }];
        }
    }

    if (folderObjects == nil) {
        [self assignSnippetError:error
                            code:RCSnippetImportExportErrorInvalidXMLFormat
                     description:NSLocalizedString(@"Plist does not contain supported snippet folders.", nil)
                 underlyingError:nil];
        return nil;
    }

    NSMutableArray<NSDictionary *> *parsedFolders = [NSMutableArray arrayWithCapacity:folderObjects.count];
    for (id folderObject in folderObjects) {
        NSDictionary *folderDictionary = [self parseFolderDictionaryFromPlistObject:folderObject];
        if (folderDictionary != nil) {
            [parsedFolders addObject:folderDictionary];
        }
    }

    return [parsedFolders copy];
}

- (BOOL)validateRevclipPlistMetadataFromRootObject:(id)rootObject error:(NSError **)error {
    if (![rootObject isKindOfClass:[NSDictionary class]]) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorInvalidXMLFormat
                            description:NSLocalizedString(@"Snippets plist root must be a dictionary.", nil)
                        underlyingError:nil];
    }

    NSDictionary *rootDictionary = (NSDictionary *)rootObject;

    id formatValue = rootDictionary[kRCRevclipPlistFormatKey];
    if (![formatValue isKindOfClass:[NSString class]]
        || ![(NSString *)formatValue isEqualToString:kRCRevclipPlistFormatValue]) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorMissingRequiredElement
                            description:NSLocalizedString(@"Snippets format identifier is missing or invalid.", nil)
                        underlyingError:nil];
    }

    NSNumber *versionNumber = [self plistVersionNumberFromValue:rootDictionary[kRCRevclipPlistVersionKey]];
    if (versionNumber == nil) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorMissingRequiredElement
                            description:NSLocalizedString(@"Snippets format version is missing or invalid.", nil)
                        underlyingError:nil];
    }

    if (versionNumber.integerValue != kRCRevclipSupportedPlistVersion) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorInvalidXMLFormat
                            description:NSLocalizedString(@"Unsupported snippets format version.", nil)
                        underlyingError:nil];
    }

    return YES;
}

- (NSNumber *)plistVersionNumberFromValue:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)value;
    }

    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString *versionString = [self trimmedString:(NSString *)value];
    if (versionString.length == 0) {
        return nil;
    }

    NSScanner *scanner = [NSScanner scannerWithString:versionString];
    NSInteger version = 0;
    if (![scanner scanInteger:&version] || !scanner.isAtEnd) {
        return nil;
    }

    return @(version);
}

- (NSDictionary *)parseFolderDictionaryFromPlistObject:(id)object {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    NSString *title = [self stringValueInDictionary:dictionary keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Folder", nil)];
    NSString *identifier = [self stringValueInDictionary:dictionary keys:@[@"identifier", @"id", @"uuid", @"folder_id", @"folderId"] defaultValue:@""];
    BOOL enabled = [self boolValueInDictionary:dictionary keys:@[@"enabled", @"enable"] defaultValue:YES];

    NSArray *snippetObjects = [self arrayValueInDictionary:dictionary keys:@[@"snippets", @"items", @"children"]];
    NSMutableArray<NSDictionary *> *snippets = [NSMutableArray arrayWithCapacity:snippetObjects.count];
    for (id snippetObject in snippetObjects) {
        NSDictionary *snippetDictionary = [self parseSnippetDictionaryFromPlistObject:snippetObject];
        if (snippetDictionary != nil) {
            [snippets addObject:snippetDictionary];
        }
    }

    return @{
        @"identifier": [self trimmedString:identifier],
        @"title": title,
        @"enabled": @(enabled),
        @"snippets": [snippets copy],
    };
}

- (NSDictionary *)parseSnippetDictionaryFromPlistObject:(id)object {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    NSString *title = [self stringValueInDictionary:dictionary keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Snippet", nil)];
    NSString *content = [self stringValueInDictionary:dictionary keys:@[@"content", @"text", @"value", @"string"] defaultValue:@""];
    NSString *identifier = [self stringValueInDictionary:dictionary keys:@[@"identifier", @"id", @"uuid", @"snippet_id", @"snippetId"] defaultValue:@""];
    BOOL enabled = [self boolValueInDictionary:dictionary keys:@[@"enabled", @"enable"] defaultValue:YES];

    return @{
        @"identifier": [self trimmedString:identifier],
        @"title": title,
        @"content": content,
        @"enabled": @(enabled),
    };
}

- (BOOL)looksLikeFolderObject:(id)object {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    id snippets = dictionary[@"snippets"] ?: dictionary[@"items"] ?: dictionary[@"children"];
    return [snippets isKindOfClass:[NSArray class]];
}

- (BOOL)looksLikeSnippetObject:(id)object {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    BOOL hasContent = ([dictionary[@"content"] isKindOfClass:[NSString class]]
                    || [dictionary[@"text"] isKindOfClass:[NSString class]]
                    || [dictionary[@"value"] isKindOfClass:[NSString class]]
                    || [dictionary[@"string"] isKindOfClass:[NSString class]]);
    BOOL hasTitle = [dictionary[@"title"] isKindOfClass:[NSString class]] || [dictionary[@"name"] isKindOfClass:[NSString class]];
    BOOL hasNestedList = ([dictionary[@"snippets"] isKindOfClass:[NSArray class]]
                       || [dictionary[@"items"] isKindOfClass:[NSArray class]]
                       || [dictionary[@"children"] isKindOfClass:[NSArray class]]);
    return !hasNestedList && (hasContent || hasTitle);
}

- (BOOL)looksLikeFolderArray:(NSArray *)objects {
    if (objects.count == 0) {
        return YES;
    }

    for (id object in objects) {
        if (![self looksLikeFolderObject:object]) {
            return NO;
        }
    }

    return YES;
}

- (BOOL)looksLikeSnippetArray:(NSArray *)objects {
    if (objects.count == 0) {
        return NO;
    }

    for (id object in objects) {
        if (![self looksLikeSnippetObject:object]) {
            return NO;
        }
    }

    return YES;
}

- (BOOL)validateImportLimitsForFolders:(NSArray<NSDictionary *> *)folders error:(NSError **)error {
    if (folders.count > kRCMaxImportFolderCount) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorInvalidXMLFormat
                            description:NSLocalizedString(@"Imported folder count exceeds the maximum supported limit (100).", nil)
                        underlyingError:nil];
    }

    NSInteger snippetCount = 0;
    for (NSDictionary *folder in folders) {
        NSString *folderTitle = [self stringValueInDictionary:folder keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Folder", nil)];
        if (folderTitle.length > kRCMaxImportTitleLength) {
            return [self assignSnippetError:error
                                       code:RCSnippetImportExportErrorInvalidXMLFormat
                                description:NSLocalizedString(@"Folder title exceeds the maximum length (500 characters).", nil)
                            underlyingError:nil];
        }

        NSArray *snippets = [self arrayValueInDictionary:folder keys:@[@"snippets", @"items", @"children"]];
        for (id snippetObject in snippets) {
            if (![snippetObject isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            snippetCount += 1;
            if (snippetCount > kRCMaxImportSnippetCount) {
                return [self assignSnippetError:error
                                           code:RCSnippetImportExportErrorInvalidXMLFormat
                                    description:NSLocalizedString(@"Imported snippet count exceeds the maximum supported limit (10000).", nil)
                                underlyingError:nil];
            }

            NSDictionary *snippet = (NSDictionary *)snippetObject;
            NSString *snippetTitle = [self stringValueInDictionary:snippet keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Snippet", nil)];
            if (snippetTitle.length > kRCMaxImportTitleLength) {
                return [self assignSnippetError:error
                                           code:RCSnippetImportExportErrorInvalidXMLFormat
                                    description:NSLocalizedString(@"Snippet title exceeds the maximum length (500 characters).", nil)
                                underlyingError:nil];
            }

            NSString *snippetContent = [self stringValueInDictionary:snippet
                                                                keys:@[@"content", @"text", @"value", @"string"]
                                                         defaultValue:@""];
            NSData *contentData = [snippetContent dataUsingEncoding:NSUTF8StringEncoding];
            if (contentData.length > kRCMaxImportContentLengthBytes) {
                return [self assignSnippetError:error
                                           code:RCSnippetImportExportErrorInvalidXMLFormat
                                    description:NSLocalizedString(@"Snippet content exceeds the maximum size (1 MB).", nil)
                                underlyingError:nil];
            }
        }
    }

    return YES;
}

#pragma mark - Private: Parse (legacy XML)

- (NSArray<NSDictionary *> *)parseFoldersFromLegacyXMLData:(NSData *)data error:(NSError **)error {
    if ([self containsDisallowedDoctypeInXMLData:data]) {
        [self assignSnippetError:error
                            code:RCSnippetImportExportErrorInvalidXMLFormat
                     description:NSLocalizedString(@"DOCTYPE is not allowed in imported XML.", nil)
                 underlyingError:nil];
        return nil;
    }

    NSError *parseError = nil;
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithData:data
                                                          options:NSXMLNodeLoadExternalEntitiesNever
                                                            error:&parseError];
    if (document == nil) {
        if (error != NULL) {
            *error = parseError;
        }
        return nil;
    }

    NSXMLElement *rootElement = document.rootElement;
    NSString *rootName = rootElement.name ?: @"";
    BOOL isRootSupported = [rootName isEqualToString:kRCClipyXMLRootElement] || [rootName isEqualToString:kRCClipyXMLLegacyRootElement];
    if (!isRootSupported) {
        [self assignSnippetError:error
                            code:RCSnippetImportExportErrorInvalidXMLFormat
                     description:NSLocalizedString(@"Root element must be <folders> or <snippets>.", nil)
                 underlyingError:nil];
        return nil;
    }

    return [self parseFoldersFromLegacyXMLRootElement:rootElement error:error];
}

- (NSArray<NSDictionary *> *)parseFoldersFromLegacyXMLRootElement:(NSXMLElement *)rootElement error:(NSError **)error {
    NSMutableArray<NSDictionary *> *parsedFolders = [NSMutableArray array];

    NSArray<NSXMLElement *> *folderElements = [rootElement elementsForName:kRCClipyXMLFolderElement];
    if (folderElements.count == 0 && [rootElement.name isEqualToString:kRCClipyXMLLegacyRootElement]) {
        folderElements = @[rootElement];
    }

    for (NSXMLElement *folderElement in folderElements) {
        NSString *folderIdentifier = [self trimmedValueForElement:kRCClipyXMLFolderIdentifierElement inElement:folderElement] ?: @"";
        NSString *folderTitle = [self valueForElement:kRCClipyXMLFolderTitleElement inElement:folderElement] ?: NSLocalizedString(@"Untitled Folder", nil);
        BOOL folderEnabled = [self boolValueFromXMLString:[self valueForElement:kRCClipyXMLFolderEnabledElement inElement:folderElement]
                                             defaultValue:YES];

        NSXMLElement *snippetsElement = [self firstChildElementNamed:kRCClipyXMLFolderSnippetsElement inElement:folderElement];
        NSArray<NSXMLElement *> *snippetElements = nil;
        if (snippetsElement != nil) {
            snippetElements = [snippetsElement elementsForName:kRCClipyXMLSnippetElement];
        } else {
            snippetElements = [folderElement elementsForName:kRCClipyXMLSnippetElement];
        }

        NSMutableArray<NSDictionary *> *parsedSnippets = [NSMutableArray arrayWithCapacity:snippetElements.count];
        for (NSXMLElement *snippetElement in snippetElements) {
            NSString *snippetIdentifier = [self trimmedValueForElement:kRCClipyXMLSnippetIdentifierElement inElement:snippetElement] ?: @"";
            NSString *snippetTitle = [self valueForElement:kRCClipyXMLSnippetTitleElement inElement:snippetElement] ?: NSLocalizedString(@"Untitled Snippet", nil);
            NSString *snippetContent = [self valueForElement:kRCClipyXMLSnippetContentElement inElement:snippetElement] ?: @"";
            BOOL snippetEnabled = [self boolValueFromXMLString:[self valueForElement:kRCClipyXMLSnippetEnabledElement inElement:snippetElement]
                                                  defaultValue:YES];

            [parsedSnippets addObject:@{
                @"identifier": snippetIdentifier,
                @"title": snippetTitle,
                @"content": snippetContent,
                @"enabled": @(snippetEnabled),
            }];
        }

        [parsedFolders addObject:@{
            @"identifier": folderIdentifier,
            @"title": folderTitle,
            @"enabled": @(folderEnabled),
            @"snippets": [parsedSnippets copy],
        }];
    }

    return [parsedFolders copy];
}

- (NSXMLElement *)firstChildElementNamed:(NSString *)name inElement:(NSXMLElement *)element {
    NSArray<NSXMLElement *> *elements = [element elementsForName:name];
    return elements.firstObject;
}

- (NSString *)valueForElement:(NSString *)name inElement:(NSXMLElement *)element {
    NSXMLElement *childElement = [self firstChildElementNamed:name inElement:element];
    return childElement.stringValue;
}

- (NSString *)trimmedValueForElement:(NSString *)name inElement:(NSXMLElement *)element {
    return [self trimmedString:[self valueForElement:name inElement:element]];
}

- (BOOL)containsDisallowedDoctypeInXMLData:(NSData *)data {
    if (data.length == 0) {
        return NO;
    }

    NSMutableArray<NSNumber *> *candidateEncodings = [NSMutableArray array];
    NSStringEncoding bomEncoding = RCStringEncodingFromXMLBOM(data);
    if (bomEncoding != 0) {
        [candidateEncodings addObject:@(bomEncoding)];
    }

    NSArray<NSNumber *> *fallbackEncodings = @[
        @(NSUTF8StringEncoding),
        @(NSUTF16LittleEndianStringEncoding),
        @(NSUTF16BigEndianStringEncoding),
        @(NSUTF32BigEndianStringEncoding),
        @(NSUTF32LittleEndianStringEncoding),
        @(NSISOLatin1StringEncoding),
    ];
    for (NSNumber *encodingNumber in fallbackEncodings) {
        if ([candidateEncodings containsObject:encodingNumber]) {
            continue;
        }
        [candidateEncodings addObject:encodingNumber];
    }

    for (NSNumber *encodingNumber in candidateEncodings) {
        NSString *decodedString = [[NSString alloc] initWithData:data
                                                        encoding:(NSStringEncoding)encodingNumber.unsignedIntegerValue];
        if (decodedString.length == 0) {
            continue;
        }

        if ([decodedString rangeOfString:@"<!doctype" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - Private: Persist

- (BOOL)persistParsedFolders:(NSArray<NSDictionary *> *)folders merge:(BOOL)merge error:(NSError **)error {
    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    NSArray<NSDictionary *> *existingFolders = merge ? [databaseManager fetchSnippetCatalog] : @[];
    if (existingFolders == nil) {
        return [self assignSnippetError:error code:RCSnippetImportExportErrorDatabase
                            description:NSLocalizedString(@"Failed to read snippets.", nil) underlyingError:nil];
    }

    NSMutableSet<NSString *> *usedFolderIdentifiers = [NSMutableSet set];
    NSMutableSet<NSString *> *usedSnippetIdentifiers = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *snippetSignaturesByFolderIdentifier = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *nextSnippetIndexByFolderIdentifier = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *snippetsToInsertByFolderIdentifier = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *existingFolderIdentifierByTitle = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *newFoldersToInsert = [NSMutableArray array];
    NSMutableArray<NSString *> *folderInsertionOrder = [NSMutableArray array];

    NSInteger nextFolderIndex = 0;

    for (NSDictionary *existingFolder in existingFolders) {
        NSString *folderIdentifier = [self trimmedString:[self stringValueInDictionary:existingFolder keys:@[@"identifier"] defaultValue:@""]];
        if (folderIdentifier.length == 0) {
            continue;
        }

        [usedFolderIdentifiers addObject:folderIdentifier];
        [folderInsertionOrder addObject:folderIdentifier];

        NSInteger existingFolderIndex = [self integerValueInDictionary:existingFolder keys:@[@"folder_index", @"folderIndex", @"index"] defaultValue:0];
        if (existingFolderIndex >= nextFolderIndex) {
            nextFolderIndex = existingFolderIndex + 1;
        }

        NSString *normalizedTitle = [self normalizedLookupString:[self stringValueInDictionary:existingFolder keys:@[@"title", @"name"] defaultValue:@""]];
        if (normalizedTitle.length > 0 && existingFolderIdentifierByTitle[normalizedTitle] == nil) {
            existingFolderIdentifierByTitle[normalizedTitle] = folderIdentifier;
        }

        NSArray<NSDictionary *> *existingSnippets = [self arrayValueInDictionary:existingFolder keys:@[@"snippets"]];
        NSInteger nextSnippetIndex = 0;
        NSMutableSet<NSString *> *existingSignatures = [NSMutableSet setWithCapacity:existingSnippets.count];

        for (NSDictionary *existingSnippet in existingSnippets) {
            NSString *snippetIdentifier = [self trimmedString:[self stringValueInDictionary:existingSnippet keys:@[@"identifier"] defaultValue:@""]];
            if (snippetIdentifier.length > 0) {
                [usedSnippetIdentifiers addObject:snippetIdentifier];
            }

            NSString *signature = [self snippetSignatureWithTitle:[self stringValueInDictionary:existingSnippet keys:@[@"title", @"name"] defaultValue:@""]
                                                          content:[self stringValueInDictionary:existingSnippet keys:@[@"content", @"text", @"value"] defaultValue:@""]];
            [existingSignatures addObject:signature];

            NSInteger snippetIndex = [self integerValueInDictionary:existingSnippet keys:@[@"snippet_index", @"snippetIndex", @"index"] defaultValue:0];
            if (snippetIndex >= nextSnippetIndex) {
                nextSnippetIndex = snippetIndex + 1;
            }
        }

        snippetSignaturesByFolderIdentifier[folderIdentifier] = existingSignatures;
        nextSnippetIndexByFolderIdentifier[folderIdentifier] = @(nextSnippetIndex);
        snippetsToInsertByFolderIdentifier[folderIdentifier] = [NSMutableArray array];
    }

    for (NSDictionary *parsedFolder in folders) {
        NSString *folderTitle = [self stringValueInDictionary:parsedFolder keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Folder", nil)];
        BOOL folderEnabled = [self boolValueInDictionary:parsedFolder keys:@[@"enabled", @"enable"] defaultValue:YES];
        NSString *folderIdentifier = [self trimmedString:[self stringValueInDictionary:parsedFolder keys:@[@"identifier", @"id", @"uuid"] defaultValue:@""]];

        NSString *targetFolderIdentifier = nil;
        BOOL isExistingFolder = NO;

        if (merge && folderIdentifier.length > 0 && [usedFolderIdentifiers containsObject:folderIdentifier]) {
            targetFolderIdentifier = folderIdentifier;
            isExistingFolder = YES;
        }

        // Only allow title-based merge when imported data does not provide an identifier.
        if (merge && !isExistingFolder && folderIdentifier.length == 0) {
            NSString *normalizedTitle = [self normalizedLookupString:folderTitle];
            NSString *existingFolderIdentifier = existingFolderIdentifierByTitle[normalizedTitle];
            if (existingFolderIdentifier.length > 0) {
                targetFolderIdentifier = existingFolderIdentifier;
                isExistingFolder = YES;
            }
        }

        if (!isExistingFolder) {
            if (folderIdentifier.length == 0 || [usedFolderIdentifiers containsObject:folderIdentifier]) {
                folderIdentifier = [self uniqueIdentifierExcludingMutableSet:usedFolderIdentifiers];
            } else {
                [usedFolderIdentifiers addObject:folderIdentifier];
            }

            targetFolderIdentifier = folderIdentifier;
            NSString *normalizedTitle = [self normalizedLookupString:folderTitle];
            if (normalizedTitle.length > 0 && existingFolderIdentifierByTitle[normalizedTitle] == nil) {
                existingFolderIdentifierByTitle[normalizedTitle] = targetFolderIdentifier;
            }

            if (snippetSignaturesByFolderIdentifier[targetFolderIdentifier] == nil) {
                snippetSignaturesByFolderIdentifier[targetFolderIdentifier] = [NSMutableSet set];
            }
            if (nextSnippetIndexByFolderIdentifier[targetFolderIdentifier] == nil) {
                nextSnippetIndexByFolderIdentifier[targetFolderIdentifier] = @0;
            }
            if (snippetsToInsertByFolderIdentifier[targetFolderIdentifier] == nil) {
                snippetsToInsertByFolderIdentifier[targetFolderIdentifier] = [NSMutableArray array];
            }

            [folderInsertionOrder addObject:targetFolderIdentifier];
            [newFoldersToInsert addObject:@{
                @"identifier": targetFolderIdentifier,
                @"folder_index": @(nextFolderIndex),
                @"enabled": @(folderEnabled),
                @"title": folderTitle,
            }];
            nextFolderIndex += 1;
        }

        NSMutableSet<NSString *> *signatureSet = snippetSignaturesByFolderIdentifier[targetFolderIdentifier];
        if (signatureSet == nil) {
            signatureSet = [NSMutableSet set];
            snippetSignaturesByFolderIdentifier[targetFolderIdentifier] = signatureSet;
        }

        NSMutableArray<NSDictionary *> *snippetsToInsert = snippetsToInsertByFolderIdentifier[targetFolderIdentifier];
        if (snippetsToInsert == nil) {
            snippetsToInsert = [NSMutableArray array];
            snippetsToInsertByFolderIdentifier[targetFolderIdentifier] = snippetsToInsert;
        }

        NSInteger nextSnippetIndex = [nextSnippetIndexByFolderIdentifier[targetFolderIdentifier] integerValue];
        NSArray *parsedSnippets = [self arrayValueInDictionary:parsedFolder keys:@[@"snippets", @"items", @"children"]];

        for (id parsedSnippetObject in parsedSnippets) {
            if (![parsedSnippetObject isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            NSDictionary *parsedSnippet = (NSDictionary *)parsedSnippetObject;
            NSString *snippetTitle = [self stringValueInDictionary:parsedSnippet keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Snippet", nil)];
            NSString *snippetContent = [self stringValueInDictionary:parsedSnippet keys:@[@"content", @"text", @"value", @"string"] defaultValue:@""];
            BOOL snippetEnabled = [self boolValueInDictionary:parsedSnippet keys:@[@"enabled", @"enable"] defaultValue:YES];

            NSString *signature = [self snippetSignatureWithTitle:snippetTitle content:snippetContent];
            if ([signatureSet containsObject:signature]) {
                continue;
            }

            NSString *snippetIdentifier = [self trimmedString:[self stringValueInDictionary:parsedSnippet
                                                                                        keys:@[@"identifier", @"id", @"uuid", @"snippet_id", @"snippetId"]
                                                                                 defaultValue:@""]];
            if (snippetIdentifier.length == 0 || [usedSnippetIdentifiers containsObject:snippetIdentifier]) {
                snippetIdentifier = [self uniqueIdentifierExcludingMutableSet:usedSnippetIdentifiers];
            } else {
                [usedSnippetIdentifiers addObject:snippetIdentifier];
            }

            NSDictionary *snippetDictionary = @{
                @"identifier": snippetIdentifier,
                @"folder_id": targetFolderIdentifier,
                @"snippet_index": @(nextSnippetIndex),
                @"enabled": @(snippetEnabled),
                @"title": snippetTitle,
                @"content": snippetContent,
            };
            [snippetsToInsert addObject:snippetDictionary];
            [signatureSet addObject:signature];
            nextSnippetIndex += 1;
        }

        nextSnippetIndexByFolderIdentifier[targetFolderIdentifier] = @(nextSnippetIndex);
    }

    __block NSError *transactionError = nil;
    BOOL persisted = [databaseManager performTransaction:^BOOL(FMDatabase *db, BOOL *rollback) {
        if (!merge) {
            BOOL deletedSnippets = [db executeUpdate:@"DELETE FROM snippets"];
            if (!deletedSnippets) {
                transactionError = [self databaseErrorFromDatabase:db fallbackDescription:NSLocalizedString(@"Failed to delete all snippets.", nil)];
                *rollback = YES;
                return NO;
            }

            BOOL deleted = [db executeUpdate:@"DELETE FROM snippet_folders"];
            if (!deleted) {
                transactionError = [self databaseErrorFromDatabase:db fallbackDescription:NSLocalizedString(@"Failed to delete all snippet folders.", nil)];
                *rollback = YES;
                return NO;
            }
        }

        for (NSDictionary *folderDictionary in newFoldersToInsert) {
            BOOL insertedFolder = [db executeUpdate:@"INSERT INTO snippet_folders (identifier, folder_index, enabled, title) VALUES (?, ?, ?, ?)"
                               withArgumentsInArray:@[
                                   [self stringValueInDictionary:folderDictionary keys:@[@"identifier"] defaultValue:@""],
                                   folderDictionary[@"folder_index"] ?: @0,
                                   folderDictionary[@"enabled"] ?: @1,
                                   [self stringValueInDictionary:folderDictionary keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Folder", nil)],
                               ]];
            if (!insertedFolder) {
                transactionError = [self databaseErrorFromDatabase:db fallbackDescription:NSLocalizedString(@"Failed to insert snippet folder.", nil)];
                *rollback = YES;
                return NO;
            }
        }

        for (NSString *folderIdentifier in folderInsertionOrder) {
            NSArray<NSDictionary *> *snippetsToInsert = snippetsToInsertByFolderIdentifier[folderIdentifier];
            for (NSDictionary *snippetDictionary in snippetsToInsert) {
                BOOL insertedSnippet = [db executeUpdate:@"INSERT INTO snippets (identifier, folder_id, snippet_index, enabled, title, content) VALUES (?, ?, ?, ?, ?, ?)"
                                    withArgumentsInArray:@[
                                        [self stringValueInDictionary:snippetDictionary keys:@[@"identifier"] defaultValue:@""],
                                        [self stringValueInDictionary:snippetDictionary keys:@[@"folder_id", @"folderId"] defaultValue:@""],
                                        snippetDictionary[@"snippet_index"] ?: @0,
                                        snippetDictionary[@"enabled"] ?: @1,
                                        [self stringValueInDictionary:snippetDictionary keys:@[@"title", @"name"] defaultValue:NSLocalizedString(@"Untitled Snippet", nil)],
                                        [self stringValueInDictionary:snippetDictionary keys:@[@"content", @"text", @"value"] defaultValue:@""],
                                    ]];
                if (!insertedSnippet) {
                    transactionError = [self databaseErrorFromDatabase:db fallbackDescription:NSLocalizedString(@"Failed to insert snippet.", nil)];
                    *rollback = YES;
                    return NO;
                }
            }
        }

        return YES;
    }];

    if (!persisted) {
        return [self assignSnippetError:error
                                   code:RCSnippetImportExportErrorDatabase
                            description:NSLocalizedString(@"Failed to persist imported snippets.", nil)
                        underlyingError:transactionError];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:RCSnippetsDidChangeNotification object:nil];
    return YES;
}

- (NSError *)databaseErrorFromDatabase:(FMDatabase *)db fallbackDescription:(NSString *)description {
    NSString *message = description.length > 0 ? description : NSLocalizedString(@"Database operation failed.", nil);
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (db.lastError != nil) {
        userInfo[NSUnderlyingErrorKey] = db.lastError;
    }
    return [NSError errorWithDomain:@"com.revclip.database"
                               code:db.lastErrorCode
                           userInfo:userInfo];
}

#pragma mark - Private: Dictionary helpers

- (id)nonNullValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if (value != nil && value != [NSNull null]) {
            return value;
        }
    }

    return nil;
}

- (NSString *)stringValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys defaultValue:(NSString *)defaultValue {
    id rawValue = [self nonNullValueInDictionary:dictionary keys:keys];
    if ([rawValue isKindOfClass:[NSString class]]) {
        return (NSString *)rawValue;
    }
    if ([rawValue respondsToSelector:@selector(stringValue)]) {
        return [rawValue stringValue];
    }

    return defaultValue ?: @"";
}

- (NSInteger)integerValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys defaultValue:(NSInteger)defaultValue {
    id rawValue = [self nonNullValueInDictionary:dictionary keys:keys];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)rawValue integerValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue integerValue];
    }

    return defaultValue;
}

- (BOOL)boolValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys defaultValue:(BOOL)defaultValue {
    id rawValue = [self nonNullValueInDictionary:dictionary keys:keys];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)rawValue boolValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [self boolValueFromXMLString:(NSString *)rawValue defaultValue:defaultValue];
    }

    return defaultValue;
}

- (NSArray *)arrayValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    id rawValue = [self nonNullValueInDictionary:dictionary keys:keys];
    if ([rawValue isKindOfClass:[NSArray class]]) {
        return (NSArray *)rawValue;
    }

    return @[];
}

#pragma mark - Private: Generic helpers

- (BOOL)boolValueFromXMLString:(NSString *)value defaultValue:(BOOL)defaultValue {
    NSString *normalized = [[value ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([normalized isEqualToString:@"true"] || [normalized isEqualToString:@"yes"] || [normalized isEqualToString:@"1"]) {
        return YES;
    }
    if ([normalized isEqualToString:@"false"] || [normalized isEqualToString:@"no"] || [normalized isEqualToString:@"0"]) {
        return NO;
    }

    return defaultValue;
}

- (NSString *)trimmedString:(NSString *)value {
    return [[value ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
}

- (NSString *)normalizedLookupString:(NSString *)value {
    return [[self trimmedString:value] lowercaseString];
}

- (NSString *)snippetSignatureWithTitle:(NSString *)title content:(NSString *)content {
    NSString *normalizedTitle = [self normalizedLookupString:title];
    NSString *normalizedContent = [self normalizedLookupString:content];
    return [NSString stringWithFormat:@"%@\n%@", normalizedTitle, normalizedContent];
}

- (NSString *)uniqueIdentifierExcludingMutableSet:(NSMutableSet<NSString *> *)reservedIdentifiers {
    NSString *identifier = [NSUUID UUID].UUIDString;
    while ([reservedIdentifiers containsObject:identifier]) {
        identifier = [NSUUID UUID].UUIDString;
    }
    [reservedIdentifiers addObject:identifier];
    return identifier;
}

- (NSString *)iso8601TimestampString {
    if (@available(macOS 10.12, *)) {
        NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        return [formatter stringFromDate:[NSDate date]];
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

#pragma mark - Private: Error

- (NSError *)snippetErrorWithCode:(RCSnippetImportExportErrorCode)code
                       description:(NSString *)description
                   underlyingError:(NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (description.length > 0) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }

    return [NSError errorWithDomain:RCSnippetImportExportErrorDomain code:code userInfo:[userInfo copy]];
}

- (BOOL)assignSnippetError:(NSError **)error
                      code:(RCSnippetImportExportErrorCode)code
               description:(NSString *)description
           underlyingError:(NSError *)underlyingError {
    if (error != NULL) {
        *error = [self snippetErrorWithCode:code description:description underlyingError:underlyingError];
    }

    return NO;
}

@end
