#import "RCSettingsCLIService.h"
#import "RCConstants.h"
#import "RCDataCleanService.h"
#import "RCExcludeAppService.h"
#import "RCLoginItemService.h"
#import "RCUpdateService.h"
#import "RCAccessibilityService.h"
#import "RCLocalization.h"
#import "RCSnippetEditorWindowController.h"
#import "Revclip-Swift.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

NSNotificationName const RCSettingsDidChangeNotification = @"RCSettingsDidChangeNotification";

static NSDictionary *RCSettingsFailure(NSString *message) { return @{@"ok":@NO, @"error":message}; }
static NSDictionary *RCSettingsSuccess(id result) { return @{@"ok":@YES, @"result":result}; }
static BOOL RCSettingsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static NSArray *RCSettingsTypeNames(void) { return @[@"HTML", @"String", @"RTF", @"RTFD", @"PDF", @"Filenames", @"URL", @"TIFF"]; }
static NSArray *RCSettingsColorNames(void) { return @[@"primary", @"text", @"background", @"hoverText", @"hoverBackground"]; }

// Bounds/defaults mirror General/Menu/Type/Updates controllers, RCUtilities and
// RCAppearanceController. Only these entries can reach a defaults setter.
static NSDictionary<NSString *, NSDictionary *> *RCSettingsDefinitions(void) {
    static NSDictionary *definitions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *items = [NSMutableDictionary dictionary];
        void (^add)(NSString *, NSString *, NSString *, id, NSString *, NSDictionary *) =
        ^(NSString *key, NSString *storage, NSString *type, id fallback, NSString *group, NSDictionary *extra) {
            NSMutableDictionary *item = [@{@"type":type, @"default":[fallback copy], @"group":group, @"writable":@YES} mutableCopy];
            if (storage) item[@"defaults_key"] = storage;
            [item addEntriesFromDictionary:extra ?: @{}];
            items[key] = [item copy];
        };
        add(@"max_history_size", kRCPrefMaxHistorySizeKey, @"integer", @30, @"general", @{@"minimum":@1, @"maximum":@9999});
        add(@"auto_expiry_enabled", kRCPrefAutoExpiryEnabledKey, @"boolean", @NO, @"general", @{});
        add(@"auto_expiry_value", kRCPrefAutoExpiryValueKey, @"integer", @30, @"general", @{@"minimum":@1, @"maximum":@9999});
        add(@"auto_expiry_unit", kRCPrefAutoExpiryUnitKey, @"integer", @0, @"general", @{@"minimum":@0, @"maximum":@2});
        add(@"login_at_startup", kRCLoginItem, @"boolean", @YES, @"general", @{});
        add(@"show_status_item", kRCPrefShowStatusItemKey, @"integer", @1, @"general", @{@"minimum":@0, @"maximum":@1});
        add(@"paste_command", kRCPrefInputPasteCommandKey, @"boolean", @YES, @"general", @{});
        add(@"reorder_after_pasting", kRCPrefReorderClipsAfterPasting, @"boolean", @YES, @"general", @{});
        add(@"overwrite_same_history", kRCPrefOverwriteSameHistory, @"boolean", @YES, @"general", @{});
        add(@"copy_same_history", kRCPrefCopySameHistory, @"boolean", @YES, @"general", @{});
        add(@"number_of_items_inline", kRCPrefNumberOfItemsPlaceInlineKey, @"integer", @0, @"menu", @{@"minimum":@0, @"maximum":@99});
        add(@"number_of_items_in_folder", kRCPrefNumberOfItemsPlaceInsideFolderKey, @"integer", @10, @"menu", @{@"minimum":@1, @"maximum":@99});
        add(@"max_title_length", kRCPrefMaxMenuItemTitleLengthKey, @"integer", @40, @"menu", @{@"minimum":@1, @"maximum":@200});
        add(@"mark_with_numbers", kRCMenuItemsAreMarkedWithNumbersKey, @"boolean", @YES, @"menu", @{});
        add(@"start_numbering_from_zero", kRCPrefMenuItemsTitleStartWithZeroKey, @"boolean", @NO, @"menu", @{});
        add(@"add_numeric_key_equivalents", kRCAddNumericKeyEquivalentsKey, @"boolean", @NO, @"menu", @{});
        add(@"add_clear_history_item", kRCPrefAddClearHistoryMenuItemKey, @"boolean", @YES, @"menu", @{});
        add(@"show_alert_before_clear", kRCPrefShowAlertBeforeClearHistoryKey, @"boolean", @YES, @"menu", @{});
        add(@"show_tooltip", kRCShowToolTipOnMenuItemKey, @"boolean", @YES, @"menu", @{});
        add(@"max_tooltip_length", kRCMaxLengthOfToolTipKey, @"integer", @10000, @"menu", @{@"minimum":@1, @"maximum":@10000});
        add(@"show_image_preview", kRCShowImageInTheMenuKey, @"boolean", @YES, @"menu", @{});
        add(@"thumbnail_width", kRCThumbnailWidthKey, @"integer", @100, @"menu", @{@"minimum":@16, @"maximum":@512});
        add(@"thumbnail_height", kRCThumbnailHeightKey, @"integer", @32, @"menu", @{@"minimum":@16, @"maximum":@512});
        add(@"show_color_preview", kRCPrefShowColorPreviewInTheMenu, @"boolean", @YES, @"menu", @{});
        add(@"show_icon", kRCPrefShowIconInTheMenuKey, @"boolean", @YES, @"menu", @{});
        add(@"icon_size", kRCPrefMenuIconSizeKey, @"integer", @16, @"menu", @{@"minimum":@8, @"maximum":@64});
        add(@"automatic_update_check", kRCEnableAutomaticCheckKey, @"boolean", @YES, @"updates", @{});
        add(@"update_check_interval", kRCUpdateCheckIntervalKey, @"integer", @86400, @"updates", @{@"enum":@[@86400,@604800,@2592000], @"unit":@"seconds"});
        add(@"language", nil, @"string", @"", @"general", @{@"enum":@[@"",@"ja",@"en",@"ko",@"zh-Hans",@"fr",@"de",@"pt-BR",@"it",@"vi"], @"description":@"Empty string follows system; applies immediately."});
        add(@"appearance", @"RCAppAppearance", @"string", @"system", @"appearance", @{@"enum":@[@"system",@"light",@"dark"]});
        add(@"menu_custom_colors_enabled", @"RCMenuCustomColorsEnabled", @"boolean", @NO, @"appearance", @{});
        for (NSString *key in @[@"menu_custom_colors_dark",@"menu_custom_colors_light"]) {
            BOOL dark = [key hasSuffix:@"dark"];
            NSDictionary *fallback = @{@"primary":@"#007AFF", @"text":dark ? @"#FFFFFF" : @"#1A1A1A", @"background":dark ? @"#171717" : @"#F2F2F2", @"hoverText":@"#FFFFFF", @"hoverBackground":@"#3478F6"};
            add(key, dark ? @"RCMenuCustomColors" : @"RCMenuCustomColorsLight", @"object", fallback, @"appearance",
                @{@"allowed_properties":RCSettingsColorNames(), @"value_type":@"string", @"pattern":@"^#[0-9A-Fa-f]{6}$", @"write_semantics":@"replace; omitted colors use defaults; empty object resets palette", @"normalization":@"trim whitespace, optional #, uppercase"});
        }
        NSMutableDictionary *types = [NSMutableDictionary dictionary];
        for (NSString *name in RCSettingsTypeNames()) types[name] = @YES;
        add(@"store_types", kRCPrefStoreTypesKey, @"object", types, @"type", @{@"allowed_properties":RCSettingsTypeNames(), @"value_type":@"boolean", @"write_semantics":@"merge; omitted types retain current values"});
        add(@"excluded_applications", kRCExcludeApplications, @"array", @[], @"exclude", @{@"items":@{@"type":@"string", @"minLength":@1, @"maxLength":@255, @"pattern":@"^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*$"}, @"maxItems":@1024, @"write_semantics":@"replace", @"normalization":@"trim whitespace, lowercase, deduplicate"});
        NSMutableDictionary *unit = [items[@"auto_expiry_unit"] mutableCopy];
        unit[@"enum"] = @[@0,@1,@2]; unit[@"enum_labels"] = @[@"days",@"hours",@"minutes"]; items[@"auto_expiry_unit"] = [unit copy];
        definitions = [items copy];
    });
    return definitions;
}

@interface RCSettingsCLIService ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic) BOOL actionPending;
@property (nonatomic) BOOL executing;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@end

@implementation RCSettingsCLIService
+ (instancetype)shared {
    static RCSettingsCLIService *service; static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [[self alloc] init]; });
    return service;
}
- (instancetype)init { return [self initWithDefaults:NSUserDefaults.standardUserDefaults]; }
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}

// Service seams allow isolated tests without touching login registration, history,
// Sparkle, editor contents or the system permission UI.
- (BOOL)loginEnabled { return RCLoginItemService.shared.loginItemEnabled; }
- (NSInteger)loginStatus { return RCLoginItemService.shared.loginItemStatus; }
- (BOOL)setLoginEnabled:(BOOL)enabled { return [RCLoginItemService.shared setLoginItemEnabled:enabled]; }
- (NSString *)language { return RCLocalization.selectedLanguage; }
- (void)applyLanguage:(NSString *)language { [RCLocalization setLanguage:language]; }
- (BOOL)saveEditor { return [RCSnippetEditorWindowController.shared saveChangesIfLoaded]; }
- (NSArray *)excludedApplications { return [RCExcludeAppService.shared excludedBundleIdentifiers]; }
- (void)applyExcludedApplications:(NSArray *)values { [RCExcludeAppService.shared setExcludedBundleIdentifiers:values]; }
- (void)applyUpdaterValues:(NSDictionary *)values {
    if (values[@"update_check_interval"]) RCUpdateService.shared.updateCheckInterval = [values[@"update_check_interval"] doubleValue];
    if (values[@"automatic_update_check"]) RCUpdateService.shared.automaticallyChecksForUpdates = [values[@"automatic_update_check"] boolValue];
}
- (void)applyAppearance { [RCAppearanceController applySavedAppearance]; }
- (void)scheduleCleanup { [RCDataCleanService.shared performCleanup]; }
- (void)performUIAction:(NSString *)action {
    [NSApp activateIgnoringOtherApps:YES];
    if ([action isEqual:@"update-check"]) [RCUpdateService.shared checkForUpdates];
    else [RCAccessibilityService.shared checkAndRequestAccessibilityWithAlert];
}

- (NSDictionary *)executeRequest:(NSDictionary *)request {
    __block NSDictionary *response;
    void (^execute)(void) = ^{
        // Defaults KVO is synchronous. A reentrant request must not observe or
        // mutate a half-applied batch, including during a modal save failure.
        if (self.executing) { response = RCSettingsFailure(@"Settings request already in progress"); return; }
        self.executing = YES;
        @try { response = [self executeOnMainThread:request]; }
        @finally { self.executing = NO; }
    };
    if (NSThread.isMainThread) execute();
    else dispatch_sync(dispatch_get_main_queue(), execute);
    return response;
}

- (id)normalizedValue:(id)value definition:(NSDictionary *)definition key:(NSString *)key {
    NSString *type = definition[@"type"];
    if ([type isEqual:@"boolean"]) return RCSettingsBoolean(value) ? value : nil;
    if ([type isEqual:@"integer"]) {
        if (![value isKindOfClass:NSNumber.class] || RCSettingsBoolean(value)) return nil;
        double number = [value doubleValue];
        if (!isfinite(number) || floor(number) != number) return nil;
        if (definition[@"minimum"] && number < [definition[@"minimum"] doubleValue]) return nil;
        if (definition[@"maximum"] && number > [definition[@"maximum"] doubleValue]) return nil;
        if (definition[@"enum"] && ![definition[@"enum"] containsObject:value]) return nil;
        return @([value integerValue]);
    }
    if ([type isEqual:@"string"]) {
        return [value isKindOfClass:NSString.class] && [definition[@"enum"] containsObject:value] ? [value copy] : nil;
    }
    if ([type isEqual:@"array"]) {
        if (![value isKindOfClass:NSArray.class] || [value count] > 1024) return nil;
        NSMutableOrderedSet *identifiers = [NSMutableOrderedSet orderedSet];
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-."] invertedSet];
        for (id entry in value) {
            if (![entry isKindOfClass:NSString.class] || [entry length] > 1024) return nil;
            NSString *identifier = [[entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
            if (!identifier.length || identifier.length > 255 || [identifier rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
            if ([identifier hasPrefix:@"."] || [identifier hasSuffix:@"."] || [identifier containsString:@".."]) return nil;
            [identifiers addObject:identifier];
        }
        return identifiers.array;
    }
    if (![value isKindOfClass:NSDictionary.class] || [value count] > [definition[@"allowed_properties"] count]) return nil;
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
    for (id name in value) {
        if (![name isKindOfClass:NSString.class] || ![definition[@"allowed_properties"] containsObject:name]) return nil;
        id entry = value[name];
        if ([key isEqual:@"store_types"]) {
            if (!RCSettingsBoolean(entry)) return nil;
            normalized[name] = entry;
        } else {
            if (![entry isKindOfClass:NSString.class] || [entry length] > 32) return nil;
            NSString *hex = [entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
            if (hex.length != 6 || [hex rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
            normalized[name] = [@"#" stringByAppendingString:hex.uppercaseString];
        }
    }
    return [normalized copy];
}

- (id)valueForSetting:(NSString *)key {
    NSDictionary *definition = RCSettingsDefinitions()[key];
    if ([key isEqual:@"login_at_startup"]) return @([self loginEnabled]);
    if ([key isEqual:@"language"]) return [self language];
    if ([key isEqual:@"excluded_applications"]) return [self excludedApplications];
    id value = [self.defaults objectForKey:definition[@"defaults_key"]];
    if ([definition[@"type"] isEqual:@"object"]) {
        NSMutableDictionary *merged = [definition[@"default"] mutableCopy];
        if ([value isKindOfClass:NSDictionary.class]) {
            for (NSString *name in definition[@"allowed_properties"]) {
                id entry = value[name];
                if ([key isEqual:@"store_types"] && ([entry isKindOfClass:NSNumber.class] || [entry isKindOfClass:NSString.class])) merged[name] = @([entry boolValue]);
                else if (entry) {
                    NSDictionary *normalized = [self normalizedValue:@{name:entry} definition:definition key:key];
                    if (normalized[name]) merged[name] = normalized[name];
                }
            }
        }
        return merged;
    }
    // Historical defaults may contain numeric booleans, as accepted by the GUI.
    if ([definition[@"type"] isEqual:@"boolean"] && [value isKindOfClass:NSNumber.class]) return @([value boolValue]);
    return [self normalizedValue:value definition:definition key:key] ?: definition[@"default"];
}
- (NSDictionary *)valuesForKeys:(NSArray *)keys {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in keys) values[key] = [self valueForSetting:key];
    return values;
}

- (NSDictionary *)executeOnMainThread:(NSDictionary *)request {
    if (![request isKindOfClass:NSDictionary.class]) return RCSettingsFailure(@"Expected JSON object");
    NSString *op = request[@"op"];
    if (![op isKindOfClass:NSString.class]) return RCSettingsFailure(@"Missing op");
    NSDictionary *fields = @{@"settings-schema":@[@"op"], @"settings-get":@[@"op",@"key"], @"settings-set":@[@"op",@"values"], @"app-action":@[@"op",@"action"]};
    if (!fields[op]) return RCSettingsFailure(@"Unknown settings operation");
    for (id field in request) if (![fields[op] containsObject:field]) return RCSettingsFailure(@"Unknown request field");
    NSDictionary *definitions = RCSettingsDefinitions();
    if ([op isEqual:@"settings-schema"]) {
        return RCSettingsSuccess(@{@"schema_version":@1, @"settings":definitions,
            @"security_boundary":@{@"history_readable":@NO, @"clipboard_readable":@NO,
                @"list_get_scope":@"user-created templates only",
                @"bug_report_auto_collects_clipboard":@NO, @"bug_report_auto_collects_history":@NO,
                @"bug_report_auto_collects_logs":@NO},
            @"operations":@[@"settings-schema",@"settings-get",@"settings-set",@"app-action"],
            @"transport_operations":@{@"bug-report":@{
                @"description":@"Submit through the CLI socket and shared report service; not an app-action or synchronous settings operation.",
                @"required":@[@"op",@"title",@"description",@"contact",@"source_info_consent"],
                @"additionalProperties":@NO,
                @"properties":@{@"op":@{@"const":@"bug-report"}, @"title":@{@"type":@"string",@"minLength":@1,@"maxLength":@120},
                    @"description":@{@"type":@"string",@"minLength":@1,@"maxLength":@2500}, @"contact":@{@"type":@"string",@"maxLength":@200},
                    @"source_info_consent":@{@"type":@"boolean",@"const":@YES}},
                @"normalization":@"Trim surrounding whitespace; length limits use UTF-16 code units, as in the GUI.",
                @"timeout_seconds":@20, @"success_status":@"sent",
                @"timeout_semantics":@"Delivery may be unknown if submission started; no automatic retry."}},
            @"actions":@{@"update-check":@{@"status":@"queued", @"description":@"Attempt a check through the normal update service; queued does not mean started. Busy/setup failure and later completion are not returned by this request."}, @"permissions":@{@"status":@"queued", @"scope":@"accessibility", @"description":@"Open normal permission guidance when permission is missing; queued does not mean permission granted."}},
            @"unsupported_actions":@{@"restart":@"No existing safe saved-editor and confirmation implementation."},
            @"excluded_groups":@[@"shortcuts",@"panic"],
            @"set_semantics":@{@"validate_all_before_mutation":@YES, @"transactional":@NO, @"retention_confirmation_required":@NO, @"cleanup":@"scheduled after all settings writes; completion not awaited", @"login":@"registration is attempted first; OS approval may remain required", @"ui_refresh":@"RCSettingsDidChangeNotification on main after writes; userInfo.keys contains applied setting names"}});
    }
    if ([op isEqual:@"app-action"]) {
        NSString *action = request[@"action"];
        if (![action isKindOfClass:NSString.class] || ![@[@"update-check",@"permissions"] containsObject:action]) return RCSettingsFailure(@"Unsupported action; use settings-schema for supported actions");
        if (self.actionPending) return RCSettingsFailure(@"An app action is already pending");
        action = [action copy];
        self.actionPending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [self performUIAction:action]; }
            @finally { self.actionPending = NO; }
        });
        return RCSettingsSuccess(@{@"action":action, @"status":@"queued"});
    }
    if ([op isEqual:@"settings-get"]) {
        id key = request[@"key"];
        if (key && (![key isKindOfClass:NSString.class] || !definitions[key])) return RCSettingsFailure(@"Unknown setting key");
        NSArray *keys = key ? @[key] : [definitions.allKeys sortedArrayUsingSelector:@selector(compare:)];
        return RCSettingsSuccess(@{@"values":[self valuesForKeys:keys]});
    }
    id rawValues = request[@"values"];
    if (![rawValues isKindOfClass:NSDictionary.class] || ![rawValues count] || [rawValues count] > definitions.count) return RCSettingsFailure(@"values must be a nonempty object of supported settings");
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (id key in rawValues) {
        if (![key isKindOfClass:NSString.class] || !definitions[key]) return RCSettingsFailure(@"Unknown setting key");
        id normalized = [self normalizedValue:rawValues[key] definition:definitions[key] key:key];
        if (!normalized) return RCSettingsFailure([NSString stringWithFormat:@"Invalid value for %@; see settings-schema", key]);
        values[key] = normalized;
    }
    NSArray *keys = [values.allKeys sortedArrayUsingSelector:@selector(compare:)];
    // Menu rendering consumes the stored palette directly. Materialize defaults
    // before replacement so storage, schema and CLI readback agree, even for {}.
    // Start from defaults, not the old palette: omitted colors are reset.
    for (NSString *key in @[@"menu_custom_colors_dark", @"menu_custom_colors_light"]) {
        if (!values[key]) continue;
        NSMutableDictionary *palette = [definitions[key][@"default"] mutableCopy];
        [palette addEntriesFromDictionary:values[key]];
        values[key] = [palette copy];
    }
    // Preserve pending editor edits before broadcasting a UI language change.
    if (values[@"language"] && ![values[@"language"] isEqual:[self language]] && ![self saveEditor]) return RCSettingsFailure(@"Could not save editor; settings unchanged");
    // Only fallible setting service runs before any defaults writes or cleanup.
    if (values[@"login_at_startup"] && ![self setLoginEnabled:[values[@"login_at_startup"] boolValue]]) return RCSettingsFailure(@"Login item registration failed; settings defaults unchanged");
    NSInteger previousLimit = [[self valueForSetting:@"max_history_size"] integerValue];
    if (values[@"store_types"]) {
        NSMutableDictionary *types = [[self valueForSetting:@"store_types"] mutableCopy];
        [types addEntriesFromDictionary:values[@"store_types"]]; values[@"store_types"] = types;
    }
    for (NSString *key in keys) {
        if ([@[@"language",@"excluded_applications",@"automatic_update_check",@"update_check_interval"] containsObject:key]) continue;
        [self.defaults setObject:values[key] forKey:definitions[key][@"defaults_key"]];
    }
    if (values[@"excluded_applications"]) [self applyExcludedApplications:values[@"excluded_applications"]];
    [self applyUpdaterValues:values];
    if (values[@"appearance"]) [self applyAppearance];
    if (values[@"show_status_item"]) [NSNotificationCenter.defaultCenter postNotificationName:@"RCStatusItemPreferenceDidChangeNotification" object:nil userInfo:@{@"showStatusItem":values[@"show_status_item"]}];
    if (values[@"language"] && ![values[@"language"] isEqual:[self language]]) [self applyLanguage:values[@"language"]];
    BOOL cleanup = values[@"auto_expiry_enabled"] || values[@"auto_expiry_value"] || values[@"auto_expiry_unit"] || (values[@"max_history_size"] && [values[@"max_history_size"] integerValue] < previousLimit);
    if (cleanup) [self scheduleCleanup];
    [NSNotificationCenter.defaultCenter postNotificationName:RCSettingsDidChangeNotification object:self userInfo:@{@"keys":keys}];
    NSMutableDictionary *result = [@{@"values":[self valuesForKeys:keys], @"applied_keys":keys, @"cleanup_scheduled":@(cleanup)} mutableCopy];
    if (values[@"login_at_startup"]) result[@"login_status"] = @([self loginStatus]);
    return RCSettingsSuccess(result);
}
@end
