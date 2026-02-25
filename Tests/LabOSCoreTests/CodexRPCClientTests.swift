import XCTest
@testable import LabOSCore

final class CodexRPCClientTests: XCTestCase {
    @MainActor
    func testPendingRequestRaceDoesNotDoubleResumeContinuation() async {
        enum TestFailure: LocalizedError {
            case disconnected
            case sendFailure

            var errorDescription: String? {
                switch self {
                case .disconnected:
                    return "socket disconnected"
                case .sendFailure:
                    return "send failed"
                }
            }
        }

        let client = CodexRPCClient(
            wsURL: URL(string: "ws://127.0.0.1:8787/codex")!,
            token: "test-token"
        )

        let requestID = CodexRequestID.string("req-race")
        let waiter = Task {
            try await client.registerPendingRequestForTesting(id: requestID)
        }

        await Task.yield()
        XCTAssertEqual(client.pendingRequestCountForTesting, 1)

        client.failPendingRequestsForTesting(TestFailure.disconnected)
        client.finishPendingSendFailureForTesting(id: requestID, error: TestFailure.sendFailure)

        do {
            _ = try await waiter.value
            XCTFail("Expected continuation to fail once after disconnection")
        } catch {
            XCTAssertEqual(error.localizedDescription, "socket disconnected")
        }

        XCTAssertEqual(client.pendingRequestCountForTesting, 0)
    }

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
