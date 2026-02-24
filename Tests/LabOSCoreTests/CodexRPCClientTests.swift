import XCTest
@testable import LabOSCore

final class CodexRPCClientTests: XCTestCase {
    func testDecodeInboundRequestResponseAndNotification() throws {
        let requestJSON = #"{"id":91,"method":"item/fileChange/requestApproval","params":{"threadId":"thr_1"}}"#
        let notificationJSON = #"{"method":"turn/started","params":{"threadId":"thr_1"}}"#
        let responseJSON = #"{"id":91,"result":{"decision":"accept"}}"#

        switch try CodexRPCClient.decodeInboundPayloadForTesting(Data(requestJSON.utf8)) {
        case let .request(request):
            XCTAssertEqual(request.method, "item/fileChange/requestApproval")
            XCTAssertEqual(request.id, .int(91))
        default:
            XCTFail("Expected server request")
        }

        switch try CodexRPCClient.decodeInboundPayloadForTesting(Data(notificationJSON.utf8)) {
        case let .notification(notification):
            XCTAssertEqual(notification.method, "turn/started")
        default:
            XCTFail("Expected notification")
        }

        switch try CodexRPCClient.decodeInboundPayloadForTesting(Data(responseJSON.utf8)) {
        case let .response(response):
            XCTAssertEqual(response.id, .int(91))
            XCTAssertNil(response.error)
        default:
            XCTFail("Expected response")
        }
    }

    func testEncodeApprovalResponsePayload() throws {
        let response = CodexRPCResponse(
            id: .int(92),
            result: .object(["decision": .string("accept")]),
            error: nil
        )

        let encoded = try CodexRPCClient.encodeResponsePayloadForTesting(response)
        XCTAssertTrue(encoded.contains("\"id\":92"))
        XCTAssertTrue(encoded.contains("\"decision\":\"accept\""))
    }

    func testUnknownItemFallbackDecode() throws {
        let unknownItemJSON = #"{"type":"futureItemType","id":"item_unknown","alpha":1,"beta":"x"}"#
        let data = Data(unknownItemJSON.utf8)
        let decoder = JSONDecoder()

        let item = try decoder.decode(CodexThreadItem.self, from: data)
        switch item {
        case let .unknown(unknown):
            XCTAssertEqual(unknown.type, "futureItemType")
            XCTAssertEqual(unknown.id, "item_unknown")
            XCTAssertEqual(unknown.rawPayload["beta"], .string("x"))
        default:
            XCTFail("Expected unknown item fallback")
        }
    }
}
