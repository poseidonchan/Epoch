import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreCodexImageBridgeTests: XCTestCase {
    private let validOnePixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X6X0AAAAASUVORK5CYII="

    func testViewImageToolCallStagesImageForSession() async throws {
        let store = makeStore(threadID: "thread_image_bridge_1")
        let sessionID = try XCTUnwrap(store.sessionsByProject.values.first?.first?.id)
        let rawPath = "/Users/chan/Downloads/LabOS.png"

        var requestedMethods: [String] = []
        store.codexRequestOverrideForTests = { method, _ in
            requestedMethods.append(method)
            XCTAssertEqual(method, "command/exec")
            return CodexRPCResponse(
                id: .string("req_image_bridge_1"),
                result: .object([
                    "exitCode": .number(0),
                    "stdout": .string(self.validOnePixelPNGBase64),
                    "stderr": .string(""),
                ]),
                error: nil
            )
        }
        defer { store.codexRequestOverrideForTests = nil }

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "codex/event/view_image_tool_call",
                params: .object([
                    "threadId": .string("thread_image_bridge_1"),
                    "event": .object([
                        "path": .string(rawPath),
                    ]),
                ])
            )
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexStagedImageURL(sessionID: sessionID, rawPath: rawPath) != nil
        }

        XCTAssertTrue(
            requestedMethods.isEmpty || requestedMethods == ["command/exec"],
            "Expected direct read or one command/exec fallback"
        )
        let staged = try XCTUnwrap(store.codexStagedImageURL(sessionID: sessionID, rawPath: rawPath))
        XCTAssertTrue(staged.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testImageViewItemStartedStagesImageForSession() async throws {
        let store = makeStore(threadID: "thread_image_bridge_2")
        let sessionID = try XCTUnwrap(store.sessionsByProject.values.first?.first?.id)
        let rawPath = "/Users/chan/Downloads/plot.jpg"

        store.codexRequestOverrideForTests = { method, _ in
            XCTAssertEqual(method, "command/exec")
            return CodexRPCResponse(
                id: .string("req_image_bridge_2"),
                result: .object([
                    "exitCode": .number(0),
                    "stdout": .string(self.validOnePixelPNGBase64),
                    "stderr": .string(""),
                ]),
                error: nil
            )
        }
        defer { store.codexRequestOverrideForTests = nil }

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string("thread_image_bridge_2"),
                    "turnId": .string("turn_2"),
                    "item": .object([
                        "type": .string("imageView"),
                        "id": .string("image_item_1"),
                        "path": .string(rawPath),
                    ]),
                ])
            )
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexStagedImageURL(sessionID: sessionID, rawPath: rawPath) != nil
        }

        XCTAssertNotNil(store.codexStagedImageURL(sessionID: sessionID, rawPath: rawPath))
    }

    func testNonImageExtensionOrInvalidBase64DoesNotStage() async throws {
        let store = makeStore(threadID: "thread_image_bridge_3")
        let sessionID = try XCTUnwrap(store.sessionsByProject.values.first?.first?.id)
        let nonImagePath = "/Users/chan/Downloads/readme.txt"
        let imagePath = "/Users/chan/Downloads/invalid.png"

        var requestCount = 0
        store.codexRequestOverrideForTests = { method, _ in
            requestCount += 1
            XCTAssertEqual(method, "command/exec")
            return CodexRPCResponse(
                id: .string("req_image_bridge_3"),
                result: .object([
                    "exitCode": .number(0),
                    "stdout": .string("not_base64"),
                    "stderr": .string(""),
                ]),
                error: nil
            )
        }
        defer { store.codexRequestOverrideForTests = nil }

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "codex/event/view_image_tool_call",
                params: .object([
                    "threadId": .string("thread_image_bridge_3"),
                    "path": .string(nonImagePath),
                ])
            )
        )

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "codex/event/view_image_tool_call",
                params: .object([
                    "threadId": .string("thread_image_bridge_3"),
                    "path": .string(imagePath),
                ])
            )
        )

        try await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(store.codexStagedImageURL(sessionID: sessionID, rawPath: nonImagePath))
        XCTAssertNil(store.codexStagedImageURL(sessionID: sessionID, rawPath: imagePath))
        XCTAssertEqual(requestCount, 1, "Only image extension should attempt command/exec")
    }

    func testCommandExecFailureKeepsPlaceholderState() async throws {
        let store = makeStore(threadID: "thread_image_bridge_4")
        let sessionID = try XCTUnwrap(store.sessionsByProject.values.first?.first?.id)
        let rawPath = "/Users/chan/Downloads/failure.png"

        store.codexRequestOverrideForTests = { _, _ in
            throw NSError(
                domain: "LabOSCoreTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "exec failed"]
            )
        }
        defer { store.codexRequestOverrideForTests = nil }

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "codex/event/view_image_tool_call",
                params: .object([
                    "threadId": .string("thread_image_bridge_4"),
                    "path": .string(rawPath),
                ])
            )
        )

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(store.codexStagedImageURL(sessionID: sessionID, rawPath: rawPath))
    }

    func testNestedViewImagePathAndTildePathAreStaged() async throws {
        let store = makeStore(threadID: "thread_image_bridge_5")
        let sessionID = try XCTUnwrap(store.sessionsByProject.values.first?.first?.id)
        let rawPath = "~/Downloads/LabOS.png"

        var requestedMethods: [String] = []
        store.codexRequestOverrideForTests = { method, _ in
            requestedMethods.append(method)
            return CodexRPCResponse(
                id: .string("req_image_bridge_5"),
                result: .object([
                    "exitCode": .number(0),
                    "stdout": .string(self.validOnePixelPNGBase64),
                    "stderr": .string(""),
                ]),
                error: nil
            )
        }
        defer { store.codexRequestOverrideForTests = nil }

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "codex/event/view_image",
                params: .object([
                    "threadId": .string("thread_image_bridge_5"),
                    "event": .object([
                        "payload": .object([
                            "path": .string(rawPath),
                        ]),
                    ]),
                ])
            )
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexStagedImageURL(sessionID: sessionID, rawPath: rawPath) != nil
        }

        XCTAssertEqual(requestedMethods, ["command/exec"])
        XCTAssertNotNil(store.codexStagedImageURL(sessionID: sessionID, rawPath: rawPath))
    }

    private func makeStore(threadID: String) -> AppStore {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Image Bridge Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Image Bridge Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID
        return store
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval,
        pollEvery interval: TimeInterval = 0.05,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        XCTFail("Timed out after \(timeoutSeconds)s")
    }
}
