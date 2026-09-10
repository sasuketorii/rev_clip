//
//  RCDatabaseManager.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FMDatabase;
@class RCClipItem;

@interface RCDatabaseManager : NSObject

+ (instancetype)shared;

// データベースパス: ~/Library/Application Support/Revclip/revclip.db
@property (nonatomic, readonly) NSString *databasePath;

// 初期化・マイグレーション
- (BOOL)setupDatabase;
- (NSInteger)currentSchemaVersion;
- (BOOL)migrateIfNeeded;
- (BOOL)performDatabaseOperation:(BOOL (^)(FMDatabase *db))block;
- (BOOL)performTransaction:(BOOL (^)(FMDatabase *db, BOOL *rollback))block;
- (void)closeDatabase;
- (void)deleteDatabaseFiles;
- (void)reinitializeDatabase;

// clip_items CRUD
- (BOOL)insertClipItem:(NSDictionary *)clipDict;
- (BOOL)updateClipItemUpdateTime:(NSString *)dataHash time:(NSInteger)updateTime;
- (BOOL)deleteClipItemWithDataHash:(NSString *)dataHash;
- (BOOL)deleteClipItemWithDataHash:(NSString *)dataHash olderThan:(NSInteger)updateTimeMs;
- (BOOL)deleteClipItemsOlderThan:(NSInteger)updateTime;
- (NSArray<RCClipItem *> *)clipItemsOlderThan:(NSInteger)updateTimeMs;
- (NSArray *)fetchClipItemsWithLimit:(NSInteger)limit;
- (nullable NSDictionary *)clipItemWithDataHash:(NSString *)dataHash;
- (NSInteger)clipItemCount;

// snippet_folders CRUD
- (BOOL)insertSnippetFolder:(NSDictionary *)folderDict;
- (BOOL)updateSnippetFolder:(NSDictionary *)folderDict;
- (BOOL)updateSnippetFolder:(NSString *)identifier withDict:(NSDictionary *)dict;
- (BOOL)deleteSnippetFolder:(NSString *)identifier;
- (BOOL)deleteAllSnippetFolders;
- (NSArray *)fetchAllSnippetFolders;
// nil means a read failure; an empty array means a successfully read empty catalog.
- (nullable NSArray<NSDictionary *> *)fetchSnippetCatalog;
- (BOOL)snippetFolderExistsWithIdentifier:(NSString *)identifier;
- (BOOL)updateSnippetFolderIndexes:(NSArray<NSString *> *)identifiers;
- (BOOL)updateSnippetPlacement:(NSArray<NSDictionary *> *)placements;

// snippets CRUD
- (BOOL)insertSnippet:(NSDictionary *)snippetDict;
- (BOOL)insertSnippet:(NSDictionary *)snippetDict inFolder:(NSString *)folderIdentifier;
- (BOOL)updateSnippet:(NSDictionary *)snippetDict;
- (BOOL)updateSnippet:(NSString *)identifier withDict:(NSDictionary *)dict;
- (BOOL)deleteSnippet:(NSString *)identifier;
- (NSArray *)fetchSnippetsForFolder:(NSString *)folderIdentifier;
- (BOOL)snippetExistsWithIdentifier:(NSString *)identifier;
- (BOOL)deleteAllClipItems;
- (BOOL)deleteAllSnippets;

/// Panic-only: delete all clip items bypassing isPanicInProgress guard.
/// Must only be called from RCPanicEraseService during panic sequence.
- (BOOL)panicDeleteAllClipItems;

/// Panic-only: delete all snippets bypassing isPanicInProgress guard.
/// Must only be called from RCPanicEraseService during panic sequence.
- (BOOL)panicDeleteAllSnippets;

@end

NS_ASSUME_NONNULL_END
