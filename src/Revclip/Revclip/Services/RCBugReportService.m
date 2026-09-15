#import "RCBugReportService.h"
#import "RCLocalization.h"

NSNotificationName const RCBugReportServiceDidChangeNotification = @"RCBugReportServiceDidChangeNotification";
static const NSUInteger RCBugReportMaximumResponseBytes = 16384;

/// Per-submission transport; retains no credentials, cookies or persistent cache.
@interface RCBugReportTransport : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic) BOOL rejected;
@property (nonatomic, copy) void (^completion)(BOOL success);
- (void)startRequest:(NSURLRequest *)request configuration:(NSURLSessionConfiguration *)configuration;
- (void)cancel;
@end

@implementation RCBugReportTransport
- (void)startRequest:(NSURLRequest *)request configuration:(NSURLSessionConfiguration *)configuration {
    self.responseData = [NSMutableData data];
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    [[self.session dataTaskWithRequest:request] resume];
}
- (void)cancel {
    self.completion = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    self.rejected = YES;
    completionHandler(nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    [self handleChallenge:challenge completionHandler:completionHandler];
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    [self handleChallenge:challenge completionHandler:completionHandler];
}
- (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    // Keep platform TLS validation; never supply an HTTP or client-certificate credential.
    completionHandler([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]
                      ? NSURLSessionAuthChallengePerformDefaultHandling : NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if (![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200 ||
        response.expectedContentLength > (int64_t)RCBugReportMaximumResponseBytes) {
        self.rejected = YES;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length > RCBugReportMaximumResponseBytes - self.responseData.length) {
        self.rejected = YES;
        [task cancel];
        return;
    }
    [self.responseData appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    BOOL success = NO;
    if (!error && !self.rejected && [task.response isKindOfClass:NSHTTPURLResponse.class] &&
        ((NSHTTPURLResponse *)task.response).statusCode == 200) {
        id json = [NSJSONSerialization JSONObjectWithData:self.responseData options:0 error:nil];
        id ok = [json isKindOfClass:NSDictionary.class] ? json[@"ok"] : nil;
        success = [ok isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)ok) == CFBooleanGetTypeID() && [ok boolValue];
    }
    void (^completion)(BOOL) = self.completion;
    self.completion = nil;
    self.responseData = nil;
    [session finishTasksAndInvalidate];
    self.session = nil;
    if (completion) { completion(success); }
}
@end

@interface RCBugReportService ()
@property (nonatomic, readwrite, getter=isSubmitting) BOOL submitting;
@property (nonatomic, copy, readwrite) NSDictionary *draft;
@property (nonatomic, copy, readwrite) NSDictionary *lastResponse;
@end

@implementation RCBugReportService
+ (instancetype)shared {
    static RCBugReportService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [[self alloc] init]; });
    return service;
}
- (NSDictionary *)bundleInformation { return NSBundle.mainBundle.infoDictionary ?: @{}; }
- (NSString *)appVersion {
    NSDictionary *info = [self bundleInformation];
    NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"";
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : @"";
    if (version.length && build.length) { return [NSString stringWithFormat:@"%@ (%@)", version, build]; }
    return version.length ? version : build;
}
- (NSString *)osVersion {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion];
}
- (NSURL *)configuredEndpoint {
    id value = [self bundleInformation][@"RCBugReportURL"];
    if (![value isKindOfClass:NSString.class] || [value length] == 0) { return nil; }
    NSURLComponents *components = [NSURLComponents componentsWithString:value];
    if (![components.scheme.lowercaseString isEqualToString:@"https"] || !components.host.length ||
        components.user != nil || components.password != nil || components.fragment != nil) { return nil; }
    return components.URL;
}
- (NSURLSessionConfiguration *)sessionConfiguration {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 15;
    configuration.timeoutIntervalForResource = 15;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    configuration.waitsForConnectivity = NO;
    return configuration;
}
- (NSDictionary<NSString *, NSString *> *)sourceMetadata {
    NSString *language = [RCLocalization selectedLanguage];
    if (!language.length) { language = NSLocale.preferredLanguages.firstObject ?: NSLocale.currentLocale.localeIdentifier; }
    return @{@"app_version": self.appVersion, @"os_version": self.osVersion,
             @"language": language, @"timezone": NSTimeZone.localTimeZone.name};
}
- (void)deliverResponse:(NSDictionary *)response completion:(void (^)(NSDictionary *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(response); });
}
- (void)submitTitle:(NSString *)title description:(NSString *)description contact:(NSString *)contact
           consent:(BOOL)consent completion:(void (^)(NSDictionary *))completion {
    NSAssert(NSThread.isMainThread, @"Bug report submissions must start on the main thread");
    NSParameterAssert(completion != nil);
    // Reject before generating metadata, changing draft state, or creating a session.
    if (!consent) {
        [self deliverResponse:@{@"ok": @NO, @"error": @"Consent to source information collection is required."} completion:completion];
        return;
    }
    if (self.isSubmitting) {
        [self deliverResponse:@{@"ok": @NO, @"error": @"A report is already being sent. Please wait."} completion:completion];
        return;
    }
    if (![title isKindOfClass:NSString.class] || ![description isKindOfClass:NSString.class] || ![contact isKindOfClass:NSString.class]) {
        [self deliverResponse:@{@"ok": @NO, @"error": @"Enter a title (1–120 characters), a description (1–2,500), and an optional contact (up to 200)."} completion:completion];
        return;
    }
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *trimmedTitle = [title stringByTrimmingCharactersInSet:whitespace];
    NSString *trimmedDescription = [description stringByTrimmingCharactersInSet:whitespace];
    NSString *trimmedContact = [contact stringByTrimmingCharactersInSet:whitespace];
    if (!trimmedTitle.length || trimmedTitle.length > 120 || !trimmedDescription.length || trimmedDescription.length > 2500 || trimmedContact.length > 200) {
        [self deliverResponse:@{@"ok": @NO, @"error": @"Enter a title (1–120 characters), a description (1–2,500), and an optional contact (up to 200)."} completion:completion];
        return;
    }
    NSURL *endpoint = [self configuredEndpoint];
    if (!endpoint) {
        [self deliverResponse:@{@"ok": @NO, @"error": @"Bug reporting is unavailable in this build."} completion:completion];
        return;
    }
    NSMutableDictionary *payload = [self.sourceMetadata mutableCopy];
    [payload addEntriesFromDictionary:@{@"title": trimmedTitle, @"description": trimmedDescription,
                                       @"contact": trimmedContact, @"source_info_consent": @YES}];
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) {
        [self deliverResponse:@{@"ok": @NO, @"error": @"Could not send the report. Your text is preserved. Please try again when you are ready."} completion:completion];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.HTTPBody = body;
    // Copy each input so caller-owned mutable strings cannot change the retained draft.
    self.draft = @{@"title": [title copy], @"description": [description copy], @"contact": [contact copy], @"source_info_consent": @YES};
    self.lastResponse = nil;
    self.submitting = YES;
    RCBugReportTransport *transport = [[RCBugReportTransport alloc] init];
    // The session retains its delegate until invalidation. Its one-shot completion retains
    // the service through delivery, without a service -> transport -> service cycle.
    transport.completion = ^(BOOL success) {
        self.submitting = NO;
        NSDictionary *response = success ? @{@"ok": @YES, @"result": @{@"status": @"sent"}}
            : @{@"ok": @NO, @"error": @"Could not send the report. Your text is preserved. Please try again when you are ready."};
        self.lastResponse = response;
        if (success) { self.draft = nil; }
        [NSNotificationCenter.defaultCenter postNotificationName:RCBugReportServiceDidChangeNotification object:self];
        [self deliverResponse:response completion:completion];
    };
    [NSNotificationCenter.defaultCenter postNotificationName:RCBugReportServiceDidChangeNotification object:self];
    [transport startRequest:request configuration:[self sessionConfiguration]];
}
@end
