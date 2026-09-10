//
//  RCUpdateService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCUpdateService.h"

#import "RCConstants.h"

static NSTimeInterval const kRCDefaultUpdateCheckInterval = 86400.0;
static NSString * const kRCSparkleFrameworkName = @"Sparkle.framework";
static NSString * const kRCUpdateServiceErrorDomain = @"com.revclip.update";
static NSString * const kRCSparkleErrorDomain = @"SUSparkleErrorDomain";

NSNotificationName const RCUpdateServiceDidFailNotification = @"RCUpdateServiceDidFailNotification";
NSString * const RCUpdateServiceErrorUserInfoKey = @"error";
NSString * const RCUpdateServiceFailureReasonUserInfoKey = @"reason";
NSString * const RCUpdateServiceUpdateCheckUserInfoKey = @"update_check";

typedef NS_ENUM(NSInteger, RCUpdateServiceErrorCode) {
    RCUpdateServiceErrorCodeUnknown = 1,
    RCUpdateServiceErrorCodeSparkleUnavailable = 2,
    RCUpdateServiceErrorCodeSparkleLoadFailed = 3,
    RCUpdateServiceErrorCodeUpdaterControllerMissing = 4,
    RCUpdateServiceErrorCodeUpdaterControllerCreationFailed = 5,
    RCUpdateServiceErrorCodeUpdaterNotInitialized = 6,
};

typedef NS_ENUM(NSInteger, RCSparkleErrorCode) {
    RCSparkleErrorCodeNoUpdate = 1001,
    RCSparkleErrorCodeInstallationCanceled = 4007,
};

@protocol RCSPUUpdater <NSObject>
@property (nonatomic, assign) BOOL automaticallyChecksForUpdates;
@property (nonatomic, assign) NSTimeInterval updateCheckInterval;
@optional
@property (nonatomic, readonly) BOOL canCheckForUpdates;
@property (nonatomic, assign) BOOL automaticallyDownloadsUpdates;
@end

@protocol RCSPUUpdaterDelegate <NSObject>
@optional
- (void)updater:(id)updater didFindValidUpdate:(id)item;
- (void)updaterDidNotFindUpdate:(id)updater error:(NSError *)error;
- (void)updater:(id)updater didFinishUpdateCycleForUpdateCheck:(NSInteger)updateCheck error:(nullable NSError *)error;
@end

@protocol RCSPUStandardUpdaterController <NSObject>
@property (nonatomic, readonly) id<RCSPUUpdater> updater;

@optional
- (instancetype)initWithStartingUpdater:(BOOL)startUpdater
                        updaterDelegate:(nullable id)updaterDelegate
                     userDriverDelegate:(nullable id)userDriverDelegate;
- (instancetype)initWithUpdaterDelegate:(nullable id)updaterDelegate
                     userDriverDelegate:(nullable id)userDriverDelegate;

@required
- (void)checkForUpdates:(nullable id)sender;
@end

@interface RCUpdateService () <RCSPUUpdaterDelegate>

@property (nonatomic, strong, nullable) id<RCSPUStandardUpdaterController> updaterController;
@property (nonatomic, strong, nullable, readwrite) NSError *lastError;

- (BOOL)setupUpdaterForUpdateCheck:(NSInteger)updateCheck
               notifyUserOnFailure:(BOOL)notifyUserOnFailure;
- (void)reportFailureWithError:(nullable NSError *)error
                        reason:(NSString *)reason
                   updateCheck:(NSInteger)updateCheck;
- (BOOL)shouldNotifyFailureForUpdateCheck:(NSInteger)updateCheck;

@end

@implementation RCUpdateService

+ (instancetype)shared {
    static RCUpdateService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (void)setupUpdater {
    [self setupUpdaterForUpdateCheck:RCUpdateServiceUpdateCheckUpdatesInBackground
                 notifyUserOnFailure:NO];
}

- (BOOL)setupUpdaterForUpdateCheck:(NSInteger)updateCheck
               notifyUserOnFailure:(BOOL)notifyUserOnFailure {
    @synchronized (self) {
        if (self.updaterController != nil) {
            return YES;
        }

        NSError *frameworkError = nil;
        if (![self loadSparkleFrameworkIfAvailableWithError:&frameworkError]) {
            NSLog(@"[RCUpdateService] Sparkle.framework unavailable: %@",
                  frameworkError.localizedDescription ?: @"Unknown error");
            self.lastError = frameworkError;
            if (notifyUserOnFailure) {
                [self reportFailureWithError:frameworkError
                                      reason:@"Sparkle.framework unavailable."
                                 updateCheck:updateCheck];
            }
            return NO;
        }

        Class updaterControllerClass = NSClassFromString(@"SPUStandardUpdaterController");
        if (updaterControllerClass == Nil) {
            NSLog(@"[RCUpdateService] SPUStandardUpdaterController class not found.");
            NSError *error = [self serviceErrorWithCode:RCUpdateServiceErrorCodeUpdaterControllerMissing
                                                 reason:@"SPUStandardUpdaterController class not found."
                                        underlyingError:nil];
            self.lastError = error;
            if (notifyUserOnFailure) {
                [self reportFailureWithError:error
                                      reason:@"SPUStandardUpdaterController class not found."
                                 updateCheck:updateCheck];
            }
            return NO;
        }

        self.updaterController = [self createUpdaterControllerWithClass:updaterControllerClass];
        if (self.updaterController == nil) {
            NSLog(@"[RCUpdateService] Failed to create updater controller.");
            NSError *error = [self serviceErrorWithCode:RCUpdateServiceErrorCodeUpdaterControllerCreationFailed
                                                 reason:@"Failed to create updater controller."
                                        underlyingError:nil];
            self.lastError = error;
            if (notifyUserOnFailure) {
                [self reportFailureWithError:error
                                      reason:@"Failed to create updater controller."
                                 updateCheck:updateCheck];
            }
            return NO;
        }

        [self applyStoredPreferencesToUpdater];
        self.lastError = nil;
        NSLog(@"[RCUpdateService] Sparkle updater initialized successfully.");
        return YES;
    }
}

- (BOOL)checkForUpdates {
    if (![NSThread isMainThread]) {
        NSLog(@"[RCUpdateService] checkForUpdates must be called on main thread.");
        return NO;
    }

    BOOL didSetup = [self setupUpdaterForUpdateCheck:RCUpdateServiceUpdateCheckUpdates
                                 notifyUserOnFailure:YES];
    if (!didSetup) {
        return NO;
    }
    if (self.updaterController == nil) {
        NSLog(@"[RCUpdateService] Cannot check for updates: updater not initialized.");
        NSError *error = self.lastError ?: [self serviceErrorWithCode:RCUpdateServiceErrorCodeUpdaterNotInitialized
                                                                reason:@"Updater not initialized."
                                                       underlyingError:nil];
        [self reportFailureWithError:error
                              reason:@"Cannot check for updates: updater not initialized."
                         updateCheck:RCUpdateServiceUpdateCheckUpdates];
        return NO;
    }

    if (!self.canCheckForUpdates) {
        NSLog(@"[RCUpdateService] Cannot start manual update check right now.");
        return NO;
    }

    [self.updaterController checkForUpdates:nil];
    return YES;
}

- (BOOL)canCheckForUpdates {
    @synchronized (self) {
        if (self.updaterController == nil) {
            return NO;
        }

        id<RCSPUUpdater> updater = [self currentUpdater];
        if (updater != nil && [updater respondsToSelector:@selector(canCheckForUpdates)]) {
            return updater.canCheckForUpdates;
        }

        return NO;
    }
}

- (BOOL)isAutomaticallyChecksForUpdates {
    NSNumber *storedValue = [NSUserDefaults.standardUserDefaults objectForKey:kRCEnableAutomaticCheckKey];
    if (storedValue == nil) {
        return YES;
    }
    return storedValue.boolValue;
}

- (void)setAutomaticallyChecksForUpdates:(BOOL)automaticallyChecksForUpdates {
    [NSUserDefaults.standardUserDefaults setBool:automaticallyChecksForUpdates forKey:kRCEnableAutomaticCheckKey];

    id<RCSPUUpdater> updater = [self currentUpdater];
    if (updater != nil && [updater respondsToSelector:@selector(setAutomaticallyChecksForUpdates:)]) {
        updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates;
    }
}

- (NSTimeInterval)updateCheckInterval {
    NSNumber *storedValue = [NSUserDefaults.standardUserDefaults objectForKey:kRCUpdateCheckIntervalKey];
    if (storedValue == nil || storedValue.doubleValue <= 0.0) {
        return kRCDefaultUpdateCheckInterval;
    }
    return storedValue.doubleValue;
}

- (void)setUpdateCheckInterval:(NSTimeInterval)updateCheckInterval {
    NSTimeInterval interval = updateCheckInterval;
    if (interval <= 0.0) {
        interval = kRCDefaultUpdateCheckInterval;
    }

    [NSUserDefaults.standardUserDefaults setDouble:interval forKey:kRCUpdateCheckIntervalKey];

    id<RCSPUUpdater> updater = [self currentUpdater];
    if (updater != nil && [updater respondsToSelector:@selector(setUpdateCheckInterval:)]) {
        updater.updateCheckInterval = interval;
    }
}

#pragma mark - RCSPUUpdaterDelegate

- (void)updater:(id)updater didFindValidUpdate:(id)item {
    (void)updater;
    (void)item;
    self.lastError = nil;
}

- (void)updaterDidNotFindUpdate:(id)updater error:(NSError *)error {
    (void)updater;
    // Sparkle reports "no update" as SUNoUpdateError. That is success for a
    // user who is already current, not a failed check.
    NSLog(@"[RCUpdateService] No update found: %@ (domain: %@ code: %ld userInfo: %@)",
          error.localizedDescription ?: @"Unknown",
          error.domain ?: @"",
          (long)error.code,
          error.userInfo);
    self.lastError = nil;
}

- (void)updater:(id)updater didFinishUpdateCycleForUpdateCheck:(NSInteger)updateCheck error:(NSError * _Nullable)error {
    (void)updater;
    (void)updateCheck;

    if (error != nil) {
        if ([self isIgnorableSparkleError:error]) {
            NSLog(@"[RCUpdateService] Ignoring non-actionable Sparkle error: %@ (domain: %@ code: %ld)",
                  error.localizedDescription ?: @"Unknown error",
                  error.domain ?: @"",
                  (long)error.code);
            self.lastError = nil;
            return;
        }
        if ([self shouldNotifyFailureForUpdateCheck:updateCheck]) {
            [self reportFailureWithError:error
                                  reason:@"Update check failed."
                             updateCheck:updateCheck];
        } else {
            NSLog(@"[RCUpdateService] Suppressing background update failure notification (check: %ld): %@",
                  (long)updateCheck,
                  error.localizedDescription ?: @"Unknown error");
            self.lastError = nil;
        }
        return;
    }

    self.lastError = nil;
}

#pragma mark - Private

- (void)applyStoredPreferencesToUpdater {
    id<RCSPUUpdater> updater = [self currentUpdater];
    if (updater == nil) {
        return;
    }

    if ([updater respondsToSelector:@selector(setAutomaticallyChecksForUpdates:)]) {
        updater.automaticallyChecksForUpdates = self.automaticallyChecksForUpdates;
    }
    if ([updater respondsToSelector:@selector(setUpdateCheckInterval:)]) {
        updater.updateCheckInterval = self.updateCheckInterval;
    }
    if ([updater respondsToSelector:@selector(setAutomaticallyDownloadsUpdates:)]) {
        updater.automaticallyDownloadsUpdates = NO;
    }
}

- (BOOL)isIgnorableSparkleError:(NSError *)error {
    if (error == nil) {
        return NO;
    }

    if (![error.domain isEqualToString:kRCSparkleErrorDomain]) {
        return NO;
    }

    switch (error.code) {
        case RCSparkleErrorCodeNoUpdate:
        case RCSparkleErrorCodeInstallationCanceled:
            return YES;
        default:
            return NO;
    }
}

- (nullable id<RCSPUUpdater>)currentUpdater {
    id<RCSPUStandardUpdaterController> controller = self.updaterController;
    if (controller == nil || ![controller respondsToSelector:@selector(updater)]) {
        return nil;
    }

    id updater = controller.updater;
    if (updater == nil) {
        return nil;
    }

    return (id<RCSPUUpdater>)updater;
}

- (nullable id<RCSPUStandardUpdaterController>)createUpdaterControllerWithClass:(Class)updaterControllerClass {
    if ([updaterControllerClass instancesRespondToSelector:@selector(initWithStartingUpdater:updaterDelegate:userDriverDelegate:)]) {
        return [(id<RCSPUStandardUpdaterController>)[updaterControllerClass alloc] initWithStartingUpdater:YES
                                                                                             updaterDelegate:self
                                                                                          userDriverDelegate:nil];
    }

    if ([updaterControllerClass instancesRespondToSelector:@selector(initWithUpdaterDelegate:userDriverDelegate:)]) {
        return [(id<RCSPUStandardUpdaterController>)[updaterControllerClass alloc] initWithUpdaterDelegate:self
                                                                                          userDriverDelegate:nil];
    }

    return nil;
}

- (BOOL)loadSparkleFrameworkIfAvailableWithError:(NSError * _Nullable __autoreleasing *)outError {
    NSBundle *sparkleBundle = [self sparkleFrameworkBundle];
    if (sparkleBundle == nil) {
        if (outError != NULL) {
            *outError = [self serviceErrorWithCode:RCUpdateServiceErrorCodeSparkleUnavailable
                                            reason:@"Sparkle.framework not found."
                                   underlyingError:nil];
        }
        return NO;
    }

    if (sparkleBundle.loaded) {
        return YES;
    }

    NSError *error = nil;
    BOOL loaded = [sparkleBundle loadAndReturnError:&error];
    if (!loaded) {
        NSLog(@"[RCUpdateService] Failed to load Sparkle.framework: %@", error.localizedDescription ?: @"Unknown error");
        if (outError != NULL) {
            *outError = [self serviceErrorWithCode:RCUpdateServiceErrorCodeSparkleLoadFailed
                                            reason:@"Failed to load Sparkle.framework."
                                   underlyingError:error];
        }
    }
    return loaded;
}

- (NSError *)serviceErrorWithCode:(RCUpdateServiceErrorCode)code
                           reason:(NSString *)reason
                  underlyingError:(nullable NSError *)underlyingError {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (reason.length > 0) {
        userInfo[NSLocalizedDescriptionKey] = reason;
    }
    if (underlyingError != nil) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:kRCUpdateServiceErrorDomain code:code userInfo:userInfo];
}

- (NSDictionary<NSString *, id> *)userInfoWithError:(NSError *)error
                                             reason:(NSString *)reason
                                        updateCheck:(NSInteger)updateCheck {
    NSMutableDictionary<NSString *, id> *userInfo = [NSMutableDictionary dictionaryWithObject:error
                                                                                         forKey:RCUpdateServiceErrorUserInfoKey];
    if (reason.length > 0) {
        userInfo[RCUpdateServiceFailureReasonUserInfoKey] = reason;
    }
    userInfo[RCUpdateServiceUpdateCheckUserInfoKey] = @(updateCheck);
    return [userInfo copy];
}

- (void)reportFailureWithError:(nullable NSError *)error
                        reason:(NSString *)reason
                   updateCheck:(NSInteger)updateCheck {
    NSError *reportedError = error;
    if (reportedError == nil) {
        reportedError = [self serviceErrorWithCode:RCUpdateServiceErrorCodeUnknown
                                            reason:reason
                                   underlyingError:nil];
    }

    self.lastError = reportedError;
    [self postNotificationName:RCUpdateServiceDidFailNotification
                      userInfo:[self userInfoWithError:reportedError
                                                 reason:reason
                                            updateCheck:updateCheck]];
}

- (BOOL)shouldNotifyFailureForUpdateCheck:(NSInteger)updateCheck {
    return updateCheck == RCUpdateServiceUpdateCheckUpdates;
}

- (void)postNotificationName:(NSNotificationName)notificationName userInfo:(nullable NSDictionary<NSString *, id> *)userInfo {
    if (notificationName.length == 0) {
        return;
    }

    dispatch_block_t postBlock = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:notificationName
                                                            object:self
                                                          userInfo:userInfo];
    };

    if ([NSThread isMainThread]) {
        postBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), postBlock);
    }
}

- (nullable NSBundle *)sparkleFrameworkBundle {
    for (NSString *frameworkPath in [self sparkleFrameworkCandidatePaths]) {
        if (frameworkPath.length == 0) {
            continue;
        }

        NSBundle *bundle = [NSBundle bundleWithPath:frameworkPath];
        if (bundle != nil) {
            return bundle;
        }
    }

    return nil;
}

- (NSArray<NSString *> *)sparkleFrameworkCandidatePaths {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];

    NSString *privateFrameworksPath = NSBundle.mainBundle.privateFrameworksPath;
    if (privateFrameworksPath.length > 0) {
        [paths addObject:[privateFrameworksPath stringByAppendingPathComponent:kRCSparkleFrameworkName]];
    }

    NSString *mainBundlePath = NSBundle.mainBundle.bundlePath;
    if (mainBundlePath.length > 0) {
        [paths addObject:[[mainBundlePath stringByAppendingPathComponent:@"Contents/Frameworks"]
                          stringByAppendingPathComponent:kRCSparkleFrameworkName]];

        [paths addObject:[[[mainBundlePath stringByAppendingPathComponent:@"../Frameworks"]
                           stringByAppendingPathComponent:kRCSparkleFrameworkName] stringByStandardizingPath]];
    }

    return paths.array;
}

@end
