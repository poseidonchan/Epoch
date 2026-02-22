import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreLiveActivityTests: XCTestCase {
    func testLifecycleStartCreatesInlineThinkingProcess() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        let payload = LifecyclePayload(
            agentRunId: UUID(),
            projectId: UUID(),
            sessionId: sessionID,
            phase: "start",
            error: nil
        )

        store._receiveGatewayEventForTesting(.lifecycle(payload))

        let process = store.activeInlineProcess(for: sessionID)
        XCTAssertNotNil(process)
        XCTAssertEqual(process?.phase, .thinking)
        XCTAssertNil(process?.activeLine)
    }

    func testFirstAssistantDeltaClearsThinkingAndBindsMessageID() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        let runID = UUID()
        let projectID = UUID()
        let messageID = UUID()

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "start",
                    error: nil
                )
            )
        )

        store._receiveGatewayEventForTesting(
            .assistantDelta(
                AssistantDeltaPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    messageId: messageID,
                    delta: "Hello"
                )
            )
        )

        let process = store.activeInlineProcess(for: sessionID)
        XCTAssertNotNil(process)
        XCTAssertEqual(process?.assistantMessageID, messageID)
        XCTAssertEqual(process?.phase, .responding)
        XCTAssertNil(process?.activeLine)
    }

    func testToolStartEndConvertsIngToEdAndReturnsToThinking() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        let runID = UUID()
        let projectID = UUID()

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "start",
                    error: nil
                )
            )
        )

        store._receiveGatewayEventForTesting(
            .toolEvent(
                ToolEventPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    runId: nil,
                    toolCallId: "tool-search-1",
                    tool: "web.search_query",
                    phase: "start",
                    summary: "Searching papers",
                    detail: [:],
                    ts: "2026-02-22T00:00:00Z"
                )
            )
        )

        let activeDuringTool = store.activeInlineProcess(for: sessionID)
        XCTAssertEqual(activeDuringTool?.phase, .toolCalling)
        XCTAssertEqual(activeDuringTool?.activeLine, "Searching...")
        XCTAssertEqual(activeDuringTool?.entries.last?.state, .active)

        store._receiveGatewayEventForTesting(
            .toolEvent(
                ToolEventPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    runId: nil,
                    toolCallId: "tool-search-1",
                    tool: "web.search_query",
                    phase: "end",
                    summary: "Search completed",
                    detail: [:],
                    ts: "2026-02-22T00:00:01Z"
                )
            )
        )

        let process = store.activeInlineProcess(for: sessionID)
        XCTAssertEqual(process?.phase, .thinking)
        XCTAssertNil(process?.activeLine)
        XCTAssertEqual(process?.entries.last?.state, .completed)
        XCTAssertEqual(process?.entries.last?.completedText, "Searched ...")
    }

    func testLifecycleEndPersistsSummaryGroupedByFamily() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        let projectID = UUID()
        let runID = UUID()
        let messageID = UUID()

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "start",
                    error: nil
                )
            )
        )

        store._receiveGatewayEventForTesting(
            .toolEvent(
                ToolEventPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    runId: nil,
                    toolCallId: "search-1",
                    tool: "web.search_query",
                    phase: "start",
                    summary: "Searching",
                    detail: [:],
                    ts: "2026-02-22T00:00:02Z"
                )
            )
        )

        store._receiveGatewayEventForTesting(
            .toolEvent(
                ToolEventPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    runId: nil,
                    toolCallId: "search-1",
                    tool: "web.search_query",
                    phase: "end",
                    summary: "Searched",
                    detail: [:],
                    ts: "2026-02-22T00:00:03Z"
                )
            )
        )

        for toolCallId in ["list-1", "list-2"] {
            store._receiveGatewayEventForTesting(
                .toolEvent(
                    ToolEventPayload(
                        agentRunId: runID,
                        projectId: projectID,
                        sessionId: sessionID,
                        runId: nil,
                        toolCallId: toolCallId,
                        tool: "fs.list",
                        phase: "start",
                        summary: "Listing files",
                        detail: [:],
                        ts: "2026-02-22T00:00:04Z"
                    )
                )
            )

            store._receiveGatewayEventForTesting(
                .toolEvent(
                    ToolEventPayload(
                        agentRunId: runID,
                        projectId: projectID,
                        sessionId: sessionID,
                        runId: nil,
                        toolCallId: toolCallId,
                        tool: "fs.list",
                        phase: "end",
                        summary: "Listed files",
                        detail: [:],
                        ts: "2026-02-22T00:00:05Z"
                    )
                )
            )
        }

        store._receiveGatewayEventForTesting(
            .assistantDelta(
                AssistantDeltaPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    messageId: messageID,
                    delta: "Done."
                )
            )
        )

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "end",
                    error: nil
                )
            )
        )

        XCTAssertNil(store.activeInlineProcess(for: sessionID))
        let summary = store.persistedProcessSummary(for: messageID)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.familyCounts[.search], 1)
        XCTAssertEqual(summary?.familyCounts[.list], 2)
        XCTAssertEqual(summary?.headline, "Explored 1 search, 2 lists")
        XCTAssertEqual(summary?.entries.count, 3)
    }

    func testLifecycleEndWithoutToolsProducesNoPersistedSummary() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        let runID = UUID()
        let projectID = UUID()
        let messageID = UUID()

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "start",
                    error: nil
                )
            )
        )

        store._receiveGatewayEventForTesting(
            .assistantDelta(
                AssistantDeltaPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    messageId: messageID,
                    delta: "Direct answer"
                )
            )
        )

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "end",
                    error: nil
                )
            )
        )

        XCTAssertNil(store.persistedProcessSummary(for: messageID))
    }

    func testToolEventWithoutRunIsStillVisibleInInlineProcess() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        let payload = ToolEventPayload(
            agentRunId: UUID(),
            projectId: UUID(),
            sessionId: sessionID,
            runId: nil,
            toolCallId: "tool-1",
            tool: "python.exec",
            phase: "start",
            summary: "Preparing Python execution",
            detail: [:],
            ts: "2026-02-22T00:00:00Z"
        )

        store._receiveGatewayEventForTesting(.toolEvent(payload))

        let process = store.activeInlineProcess(for: sessionID)
        XCTAssertNotNil(process)
        XCTAssertEqual(process?.phase, .toolCalling)
        XCTAssertEqual(process?.activeLine, "Running command...")
    }

    func testLateToolEventAfterAssistantCompletionDoesNotResurrectPendingThinking() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        let projectID = UUID()
        let runID = UUID()
        let messageID = UUID()

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "start",
                    error: nil
                )
            )
        )
        store._receiveGatewayEventForTesting(
            .assistantDelta(
                AssistantDeltaPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    messageId: messageID,
                    delta: "I can help with that."
                )
            )
        )
        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "end",
                    error: nil
                )
            )
        )

        XCTAssertNil(store.pendingInlineProcess(for: sessionID))
        XCTAssertNil(store.activeInlineProcess(for: sessionID))

        store._receiveGatewayEventForTesting(
            .toolEvent(
                ToolEventPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    runId: nil,
                    toolCallId: "late-tool-1",
                    tool: "labos_plan_propose",
                    phase: "start",
                    summary: "Starting labos_plan_propose",
                    detail: [:],
                    ts: "2026-02-22T00:00:04Z"
                )
            )
        )

        XCTAssertNil(store.pendingInlineProcess(for: sessionID))
        XCTAssertNil(store.activeInlineProcess(for: sessionID))
    }

    func testHistorySnapshotClearsStalePendingProcessWhenAssistantReplyExists() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_771_781_100)

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "start",
                    error: nil
                )
            )
        )
        store._receiveGatewayEventForTesting(
            .toolEvent(
                ToolEventPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    runId: nil,
                    toolCallId: "tool-ghost",
                    tool: "labos_plan_propose",
                    phase: "start",
                    summary: "Thinking",
                    detail: [:],
                    ts: "2026-02-22T00:00:00Z"
                )
            )
        )

        XCTAssertEqual(store.pendingInlineProcess(for: sessionID)?.activeLine, "Thinking...")

        let user = ChatMessage(
            sessionID: sessionID,
            role: .user,
            text: "What is this?",
            createdAt: base
        )
        let assistant = ChatMessage(
            sessionID: sessionID,
            role: .assistant,
            text: "It is a flower.",
            createdAt: base.addingTimeInterval(1)
        )

        store.applySessionHistorySnapshot(
            projectID: projectID,
            sessionID: sessionID,
            messages: [user, assistant],
            fetchedAt: base.addingTimeInterval(2)
        )

        XCTAssertNil(store.pendingInlineProcess(for: sessionID))
        XCTAssertNil(store.activeInlineProcess(for: sessionID))
    }

    func testHistorySnapshotPreservesPendingProcessWhenLatestMessageIsUser() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let runID = UUID()
        let base = Date(timeIntervalSince1970: 1_771_781_300)

        store._receiveGatewayEventForTesting(
            .lifecycle(
                LifecyclePayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    phase: "start",
                    error: nil
                )
            )
        )
        store._receiveGatewayEventForTesting(
            .toolEvent(
                ToolEventPayload(
                    agentRunId: runID,
                    projectId: projectID,
                    sessionId: sessionID,
                    runId: nil,
                    toolCallId: "tool-ghost",
                    tool: "labos_plan_propose",
                    phase: "start",
                    summary: "Thinking",
                    detail: [:],
                    ts: "2026-02-22T00:00:00Z"
                )
            )
        )

        let user = ChatMessage(
            sessionID: sessionID,
            role: .user,
            text: "Pending reply",
            createdAt: base
        )

        store.applySessionHistorySnapshot(
            projectID: projectID,
            sessionID: sessionID,
            messages: [user],
            fetchedAt: base.addingTimeInterval(1)
        )

        XCTAssertNotNil(store.pendingInlineProcess(for: sessionID))
        XCTAssertNotNil(store.activeInlineProcess(for: sessionID))
    }

    func testHistorySnapshotClearsPendingInlineProcessEvenWithStalePendingEchoWhenAssistantReplyExists() async {
        let suiteName = "LabOS.StalePendingEcho.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create test defaults suite.")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        guard let project = await store.createProject(name: "P") else {
            XCTFail("Failed to create project.")
            return
        }
        guard let session = await store.createSession(projectID: project.id) else {
            XCTFail("Failed to create session.")
            return
        }

        store.saveGatewaySettings(wsURLString: "ws://127.0.0.1:8787/ws", token: "fake-token")
        store.sendMessage(projectID: project.id, sessionID: session.id, text: "hello")

        XCTAssertNotNil(store.pendingInlineProcess(for: session.id))

        let base = Date(timeIntervalSince1970: 1_771_781_500)
        let user = ChatMessage(
            sessionID: session.id,
            role: .user,
            text: "hello",
            createdAt: base
        )
        let assistant = ChatMessage(
            sessionID: session.id,
            role: .assistant,
            text: "done",
            createdAt: base.addingTimeInterval(1)
        )

        store.applySessionHistorySnapshot(
            projectID: project.id,
            sessionID: session.id,
            messages: [user, assistant],
            fetchedAt: base.addingTimeInterval(2)
        )

        XCTAssertNil(store.pendingInlineProcess(for: session.id))
        XCTAssertNil(store.activeInlineProcess(for: session.id))
    }

    func testMessageOrderIsStableWhenTimestampsMatch() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let ts = Date(timeIntervalSince1970: 1_771_732_700)

        let laterLexicalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000f0")!
        let earlierLexicalID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

        let first = ChatMessage(
            id: laterLexicalID,
            sessionID: sessionID,
            role: .assistant,
            text: "first insert",
            createdAt: ts
        )
        let second = ChatMessage(
            id: earlierLexicalID,
            sessionID: sessionID,
            role: .assistant,
            text: "second insert",
            createdAt: ts
        )

        store._receiveGatewayEventForTesting(
            .chatMessageCreated(projectID: projectID, sessionID: sessionID, message: first)
        )
        store._receiveGatewayEventForTesting(
            .chatMessageCreated(projectID: projectID, sessionID: sessionID, message: second)
        )

        XCTAssertEqual(store.messages(for: sessionID).map(\.id), [earlierLexicalID, laterLexicalID])
    }
}
