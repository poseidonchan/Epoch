import XCTest
@testable import EpochCore

final class ChatImageURLResolverTests: XCTestCase {
    func testResolvesHTTPSURL() {
        let result = ChatImageURLResolver.resolve("https://example.com/image.png")

        XCTAssertEqual(result?.scheme?.lowercased(), "https")
        XCTAssertEqual(result?.absoluteString, "https://example.com/image.png")
    }

    func testResolvesFileURL() {
        let result = ChatImageURLResolver.resolve("file:///tmp/flower.jpg")

        XCTAssertTrue(result?.isFileURL == true)
        XCTAssertEqual(result?.path, "/tmp/flower.jpg")
    }

    func testResolvesAbsolutePathAsFileURL() {
        let result = ChatImageURLResolver.resolve("/Users/chan/Pictures/rose.png")

        XCTAssertTrue(result?.isFileURL == true)
        XCTAssertEqual(result?.path, "/Users/chan/Pictures/rose.png")
    }

    func testRejectsUnsupportedScheme() {
        let result = ChatImageURLResolver.resolve("ftp://example.com/file.png")

        XCTAssertNil(result)
    }

    func testRejectsInvalidURL() {
        let result = ChatImageURLResolver.resolve("not a url")

        XCTAssertNil(result)
    }
}
