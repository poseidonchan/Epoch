import XCTest
@testable import LabOSCore

final class CodexPlanPreviewTests: XCTestCase {
    func testCollapsedTextReturnsOriginalWhenWithinCap() {
        let text = String(repeating: "a", count: 120)
        XCTAssertEqual(
            CodexPlanPreview.collapsedText(from: text, characterLimit: 280),
            text
        )
    }

    func testCollapsedTextTruncatesWhenOverCap() {
        let text = String(repeating: "a", count: 400)
        let collapsed = CodexPlanPreview.collapsedText(from: text, characterLimit: 280)
        XCTAssertTrue(collapsed.hasSuffix("..."))
        XCTAssertEqual(collapsed.count, 280)
    }

    func testIsCollapsibleAtBoundary() {
        let exact = String(repeating: "a", count: 280)
        let over = String(repeating: "a", count: 281)
        XCTAssertFalse(CodexPlanPreview.isCollapsible(exact, characterLimit: 280))
        XCTAssertTrue(CodexPlanPreview.isCollapsible(over, characterLimit: 280))
    }
}
