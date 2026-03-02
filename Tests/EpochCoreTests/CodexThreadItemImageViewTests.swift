import XCTest
@testable import EpochCore

final class CodexThreadItemImageViewTests: XCTestCase {
    func testDecodeImageViewThreadItem() throws {
        let json = """
        {
          "type": "imageView",
          "id": "img_1",
          "path": "/Users/chan/Downloads/Epoch.png"
        }
        """

        let item = try JSONDecoder().decode(CodexThreadItem.self, from: Data(json.utf8))
        guard case let .imageView(imageItem) = item else {
            return XCTFail("Expected imageView item, got \(item.itemType)")
        }

        XCTAssertEqual(imageItem.type, "imageView")
        XCTAssertEqual(imageItem.id, "img_1")
        XCTAssertEqual(imageItem.path, "/Users/chan/Downloads/Epoch.png")
        XCTAssertEqual(item.itemType, "imageView")
    }

    func testEncodeImageViewThreadItem() throws {
        let item = CodexThreadItem.imageView(
            CodexImageViewItem(
                type: "imageView",
                id: "img_2",
                path: "/tmp/plot.png"
            )
        )

        let data = try JSONEncoder().encode(item)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(object) = value else {
            return XCTFail("Expected object payload")
        }

        XCTAssertEqual(object["type"], .string("imageView"))
        XCTAssertEqual(object["id"], .string("img_2"))
        XCTAssertEqual(object["path"], .string("/tmp/plot.png"))
    }
}
