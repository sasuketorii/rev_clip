//
//  RCUpdateService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCUpdateService.h"

#import "RCConstants.h"
#import "RCLocalization.h"
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>

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
    RCUpdateServiceErrorCodeFeedNotConfigured = 7,
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
- (void)updaterWillRelaunchApplication:(id)updater;
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

// Sparkle is loaded dynamically; these selectors match its public delegate API.
@protocol RCUpdateUserState <NSObject>
@property (nonatomic, readonly) BOOL userInitiated;
@end

@interface RCUpdateService () <RCSPUUpdaterDelegate, UNUserNotificationCenterDelegate>

@property (nonatomic, strong, nullable) id<RCSPUStandardUpdaterController> updaterController;
@property (nonatomic, strong, nullable, readwrite) NSError *lastError;
@property (nonatomic, strong, nullable) NSStatusItem *updateReminderItem;
@property (nonatomic, assign) NSUInteger reminderGeneration;
@property (nonatomic, assign) BOOL awaitingUpdateAttention;
@property (nonatomic, copy, nullable) NSString *reminderNotificationIdentifier;

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
    // Register at launch so notifications from a previous process remain actionable.
    if ([self updateFeedURL].length > 0) {
        [self updateNotificationCenter].delegate = self;
    }
    [self setupUpdaterForUpdateCheck:RCUpdateServiceUpdateCheckUpdatesInBackground
                 notifyUserOnFailure:NO];
}

- (NSString *)updateFeedURL {
    id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"SUFeedURL"];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (BOOL)setupUpdaterForUpdateCheck:(NSInteger)updateCheck
               notifyUserOnFailure:(BOOL)notifyUserOnFailure {
    @synchronized (self) {
        if (self.updaterController != nil) {
            return YES;
        }

        if ([self updateFeedURL].length == 0) {
            NSError *error = [self serviceErrorWithCode:RCUpdateServiceErrorCodeFeedNotConfigured
                                               reason:@"This distribution has no update feed configured."
                                      underlyingError:nil];
            self.lastError = error;
            if (notifyUserOnFailure) {
                [self reportFailureWithError:error reason:error.localizedDescription updateCheck:updateCheck];
            }
            return NO;
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

// The relaunch after an update is not the user opening Revclip: no menu for it.
- (void)updaterWillRelaunchApplication:(id)updater {
    (void)updater;
    [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSinceReferenceDate forKey:kRCSelfRelaunchStampKey];
}

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
            self.lastError = error;
        }
        return;
    }

    self.lastError = nil;
}

#pragma mark - Gentle update reminders

- (BOOL)supportsGentleScheduledUpdateReminders {
    return YES;
}

- (BOOL)standardUserDriverShouldHandleShowingScheduledUpdate:(id)update andInImmediateFocus:(BOOL)immediateFocus {
    // A dockless app otherwise gets an update window behind other applications.
    // Keep Sparkle's immediate alerts; defer the others until our reminder is clicked.
    return immediateFocus;
}

- (void)standardUserDriverWillHandleShowingUpdate:(BOOL)handleShowingUpdate forUpdate:(id)update state:(id<RCUpdateUserState>)state {
    if (handleShowingUpdate || state.userInitiated || self.awaitingUpdateAttention) {
        return;
    }
    self.awaitingUpdateAttention = YES;
    NSUInteger generation = ++self.reminderGeneration;
    self.reminderNotificationIdentifier = [@"com.revclip.update-reminder." stringByAppendingString:NSUUID.UUID.UUIDString];
    [self showUpdateReminder];
    [self deliverUpdateNotificationForGeneration:generation];
}

- (void)showUpdateReminder {
    // Independent of the optional clipboard status icon: users who hide that icon
    // must still have a visible fallback when notifications are denied or silenced.
    self.updateReminderItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.updateReminderItem.autosaveName = @"RevclipUpdateReminder";
    NSStatusBarButton *button = self.updateReminderItem.button;
    button.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle.fill" accessibilityDescription:RCLocalizedString(@"Revclip update available", nil)];
    button.toolTip = RCLocalizedString(@"Revclip update available", nil);
    button.target = self;
    button.action = @selector(openUpdateReminder:);
}

- (void)openUpdateReminder:(id)sender {
    // Sparkle's controller brings the existing session forward (no extra request).
    [self.updaterController checkForUpdates:sender];
}

- (UNUserNotificationCenter *)updateNotificationCenter {
    return UNUserNotificationCenter.currentNotificationCenter;
}

- (void)deliverUpdateNotificationForGeneration:(NSUInteger)generation {
    UNUserNotificationCenter *center = [self updateNotificationCenter];
    NSString *identifier = self.reminderNotificationIdentifier;
    center.delegate = self;
    __weak typeof(self) weakSelf = self;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || !granted || !self.awaitingUpdateAttention || self.reminderGeneration != generation) {
                return;
            }
            UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
            content.title = RCLocalizedString(@"Revclip update available", nil);
            content.body = RCLocalizedString(@"Click to review and install the update.", nil);
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
            __weak UNUserNotificationCenter *weakCenter = center;
            [center addNotificationRequest:request withCompletionHandler:^(NSError *deliveryError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) self = weakSelf;
                    // The user can attend/dismiss the update while delivery is pending.
                    if (!self || !self.awaitingUpdateAttention || self.reminderGeneration != generation) {
                        [weakCenter removePendingNotificationRequestsWithIdentifiers:@[identifier]];
                        [weakCenter removeDeliveredNotificationsWithIdentifiers:@[identifier]];
                    }
                    if (deliveryError) {
                        NSLog(@"[RCUpdateService] Update notification delivery failed: %@", deliveryError.localizedDescription);
                    }
                });
            }];
        });
    }];
}

- (void)removeUpdateNotification {
    UNUserNotificationCenter *center = [self updateNotificationCenter];
    NSString *identifier = self.reminderNotificationIdentifier;
    if (identifier) {
        [center removePendingNotificationRequestsWithIdentifiers:@[identifier]];
        [center removeDeliveredNotificationsWithIdentifiers:@[identifier]];
        self.reminderNotificationIdentifier = nil;
    }
}

- (void)clearUpdateReminder {
    self.awaitingUpdateAttention = NO;
    ++self.reminderGeneration;
    if (self.updateReminderItem) {
        [NSStatusBar.systemStatusBar removeStatusItem:self.updateReminderItem];
        self.updateReminderItem = nil;
    }
    [self removeUpdateNotification];
}

- (void)standardUserDriverDidReceiveUserAttentionForUpdate:(id)update {
    [self clearUpdateReminder];
}

- (void)standardUserDriverWillFinishUpdateSession {
    [self clearUpdateReminder];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completionHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([response.notification.request.identifier hasPrefix:@"com.revclip.update-reminder."] &&
            [response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
            [center removeDeliveredNotificationsWithIdentifiers:@[response.notification.request.identifier]];
            [self openUpdateReminder:nil];
        }
        completionHandler();
    });
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
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
                                                                                          userDriverDelegate:self];
    }

    if ([updaterControllerClass instancesRespondToSelector:@selector(initWithUpdaterDelegate:userDriverDelegate:)]) {
        return [(id<RCSPUStandardUpdaterController>)[updaterControllerClass alloc] initWithUpdaterDelegate:self
                                                                                          userDriverDelegate:self];
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
