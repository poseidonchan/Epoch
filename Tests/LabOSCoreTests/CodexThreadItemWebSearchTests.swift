import XCTest
@testable import LabOSCore

final class CodexThreadItemWebSearchTests: XCTestCase {
    func testDecodeWebSearchWithSearchAction() throws {
        let item = try decodeThreadItem(
            #"{"type":"webSearch","id":"ws-1","query":"Skogafoss weather","action":{"type":"search","query":"Skogafoss weather","queries":["Skogafoss weather","south iceland forecast"]}}"#
        )

        guard case let .webSearch(search) = item else {
            return XCTFail("Expected webSearch item, got \(item.itemType)")
        }

        XCTAssertEqual(search.id, "ws-1")
        XCTAssertEqual(search.query, "Skogafoss weather")
        XCTAssertEqual(search.action, .search(query: "Skogafoss weather", queries: ["Skogafoss weather", "south iceland forecast"]))
    }

    func testDecodeWebSearchWithOpenPageAction() throws {
        let item = try decodeThreadItem(
            #"{"type":"webSearch","id":"ws-2","query":"Skogafoss","action":{"type":"openPage","url":"https://example.com/skogafoss"}}"#
        )

        guard case let .webSearch(search) = item else {
            return XCTFail("Expected webSearch item, got \(item.itemType)")
        }

        XCTAssertEqual(search.action, .openPage(url: "https://example.com/skogafoss"))
    }

    func testDecodeWebSearchWithFindInPageAction() throws {
        let item = try decodeThreadItem(
            #"{"type":"webSearch","id":"ws-3","query":"Skogafoss","action":{"type":"findInPage","url":"https://example.com/skogafoss","pattern":"parking"}}"#
        )

        guard case let .webSearch(search) = item else {
            return XCTFail("Expected webSearch item, got \(item.itemType)")
        }

        XCTAssertEqual(search.action, .findInPage(url: "https://example.com/skogafoss", pattern: "parking"))
    }

    func testDecodeWebSearchUnknownActionFallsBackToOther() throws {
        let item = try decodeThreadItem(
            #"{"type":"webSearch","id":"ws-4","query":"Skogafoss","action":{"type":"somethingElse","foo":"bar"}}"#
        )

        guard case let .webSearch(search) = item else {
            return XCTFail("Expected webSearch item, got \(item.itemType)")
        }

        XCTAssertEqual(search.action, .other)
    }

    func testDecodeWebSearchWithNilAction() throws {
        let item = try decodeThreadItem(
            #"{"type":"webSearch","id":"ws-5","query":"Skogafoss","action":null}"#
        )

        guard case let .webSearch(search) = item else {
            return XCTFail("Expected webSearch item, got \(item.itemType)")
        }

        XCTAssertNil(search.action)
    }

    private func decodeThreadItem(_ json: String) throws -> CodexThreadItem {
        try JSONDecoder().decode(CodexThreadItem.self, from: Data(json.utf8))
    }
}
