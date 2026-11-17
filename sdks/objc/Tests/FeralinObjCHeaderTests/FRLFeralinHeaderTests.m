@import Foundation;
@import XCTest;
@import FeralinObjC;

// Köprünün Objective-C'den derlenip çağrılabildiğini sınar. Ağa çıkmaz: izin yoktur, olay üretilmez.
@interface FRLFeralinHeaderTests : XCTestCase
@end

@implementation FRLFeralinHeaderTests

- (void)testSecretKeyIsRejectedWithError {
    FRLConfiguration *configuration = [[FRLConfiguration alloc] initWithProjectKey:@"sk_live_abcdefgh"
                                                                        collectURL:@"https://collect.example.test"];
    NSError *error = nil;
    FRLFeralin *feralin = [[FRLFeralin alloc] initWithConfiguration:configuration error:&error];
    XCTAssertNil(feralin);
    XCTAssertEqual(error.code, (NSInteger)FRLErrorCodeConfiguration);
}

- (void)testTrackWithoutConsentProducesNoEvent {
    FRLConfiguration *configuration = [[FRLConfiguration alloc] initWithProjectKey:@"pk_test_objc_0001"
                                                                        collectURL:@"https://collect.example.test"];
    configuration.flushInterval = 0;
    NSError *error = nil;
    FRLFeralin *feralin = [[FRLFeralin alloc] initWithConfiguration:configuration error:&error];
    XCTAssertNotNil(feralin);
    XCTAssertNil(error);

    XCTestExpectation *done = [self expectationWithDescription:@"track"];
    [feralin track:@"order_completed"
        properties:@{@"order_id": @"ord_1", @"amount": @12.5}
        completion:^(NSString *eventID, NSError *trackError) {
            XCTAssertNil(eventID);
            XCTAssertNil(trackError);
            [done fulfill];
        }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testConsentConstraint {
    FRLConsent *consent = [[FRLConsent alloc] initWithAnalytics:YES advertising:YES personalization:NO sessionReplay:NO];
    FRLConsent *denied = [consent constrainedByTrackingStatus:FRLTrackingAuthorizationStatusDenied];
    XCTAssertFalse(denied.advertising);
    XCTAssertTrue(denied.analytics);
}

@end
