//
//  RCEnvironment.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCEnvironment.h"

@implementation RCEnvironment

+ (instancetype)shared {
    static RCEnvironment *sharedEnvironment = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedEnvironment = [[RCEnvironment alloc] init];
    });
    return sharedEnvironment;
}

@end
