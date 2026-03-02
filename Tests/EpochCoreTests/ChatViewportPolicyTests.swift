import XCTest
@testable import EpochCore

final class ChatViewportPolicyTests: XCTestCase {
    func testIncomingContentDoesNotAutoScroll() {
        XCTAssertFalse(AppStore.shouldAutoScrollOnIncomingMessage())
        XCTAssertFalse(AppStore.shouldAutoScrollOnIncomingDelta())
        XCTAssertFalse(AppStore.shouldAutoScrollWhenStreamingCompletes())
    }

    func testInitialAppearCanAnchorToLatest() {
        XCTAssertTrue(AppStore.shouldAutoScrollOnInitialAppear(hasMessages: true))
        XCTAssertFalse(AppStore.shouldAutoScrollOnInitialAppear(hasMessages: false))
    }
}
