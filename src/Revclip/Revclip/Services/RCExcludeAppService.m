//
//  RCExcludeAppService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCExcludeAppService.h"

#import <Cocoa/Cocoa.h>

#import "RCConstants.h"

@interface RCExcludeAppService ()

@property (nonatomic, strong) NSUserDefaults *userDefaults;

- (nullable NSString *)bundleIdentifierFromStoredEntry:(id)entry;

@end

@implementation RCExcludeAppService

+ (instancetype)shared {
    static RCExcludeAppService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _userDefaults = [NSUserDefaults standardUserDefaults];
    }
    return self;
}

#pragma mark - Public

- (BOOL)shouldExcludeAppWithBundleIdentifier:(nullable NSString *)bundleID {
    NSString *normalized = [self normalizedBundleIdentifier:bundleID];
    if (normalized.length == 0) {
        normalized = [self normalizedBundleIdentifier:[self fallbackBundleIdentifierFromFrontmostApplication]];
    }
    if (normalized.length == 0) {
        NSLog(@"[RCExcludeAppService] Warning: bundle identifier is unavailable; exclusion check skipped.");
        return NO;
    }

    return [[self excludedBundleIdentifiers] containsObject:normalized];
}

- (BOOL)shouldExcludeCurrentApp {
    NSString *bundleIdentifier = [self frontmostApplicationBundleIdentifier];
    return [self shouldExcludeAppWithBundleIdentifier:bundleIdentifier];
}

- (NSArray<NSString *> *)excludedBundleIdentifiers {
    @synchronized(self) {
        id storedValue = [self.userDefaults objectForKey:kRCExcludeApplications];
        if (storedValue == nil) {
            return @[];
        }

        if (![storedValue isKindOfClass:[NSArray class]]) {
            NSLog(@"[RCExcludeAppService] Warning: Invalid excluded applications defaults type (%@). Resetting to empty array.",
                  NSStringFromClass([storedValue class]));
            [self.userDefaults setObject:@[] forKey:kRCExcludeApplications];
            return @[];
        }

        NSArray *storedEntries = (NSArray *)storedValue;
        NSMutableArray<NSString *> *normalizedEntries = [NSMutableArray arrayWithCapacity:storedEntries.count];
        for (id entry in storedEntries) {
            NSString *bundleIdentifier = [self bundleIdentifierFromStoredEntry:entry];
            if (bundleIdentifier == nil) {
                NSLog(@"[RCExcludeAppService] Warning: Corrupted excluded applications defaults. Resetting to empty array.");
                [self.userDefaults setObject:@[] forKey:kRCExcludeApplications];
                return @[];
            }
            [normalizedEntries addObject:bundleIdentifier];
        }

        NSArray<NSString *> *sanitizedIdentifiers = [self sanitizedBundleIdentifiersFromArray:[normalizedEntries copy]];
        if (![storedEntries isEqualToArray:sanitizedIdentifiers]) {
            [self.userDefaults setObject:sanitizedIdentifiers forKey:kRCExcludeApplications];
        }

        return sanitizedIdentifiers;
    }
}

- (void)setExcludedBundleIdentifiers:(NSArray<NSString *> *)identifiers {
    @synchronized(self) {
        NSArray<NSString *> *sanitizedIdentifiers = [self sanitizedBundleIdentifiersFromArray:identifiers ?: @[]];
        [self.userDefaults setObject:sanitizedIdentifiers forKey:kRCExcludeApplications];
    }
}

- (void)addExcludedBundleIdentifier:(NSString *)bundleId {
    NSString *normalizedBundleId = [self normalizedBundleIdentifier:bundleId];
    if (normalizedBundleId.length == 0) {
        return;
    }

    @synchronized(self) {
        NSArray<NSString *> *currentIdentifiers = [self excludedBundleIdentifiers];
        if ([currentIdentifiers containsObject:normalizedBundleId]) {
            return;
        }

        NSMutableArray<NSString *> *updatedIdentifiers = [currentIdentifiers mutableCopy];
        [updatedIdentifiers addObject:normalizedBundleId];
        [self setExcludedBundleIdentifiers:[updatedIdentifiers copy]];
    }
}

- (void)removeExcludedBundleIdentifier:(NSString *)bundleId {
    NSString *normalizedBundleId = [self normalizedBundleIdentifier:bundleId];
    if (normalizedBundleId.length == 0) {
        return;
    }

    @synchronized(self) {
        NSMutableArray<NSString *> *updatedIdentifiers = [[self excludedBundleIdentifiers] mutableCopy];
        [updatedIdentifiers removeObject:normalizedBundleId];
        [self setExcludedBundleIdentifiers:[updatedIdentifiers copy]];
    }
}

#pragma mark - Private

- (nullable NSRunningApplication *)frontmostApplication {
    __block NSRunningApplication *application = nil;
    dispatch_block_t resolveBlock = ^{
        application = [NSWorkspace sharedWorkspace].frontmostApplication;
    };

    if ([NSThread isMainThread]) {
        resolveBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), resolveBlock);
    }

    return application;
}

- (NSString *)frontmostApplicationBundleIdentifier {
    NSRunningApplication *application = [self frontmostApplication];
    return application.bundleIdentifier ?: @"";
}

- (NSString *)fallbackBundleIdentifierFromFrontmostApplication {
    NSRunningApplication *application = [self frontmostApplication];
    if (application == nil) {
        return @"";
    }

    NSString *bundleIdentifier = [self bundleIdentifierFromExecutableURL:application.executableURL];
    if (bundleIdentifier.length > 0) {
        return bundleIdentifier;
    }

    bundleIdentifier = [self bundleIdentifierFromProcessPath:application.executableURL.path];
    if (bundleIdentifier.length > 0) {
        return bundleIdentifier;
    }

    if (application.bundleURL != nil) {
        NSBundle *bundle = [NSBundle bundleWithURL:application.bundleURL];
        if (bundle.bundleIdentifier.length > 0) {
            return bundle.bundleIdentifier;
        }
    }

    return @"";
}

- (NSString *)bundleIdentifierFromExecutableURL:(nullable NSURL *)executableURL {
    if (![executableURL isKindOfClass:[NSURL class]]) {
        return @"";
    }

    NSString *processPath = executableURL.path ?: @"";
    return [self bundleIdentifierFromProcessPath:processPath];
}

- (NSString *)bundleIdentifierFromProcessPath:(nullable NSString *)processPath {
    if (![processPath isKindOfClass:[NSString class]]) {
        return @"";
    }

    NSString *trimmedPath = [processPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedPath.length == 0) {
        return @"";
    }

    NSURL *currentURL = [NSURL fileURLWithPath:trimmedPath];
    while (currentURL != nil) {
        NSString *lastComponent = currentURL.lastPathComponent;
        NSString *pathExtension = [lastComponent.pathExtension lowercaseString];
        if ([pathExtension isEqualToString:@"app"]) {
            NSBundle *bundle = [NSBundle bundleWithURL:currentURL];
            NSString *bundleIdentifier = bundle.bundleIdentifier ?: @"";
            if (bundleIdentifier.length > 0) {
                return bundleIdentifier;
            }
        }

        NSURL *parentURL = [currentURL URLByDeletingLastPathComponent];
        if (parentURL == nil || [parentURL.path isEqualToString:currentURL.path]) {
            break;
        }
        currentURL = parentURL;
    }

    NSBundle *bundleFromPath = [NSBundle bundleWithPath:trimmedPath];
    return bundleFromPath.bundleIdentifier ?: @"";
}

- (NSArray<NSString *> *)sanitizedBundleIdentifiersFromArray:(NSArray *)identifiers {
    if (identifiers.count == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *sanitizedIdentifiers = [NSMutableArray arrayWithCapacity:identifiers.count];
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet setWithCapacity:identifiers.count];

    for (id identifier in identifiers) {
        if (![identifier isKindOfClass:[NSString class]]) {
            continue;
        }

        NSString *normalizedIdentifier = [self normalizedBundleIdentifier:identifier];
        if (normalizedIdentifier.length == 0 || [seenIdentifiers containsObject:normalizedIdentifier]) {
            continue;
        }

        [seenIdentifiers addObject:normalizedIdentifier];
        [sanitizedIdentifiers addObject:normalizedIdentifier];
    }

    return [sanitizedIdentifiers copy];
}

- (NSString *)normalizedBundleIdentifier:(nullable NSString *)bundleIdentifier {
    if (![bundleIdentifier isKindOfClass:[NSString class]]) {
        return @"";
    }

    NSString *trimmed = [bundleIdentifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [trimmed lowercaseString] ?: @"";
}

- (nullable NSString *)bundleIdentifierFromStoredEntry:(id)entry {
    if ([entry isKindOfClass:[NSString class]]) {
        return (NSString *)entry;
    }

    if (![entry isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *dictionary = (NSDictionary *)entry;
    id rawIdentifier = dictionary[@"bundleIdentifier"];
    if (![rawIdentifier isKindOfClass:[NSString class]]) {
        rawIdentifier = dictionary[@"bundle_id"];
    }
    if (![rawIdentifier isKindOfClass:[NSString class]]) {
        rawIdentifier = dictionary[@"bundleId"];
    }
    if (![rawIdentifier isKindOfClass:[NSString class]]) {
        rawIdentifier = dictionary[@"identifier"];
    }

    if (![rawIdentifier isKindOfClass:[NSString class]]) {
        return nil;
    }

    return (NSString *)rawIdentifier;
}

@end
