import XCTest
@testable import EpochCore

@MainActor
final class GatewayClientReliabilityTests: XCTestCase {
    private enum TestFailure: LocalizedError {
        case disconnected

        var errorDescription: String? {
            switch self {
            case .disconnected:
                return "socket disconnected"
            }
        }
    }

    func testFailPendingRequestsResumesWaitingContinuation() async {
        let client = GatewayClient(
            wsURL: URL(string: "ws://127.0.0.1:8787/ws")!,
            token: "test-token"
        )

        let waiter = Task {
            try await client.registerPendingRequestForTesting(id: "req-1")
        }

        await Task.yield()
        XCTAssertEqual(client.pendingRequestCountForTesting, 1)

        client.failPendingRequestsForTesting(TestFailure.disconnected)

        do {
            _ = try await waiter.value
            XCTFail("Expected pending continuation to fail when socket disconnects")
        } catch {
            XCTAssertEqual(error.localizedDescription, "socket disconnected")
        }

        XCTAssertEqual(client.pendingRequestCountForTesting, 0)
    }

    func testValidateOutgoingFrameSizeRejectsOversizedPayloads() {
        XCTAssertNoThrow(try GatewayClient.validateOutgoingFrameSizeForTesting(bytes: GatewayClient.maxOutgoingFrameBytesForTesting))
        XCTAssertThrowsError(
            try GatewayClient.validateOutgoingFrameSizeForTesting(bytes: GatewayClient.maxOutgoingFrameBytesForTesting + 1)
        )
    }
}
