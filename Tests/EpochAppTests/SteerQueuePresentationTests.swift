#if os(iOS)
import XCTest
@testable import EpochCore
@testable import EpochApp

final class SteerQueuePresentationTests: XCTestCase {
    func testDisplayItemsAreReversedFromActualQueueOrder() {
        let first = makeQueueItem(text: "first", sortIndex: 0)
        let second = makeQueueItem(text: "second", sortIndex: 1)
        let third = makeQueueItem(text: "third", sortIndex: 2)

        let display = SteerQueuePresentation.displayItems(from: [first, second, third])

        XCTAssertEqual(display.map(\.id), [third.id, second.id, first.id])
    }

    func testActualOrderFromDisplayIDsIsReverseOfDisplayOrder() {
        let first = makeQueueItem(text: "first", sortIndex: 0)
        let second = makeQueueItem(text: "second", sortIndex: 1)
        let third = makeQueueItem(text: "third", sortIndex: 2)
        let queue = [first, second, third]
        let displayIDs = [third.id, first.id, second.id]

        let actualIDs = SteerQueuePresentation.actualOrderIDs(fromDisplayOrder: displayIDs, queue: queue)

        XCTAssertEqual(actualIDs, [second.id, first.id, third.id])
    }

    func testPriorityDisplayItemMatchesActualFirstQueueItem() {
        let first = makeQueueItem(text: "priority", sortIndex: 0)
        let second = makeQueueItem(text: "second", sortIndex: 1)
        let third = makeQueueItem(text: "third", sortIndex: 2)

        let display = SteerQueuePresentation.displayItems(from: [first, second, third])
        let priority = SteerQueuePresentation.priorityDisplayItem(in: display)

        XCTAssertEqual(priority?.id, first.id)
    }

    private func makeQueueItem(text: String, sortIndex: Int) -> CodexQueuedUserInputItem {
        CodexQueuedUserInputItem(
            id: UUID(),
            sessionID: UUID(),
            text: text,
            attachments: [],
            createdAt: Date(),
            status: .queued,
            error: nil,
            sortIndex: sortIndex
        )
    }
}
#endif

#if !os(iOS)
import XCTest

final class SteerQueuePresentationTests: XCTestCase {
    func testSteerQueuePresentationBehaviorCoveredOnIOSOnly() {
        XCTAssertTrue(true)
    }
}
#endif
