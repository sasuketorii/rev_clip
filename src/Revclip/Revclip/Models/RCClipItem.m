//
//  RCClipItem.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCClipItem.h"

static id RCNonNullValueForKeys(NSDictionary *dictionary, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if (value != nil && value != [NSNull null]) {
            return value;
        }
    }
    return nil;
}

static NSString *RCStringValueForKeys(NSDictionary *dictionary, NSArray<NSString *> *keys, NSString *defaultValue) {
    id rawValue = RCNonNullValueForKeys(dictionary, keys);
    if (rawValue == nil) {
        return defaultValue;
    }

    if ([rawValue isKindOfClass:[NSString class]]) {
        return rawValue;
    }

    if ([rawValue respondsToSelector:@selector(stringValue)]) {
        return [rawValue stringValue];
    }

    return defaultValue;
}

static NSInteger RCIntegerValueForKeys(NSDictionary *dictionary, NSArray<NSString *> *keys, NSInteger defaultValue) {
    id rawValue = RCNonNullValueForKeys(dictionary, keys);
    if (rawValue == nil) {
        return defaultValue;
    }

    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue integerValue];
    }

    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue integerValue];
    }

    return defaultValue;
}

static BOOL RCBoolValueForKeys(NSDictionary *dictionary, NSArray<NSString *> *keys, BOOL defaultValue) {
    id rawValue = RCNonNullValueForKeys(dictionary, keys);
    if (rawValue == nil) {
        return defaultValue;
    }

    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue boolValue];
    }

    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue boolValue];
    }

    return defaultValue;
}

@implementation RCClipItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _itemId = 0;
        _dataPath = @"";
        _title = @"";
        _dataHash = @"";
        _primaryType = @"";
        _updateTime = 0;
        _thumbnailPath = @"";
        _isColorCode = NO;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [self init];
    if (self) {
        self.itemId = RCIntegerValueForKeys(dict, @[@"id", @"itemId"], 0);
        self.dataPath = RCStringValueForKeys(dict, @[@"data_path", @"dataPath"], @"");
        self.title = RCStringValueForKeys(dict, @[@"title"], @"");
        self.dataHash = RCStringValueForKeys(dict, @[@"data_hash", @"dataHash"], @"");
        self.primaryType = RCStringValueForKeys(dict, @[@"primary_type", @"primaryType"], @"");
        self.updateTime = RCIntegerValueForKeys(dict, @[@"update_time", @"updateTime"], 0);
        self.thumbnailPath = RCStringValueForKeys(dict, @[@"thumbnail_path", @"thumbnailPath"], @"");
        self.isColorCode = RCBoolValueForKeys(dict, @[@"is_color_code", @"isColorCode"], NO);
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[RCClipItem class]]) {
        return NO;
    }
    RCClipItem *other = (RCClipItem *)object;
    BOOL selfPersisted = (self.itemId > 0);
    BOOL otherPersisted = (other.itemId > 0);

    if (selfPersisted || otherPersisted) {
        return selfPersisted && otherPersisted && self.itemId == other.itemId;
    }

    if (self.dataHash.length == 0 || other.dataHash.length == 0) {
        return NO;
    }

    return [self.dataHash isEqualToString:other.dataHash];
}

- (NSUInteger)hash {
    if (self.itemId > 0) {
        return (NSUInteger)self.itemId;
    }
    if (self.dataHash.length > 0) {
        return self.dataHash.hash;
    }
    return [super hash];
}

- (NSDictionary *)toDictionary {
    return @{
        @"id": @(self.itemId),
        @"data_path": self.dataPath ?: @"",
        @"title": self.title ?: @"",
        @"data_hash": self.dataHash ?: @"",
        @"primary_type": self.primaryType ?: @"",
        @"update_time": @(self.updateTime),
        @"thumbnail_path": self.thumbnailPath ?: @"",
        @"is_color_code": @(self.isColorCode),
    };
}

@end
