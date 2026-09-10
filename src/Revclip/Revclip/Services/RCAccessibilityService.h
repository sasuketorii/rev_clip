//
//  RCAccessibilityService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>

@interface RCAccessibilityService : NSObject

+ (instancetype)shared;

// Accessibility権限の確認
- (BOOL)isAccessibilityEnabled;

// Accessibility権限の要求（システムダイアログを表示）
- (void)requestAccessibilityPermission;

// 権限チェック + 未付与時にガイダンスアラート表示
- (void)checkAndRequestAccessibilityWithAlert;

@end
