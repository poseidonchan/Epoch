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

    func testRespondToCodexPromptMarksSessionAsStreaming() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.projects = [Project(id: projectID, name: "Prompt Streaming Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Prompt Streaming Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_prompt_streaming"
            ),
        ]
        store.codexSessionByThread["thread_prompt_streaming"] = sessionID

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_prompt_streaming"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread_prompt_streaming"),
                    "turnId": .string("turn_prompt_streaming"),
                    "prompt": .string("Select a flow"),
                    "questions": .array([
                        .object([
                            "id": .string("response"),
                            "question": .string("Pick"),
                            "options": .array([
                                .object([
                                    "label": .string("Continue"),
                                    "description": .string("Proceed"),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        XCTAssertFalse(store.streamingSessions.contains(sessionID))
        store.codexActiveTurnIDBySession[sessionID] = "turn_prompt_streaming"

        store.codexServerResponseOverrideForTests = { _, _, _ in }
        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .string("req_prompt_streaming"),
            answers: ["response": "Continue"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.streamingSessions.contains(sessionID)
        }
    }

    func testRequestUserInputPausesStreamingForSession() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Prompt Pause Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Prompt Pause Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_prompt_pause"
            ),
        ]
        store.codexSessionByThread["thread_prompt_pause"] = sessionID
        store.streamingSessions.insert(sessionID)
        store.codexActiveTurnIDBySession[sessionID] = "turn_prompt_pause"

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_prompt_pause"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread_prompt_pause"),
                    "turnId": .string("turn_prompt_pause"),
                    "prompt": .string("Need input"),
                    "questions": .array([
                        .object([
                            "id": .string("response"),
                            "question": .string("Pick"),
                            "options": .array([
                                .object([
                                    "label": .string("Continue"),
                                    "description": .string("Proceed"),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        XCTAssertFalse(store.streamingSessions.contains(sessionID))
        XCTAssertNotNil(store.codexPendingPrompt(for: sessionID))
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

    func testRespondToImplementConfirmationPromptDisablesPlanModeOnApproval() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Implement Confirmation Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Implement Confirmation Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_impl_confirm"
            ),
        ]
        store.setPlanModeEnabled(for: sessionID, enabled: true)
        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_impl_confirm"),
                sessionID: sessionID,
                threadId: "thread_impl_confirm",
                turnId: "turn_impl_confirm",
                kind: "implement_confirmation",
                prompt: "Implement this plan?",
                questions: [],
                rawParams: nil
            ),
        ]

        var captured: JSONValue?
        store.codexServerResponseOverrideForTests = { _, result, _ in
            captured = result
        }

        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .string("req_impl_confirm"),
            answers: ["labos_plan_implementation_decision": "Yes, implement this plan"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            captured != nil
        }

        XCTAssertEqual(store.planModeEnabled(for: sessionID), false)
        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
    }

    func testRespondToImplementConfirmationPromptKeepsPlanModeEnabledForFeedback() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Implement Feedback Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Implement Feedback Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_impl_feedback"
            ),
        ]
        store.setPlanModeEnabled(for: sessionID, enabled: false)
        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_impl_feedback"),
                sessionID: sessionID,
                threadId: "thread_impl_feedback",
                turnId: "turn_impl_feedback",
                kind: "implement_confirmation",
                prompt: "Implement this plan?",
                questions: [],
                rawParams: nil
            ),
        ]

        var captured: JSONValue?
        store.codexServerResponseOverrideForTests = { _, result, _ in
            captured = result
        }

        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .string("req_impl_feedback"),
            answers: ["labos_plan_implementation_decision": "Use stricter constraints first"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            captured != nil
        }

        XCTAssertEqual(store.planModeEnabled(for: sessionID), true)
        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
    }

    func testImplementApprovalWithActiveTurnResumesStreaming() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Implement Resume Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Implement Resume Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_impl_resume"
            ),
        ]
        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_impl_resume"),
                sessionID: sessionID,
                threadId: "thread_impl_resume",
                turnId: "turn_impl_resume",
                kind: "implement_confirmation",
                prompt: "Implement this plan?",
                questions: [],
                rawParams: nil
            ),
        ]
        store.codexActiveTurnIDBySession[sessionID] = "turn_impl_resume"

        var captured: JSONValue?
        store.codexServerResponseOverrideForTests = { _, result, _ in
            captured = result
        }

        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .string("req_impl_resume"),
            answers: ["labos_plan_implementation_decision": "Yes, implement this plan"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            captured != nil
        }

        XCTAssertTrue(store.streamingSessions.contains(sessionID))
        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
    }

    func testRespondToImplementConfirmationPromptWithoutActiveTurnDoesNotMarkStreaming() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Implement Streaming Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Implement Streaming Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_impl_streaming"
            ),
        ]
        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_impl_streaming"),
                sessionID: sessionID,
                threadId: "thread_impl_streaming",
                turnId: "turn_impl_streaming",
                kind: "implement_confirmation",
                prompt: "Implement this plan?",
                questions: [],
                rawParams: nil
            ),
        ]

        var captured: JSONValue?
        store.codexServerResponseOverrideForTests = { _, result, _ in
            captured = result
        }

        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .string("req_impl_streaming"),
            answers: ["labos_plan_implementation_decision": "Yes, implement this plan"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            captured != nil
        }

        XCTAssertFalse(store.streamingSessions.contains(sessionID))
        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
    }

    func testImplementApprovalWithoutActiveTurnWaitsForTurnStarted() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_impl_wait"
        let turnID = "turn_impl_wait"
        store.projects = [Project(id: projectID, name: "Implement Wait Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Implement Wait Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexSessionByThread[threadID] = sessionID
        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_impl_wait"),
                sessionID: sessionID,
                threadId: threadID,
                turnId: turnID,
                kind: "implement_confirmation",
                prompt: "Implement this plan?",
                questions: [],
                rawParams: nil
            ),
        ]

        var captured: JSONValue?
        store.codexServerResponseOverrideForTests = { _, result, _ in
            captured = result
        }

        store.respondToCodexPrompt(
            sessionID: sessionID,
            requestID: .string("req_impl_wait"),
            answers: ["labos_plan_implementation_decision": "Yes, implement this plan"]
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            captured != nil
        }

        XCTAssertFalse(store.streamingSessions.contains(sessionID))

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string(turnID),
                        "status": .string("inProgress"),
                    ]),
                ])
            )
        )

        XCTAssertTrue(store.streamingSessions.contains(sessionID))
    }

    func testSendMessageDismissesImplementConfirmationPrompt() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_prompt_dismiss_send"

        store.projects = [Project(id: projectID, name: "Prompt Dismiss Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Prompt Dismiss Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID
        store.codexConnectionState = .connected
        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_impl_prompt_send"),
                sessionID: sessionID,
                threadId: threadID,
                turnId: "turn_impl_prompt_send",
                kind: "implement_confirmation",
                prompt: "Implement this plan?",
                questions: [],
                rawParams: nil
            ),
        ]

        var capturedMethod: String?
        store.codexRequestOverrideForTests = { method, _ in
            capturedMethod = method
            return CodexRPCResponse(
                id: .string("turn_start_ok"),
                result: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string("turn_after_prompt_send"),
                        "status": .string("inProgress"),
                    ]),
                ]),
                error: nil
            )
        }

        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "continue manually")

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedMethod == "turn/start"
        }
        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
    }

    func testSteerQueuedCodexInputDismissesImplementConfirmationPrompt() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_prompt_dismiss_steer"

        store.projects = [Project(id: projectID, name: "Prompt Dismiss Steer Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Prompt Dismiss Steer Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID
        store.codexActiveTurnIDBySession[sessionID] = "turn_active_prompt_dismiss"
        store.streamingSessions.insert(sessionID)
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "queued steer input")
        let queued = try XCTUnwrap(store.codexQueuedInputs(for: sessionID).first)

        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_impl_prompt_steer"),
                sessionID: sessionID,
                threadId: threadID,
                turnId: "turn_impl_prompt_steer",
                kind: "implement_confirmation",
                prompt: "Implement this plan?",
                questions: [],
                rawParams: nil
            ),
        ]

        var capturedMethod: String?
        store.codexRequestOverrideForTests = { method, _ in
            capturedMethod = method
            return CodexRPCResponse(id: .string("turn_steer_ok"), result: .object([:]), error: nil)
        }

        store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: queued.id)

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedMethod == "turn/steer"
        }
        XCTAssertNil(store.codexPendingPrompt(for: sessionID))
    }

    func testDynamicUpdatePlanToolCallUpdatesLivePlanAndRespondsSuccess() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Dynamic Plan Tool Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Dynamic Plan Tool Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_dynamic_plan"
            ),
        ]
        store.codexSessionByThread["thread_dynamic_plan"] = sessionID

        var capturedRequestID: CodexRequestID?
        var capturedResult: JSONValue?
        var capturedError: CodexRPCError?
        store.codexServerResponseOverrideForTests = { id, result, error in
            capturedRequestID = id
            capturedResult = result
            capturedError = error
        }

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_dynamic_plan"),
                method: "item/tool/call",
                params: .object([
                    "threadId": .string("thread_dynamic_plan"),
                    "turnId": .string("turn_dynamic_plan"),
                    "callId": .string("call_dynamic_plan"),
                    "tool": .string("update_plan"),
                    "arguments": .object([
                        "explanation": .string("Executing checklist"),
                        "plan": .array([
                            .object([
                                "step": .string("Investigate context"),
                                "status": .string("completed"),
                            ]),
                            .object([
                                "step": .string("Implement patch"),
                                "status": .string("in_progress"),
                            ]),
                            .object([
                                "step": .string("Run regression tests"),
                                "status": .string("pending"),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        XCTAssertEqual(capturedRequestID, .string("req_dynamic_plan"))
        XCTAssertNil(capturedError)
        XCTAssertEqual(
            capturedResult,
            .object([
                "success": .bool(true),
                "contentItems": .array([
                    .object([
                        "type": .string("inputText"),
                        "text": .string("Plan updated."),
                    ]),
                ]),
            ])
        )

        let livePlan = try XCTUnwrap(store.livePlanBySession[sessionID])
        XCTAssertEqual(livePlan.explanation, "Executing checklist")
        XCTAssertEqual(
            livePlan.plan,
            [
                .init(step: "Investigate context", status: "completed"),
                .init(step: "Implement patch", status: "in_progress"),
                .init(step: "Run regression tests", status: "pending"),
            ]
        )
    }

    func testSendMessageWhileStreamingQueuesCodexInputWithAttachmentsMetadata() throws {
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

        let attachmentData = Data("hello".utf8)
        let attachment = ComposerAttachment(
            displayName: "note.txt",
            mimeType: "text/plain",
            inlineDataBase64: attachmentData.base64EncodedString(),
            byteCount: attachmentData.count
        )

        store.sendMessage(
            projectID: projectID,
            sessionID: sessionID,
            text: "Steer this trajectory",
            attachments: [attachment]
        )

        let queued = store.codexQueuedInputs(for: sessionID)
        XCTAssertEqual(queued.count, 1)

        let first = try XCTUnwrap(queued.first)
        XCTAssertEqual(first.text, "Steer this trajectory")
        XCTAssertEqual(first.status, .queued)
        XCTAssertEqual(first.attachments.count, 1)

        let stored = try XCTUnwrap(first.attachments.first?.storedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored))
    }

    func testSendMessageWithActiveTurnButStreamingFalseQueuesCodexInput() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.projects = [Project(id: projectID, name: "Steer Queue Active Turn Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_active_turn_queue"
            ),
        ]
        store.codexThreadBySession[sessionID] = "thread_active_turn_queue"
        store.codexActiveTurnIDBySession[sessionID] = "turn_active_turn_queue"

        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "Queue while active turn")

        let queued = store.codexQueuedInputs(for: sessionID)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.text, "Queue while active turn")
        XCTAssertEqual(queued.first?.status, .queued)
    }

    func testCodexQueuedInputsReorderPersistsAcrossStoreRecreate() {
        let suiteName = "LabOSCoreTests.CodexQueuedInput.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create suite-backed defaults.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Queue Persist Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_queue_persist"
            ),
        ]
        store.streamingSessions.insert(sessionID)

        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "first")
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "second")
        XCTAssertEqual(store.codexQueuedInputs(for: sessionID).map(\.text), ["first", "second"])

        store.moveCodexQueuedInputs(sessionID: sessionID, from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(store.codexQueuedInputs(for: sessionID).map(\.text), ["second", "first"])

        let reloaded = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertEqual(reloaded.codexQueuedInputs(for: sessionID).map(\.text), ["second", "first"])
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

    func testTurnStartedMarksSessionAsStreaming() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        store.codexSessionByThread["thread_turn_streaming"] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/started",
                params: .object([
                    "threadId": .string("thread_turn_streaming"),
                    "turn": .object([
                        "id": .string("turn_streaming"),
                        "status": .string("inProgress"),
                    ]),
                ])
            )
        )

        XCTAssertTrue(store.streamingSessions.contains(sessionID))
    }

    func testTurnCompletedPersistsDurationFromBackendTurnLifecycle() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_duration_lifecycle"
        let turnID = "turn_duration_lifecycle"
        let userItemID = "user_duration_lifecycle"

        store.projects = [Project(id: projectID, name: "Duration Lifecycle Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Duration Lifecycle Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexSessionByThread[threadID] = sessionID
        store.codexThreadBySession[sessionID] = threadID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string(turnID),
                        "status": .string("inProgress"),
                    ]),
                ])
            )
        )

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_duration_lifecycle"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "prompt": .string("Need confirmation"),
                    "questions": .array([
                        .object([
                            "id": .string("response"),
                            "question": .string("Continue?"),
                            "options": .array([
                                .object([
                                    "label": .string("Continue"),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("userMessage"),
                        "id": .string(userItemID),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("hello"),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        try await Task.sleep(for: .milliseconds(35))

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string(turnID),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )

        let duration = store.codexTrajectoryDuration(sessionID: sessionID, turnID: userItemID)
        XCTAssertNotNil(duration)
        XCTAssertTrue((duration ?? 0) > 0)
    }

    func testUserMessageArrivalTransfersPendingDurationToTrajectoryDuration() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_duration_pending"
        let turnID = "turn_duration_pending"
        let userItemID = "user_duration_pending"

        store.projects = [Project(id: projectID, name: "Pending Duration Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Pending Duration Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexSessionByThread[threadID] = sessionID
        store.codexThreadBySession[sessionID] = threadID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string(turnID),
                        "status": .string("inProgress"),
                    ]),
                ])
            )
        )

        try await Task.sleep(for: .milliseconds(35))

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string(turnID),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )

        XCTAssertNil(store.codexTrajectoryDuration(sessionID: sessionID, turnID: userItemID))

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("userMessage"),
                        "id": .string(userItemID),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("hello pending"),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        let duration = store.codexTrajectoryDuration(sessionID: sessionID, turnID: userItemID)
        XCTAssertNotNil(duration)
        XCTAssertTrue((duration ?? 0) > 0)
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
        store.codexSessionByThread["thread_queued"] = sessionID
        store.codexActiveTurnIDBySession[sessionID] = "turn_active"
        store.streamingSessions.insert(sessionID)
        store.codexConnectionState = .connected

        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "first queued steer")
        let attachmentData = Data("hello".utf8)
        let attachmentBase64 = attachmentData.base64EncodedString()
        store.sendMessage(
            projectID: projectID,
            sessionID: sessionID,
            text: "second queued steer",
            attachments: [
                ComposerAttachment(
                    displayName: "note.txt",
                    mimeType: "text/plain",
                    inlineDataBase64: attachmentBase64,
                    byteCount: attachmentData.count
                ),
            ]
        )
        let queuedBefore = store.codexQueuedInputs(for: sessionID)
        XCTAssertEqual(queuedBefore.count, 2)

        var capturedRequests: [(method: String, params: JSONValue?)] = []
        store.codexRequestOverrideForTests = { method, params in
            capturedRequests.append((method, params))
            switch method {
            case "turn/steer":
                return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
            default:
                XCTFail("Unexpected Codex request: \(method)")
                return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
            }
        }

        let target = try XCTUnwrap(queuedBefore.dropFirst().first)
        store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: target.id)

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedRequests.contains(where: { $0.method == "turn/steer" })
        }

        XCTAssertEqual(capturedRequests.first?.method, "turn/steer")
        XCTAssertEqual(
            capturedRequests.first?.params,
            .object([
                "threadId": .string("thread_queued"),
                "turnId": .string("turn_active"),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("second queued steer"),
                    ]),
                    .object([
                        "type": .string("attachment"),
                        "name": .string("note.txt"),
                        "mimeType": .string("text/plain"),
                        "inlineDataBase64": .string(attachmentBase64),
                    ]),
                ]),
            ])
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexQueuedInputs(for: sessionID).count == 1
        }
        XCTAssertEqual(store.codexQueuedInputs(for: sessionID).first?.text, "first queued steer")
        XCTAssertFalse(capturedRequests.contains(where: { $0.method == "turn/start" }))
    }

    func testSteerQueuedCodexInputFallbackToInterruptWhenSteerUnsupported() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Steer Fallback Project")]
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
        store.codexSessionByThread["thread_queued"] = sessionID
        store.codexActiveTurnIDBySession[sessionID] = "turn_active"
        store.streamingSessions.insert(sessionID)
        store.codexConnectionState = .connected
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "queued steer fallback")

        var capturedRequests: [(method: String, params: JSONValue?)] = []
        store.codexRequestOverrideForTests = { method, params in
            capturedRequests.append((method, params))
            switch method {
            case "turn/steer":
                throw NSError(domain: "Test", code: -32601, userInfo: [NSLocalizedDescriptionKey: "Method not found"])
            case "turn/interrupt":
                return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
            case "turn/start":
                return CodexRPCResponse(
                    id: .string("turn_start_ok"),
                    result: .object([
                        "threadId": .string("thread_queued"),
                        "turn": .object([
                            "id": .string("turn_after_steer"),
                            "status": .string("inProgress"),
                        ]),
                    ]),
                    error: nil
                )
            default:
                XCTFail("Unexpected Codex request: \(method)")
                return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
            }
        }

        let target = try XCTUnwrap(store.codexQueuedInputs(for: sessionID).first)
        store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: target.id)

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedRequests.contains(where: { $0.method == "turn/interrupt" })
        }

        XCTAssertEqual(capturedRequests.first?.method, "turn/steer")
        XCTAssertEqual(capturedRequests.dropFirst().first?.method, "turn/interrupt")

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread_queued"),
                    "turn": .object([
                        "id": .string("turn_active"),
                        "status": .string("interrupted"),
                    ]),
                ])
            )
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedRequests.contains(where: { $0.method == "turn/start" })
        }
        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexQueuedInputs(for: sessionID).isEmpty
        }
    }

    func testSteerQueuedCodexInputRetriesWithTextWhenInputPayloadRejected() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Steer Text Retry Project")]
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
        store.codexSessionByThread["thread_queued"] = sessionID
        store.codexActiveTurnIDBySession[sessionID] = "turn_active"
        store.streamingSessions.insert(sessionID)
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "retry steer text")

        var capturedRequests: [(method: String, params: JSONValue?)] = []
        store.codexRequestOverrideForTests = { method, params in
            capturedRequests.append((method, params))
            if method == "turn/steer" {
                if params?.objectValue?["input"] != nil {
                    throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid input payload"])
                }
                return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
            }
            XCTFail("Unexpected Codex request: \(method)")
            return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
        }

        let target = try XCTUnwrap(store.codexQueuedInputs(for: sessionID).first)
        store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: target.id)

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedRequests.filter { $0.method == "turn/steer" }.count >= 2
        }

        let steerCalls = capturedRequests.filter { $0.method == "turn/steer" }
        XCTAssertEqual(steerCalls.count, 2)
        XCTAssertEqual(
            steerCalls.first?.params,
            .object([
                "threadId": .string("thread_queued"),
                "turnId": .string("turn_active"),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("retry steer text"),
                    ]),
                ]),
            ])
        )
        XCTAssertEqual(
            steerCalls.last?.params,
            .object([
                "threadId": .string("thread_queued"),
                "turnId": .string("turn_active"),
                "text": .string("retry steer text"),
            ])
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexQueuedInputs(for: sessionID).isEmpty
        }
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

        let target = try XCTUnwrap(store.codexQueuedInputs(for: sessionID).first)
        store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: target.id)

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexQueuedInputs(for: sessionID).first?.status == .failed
        }

        let queuedAfter = try XCTUnwrap(store.codexQueuedInputs(for: sessionID).first)
        XCTAssertEqual(queuedAfter.text, "retry steer")
        XCTAssertEqual(queuedAfter.status, .failed)
        XCTAssertNotNil(queuedAfter.error)
    }

    func testCodexTurnCompletedInterruptedMarksTrajectoryTurnInterrupted() throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_interrupted_marker"
        let turnID = "turn_interrupted_marker"
        let userItemID = "user_item_interrupted_marker"

        store.projects = [Project(id: projectID, name: "Interrupted Marker Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Interrupted Marker Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("userMessage"),
                        "id": .string(userItemID),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("hello"),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string(turnID),
                        "status": .string("interrupted"),
                    ]),
                ])
            )
        )

        XCTAssertTrue(store.codexInterruptedTurnIDs(sessionID: sessionID).contains(userItemID))
    }

    func testTurnCompletedDrainsQueuedInputsWhenNoPendingUserInput() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.projects = [Project(id: projectID, name: "Drain Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_drain"
            ),
        ]
        store.codexThreadBySession[sessionID] = "thread_drain"
        store.codexSessionByThread["thread_drain"] = sessionID
        store.codexConnectionState = .connected

        store.streamingSessions.insert(sessionID)
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "queued after completion")
        XCTAssertEqual(store.codexQueuedInputs(for: sessionID).count, 1)

        var capturedMethod: String?
        var capturedParams: JSONValue?
        store.codexRequestOverrideForTests = { method, params in
            capturedMethod = method
            capturedParams = params
            return CodexRPCResponse(
                id: .string("turn_start_ok"),
                result: .object([
                    "threadId": .string("thread_drain"),
                    "turn": .object([
                        "id": .string("turn_after_drain"),
                        "status": .string("inProgress"),
                    ]),
                ]),
                error: nil
            )
        }

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread_drain"),
                    "turn": .object([
                        "id": .string("turn_initial"),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedMethod == "turn/start"
        }

        XCTAssertEqual(
            capturedParams,
            .object([
                "threadId": .string("thread_drain"),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("queued after completion"),
                    ]),
                ]),
                "planMode": .bool(false),
            ])
        )

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexQueuedInputs(for: sessionID).isEmpty
        }
    }

    func testTurnCompletedDoesNotDrainQueuedInputsWhenPromptPending() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.projects = [Project(id: projectID, name: "Drain Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_drain"
            ),
        ]
        store.codexThreadBySession[sessionID] = "thread_drain"
        store.codexSessionByThread["thread_drain"] = sessionID
        store.codexConnectionState = .connected

        store.streamingSessions.insert(sessionID)
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "queued after completion")
        XCTAssertEqual(store.codexQueuedInputs(for: sessionID).count, 1)

        store.codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_prompt_block"),
                sessionID: sessionID,
                threadId: "thread_drain",
                turnId: "turn_prompt_block",
                prompt: "Need input",
                rawParams: nil
            ),
        ]
        XCTAssertTrue(store.sessionNeedsUserInput(sessionID: sessionID))

        var capturedMethod: String?
        store.codexRequestOverrideForTests = { method, _ in
            capturedMethod = method
            return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
        }

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread_drain"),
                    "turn": .object([
                        "id": .string("turn_initial"),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )

        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(capturedMethod)
        XCTAssertEqual(store.codexQueuedInputs(for: sessionID).count, 1)
    }

    func testInterruptCodexTurnSendsTurnInterruptRequest() async throws {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        store.codexThreadBySession[sessionID] = "thr_interrupt"
        store.codexActiveTurnIDBySession[sessionID] = "turn_interrupt"

        var capturedMethod: String?
        var capturedParams: JSONValue?
        store.codexRequestOverrideForTests = { method, params in
            capturedMethod = method
            capturedParams = params
            return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
        }

        store.interruptCodexTurn(sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedMethod == "turn/interrupt"
        }

        XCTAssertEqual(
            capturedParams,
            .object([
                "threadId": .string("thr_interrupt"),
                "turnId": .string("turn_interrupt"),
            ])
        )
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

    func testSetPermissionLevelInCodexModeSyncsSessionAndProjectDefaults() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_permission_sync"
        let now = "2026-02-25T00:00:00.000Z"

        store.projects = [
            Project(
                id: projectID,
                name: "Permission Sync Project",
                backendEngine: "codex-app-server",
                codexApprovalPolicy: "on-request",
                codexSandbox: .object(["mode": .string("workspace-write")])
            ),
        ]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Permission Sync Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID,
                codexApprovalPolicy: "on-request",
                codexSandbox: .object(["mode": .string("workspace-write")])
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID
        store.codexConnectionState = .connected

        var calls: [(method: String, params: JSONValue?)] = []
        store.codexRequestOverrideForTests = { method, params in
            calls.append((method, params))
            switch method {
            case "labos/session/update":
                return CodexRPCResponse(
                    id: .string("session_update"),
                    result: .object([
                        "session": Self.codexSessionJSON(
                            sessionID: sessionID,
                            projectID: projectID,
                            threadID: threadID,
                            nowISO: now,
                            sandboxMode: "danger-full-access"
                        ),
                    ]),
                    error: nil
                )
            case "labos/project/update":
                return CodexRPCResponse(
                    id: .string("project_update"),
                    result: .object([
                        "project": Self.codexProjectJSON(
                            projectID: projectID,
                            nowISO: now,
                            sandboxMode: "danger-full-access"
                        ),
                    ]),
                    error: nil
                )
            default:
                return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
            }
        }

        store.setPermissionLevel(projectID: projectID, sessionID: sessionID, level: .full)
        XCTAssertEqual(store.permissionLevel(for: sessionID), .full)

        try await waitUntil(timeoutSeconds: 1.0) {
            Set(calls.map(\.method)).isSuperset(of: ["labos/session/update", "labos/project/update"])
        }

        let sessionParams = try XCTUnwrap(
            calls.first(where: { $0.method == "labos/session/update" })?.params?.objectValue
        )
        XCTAssertEqual(sessionParams["projectId"]?.stringValue, projectID.uuidString.lowercased())
        XCTAssertEqual(sessionParams["sessionId"]?.stringValue, sessionID.uuidString.lowercased())
        XCTAssertEqual(sessionParams["codexApprovalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(sessionParams["codexSandbox"]?.objectValue?["mode"]?.stringValue, "danger-full-access")

        let projectParams = try XCTUnwrap(
            calls.first(where: { $0.method == "labos/project/update" })?.params?.objectValue
        )
        XCTAssertEqual(projectParams["projectId"]?.stringValue, projectID.uuidString.lowercased())
        XCTAssertEqual(projectParams["codexApprovalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(projectParams["codexSandbox"]?.objectValue?["mode"]?.stringValue, "danger-full-access")
    }

    func testTurnStartWaitsForSessionPermissionSyncCompletion() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_permission_order"
        let now = "2026-02-25T00:00:00.000Z"

        store.projects = [
            Project(
                id: projectID,
                name: "Permission Order Project",
                backendEngine: "codex-app-server",
                codexApprovalPolicy: "on-request",
                codexSandbox: .object(["mode": .string("workspace-write")])
            ),
        ]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Permission Order Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID,
                codexApprovalPolicy: "on-request",
                codexSandbox: .object(["mode": .string("workspace-write")])
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID
        store.codexConnectionState = .connected

        var events: [String] = []
        store.codexRequestOverrideForTests = { method, _ in
            switch method {
            case "labos/session/update":
                events.append("session-update:start")
                try await Task.sleep(for: .milliseconds(150))
                events.append("session-update:end")
                return CodexRPCResponse(
                    id: .string("session_update"),
                    result: .object([
                        "session": Self.codexSessionJSON(
                            sessionID: sessionID,
                            projectID: projectID,
                            threadID: threadID,
                            nowISO: now,
                            sandboxMode: "danger-full-access"
                        ),
                    ]),
                    error: nil
                )
            case "labos/project/update":
                events.append("project-update")
                return CodexRPCResponse(
                    id: .string("project_update"),
                    result: .object([
                        "project": Self.codexProjectJSON(
                            projectID: projectID,
                            nowISO: now,
                            sandboxMode: "danger-full-access"
                        ),
                    ]),
                    error: nil
                )
            case "turn/start":
                events.append("turn-start")
                return CodexRPCResponse(
                    id: .string("turn_start"),
                    result: .object([
                        "threadId": .string(threadID),
                        "turn": .object([
                            "id": .string("turn_permission_order"),
                            "status": .string("inProgress"),
                        ]),
                    ]),
                    error: nil
                )
            default:
                return CodexRPCResponse(id: .string("ok"), result: .object([:]), error: nil)
            }
        }

        store.setPermissionLevel(projectID: projectID, sessionID: sessionID, level: .full)
        store.sendMessage(projectID: projectID, sessionID: sessionID, text: "apply latest permission")

        try await waitUntil(timeoutSeconds: 1.5) {
            events.contains("turn-start")
        }

        let turnStartIndex = try XCTUnwrap(events.firstIndex(of: "turn-start"))
        let sessionEndIndex = try XCTUnwrap(events.firstIndex(of: "session-update:end"))
        XCTAssertGreaterThan(turnStartIndex, sessionEndIndex)
    }

    func testCodexTurnPlanUpdatedHydratesLivePlanAndKeepsIncompletePlanOnCompletion() throws {
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

        let retainedPlan = try XCTUnwrap(store.livePlanBySession[sessionID])
        XCTAssertEqual(retainedPlan.plan.count, 2)
        XCTAssertEqual(retainedPlan.plan[0].status, "completed")
        XCTAssertEqual(retainedPlan.plan[1].status, "in_progress")
    }

    func testCodexTurnCompletedClearsTerminalLivePlan() throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        store.projects = [Project(id: projectID, name: "Plan Terminal Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Codex Session",
                backendEngine: "codex-app-server",
                codexThreadId: "thread_plan_terminal"
            ),
        ]
        store.codexSessionByThread["thread_plan_terminal"] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/plan/updated",
                params: .object([
                    "threadId": .string("thread_plan_terminal"),
                    "turnId": .string("turn_plan_terminal"),
                    "plan": .array([
                        .object([
                            "step": .string("Investigate context"),
                            "status": .string("completed"),
                        ]),
                        .object([
                            "step": .string("Propose options"),
                            "status": .string("completed"),
                        ]),
                    ]),
                ])
            )
        )
        XCTAssertNotNil(store.livePlanBySession[sessionID])

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string("thread_plan_terminal"),
                    "turn": .object([
                        "id": .string("turn_plan_terminal"),
                        "status": .string("completed"),
                    ]),
                ])
            )
        )

        XCTAssertNil(store.livePlanBySession[sessionID])
    }

    func testThreadTokenUsageUpdatedParsesNestedShapeAndHydratesContextState() throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_usage_nested"

        store.projects = [Project(id: projectID, name: "Usage Nested Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Usage Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexSessionByThread[threadID] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "thread/tokenUsage/updated",
                params: .object([
                    "threadId": .string(threadID),
                    "tokenUsage": .object([
                        "modelContextWindow": .number(200000),
                        "last": .object([
                            "inputTokens": .number(4321),
                            "totalTokens": .number(6789),
                            "outputTokens": .number(2468),
                        ]),
                    ]),
                ])
            )
        )

        let usage = try XCTUnwrap(store.codexTokenUsageBySession[sessionID])
        XCTAssertEqual(usage.contextWindowTokens, 200000)
        XCTAssertEqual(usage.inputTokens, 4321)
        XCTAssertEqual(usage.totalTokens, 6789)
        XCTAssertEqual(usage.outputTokens, 2468)
        XCTAssertEqual(usage.remainingTokens, 195679)

        let context = try XCTUnwrap(store.sessionContextBySession[sessionID])
        XCTAssertEqual(context.contextWindowTokens, 200000)
        XCTAssertEqual(context.usedInputTokens, 4321)
        XCTAssertEqual(context.usedTokens, 6789)
        XCTAssertEqual(context.remainingTokens, 195679)
    }

    func testThreadTokenUsageUpdatedSupportsLegacyFlatShape() throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_usage_legacy"

        store.projects = [Project(id: projectID, name: "Usage Legacy Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Usage Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexSessionByThread[threadID] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "thread/tokenUsage/updated",
                params: .object([
                    "threadId": .string(threadID),
                    "tokenUsage": .object([
                        "contextWindow": .number(128000),
                        "inputTokens": .number(2222),
                        "totalTokens": .number(3333),
                    ]),
                ])
            )
        )

        let usage = try XCTUnwrap(store.codexTokenUsageBySession[sessionID])
        XCTAssertEqual(usage.contextWindowTokens, 128000)
        XCTAssertEqual(usage.inputTokens, 2222)
        XCTAssertEqual(usage.totalTokens, 3333)
        XCTAssertEqual(usage.remainingTokens, 125778)
    }

    func testCodexContextFractionFallsBackToSessionContextState() throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.sessionContextBySession[sessionID] = SessionContextState(
            projectId: projectID,
            sessionId: sessionID,
            contextWindowTokens: 1000,
            usedInputTokens: 250,
            usedTokens: 400,
            remainingTokens: 750
        )
        store.codexTokenUsageBySession[sessionID] = nil

        XCTAssertEqual(store.contextWindowTokens(for: sessionID), 1000)
        let fraction = try XCTUnwrap(store.contextRemainingFraction(for: sessionID))
        XCTAssertEqual(fraction, 0.75, accuracy: 0.0001)
    }

    func testCodexContextFractionReturnsNilWhenNoUsageDataExists() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        store.sessionContextBySession[sessionID] = nil
        store.codexTokenUsageBySession[sessionID] = nil

        XCTAssertNil(store.contextWindowTokens(for: sessionID))
        XCTAssertNil(store.contextRemainingFraction(for: sessionID))
    }

    func testImplementConfirmationCapturesProposedPlanTextForTurn() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_plan_capture"
        let turnID = "turn_plan_capture"
        let userItemID = "user_item_plan_capture"

        store.projects = [Project(id: projectID, name: "Plan Capture Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Plan Capture Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("userMessage"),
                        "id": .string(userItemID),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("Make a plan"),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        let proposedPlan = """
        <proposed_plan>
        - Step A
        - Step B
        - Step C
        </proposed_plan>
        """

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("agentMessage"),
                        "id": .string("agent_plan"),
                        "text": .string(proposedPlan),
                    ]),
                ])
            )
        )

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("agentMessage"),
                        "id": .string("agent_final"),
                        "text": .string("OK."),
                    ]),
                ])
            )
        )

        await store._receiveCodexServerRequestForTesting(
            CodexRPCRequest(
                id: .string("req_impl_confirm"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "prompt": .string("Implement this plan?"),
                    "questions": .array([
                        .object([
                            "id": .string("labos_plan_implementation_decision"),
                            "question": .string(""),
                            "isOther": .bool(true),
                            "options": .array([
                                .object([
                                    "label": .string("Yes, implement this plan"),
                                    "description": .string("Start implementing the approved plan immediately."),
                                ]),
                                .object([
                                    "label": .string("No, and tell Codex what to do differently"),
                                    "description": .string("Close this prompt and continue from the composer."),
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        )

        let captured = store.codexProposedPlanTextBySession[sessionID]?[userItemID]
        XCTAssertEqual(captured, "- Step A\n- Step B\n- Step C")
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

    private static func codexProjectJSON(
        projectID: UUID,
        nowISO: String,
        sandboxMode: String
    ) -> JSONValue {
        .object([
            "id": .string(projectID.uuidString.lowercased()),
            "name": .string("Permission Project"),
            "createdAt": .string(nowISO),
            "updatedAt": .string(nowISO),
            "backendEngine": .string("codex-app-server"),
            "codexModelProvider": .string("openai"),
            "codexModel": .string("gpt-5.3-codex"),
            "codexApprovalPolicy": .string("on-request"),
            "codexSandbox": .object(["mode": .string(sandboxMode)]),
            "hpcWorkspacePath": .null,
            "hpcWorkspaceState": .string("queued"),
        ])
    }

    private static func codexSessionJSON(
        sessionID: UUID,
        projectID: UUID,
        threadID: String,
        nowISO: String,
        sandboxMode: String
    ) -> JSONValue {
        .object([
            "id": .string(sessionID.uuidString.lowercased()),
            "projectID": .string(projectID.uuidString.lowercased()),
            "title": .string("Permission Session"),
            "lifecycle": .string("active"),
            "createdAt": .string(nowISO),
            "updatedAt": .string(nowISO),
            "backendEngine": .string("codex-app-server"),
            "codexThreadId": .string(threadID),
            "codexModel": .string("gpt-5.3-codex"),
            "codexModelProvider": .string("openai"),
            "codexApprovalPolicy": .string("on-request"),
            "codexSandbox": .object(["mode": .string(sandboxMode)]),
            "hpcWorkspaceState": .string("queued"),
            "hasPendingUserInput": .bool(false),
            "pendingUserInputCount": .number(0),
            "pendingUserInputKind": .null,
        ])
    }
}
