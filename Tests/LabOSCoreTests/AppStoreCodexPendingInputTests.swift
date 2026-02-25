import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreCodexPendingInputTests: XCTestCase {
    func testRequestUserInputPublishesPendingSignalForNotifications() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Pending Signal Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Pending Signal Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_pending_signal"
            ),
        ]
        store.codexSessionByThread["thread_pending_signal"] = sessionID

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_pending_signal"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread_pending_signal"),
                    "turnId": .string("turn_pending_signal"),
                    "prompt": .string("Need operator decision"),
                    "questions": .array([
                        .object([
                            "id": .string("response"),
                            "question": .string("Choose one"),
                            "options": .array([
                                .object([
                                    "id": .string("safe"),
                                    "label": .string("Safe"),
                                    "description": .string("Recommended"),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        let pendingPrompt = try XCTUnwrap(store.codexPendingPrompt(for: sessionID))
        XCTAssertEqual(pendingPrompt.prompt, "Need operator decision")
        XCTAssertTrue(store.sessionNeedsUserInput(sessionID: sessionID))

        let signal = try XCTUnwrap(store.latestPendingUserInputSignal)
        XCTAssertEqual(signal.projectID, projectID)
        XCTAssertEqual(signal.sessionID, sessionID)
        XCTAssertEqual(signal.projectName, "Pending Signal Project")
        XCTAssertEqual(signal.sessionTitle, "Pending Signal Session")
    }

    func testRequestUserInputQueuesPromptsAndDequeuesByRequestID() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Prompt Queue Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Prompt Queue Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_prompt_queue"
            ),
        ]
        store.codexSessionByThread["thread_prompt_queue"] = sessionID

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_prompt_first"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread_prompt_queue"),
                    "turnId": .string("turn_prompt_queue_1"),
                    "prompt": .string("First prompt"),
                    "questions": .array([
                        .object([
                            "id": .string("response"),
                            "question": .string("Pick"),
                            "options": .array([
                                .object([
                                    "label": .string("One"),
                                    "description": .string("First"),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )
        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_prompt_second"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread_prompt_queue"),
                    "turnId": .string("turn_prompt_queue_2"),
                    "prompt": .string("Second prompt"),
                    "questions": .array([
                        .object([
                            "id": .string("response"),
                            "question": .string("Pick"),
                            "options": .array([
                                .object([
                                    "label": .string("Two"),
                                    "description": .string("Second"),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        XCTAssertEqual(store.codexPendingPromptQueue(for: sessionID).count, 2)
        XCTAssertEqual(store.codexPendingPrompt(for: sessionID)?.prompt, "First prompt")

        store.codexServerResponseOverrideForTests = { _, _, _ in }
        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .string("req_prompt_first"),
            answers: ["response": "One"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexPendingPromptQueue(for: sessionID).count == 1
        }
        XCTAssertEqual(store.codexPendingPrompt(for: sessionID)?.prompt, "Second prompt")
    }

    func testRequestUserInputParsesQuestionHeaderAndQuestionLevelIsOther() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Prompt Parse Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Prompt Parse Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_prompt_parse"
            ),
        ]
        store.codexSessionByThread["thread_prompt_parse"] = sessionID

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_prompt_parse"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread_prompt_parse"),
                    "turnId": .string("turn_prompt_parse"),
                    "prompt": .string("Need preference"),
                    "questions": .array([
                        .object([
                            "id": .string("label_mode"),
                            "header": .string("Labeling"),
                            "question": .string("How should labels render?"),
                            "isOther": .bool(true),
                            "options": .array([
                                .object([
                                    "label": .string("Verbatim"),
                                    "description": .string("Recommended"),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        let prompt = try XCTUnwrap(store.codexPendingPrompt(for: sessionID))
        let question = try XCTUnwrap(prompt.questions.first)
        XCTAssertEqual(question.header, "Labeling")
        XCTAssertEqual(question.isOther, true)
        XCTAssertEqual(question.options.first?.label, "Verbatim")
    }

    func testSessionNeedsUserInputIncludesPlanPromptApprovalsAndSessionMetadata() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.projects = [Project(id: projectID, name: "Pending Input Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server"
            ),
        ]

        XCTAssertFalse(store.sessionNeedsUserInput(sessionID: sessionID))

        let plan = ExecutionPlan(
            projectID: projectID,
            sessionID: sessionID,
            steps: [
                PlanStep(
                    title: "Step",
                    runtime: .shell,
                    inputs: [],
                    outputs: []
                ),
            ]
        )
        store.planService.pendingApprovalsBySession[sessionID] = PendingApproval(
            planId: UUID(),
            projectId: projectID,
            sessionId: sessionID,
            agentRunId: UUID(),
            plan: plan,
            required: true,
            judgment: nil
        )
        XCTAssertTrue(store.sessionNeedsUserInput(sessionID: sessionID))

        store.planService.pendingApprovalsBySession[sessionID] = nil
        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .int(11),
                sessionID: sessionID,
                threadId: "thr_pending",
                turnId: "turn_1",
                prompt: "Need your input",
                rawParams: nil
            ),
        ]
        XCTAssertTrue(store.sessionNeedsUserInput(sessionID: sessionID))

        store.codexPendingPromptBySession[sessionID] = nil
        store.codexPendingApprovalsBySession[sessionID] = [
            CodexPendingApproval(
                requestID: .int(12),
                kind: .commandExecution,
                sessionID: sessionID,
                threadId: "thr_pending",
                turnId: "turn_1",
                itemId: "item_1",
                reason: "approval",
                command: "echo test",
                cwd: "/tmp",
                grantRoot: nil,
                rawParams: nil
            ),
        ]
        XCTAssertTrue(store.sessionNeedsUserInput(sessionID: sessionID))

        store.codexPendingApprovalsBySession[sessionID] = []
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                hasPendingUserInput: true,
                pendingUserInputCount: 2,
                pendingUserInputKind: "prompt"
            ),
        ]
        XCTAssertTrue(store.sessionNeedsUserInput(sessionID: sessionID))
    }

    func testRespondToCodexPromptSendsNestedAnswerPayload() async throws {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        let requestID: CodexRequestID = .int(99)

        var capturedRequestID: CodexRequestID?
        var capturedResult: JSONValue?
        var capturedError: CodexRPCError?
        store.codexServerResponseOverrideForTests = { id, result, error in
            capturedRequestID = id
            capturedResult = result
            capturedError = error
        }

        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: requestID,
            answers: ["question_main": "Option A"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedResult != nil
        }

        XCTAssertEqual(capturedRequestID, requestID)
        XCTAssertNil(capturedError)
        XCTAssertEqual(
            capturedResult,
            .object([
                "answers": .object([
                    "question_main": .object([
                        "answers": .array([.string("Option A")]),
                    ]),
                ]),
            ])
        )
        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
    }

    func testRespondToCodexPromptClearsSessionPendingMetadata() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Prompt Metadata Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Prompt Metadata Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_prompt_metadata",
                hasPendingUserInput: true,
                pendingUserInputCount: 1,
                pendingUserInputKind: "prompt"
            ),
        ]

        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .int(12),
                sessionID: sessionID,
                threadId: "thread_prompt_metadata",
                turnId: "turn_1",
                prompt: "Need your input",
                rawParams: nil
            ),
        ]
        XCTAssertTrue(store.sessionNeedsUserInput(sessionID: sessionID))

        var captured: JSONValue?
        store.codexServerResponseOverrideForTests = { _, result, _ in
            captured = result
        }

        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .int(12),
            answers: ["response": "Proceed now"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            captured != nil
        }

        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
        XCTAssertFalse(store.sessionNeedsUserInput(sessionID: sessionID))
    }

    func testSendMessageWhileStreamingQueuesCodexSteerInput() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.projects = [Project(id: projectID, name: "Steer Queue Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_queued"
            ),
        ]
        store.codexThreadBySession[sessionID] = "thread_queued"
        store.codexActiveTurnIDBySession[sessionID] = "turn_active"
        store.streamingSessions.insert(sessionID)

        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "Steer this trajectory")

        let queued = store.codexSteerQueue(for: sessionID)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.text, "Steer this trajectory")
        XCTAssertEqual(queued.first?.status, .queued)
    }

    func testTurnStartedAndCompletedTrackActiveTurnID() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        store.codexSessionByThread["thread_turn"] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/started",
                params: .object([
                    "threadId": .string("thread_turn"),
                    "turn": .object([
                        "id": .string("turn_123"),
                        "status": .string("inProgress"),
                    ]),
                ])
            )
        )
        XCTAssertEqual(store.codexActiveTurnID(for: sessionID), "turn_123")

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread_turn"),
                    "turn": .object([
                        "id": .string("turn_123"),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )
        XCTAssertNil(store.codexActiveTurnID(for: sessionID))
    }

    func testSteerQueuedCodexInputSuccessRemovesOnlyClickedRow() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Steer Queue Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_queued"
            ),
        ]
        store.codexThreadBySession[sessionID] = "thread_queued"
        store.codexActiveTurnIDBySession[sessionID] = "turn_active"
        store.streamingSessions.insert(sessionID)

        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "first queued steer")
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "second queued steer")
        let queuedBefore = store.codexSteerQueue(for: sessionID)
        XCTAssertEqual(queuedBefore.count, 2)

        var capturedMethod: String?
        var capturedParams: JSONValue?
        store.codexRequestOverrideForTests = { method, params in
            capturedMethod = method
            capturedParams = params
            return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
        }

        let target = try XCTUnwrap(queuedBefore.dropFirst().first)
        store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: target.id)

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexSteerQueue(for: sessionID).count == 1
        }

        XCTAssertEqual(capturedMethod, "turn/steer")
        XCTAssertEqual(
            capturedParams,
            .object([
                "threadId": .string("thread_queued"),
                "turnId": .string("turn_active"),
                "text": .string("second queued steer"),
            ])
        )
        XCTAssertEqual(store.codexSteerQueue(for: sessionID).first?.text, "first queued steer")
    }

    func testSteerQueuedCodexInputFailureMarksRowRetryable() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Steer Queue Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_queued"
            ),
        ]
        store.codexThreadBySession[sessionID] = "thread_queued"
        store.codexActiveTurnIDBySession[sessionID] = "turn_active"
        store.streamingSessions.insert(sessionID)
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "retry steer")

        store.codexRequestOverrideForTests = { _, _ in
            struct TestError: Error {}
            throw TestError()
        }

        let target = try XCTUnwrap(store.codexSteerQueue(for: sessionID).first)
        store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: target.id)

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexSteerQueue(for: sessionID).first?.status == .failed
        }

        let queuedAfter = try XCTUnwrap(store.codexSteerQueue(for: sessionID).first)
        XCTAssertEqual(queuedAfter.text, "retry steer")
        XCTAssertEqual(queuedAfter.status, .failed)
        XCTAssertNotNil(queuedAfter.error)
    }

    func testCodexTurnStartIncludesPlanModeFlag() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Plan Mode Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Codex Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_plan_mode"
            ),
        ]
        store.codexThreadBySession[sessionID] = "thread_plan_mode"
        store.codexSessionByThread["thread_plan_mode"] = sessionID
        store.codexConnectionState = .connected
        store.setPlanModeEnabled(for: sessionID, enabled: true)

        var capturedMethod: String?
        var capturedParams: JSONValue?
        store.codexRequestOverrideForTests = { method, params in
            capturedMethod = method
            capturedParams = params
            return CodexRPCResponse(
                id: .string("turn_start_ok"),
                result: .object([
                    "threadId": .string("thread_plan_mode"),
                    "turn": .object([
                        "id": .string("turn_plan_mode"),
                        "status": .string("inProgress"),
                    ]),
                ]),
                error: nil
            )
        }

        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "Please plan this task")

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedMethod == "turn/start"
        }

        XCTAssertEqual(capturedMethod, "turn/start")
        XCTAssertEqual(
            capturedParams,
            .object([
                "threadId": .string("thread_plan_mode"),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Please plan this task"),
                    ]),
                ]),
                "planMode": .bool(true),
            ])
        )
    }

    func testCodexTurnPlanUpdatedHydratesLivePlanAndClearsOnCompletion() throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Plan Progress Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Codex Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_plan_progress"
            ),
        ]
        store.codexSessionByThread["thread_plan_progress"] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/plan/updated",
                params: .object([
                    "threadId": .string("thread_plan_progress"),
                    "turnId": .string("turn_plan_progress"),
                    "explanation": .string("Validating assumptions"),
                    "plan": .array([
                        .object([
                            "step": .string("Investigate context"),
                            "status": .string("completed"),
                        ]),
                        .object([
                            "step": .string("Propose options"),
                            "status": .string("inProgress"),
                        ]),
                    ]),
                ])
            )
        )

        let livePlan = try XCTUnwrap(store.livePlanBySession[sessionID])
        XCTAssertEqual(livePlan.plan.count, 2)
        XCTAssertEqual(livePlan.plan[0].status, "completed")
        XCTAssertEqual(livePlan.plan[1].status, "in_progress")
        XCTAssertEqual(livePlan.explanation, "Validating assumptions")

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread_plan_progress"),
                    "turn": .object([
                        "id": .string("turn_plan_progress"),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )

        XCTAssertNil(store.livePlanBySession[sessionID])
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
