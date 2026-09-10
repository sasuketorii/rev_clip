//
//  RCLoginItemService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCLoginItemService.h"

#import <ServiceManagement/ServiceManagement.h>

@implementation RCLoginItemService

+ (instancetype)shared {
    static RCLoginItemService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (RCLoginItemStatus)loginItemStatus {
    SMAppServiceStatus status = [SMAppService mainAppService].status;
    switch (status) {
        case SMAppServiceStatusEnabled:
            return RCLoginItemStatusEnabled;
        case SMAppServiceStatusRequiresApproval:
            return RCLoginItemStatusRequiresApproval;
        case SMAppServiceStatusNotFound:
            return RCLoginItemStatusNotFound;
        case SMAppServiceStatusNotRegistered:
        default:
            return RCLoginItemStatusNotRegistered;
    }
}

- (BOOL)isLoginItemEnabled {
    return (self.loginItemStatus == RCLoginItemStatusEnabled);
}

- (BOOL)setLoginItemEnabled:(BOOL)enabled {
    return [self setLoginItemEnabled:enabled error:nil];
}

- (BOOL)setLoginItemEnabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error {
    SMAppService *service = [SMAppService mainAppService];
    NSError *operationError = nil;
    BOOL success = NO;

    if (enabled) {
        success = [service registerAndReturnError:&operationError];
    } else {
        success = [service unregisterAndReturnError:&operationError];
    }

    if (error != NULL) {
        *error = operationError;
    }

    if (!success) {
        NSLog(@"[RCLoginItemService] Failed to %@ login item: %@",
              enabled ? @"enable" : @"disable",
              operationError.localizedDescription ?: @"Unknown error");
    }

    return success;
}

@end
