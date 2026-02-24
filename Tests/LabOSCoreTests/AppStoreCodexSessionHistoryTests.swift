import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreCodexSessionHistoryTests: XCTestCase {
    func testOpenSessionHydratesCodexHistoryFromSessionRead() async throws {
        let store = AppStore(bootstrapDemo: false)

        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thr_history_1"

        store.projects = [
            Project(id: projectID, name: "Codex History Project"),
        ]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Codex Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexConnectionState = .connected

        let thread = CodexThread(
            id: threadID,
            preview: "hi",
            modelProvider: "openai",
            createdAt: 1,
            updatedAt: 2,
            path: nil,
            cwd: "/tmp",
            cliVersion: "0.1.0",
            source: "appServer",
            gitInfo: nil,
            turns: [
                CodexTurn(
                    id: "turn_1",
                    items: [
                        .userMessage(
                            CodexUserMessageItem(
                                type: "userMessage",
                                id: "item_user_1",
                                content: [CodexUserInput(type: "text", text: "Hi", url: nil, path: nil)]
                            )
                        ),
                        .agentMessage(
                            CodexAgentMessageItem(
                                type: "agentMessage",
                                id: "item_agent_1",
                                text: "Hello from history"
                            )
                        ),
                    ],
                    status: "completed",
                    error: nil
                ),
            ]
        )

        var session = store.sessionsByProject[projectID]?[0]
        session?.codexThreadId = threadID
        guard let codexSession = session else {
            XCTFail("Missing test session")
            return
        }

        var requestedMethods: [String] = []
        store.codexRequestOverrideForTests = { method, _ in
            requestedMethods.append(method)

            switch method {
            case "labos/session/read":
                let sessionJSON = try Self.encodeJSONValue(codexSession, store: store)
                let threadJSON = try Self.encodeJSONValue(thread, store: store)
                return CodexRPCResponse(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "session": sessionJSON,
                        "thread": threadJSON,
                    ]),
                    error: nil
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw NSError(domain: "LabOSCoreTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected method"])
            }
        }
        defer { store.codexRequestOverrideForTests = nil }

        store.openSession(projectID: projectID, sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            (store.codexItemsBySession[sessionID] ?? []).count == 2
        }

        XCTAssertTrue(requestedMethods.contains("labos/session/read"))
        XCTAssertEqual(store.codexItemsBySession[sessionID]?.count, 2)
        XCTAssertEqual(store.codexStatusTextBySession[sessionID], "completed")
        XCTAssertEqual(store.codexThreadBySession[sessionID], threadID)
        XCTAssertEqual(store.codexSessionByThread[threadID], sessionID)
    }

    func testOpenSessionFallsBackToThreadReadWhenSessionReadThreadIsEmpty() async throws {
        let store = AppStore(bootstrapDemo: false)

        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thr_history_fallback"

        store.projects = [
            Project(id: projectID, name: "Codex History Project"),
        ]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Codex Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexConnectionState = .connected

        let emptyThread = CodexThread(
            id: threadID,
            preview: "",
            modelProvider: "openai",
            createdAt: 1,
            updatedAt: 1,
            path: nil,
            cwd: "/tmp",
            cliVersion: "0.1.0",
            source: "appServer",
            gitInfo: nil,
            turns: []
        )

        let hydratedThread = CodexThread(
            id: threadID,
            preview: "hello",
            modelProvider: "openai",
            createdAt: 1,
            updatedAt: 2,
            path: nil,
            cwd: "/tmp",
            cliVersion: "0.1.0",
            source: "appServer",
            gitInfo: nil,
            turns: [
                CodexTurn(
                    id: "turn_1",
                    items: [
                        .userMessage(
                            CodexUserMessageItem(
                                type: "userMessage",
                                id: "item_user_1",
                                content: [CodexUserInput(type: "text", text: "Hi", url: nil, path: nil)]
                            )
                        ),
                        .agentMessage(
                            CodexAgentMessageItem(
                                type: "agentMessage",
                                id: "item_agent_1",
                                text: "Hello from thread/read"
                            )
                        ),
                    ],
                    status: "completed",
                    error: nil
                ),
            ]
        )

        let codexSession = store.sessionsByProject[projectID]![0]
        var requestedMethods: [String] = []
        store.codexRequestOverrideForTests = { method, _ in
            requestedMethods.append(method)
            switch method {
            case "labos/session/read":
                let sessionJSON = try Self.encodeJSONValue(codexSession, store: store)
                let threadJSON = try Self.encodeJSONValue(emptyThread, store: store)
                return CodexRPCResponse(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "session": sessionJSON,
                        "thread": threadJSON,
                    ]),
                    error: nil
                )
            case "thread/read":
                let threadJSON = try Self.encodeJSONValue(hydratedThread, store: store)
                return CodexRPCResponse(
                    id: .string(UUID().uuidString),
                    result: .object(["thread": threadJSON]),
                    error: nil
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw NSError(domain: "LabOSCoreTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected method"])
            }
        }
        defer { store.codexRequestOverrideForTests = nil }

        store.openSession(projectID: projectID, sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            (store.codexItemsBySession[sessionID] ?? []).count == 2
        }

        XCTAssertEqual(requestedMethods.first, "labos/session/read")
        XCTAssertTrue(requestedMethods.contains("thread/read"))
        XCTAssertEqual(store.codexItemsBySession[sessionID]?.count, 2)
        XCTAssertEqual(store.codexStatusTextBySession[sessionID], "completed")
    }

    private static func encodeJSONValue<T: Encodable>(_ value: T, store: AppStore) throws -> JSONValue {
        let data = try store.gatewayJSONEncoder.encode(value)
        return try store.gatewayJSONDecoder.decode(JSONValue.self, from: data)
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval,
        pollEvery interval: TimeInterval = 0.05,
        condition: @escaping () -> Bool
    ) async throws {
        let timeoutDate = Date().addingTimeInterval(timeoutSeconds)
        while Date() < timeoutDate {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        XCTFail("Condition timed out after \(timeoutSeconds)s")
    }
}
