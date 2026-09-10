//
//  RCClipItem.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCClipItem : NSObject

@property (nonatomic, assign) NSInteger itemId;
@property (nonatomic, copy) NSString *dataPath;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *dataHash;
@property (nonatomic, copy) NSString *primaryType;
@property (nonatomic, assign) NSInteger updateTime;
@property (nonatomic, copy) NSString *thumbnailPath;
@property (nonatomic, assign) BOOL isColorCode;

// NSDictionaryからの初期化
- (instancetype)initWithDictionary:(NSDictionary *)dict;
// NSDictionaryへの変換
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END
