#import <XCTest/XCTest.h>
#import "RCBugReportPreferencesViewController.h"
#import "RCBugReportService.h"
#import "RCLocalization.h"
#import "RCPreferencesPage.h"

@interface RCBugReportService (Testing)
- (NSDictionary *)bundleInformation;
- (NSURL *)configuredEndpoint;
- (NSURLSessionConfiguration *)sessionConfiguration;
@end
@interface RCBugReportPreferencesViewController (Testing)
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextView *descriptionField;
@property (nonatomic, strong) NSTextField *contactField;
@property (nonatomic, strong) NSButton *consentCheckbox;
@property (nonatomic, strong) NSTextField *metadataLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *sendButton;
@property (nonatomic) BOOL inFlight;
- (RCBugReportService *)reportService;
- (IBAction)sendReport:(id)sender;
- (void)controlTextDidChange:(NSNotification *)notification;
- (void)textDidChange:(NSNotification *)notification;
- (IBAction)formValueDidChange:(id)sender;
@end

@interface RCBugReportStubProtocol : NSURLProtocol
+ (void)setHandler:(void (^)(RCBugReportStubProtocol *))handler;
- (void)respondWithStatus:(NSInteger)status data:(NSData *)data;
@end
static void (^RCBugReportStubHandler)(RCBugReportStubProtocol *);

@implementation RCBugReportStubProtocol
+ (void)setHandler:(void (^)(RCBugReportStubProtocol *))handler {
    @synchronized(self) { RCBugReportStubHandler = [handler copy]; }
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    void (^handler)(RCBugReportStubProtocol *);
    @synchronized(self.class) { handler = RCBugReportStubHandler; }
    if (handler) { handler(self); }
    else { [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]]; }
}
- (void)stopLoading {}
- (void)respondWithStatus:(NSInteger)status data:(NSData *)data {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
@end

@interface RCBugReportServiceProbe : RCBugReportService
@property (nonatomic, copy) NSDictionary *testInfo;
@property (nonatomic) NSUInteger sessionCount;
@property (nonatomic) NSUInteger metadataReads;
@end
@implementation RCBugReportServiceProbe
- (NSDictionary *)bundleInformation { return self.testInfo ?: @{}; }
- (NSURLSessionConfiguration *)sessionConfiguration {
    self.sessionCount++;
    NSURLSessionConfiguration *configuration = [super sessionConfiguration];
    configuration.protocolClasses = @[RCBugReportStubProtocol.class];
    return configuration;
}
- (NSDictionary<NSString *, NSString *> *)sourceMetadata {
    self.metadataReads++;
    return [super sourceMetadata];
}
@end
@interface RCBugReportProbe : RCBugReportPreferencesViewController
@property (nonatomic, strong) RCBugReportService *testService;
@end
@implementation RCBugReportProbe
- (RCBugReportService *)reportService { return self.testService; }
@end

@interface RCBugReportTests : XCTestCase
@end
@implementation RCBugReportTests
- (void)tearDown {
    [RCBugReportStubProtocol setHandler:nil];
    [super tearDown];
}
- (RCBugReportServiceProbe *)service {
    RCBugReportServiceProbe *service = [RCBugReportServiceProbe new];
    service.testInfo = @{@"RCBugReportURL": @"https://reports.invalid/bug", @"CFBundleShortVersionString": @"1.2.3", @"CFBundleVersion": @"45"};
    return service;
}
- (RCBugReportProbe *)formForService:(RCBugReportService *)service {
    [NSApplication sharedApplication];
    RCBugReportProbe *form = [RCBugReportProbe new];
    form.testService = service;
    (void)form.view;
    return form;
}
- (void)fillForm:(RCBugReportProbe *)form {
    form.titleField.stringValue = @"  Example problem  ";
    form.descriptionField.string = @"Steps to reproduce\nObserved result";
    form.contactField.stringValue = @"person@example.invalid";
}
- (void)waitUntil:(BOOL (^)(void))condition {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return condition(); }];
    XCTestExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:nil];
    [self waitForExpectations:@[expectation] timeout:3];
}
- (NSDictionary *)bodyForRequest:(NSURLRequest *)request {
    NSData *body = request.HTTPBody;
    if (!body && request.HTTPBodyStream) {
        NSInputStream *stream = request.HTTPBodyStream;
        NSMutableData *bytes = [NSMutableData data];
        [stream open];
        uint8_t buffer[1024];
        NSInteger length;
        while ((length = [stream read:buffer maxLength:sizeof(buffer)]) > 0 && bytes.length < 32768) {
            [bytes appendBytes:buffer length:(NSUInteger)length];
        }
        [stream close];
        body = bytes;
    }
    return [NSJSONSerialization JSONObjectWithData:body ?: NSData.data options:0 error:nil];
}
- (void)testNoConsentIsAsyncMainFailureWithoutMetadataOrSession {
    RCBugReportServiceProbe *service = [self service];
    XCTestExpectation *done = [self expectationWithDescription:@"consent rejected asynchronously"];
    __block BOOL returned = NO;
    [service submitTitle:@"Title" description:@"Description" contact:@"" consent:NO completion:^(NSDictionary *response) {
        XCTAssertTrue(returned);
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqualObjects(response, (@{@"ok": @NO, @"error": @"Consent to source information collection is required."}));
        [done fulfill];
    }];
    returned = YES;
    XCTAssertFalse(service.isSubmitting);
    XCTAssertNil(service.draft);
    XCTAssertEqual(service.sessionCount, 0u);
    XCTAssertEqual(service.metadataReads, 0u);
    [self waitForExpectations:@[done] timeout:3];
}
- (void)testValidationIsSharedAndRejectsEachInvalidBoundaryBeforeNetworking {
    NSString *(^repeat)(NSUInteger) = ^NSString *(NSUInteger count) { return [@"x" stringByPaddingToLength:count withString:@"x" startingAtIndex:0]; };
    NSArray *cases = @[@[@" \n\t", @"Description", @""], @[@"Title", @" \n\t", @""],
                       @[repeat(121), @"Description", @""], @[@"Title", repeat(2501), @""], @[@"Title", @"Description", repeat(201)]];
    RCBugReportServiceProbe *service = [self service];
    for (NSArray *entry in cases) {
        XCTestExpectation *done = [self expectationWithDescription:@"invalid submission"];
        [service submitTitle:entry[0] description:entry[1] contact:entry[2] consent:YES completion:^(NSDictionary *response) {
            XCTAssertEqualObjects(response[@"ok"], @NO);
            XCTAssertNotNil(response[@"error"]);
            XCTAssertNil(response[@"result"]);
            [done fulfill];
        }];
        [self waitForExpectations:@[done] timeout:3];
    }
    XCTAssertEqual(service.sessionCount, 0u);
    XCTAssertEqual(service.metadataReads, 0u);
}
- (void)testExactEightFieldPayloadAndSuccessfulMainCallback {
    RCBugReportServiceProbe *service = [self service];
    NSString *title = [@"a" stringByPaddingToLength:120 withString:@"a" startingAtIndex:0];
    NSString *description = [@"b" stringByPaddingToLength:2500 withString:@"b" startingAtIndex:0];
    NSString *contact = [@"c" stringByPaddingToLength:200 withString:@"c" startingAtIndex:0];
    XCTestExpectation *done = [self expectationWithDescription:@"eight-field submission"];
    [RCBugReportStubProtocol setHandler:^(RCBugReportStubProtocol *stub) {
        XCTAssertEqualObjects(stub.request.HTTPMethod, @"POST");
        XCTAssertEqualObjects(stub.request.URL.absoluteString, @"https://reports.invalid/bug");
        XCTAssertEqualObjects([stub.request valueForHTTPHeaderField:@"Content-Type"], @"application/json");
        XCTAssertNil([stub.request valueForHTTPHeaderField:@"Authorization"]);
        NSDictionary *payload = [self bodyForRequest:stub.request];
        NSSet *expectedKeys = [NSSet setWithArray:@[@"title", @"description", @"contact", @"app_version", @"os_version", @"language", @"timezone", @"source_info_consent"]];
        XCTAssertEqualObjects([NSSet setWithArray:payload.allKeys], expectedKeys);
        XCTAssertEqualObjects(payload[@"title"], title);
        XCTAssertEqualObjects(payload[@"description"], description);
        XCTAssertEqualObjects(payload[@"contact"], contact);
        XCTAssertEqualObjects(payload[@"app_version"], @"1.2.3 (45)");
        XCTAssertTrue([payload[@"language"] length] > 0);
        XCTAssertEqualObjects(payload[@"timezone"], NSTimeZone.localTimeZone.name);
        XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)payload[@"source_info_consent"]), CFBooleanGetTypeID());
        XCTAssertEqualObjects(payload[@"source_info_consent"], @YES);
        [stub respondWithStatus:200 data:[@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding]];
    }];
    __block BOOL returned = NO;
    [service submitTitle:title description:description contact:contact consent:YES completion:^(NSDictionary *response) {
        XCTAssertTrue(returned);
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqualObjects(response, (@{@"ok": @YES, @"result": @{@"status": @"sent"}}));
        XCTAssertFalse(service.isSubmitting);
        XCTAssertNil(service.draft);
        [done fulfill];
    }];
    returned = YES;
    [self waitForExpectations:@[done] timeout:3];
    XCTAssertEqual(service.sessionCount, 1u);
}
- (void)testConcurrentSubmissionFailsBusyAndCannotMutateOriginalDraft {
    RCBugReportServiceProbe *service = [self service];
    __block RCBugReportStubProtocol *pending;
    XCTestExpectation *started = [self expectationWithDescription:@"first request"];
    XCTestExpectation *done = [self expectationWithDescription:@"first completes"];
    XCTestExpectation *busy = [self expectationWithDescription:@"second rejected"];
    [RCBugReportStubProtocol setHandler:^(RCBugReportStubProtocol *stub) { pending = stub; [started fulfill]; }];
    NSMutableString *title = [@"Original title" mutableCopy];
    [service submitTitle:title description:@"Description" contact:@"" consent:YES completion:^(NSDictionary *response) { [done fulfill]; }];
    [title setString:@"Mutated title"];
    __block BOOL returned = NO;
    [service submitTitle:@"Second title" description:@"Other" contact:@"" consent:YES completion:^(NSDictionary *response) {
        XCTAssertTrue(returned);
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqualObjects(response[@"error"], @"A report is already being sent. Please wait.");
        XCTAssertEqualObjects(response[@"ok"], @NO);
        [busy fulfill];
    }];
    returned = YES;
    [self waitForExpectations:@[started, busy] timeout:3];
    XCTAssertEqual(service.sessionCount, 1u);
    XCTAssertEqualObjects(service.draft[@"title"], @"Original title");
    [pending respondWithStatus:200 data:[@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitForExpectations:@[done] timeout:3];
}
- (void)testOnlyHTTP200AndBooleanTrueSucceedAndFailuresPreserveDraft {
    NSArray *cases = @[@[@200, @"{\"ok\":false}"], @[@200, @"{\"ok\":1}"], @[@200, @"{\"ok\":\"true\"}"],
                       @[@200, @"[]"], @[@200, @"private server details"], @[@201, @"{\"ok\":true}"], @[@500, @"private server details"],
                       @[@200, [@"x" stringByPaddingToLength:17000 withString:@"x" startingAtIndex:0]]];
    for (NSArray *entry in cases) {
        RCBugReportServiceProbe *service = [self service];
        XCTestExpectation *done = [self expectationWithDescription:@"generic failure"];
        [RCBugReportStubProtocol setHandler:^(RCBugReportStubProtocol *stub) {
            [stub respondWithStatus:[entry[0] integerValue] data:[entry[1] dataUsingEncoding:NSUTF8StringEncoding]];
        }];
        [service submitTitle:@" Title " description:@"Description" contact:@"" consent:YES completion:^(NSDictionary *response) {
            XCTAssertEqualObjects(response, (@{@"ok": @NO, @"error": @"Could not send the report. Your text is preserved. Please try again when you are ready."}));
            XCTAssertEqualObjects(service.draft[@"title"], @" Title ");
            XCTAssertEqualObjects(service.draft[@"description"], @"Description");
            [done fulfill];
        }];
        [self waitForExpectations:@[done] timeout:3];
    }
}
- (void)testNetworkErrorNeverResendsOrReturnsRawDetails {
    RCBugReportServiceProbe *service = [self service];
    XCTestExpectation *done = [self expectationWithDescription:@"timeout"];
    __block NSUInteger count = 0;
    [RCBugReportStubProtocol setHandler:^(RCBugReportStubProtocol *stub) {
        count++;
        [stub.client URLProtocol:stub didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
                                                                    userInfo:@{NSLocalizedDescriptionKey: @"sensitive diagnostic"}]];
    }];
    [service submitTitle:@"Title" description:@"Description" contact:@"" consent:YES completion:^(NSDictionary *response) {
        XCTAssertFalse([response[@"error"] containsString:@"sensitive diagnostic"]);
        XCTAssertEqualObjects(response[@"ok"], @NO);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:3];
    XCTAssertEqual(count, 1u);
}
- (void)testEndpointConfigurationAndTransportPrivacy {
    RCBugReportServiceProbe *service = [self service];
    NSURLSessionConfiguration *configuration = [service sessionConfiguration];
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 15);
    XCTAssertEqual(configuration.timeoutIntervalForResource, 15);
    XCTAssertNil(configuration.URLCredentialStorage);
    XCTAssertNil(configuration.HTTPCookieStorage);
    XCTAssertNil(configuration.URLCache);
    XCTAssertFalse(configuration.HTTPShouldSetCookies);
    XCTAssertFalse(configuration.waitsForConnectivity);
    XCTAssertEqualObjects([service configuredEndpoint].absoluteString, @"https://reports.invalid/bug");
    for (id value in @[@"", @"http://reports.invalid/bug", @"file:///tmp/report", @"https:///", @"https://user:secret@reports.invalid/bug", @"https://reports.invalid/#fragment", @42]) {
        service.testInfo = @{@"RCBugReportURL": value};
        XCTAssertNil([service configuredEndpoint]);
    }
}
- (void)testRedirectDelegateRejectsSameHostAndCrossHostRedirects {
    id<NSURLSessionTaskDelegate> transport = [NSClassFromString(@"RCBugReportTransport") new];
    XCTAssertNotNil(transport);
    for (NSString *target in @[@"https://reports.invalid/other", @"https://elsewhere.invalid/", @"http://elsewhere.invalid/"]) {
        __block BOOL callback = NO;
        [transport URLSession:nil task:nil willPerformHTTPRedirection:nil newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:target]]
            completionHandler:^(NSURLRequest *request) { callback = YES; XCTAssertNil(request); }];
        XCTAssertTrue(callback);
    }
}
- (void)testGUIConsentIsUncheckedAndRequired {
    RCBugReportServiceProbe *service = [self service];
    RCBugReportProbe *form = [self formForService:service];
    [self fillForm:form];
    XCTAssertEqual(form.consentCheckbox.state, NSControlStateValueOff);
    XCTAssertEqualObjects(form.consentCheckbox.title, RCLocalizedString(@"I consent to the collection of source information.", nil));
    XCTAssertFalse(form.sendButton.enabled);
    [form sendReport:nil];
    XCTAssertFalse(form.inFlight);
    XCTAssertEqual(service.sessionCount, 0u);
    XCTAssertEqualObjects(form.descriptionField.string, @"Steps to reproduce\nObserved result");
}
- (void)testConsentAccessibilityRoleValueAndPressPreserveNativeBehavior {
    RCBugReportServiceProbe *service = [self service];
    RCBugReportProbe *form = [self formForService:service];
    [self fillForm:form];
    NSButton *checkbox = form.consentCheckbox;
    XCTAssertTrue(checkbox.isAccessibilityElement);
    XCTAssertEqualObjects(checkbox.accessibilityRole, NSAccessibilityCheckBoxRole);
    XCTAssertEqualObjects(checkbox.accessibilityValue, @0);
    XCTAssertTrue([checkbox accessibilityPerformPress]);
    XCTAssertEqual(checkbox.state, NSControlStateValueOn);
    XCTAssertEqualObjects(checkbox.accessibilityValue, @1);
    XCTAssertTrue(form.sendButton.enabled);
    XCTAssertFalse(form.sendButton.allowsVibrancy);
    checkbox.enabled = NO;
    XCTAssertFalse(checkbox.isAccessibilityEnabled);
    XCTAssertFalse([checkbox accessibilityPerformPress]);
    XCTAssertEqual(checkbox.state, NSControlStateValueOn);
    form.sendButton.enabled = NO;
    XCTAssertEqualObjects(form.sendButton.accessibilityRole, NSAccessibilityButtonRole);
    XCTAssertFalse([form.sendButton accessibilityPerformPress]);
    XCTAssertEqual(service.sessionCount, 0u);
}
- (void)testSubmissionAndDraftSurvivePageDeallocationAndLanguageRefresh {
    RCBugReportServiceProbe *service = [self service];
    __block RCBugReportStubProtocol *pending;
    XCTestExpectation *started = [self expectationWithDescription:@"pending report"];
    [RCBugReportStubProtocol setHandler:^(RCBugReportStubProtocol *stub) { pending = stub; [started fulfill]; }];
    __weak RCBugReportProbe *weakPage;
    @autoreleasepool {
        RCBugReportProbe *form = [self formForService:service];
        [self fillForm:form];
        form.consentCheckbox.state = NSControlStateValueOn;
        weakPage = form;
        [form sendReport:nil];
        XCTAssertTrue(form.inFlight);
        XCTAssertFalse(form.sendButton.enabled);
        XCTAssertFalse(form.consentCheckbox.enabled);
    }
    XCTAssertNil(weakPage);
    [self waitForExpectations:@[started] timeout:3];
    RCBugReportProbe *replacement = [self formForService:service];
    XCTAssertEqualObjects(replacement.titleField.stringValue, @"  Example problem  ");
    XCTAssertEqualObjects(replacement.descriptionField.string, @"Steps to reproduce\nObserved result");
    XCTAssertTrue(replacement.inFlight);
    [NSNotificationCenter.defaultCenter postNotificationName:RCLanguageDidChangeNotification object:nil];
    XCTAssertEqualObjects(replacement.contactField.stringValue, @"person@example.invalid");
    [pending respondWithStatus:200 data:[@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self waitUntil:^BOOL { return !service.isSubmitting; }];
    XCTAssertEqualObjects(replacement.titleField.stringValue, @"");
    XCTAssertEqual(replacement.consentCheckbox.state, NSControlStateValueOff);
    XCTAssertFalse(replacement.sendButton.enabled);
}
- (void)testSendAvailabilityUpdatesForEveryInputBoundaryAndConsent {
    RCBugReportProbe *form = [self formForService:[self service]];
    XCTAssertFalse(form.sendButton.enabled);
    XCTAssertEqual(form.titleField.delegate, form);
    XCTAssertEqual(form.contactField.delegate, form);
    XCTAssertEqual(form.descriptionField.delegate, form);
    XCTAssertEqual(form.consentCheckbox.action, @selector(formValueDidChange:));
    form.titleField.stringValue = @"Title";
    [form controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:form.titleField]];
    XCTAssertFalse(form.sendButton.enabled);
    form.descriptionField.string = @"Description";
    [form textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:form.descriptionField]];
    XCTAssertFalse(form.sendButton.enabled);
    form.consentCheckbox.state = NSControlStateValueOn;
    [form formValueDidChange:form.consentCheckbox];
    XCTAssertTrue(form.sendButton.enabled);
    form.titleField.stringValue = [@"a" stringByPaddingToLength:120 withString:@"a" startingAtIndex:0];
    [form controlTextDidChange:nil];
    XCTAssertTrue(form.sendButton.enabled);
    form.titleField.stringValue = [form.titleField.stringValue stringByAppendingString:@"a"];
    [form controlTextDidChange:nil];
    XCTAssertFalse(form.sendButton.enabled);
    form.titleField.stringValue = @" \n ";
    [form controlTextDidChange:nil];
    XCTAssertFalse(form.sendButton.enabled);
    form.titleField.stringValue = @"Title";
    form.descriptionField.string = [@"b" stringByPaddingToLength:2500 withString:@"b" startingAtIndex:0];
    [form textDidChange:nil];
    XCTAssertTrue(form.sendButton.enabled);
    form.descriptionField.string = [form.descriptionField.string stringByAppendingString:@"b"];
    [form textDidChange:nil];
    XCTAssertFalse(form.sendButton.enabled);
    form.descriptionField.string = @" \n ";
    [form textDidChange:nil];
    XCTAssertFalse(form.sendButton.enabled);
    form.descriptionField.string = @"Description";
    form.contactField.stringValue = [@"c" stringByPaddingToLength:200 withString:@"c" startingAtIndex:0];
    [form controlTextDidChange:nil];
    XCTAssertTrue(form.sendButton.enabled);
    form.contactField.stringValue = [form.contactField.stringValue stringByAppendingString:@"c"];
    [form controlTextDidChange:nil];
    XCTAssertFalse(form.sendButton.enabled);
    form.contactField.stringValue = @"";
    [form controlTextDidChange:nil];
    XCTAssertTrue(form.sendButton.enabled);
    form.consentCheckbox.state = NSControlStateValueOff;
    [form formValueDidChange:form.consentCheckbox];
    XCTAssertFalse(form.sendButton.enabled);
}
- (void)testSendButtonReservesPillPaddingAcrossLocalizedTitles {
    RCBugReportProbe *form = [self formForService:[self service]];
    XCTAssertFalse(form.sendButton.bordered);
    for (NSString *title in @[@"送信", @"Envoyer le signalement", @"Bericht senden"]) {
        form.sendButton.title = title;
        NSSize textSize = [title sizeWithAttributes:@{NSFontAttributeName: form.sendButton.font}];
        XCTAssertGreaterThanOrEqual(form.sendButton.intrinsicContentSize.width, textSize.width + 40);
        XCTAssertEqual(form.sendButton.intrinsicContentSize.height, 36);
    }
}
- (void)testFailedDraftIsRestoredButANewFormRequiresConsentAgain {
    RCBugReportServiceProbe *service = [self service];
    XCTestExpectation *done = [self expectationWithDescription:@"failure retained"];
    [RCBugReportStubProtocol setHandler:^(RCBugReportStubProtocol *stub) { [stub respondWithStatus:500 data:NSData.data]; }];
    [service submitTitle:@"Draft title" description:@"Draft description" contact:@"" consent:YES completion:^(NSDictionary *response) { [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:3];
    RCBugReportProbe *form = [self formForService:service];
    XCTAssertEqualObjects(form.titleField.stringValue, @"Draft title");
    XCTAssertEqualObjects(form.descriptionField.string, @"Draft description");
    XCTAssertEqual(form.consentCheckbox.state, NSControlStateValueOff);
}
- (void)testCLISubmissionDoesNotEraseAnUnrelatedOpenGUIDraft {
    RCBugReportServiceProbe *service = [self service];
    RCBugReportProbe *form = [self formForService:service];
    [self fillForm:form];
    XCTestExpectation *done = [self expectationWithDescription:@"CLI completed"];
    [RCBugReportStubProtocol setHandler:^(RCBugReportStubProtocol *stub) {
        [stub respondWithStatus:200 data:[@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding]];
    }];
    [service submitTitle:@"CLI title" description:@"CLI description" contact:@"" consent:YES completion:^(NSDictionary *response) { [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:3];
    XCTAssertEqualObjects(form.titleField.stringValue, @"  Example problem  ");
    XCTAssertEqualObjects(form.descriptionField.string, @"Steps to reproduce\nObserved result");
}
- (void)testNarrowFormDocumentScrollsWithoutLosingDraft {
    RCBugReportProbe *form = [self formForService:[self service]];
    [self fillForm:form];
    NSView *document = form.view;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 520) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(200, 0, 660, 480)];
    scroll.hasVerticalScroller = YES;
    [window.contentView addSubview:scroll];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    [NSLayoutConstraint activateConstraints:@[
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
    ]];
    [window.contentView layoutSubtreeIfNeeded];
    NSScrollView *editorScroll = form.descriptionField.enclosingScrollView;
    XCTAssertEqual(editorScroll.borderType, NSNoBorder);
    XCTAssertFalse(editorScroll.drawsBackground);
    XCTAssertTrue([editorScroll.superview isKindOfClass:RCPreferencesTextField.class]);
    // The reused NSTextField surface has alignment insets; anchors describe that rect,
    // not the background's outer frame. Compare both in the surface's coordinates.
    NSView *surface = editorScroll.superview;
    NSRect surfaceAlignment = [surface alignmentRectForFrame:surface.frame];
    surfaceAlignment = [surface convertRect:surfaceAlignment fromView:surface.superview];
    NSRect editorAlignment = [editorScroll alignmentRectForFrame:editorScroll.frame];
    XCTAssertEqualWithAccuracy(NSMinX(editorAlignment) - NSMinX(surfaceAlignment), 12, 1);
    XCTAssertEqualWithAccuracy(NSHeight(surfaceAlignment) - NSHeight(editorAlignment), 16, 1);
    XCTAssertTrue(document.isFlipped);
    XCTAssertEqualWithAccuracy(document.frame.size.width, scroll.contentView.bounds.size.width, 1);
    XCTAssertLessThanOrEqual(document.subviews.firstObject.frame.size.width, 680.5);
    [document scrollPoint:NSZeroPoint];
    XCTAssertEqualWithAccuracy(NSMinY(document.visibleRect), 0, 1);
    [document scrollPoint:NSMakePoint(0, document.bounds.size.height)];
    XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0);
    XCTAssertEqualObjects(form.titleField.stringValue, @"  Example problem  ");
    [window close];
}
- (void)testRoundedDescriptionSurfaceExposesTheNativeEditableTextArea {
    RCBugReportServiceProbe *service = [self service];
    RCBugReportProbe *form = [self formForService:service];
    [self fillForm:form];
    NSTextView *editor = form.descriptionField;
    NSScrollView *scroll = editor.enclosingScrollView;
    NSView *surface = scroll.superview;
    XCTAssertFalse(surface.isAccessibilityElement);
    XCTAssertTrue([surface.accessibilityChildren containsObject:scroll]);
    XCTAssertEqualObjects(surface.accessibilityChildrenInNavigationOrder, surface.accessibilityChildren);
    NSMutableArray *pending = [surface.accessibilityChildren mutableCopy];
    NSMutableSet *visited = [NSMutableSet set];
    BOOL foundEditor = NO;
    while (pending.count && visited.count < 100) {
        id child = pending.lastObject;
        [pending removeLastObject];
        if (child == editor) { foundEditor = YES; break; }
        if ([visited containsObject:child]) { continue; }
        [visited addObject:child];
        if ([child respondsToSelector:@selector(accessibilityChildren)]) {
            [pending addObjectsFromArray:[child accessibilityChildren] ?: @[]];
        }
    }
    XCTAssertTrue(foundEditor, @"The rounded surface must expose its editor through the AX child tree");
    XCTAssertTrue(editor.isAccessibilityElement);
    XCTAssertEqualObjects(editor.accessibilityRole, NSAccessibilityTextAreaRole);
    XCTAssertTrue(editor.editable);
    XCTAssertEqualObjects(editor.accessibilityLabel, RCLocalizedString(@"Description (required, up to 2,500 characters)", nil));
    XCTAssertEqualObjects(editor.string, @"Steps to reproduce\nObserved result");
    XCTAssertEqual(service.sessionCount, 0u);
}
@end
