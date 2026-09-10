//
//  RCClipData.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class NSPasteboard;

@interface RCClipData : NSObject <NSSecureCoding>

// クリップボードのタイプ別データ
@property (nonatomic, copy, nullable) NSString *stringValue;            // NSPasteboardTypeString
@property (nonatomic, copy, nullable) NSData *RTFData;                   // NSPasteboardTypeRTF
@property (nonatomic, copy, nullable) NSData *RTFDData;                  // NSPasteboardTypeRTFD
@property (nonatomic, copy, nullable) NSData *PDFData;                   // NSPasteboardTypePDF
@property (nonatomic, copy, nullable) NSArray<NSString *> *fileNames;    // NSFilenamesPboardType
@property (nonatomic, copy, nullable) NSArray<NSURL *> *fileURLs;        // NSPasteboardTypeFileURL
@property (nonatomic, copy, nullable) NSString *URLString;               // NSPasteboardTypeURL
@property (nonatomic, copy, nullable) NSData *TIFFData;                  // NSPasteboardTypeTIFF

// プライマリタイプ
@property (nonatomic, copy, nullable) NSString *primaryType;

// NSPasteboardからの作成
+ (instancetype)clipDataFromPasteboard:(NSPasteboard *)pasteboard;

// データハッシュ生成（SHA256）
- (NSString *)dataHash;

// タイトル文字列（メニュー表示用）
- (NSString *)title;

// NSPasteboardへの書き戻し
- (BOOL)writeToPasteboard:(NSPasteboard *)pasteboard;

// ファイル保存・読み込み
- (BOOL)saveToPath:(NSString *)path;
// Reject archives larger than the limit before writing; serialize only once.
- (BOOL)saveToPath:(NSString *)path maximumArchiveSize:(NSUInteger)maximumArchiveSize;
+ (nullable instancetype)clipDataFromPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
