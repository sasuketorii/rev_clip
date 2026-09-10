//
//  RCLoginItemService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RCLoginItemStatus) {
    RCLoginItemStatusEnabled = 0,
    RCLoginItemStatusRequiresApproval = 1,
    RCLoginItemStatusNotRegistered = 2,
    RCLoginItemStatusNotFound = 3,
};

@interface RCLoginItemService : NSObject

+ (instancetype)shared;

// ログインアイテムの状態
@property (nonatomic, readonly, getter=isLoginItemEnabled) BOOL loginItemEnabled;
@property (nonatomic, readonly) RCLoginItemStatus loginItemStatus;

// ログインアイテムの有効/無効切り替え
- (BOOL)setLoginItemEnabled:(BOOL)enabled;
- (BOOL)setLoginItemEnabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
