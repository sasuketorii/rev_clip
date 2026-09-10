//
//  RCSnippetImportExportService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const RCSnippetImportExportErrorDomain;

typedef NS_ENUM(NSInteger, RCSnippetImportExportErrorCode) {
    RCSnippetImportExportErrorFileRead = 1001,
    RCSnippetImportExportErrorInvalidXMLFormat = 1002,
    RCSnippetImportExportErrorMissingRequiredElement = 1003,
    RCSnippetImportExportErrorFileWrite = 1004,
    RCSnippetImportExportErrorDatabase = 1005,
};

@interface RCSnippetImportExportService : NSObject

+ (instancetype)shared;

// Export
- (BOOL)exportSnippetsToURL:(NSURL *)fileURL error:(NSError **)error;
- (nullable NSData *)exportSnippetsAsXMLData:(NSError **)error;
- (BOOL)exportFolders:(NSArray<NSDictionary *> *)folders
                 toURL:(NSURL *)fileURL
                 error:(NSError **)error;
- (nullable NSData *)exportFoldersAsXMLData:(NSArray<NSDictionary *> *)folders
                                      error:(NSError **)error;

// Import
- (BOOL)importSnippetsFromURL:(NSURL *)fileURL
                        merge:(BOOL)merge
                        error:(NSError **)error;
- (BOOL)importSnippetsFromData:(NSData *)data
                         merge:(BOOL)merge
                         error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
