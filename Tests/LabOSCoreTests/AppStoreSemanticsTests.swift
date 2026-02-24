import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreSemanticsTests: XCTestCase {
    func testDeleteSessionKeepsArtifacts() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project A") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session A") else {
            XCTFail("Session was not created")
            return
        }

        store.messagesBySession[session.id] = [
            ChatMessage(sessionID: session.id, role: .user, text: "hello")
        ]
        store.codexItemsBySession[session.id] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "item_user_1",
                    content: [CodexUserInput(type: "text", text: "hello", url: nil, path: nil)]
                )
            )
        ]
        store.runsByProject[project.id] = [
            RunRecord(
                projectID: project.id,
                sessionID: session.id,
                status: .succeeded,
                currentStep: 1,
                totalSteps: 1,
                logSnippet: "ok",
                stepTitles: ["step"]
            )
        ]
        _ = store.projectService.upsertArtifact(
            projectID: project.id,
            path: "artifacts/result.txt",
            createdBySessionID: session.id,
            origin: .generated
        )

        let artifactsBeforeDelete = store.artifacts(for: project.id)
        XCTAssertFalse(artifactsBeforeDelete.isEmpty)

        store.deleteSession(projectID: project.id, sessionID: session.id)

        let artifactsAfterDelete = store.artifacts(for: project.id)
        XCTAssertEqual(artifactsAfterDelete.count, artifactsBeforeDelete.count)
        XCTAssertTrue(store.sessions(for: project.id).isEmpty)
        XCTAssertTrue(store.messages(for: session.id).isEmpty)
        XCTAssertTrue(store.codexItems(for: session.id).isEmpty)

        let detachedRuns = store.runs(for: project.id)
        XCTAssertTrue(detachedRuns.allSatisfy { $0.sessionID == nil }, "Run references should be detached from deleted session")
    }

    func testDeleteProjectWipesSessionsRunsAndArtifacts() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project B") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session B") else {
            XCTFail("Session was not created")
            return
        }

        store.messagesBySession[session.id] = [
            ChatMessage(sessionID: session.id, role: .assistant, text: "done")
        ]
        store.runsByProject[project.id] = [
            RunRecord(
                projectID: project.id,
                sessionID: session.id,
                status: .succeeded,
                currentStep: 1,
                totalSteps: 1,
                logSnippet: "ok",
                stepTitles: ["step"]
            )
        ]
        _ = store.projectService.upsertArtifact(
            projectID: project.id,
            path: "artifacts/report.txt",
            createdBySessionID: session.id,
            origin: .generated
        )

        XCTAssertFalse(store.sessions(for: project.id).isEmpty)
        XCTAssertFalse(store.artifacts(for: project.id).isEmpty)
        XCTAssertFalse(store.runs(for: project.id).isEmpty)

        store.deleteProject(projectID: project.id)

        XCTAssertFalse(store.projects.contains(where: { $0.id == project.id }))
        XCTAssertTrue(store.sessions(for: project.id).isEmpty)
        XCTAssertTrue(store.artifacts(for: project.id).isEmpty)
        XCTAssertTrue(store.runs(for: project.id).isEmpty)
    }

    func testCancelPlanDoesNotCreateRun() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project C") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session C") else {
            XCTFail("Session was not created")
            return
        }

        let plan = ExecutionPlan(
            projectID: project.id,
            sessionID: session.id,
            steps: [
                PlanStep(
                    title: "Execute pipeline",
                    runtime: .shell,
                    inputs: [],
                    outputs: ["artifacts/output.txt"]
                )
            ]
        )
        let pending = PendingApproval(
            planId: UUID(),
            projectId: project.id,
            sessionId: session.id,
            agentRunId: UUID(),
            plan: plan,
            required: true,
            judgment: nil
        )
        store.planService.pendingApprovalsBySession[session.id] = pending
        store.planService.planSessionByPlanID[pending.planId] = session.id

        store.cancelPlan(sessionID: session.id)

        XCTAssertNil(store.pendingPlan(for: session.id))
        XCTAssertTrue(store.runs(for: project.id).isEmpty)
    }

    func testUploadedFilesAreSeparatedFromGeneratedResults() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project D") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session D") else {
            XCTFail("Session was not created")
            return
        }

        store.addUploadedFiles(
            projectID: project.id,
            fileNames: ["dataset.csv", "nested/path/notes.txt"],
            createdBySessionID: session.id
        )

        let uploadedBeforeRun = store.uploadedArtifacts(for: project.id)
        XCTAssertEqual(uploadedBeforeRun.count, 2)
        XCTAssertTrue(uploadedBeforeRun.allSatisfy { $0.path.hasPrefix("uploads/") })
        XCTAssertTrue(store.generatedArtifacts(for: project.id).isEmpty)

        _ = store.projectService.upsertArtifact(
            projectID: project.id,
            path: "uploads/source.csv",
            createdBySessionID: session.id,
            origin: .generated
        )
        _ = store.projectService.upsertArtifact(
            projectID: project.id,
            path: "artifacts/summary.json",
            createdBySessionID: session.id,
            origin: .generated
        )

        let uploadedAfterRun = store.uploadedArtifacts(for: project.id)
        let generatedAfterRun = store.generatedArtifacts(for: project.id)

        XCTAssertEqual(uploadedAfterRun.count, 2, "Generated outputs should not be counted as uploaded files")
        XCTAssertFalse(generatedAfterRun.isEmpty)
        XCTAssertTrue(generatedAfterRun.contains { $0.path == "uploads/source.csv" }, "Generated files can still live under uploads/ but must not be treated as user uploads")
    }

    func testSessionComposerAttachmentsStayOutOfProjectUploads() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project Attachments") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session Attachments") else {
            XCTFail("Session was not created")
            return
        }

        store.addPendingComposerAttachments(
            sessionID: session.id,
            attachments: [
                ComposerAttachment(displayName: "notes.txt", mimeType: "text/plain"),
                ComposerAttachment(
                    displayName: "figure.png",
                    mimeType: "image/png",
                    inlineDataBase64: Self.tinyPNGBase64,
                    byteCount: 68
                )
            ]
        )

        let refs = store.composerService.makeSessionAttachmentReferences(
            projectID: project.id,
            sessionID: session.id,
            attachments: store.pendingComposerAttachments(for: session.id)
        )
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(refs.allSatisfy { $0.scope == "session" })

        makeCodexReady(store: store, sessionID: session.id, threadID: "thread_attach_1")
        var capturedParams: JSONValue?
        store.codexRequestOverrideForTests = { method, params in
            if method == "turn/start" {
                capturedParams = params
            }
            return CodexRPCResponse(
                id: .string("turn_start_ok"),
                result: .object([
                    "threadId": .string("thread_attach_1"),
                    "turn": .object([
                        "id": .string("turn_attach_1"),
                        "status": .string("inProgress"),
                    ]),
                ]),
                error: nil
            )
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "Use my attachments")
        try await waitUntil(timeoutSeconds: 2.0) {
            capturedParams != nil
        }

        let inputParts = capturedParams?.objectValue?["input"]?.arrayValue ?? []
        XCTAssertTrue(inputParts.contains(where: { $0.objectValue?["type"]?.stringValue == "localImage" }))
        XCTAssertTrue(store.uploadedArtifacts(for: project.id).isEmpty, "Session composer attachments must not become project uploads")
        XCTAssertTrue(store.pendingComposerAttachments(for: session.id).isEmpty, "Pending attachments should clear after send")
    }

    func testSendMessageCanAcceptExplicitSessionAttachments() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project Explicit Attachments") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session Explicit Attachments") else {
            XCTFail("Session was not created")
            return
        }

        makeCodexReady(store: store, sessionID: session.id, threadID: "thread_attach_2")

        var capturedParams: JSONValue?
        store.codexRequestOverrideForTests = { method, params in
            if method == "turn/start" {
                capturedParams = params
            }
            return CodexRPCResponse(
                id: .string("turn_start_ok"),
                result: .object([
                    "threadId": .string("thread_attach_2"),
                    "turn": .object([
                        "id": .string("turn_attach_2"),
                        "status": .string("inProgress"),
                    ]),
                ]),
                error: nil
            )
        }

        let pending = [
            ComposerAttachment(
                displayName: "draft.png",
                mimeType: "image/png",
                inlineDataBase64: Self.tinyPNGBase64,
                byteCount: 68
            )
        ]

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "Check this", attachments: pending)
        try await waitUntil(timeoutSeconds: 2.0) {
            capturedParams != nil
        }

        let inputParts = capturedParams?.objectValue?["input"]?.arrayValue ?? []
        XCTAssertTrue(inputParts.contains(where: { $0.objectValue?["type"]?.stringValue == "localImage" }))

        let latestUser = store.codexItems(for: session.id).compactMap { item -> CodexUserMessageItem? in
            if case let .userMessage(user) = item {
                return user
            }
            return nil
        }.last
        XCTAssertNotNil(latestUser)
        XCTAssertTrue((latestUser?.content.contains { $0.type == "localImage" }) ?? false)
        XCTAssertTrue(store.uploadedArtifacts(for: project.id).isEmpty)
    }

    private func makeCodexReady(store: AppStore, sessionID: UUID, threadID: String) {
        store.codexConnectionState = .connected
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID
    }

    private static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5GZfQAAAAASUVORK5CYII="

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
