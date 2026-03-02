import XCTest
@testable import EpochCore

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
            case "epoch/session/read":
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
                throw NSError(domain: "EpochCoreTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected method"])
            }
        }
        defer { store.codexRequestOverrideForTests = nil }

        store.openSession(projectID: projectID, sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            (store.codexItemsBySession[sessionID] ?? []).count == 2
        }

        XCTAssertTrue(requestedMethods.contains("epoch/session/read"))
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
            case "epoch/session/read":
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
                throw NSError(domain: "EpochCoreTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected method"])
            }
        }
        defer { store.codexRequestOverrideForTests = nil }

        store.openSession(projectID: projectID, sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            (store.codexItemsBySession[sessionID] ?? []).count == 2
        }

        XCTAssertEqual(requestedMethods.first, "epoch/session/read")
        XCTAssertTrue(requestedMethods.contains("thread/read"))
        XCTAssertEqual(store.codexItemsBySession[sessionID]?.count, 2)
        XCTAssertEqual(store.codexStatusTextBySession[sessionID], "completed")
    }

    func testOpenSessionHydratesContextFromSessionRead() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thr_history_context_1"

        store.projects = [
            Project(id: projectID, name: "Codex History Context Project"),
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
            preview: "context",
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
                    id: "turn_ctx_1",
                    items: [
                        .userMessage(
                            CodexUserMessageItem(
                                type: "userMessage",
                                id: "item_ctx_user_1",
                                content: [CodexUserInput(type: "text", text: "Hi", url: nil, path: nil)]
                            )
                        ),
                        .agentMessage(
                            CodexAgentMessageItem(
                                type: "agentMessage",
                                id: "item_ctx_agent_1",
                                text: "Context ready"
                            )
                        ),
                    ],
                    status: "completed",
                    error: nil
                ),
            ]
        )
        let context = SessionContextState(
            projectId: projectID,
            sessionId: sessionID,
            permissionLevel: "full",
            modelId: "gpt-5.1",
            contextWindowTokens: 100000,
            usedInputTokens: 12000,
            usedTokens: 19000,
            remainingTokens: 88000,
            updatedAt: Date(timeIntervalSince1970: 1_772_200_000)
        )

        let codexSession = store.sessionsByProject[projectID]![0]
        store.codexRequestOverrideForTests = { method, _ in
            switch method {
            case "epoch/session/read":
                let sessionJSON = try Self.encodeJSONValue(codexSession, store: store)
                let threadJSON = try Self.encodeJSONValue(thread, store: store)
                let contextJSON = try Self.encodeJSONValue(context, store: store)
                return CodexRPCResponse(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "session": sessionJSON,
                        "thread": threadJSON,
                        "context": contextJSON,
                    ]),
                    error: nil
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw NSError(domain: "EpochCoreTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected method"])
            }
        }
        defer { store.codexRequestOverrideForTests = nil }

        store.openSession(projectID: projectID, sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            store.sessionContextBySession[sessionID]?.remainingTokens == 88000
        }

        let hydratedContext = try XCTUnwrap(store.sessionContextBySession[sessionID])
        XCTAssertEqual(hydratedContext.permissionLevel, "full")
        XCTAssertEqual(hydratedContext.contextWindowTokens, 100000)
        XCTAssertEqual(hydratedContext.usedInputTokens, 12000)
        XCTAssertEqual(hydratedContext.usedTokens, 19000)
        XCTAssertEqual(hydratedContext.remainingTokens, 88000)

        let usage = try XCTUnwrap(store.codexTokenUsageBySession[sessionID])
        XCTAssertEqual(usage.threadId, threadID)
        XCTAssertEqual(usage.inputTokens, 12000)
        XCTAssertEqual(usage.totalTokens, 19000)
        XCTAssertEqual(usage.contextWindowTokens, 100000)
        XCTAssertEqual(usage.remainingTokens, 88000)
        let fraction = try XCTUnwrap(store.contextRemainingFraction(for: sessionID))
        XCTAssertEqual(fraction, 0.88, accuracy: 0.0001)
    }

    func testSessionReadWithoutActivePlanKeepsIncompleteLocalLivePlan() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thr_history_plan_keep"

        store.projects = [Project(id: projectID, name: "Codex History Plan Keep Project")]
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

        store.livePlanBySession[sessionID] = AgentPlanUpdatedPayload(
            agentRunId: UUID(),
            projectId: projectID,
            sessionId: sessionID,
            explanation: "Keep this plan",
            plan: [
                .init(step: "Step A", status: "completed"),
                .init(step: "Step B", status: "in_progress"),
            ]
        )

        let thread = CodexThread(
            id: threadID,
            preview: "history",
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
                    id: "turn_keep_1",
                    items: [
                        .userMessage(
                            CodexUserMessageItem(
                                type: "userMessage",
                                id: "item_keep_user_1",
                                content: [CodexUserInput(type: "text", text: "Hi", url: nil, path: nil)]
                            )
                        ),
                        .agentMessage(
                            CodexAgentMessageItem(
                                type: "agentMessage",
                                id: "item_keep_agent_1",
                                text: "Hello from history"
                            )
                        ),
                    ],
                    status: "completed",
                    error: nil
                ),
            ]
        )
        let codexSession = store.sessionsByProject[projectID]![0]

        store.codexRequestOverrideForTests = { method, _ in
            switch method {
            case "epoch/session/read":
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
                throw NSError(domain: "EpochCoreTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected method"])
            }
        }
        defer { store.codexRequestOverrideForTests = nil }

        store.openSession(projectID: projectID, sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            (store.codexItemsBySession[sessionID] ?? []).count == 2
        }

        let retained = try XCTUnwrap(store.livePlanBySession[sessionID])
        XCTAssertEqual(retained.plan.count, 2)
        XCTAssertEqual(retained.plan[1].status, "in_progress")
    }

    func testSessionReadWithoutActivePlanClearsTerminalLocalLivePlan() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thr_history_plan_clear"

        store.projects = [Project(id: projectID, name: "Codex History Plan Clear Project")]
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

        store.livePlanBySession[sessionID] = AgentPlanUpdatedPayload(
            agentRunId: UUID(),
            projectId: projectID,
            sessionId: sessionID,
            explanation: "Already done",
            plan: [
                .init(step: "Step A", status: "completed"),
                .init(step: "Step B", status: "completed"),
            ]
        )

        let thread = CodexThread(
            id: threadID,
            preview: "history",
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
                    id: "turn_clear_1",
                    items: [
                        .userMessage(
                            CodexUserMessageItem(
                                type: "userMessage",
                                id: "item_clear_user_1",
                                content: [CodexUserInput(type: "text", text: "Hi", url: nil, path: nil)]
                            )
                        ),
                        .agentMessage(
                            CodexAgentMessageItem(
                                type: "agentMessage",
                                id: "item_clear_agent_1",
                                text: "Hello from history"
                            )
                        ),
                    ],
                    status: "completed",
                    error: nil
                ),
            ]
        )
        let codexSession = store.sessionsByProject[projectID]![0]

        store.codexRequestOverrideForTests = { method, _ in
            switch method {
            case "epoch/session/read":
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
                throw NSError(domain: "EpochCoreTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected method"])
            }
        }
        defer { store.codexRequestOverrideForTests = nil }

        store.openSession(projectID: projectID, sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            (store.codexItemsBySession[sessionID] ?? []).count == 2
        }

        XCTAssertNil(store.livePlanBySession[sessionID])
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
