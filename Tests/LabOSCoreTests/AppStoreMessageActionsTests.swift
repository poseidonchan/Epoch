import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreMessageActionsTests: XCTestCase {
    func testAutoRecoverMissingSessionOnlyForFirstMessageLikeThreads() {
        XCTAssertTrue(AppStore.shouldAutoRecoverMissingGatewaySession(localNonSystemMessageCount: 0))
        XCTAssertTrue(AppStore.shouldAutoRecoverMissingGatewaySession(localNonSystemMessageCount: 1))
        XCTAssertFalse(AppStore.shouldAutoRecoverMissingGatewaySession(localNonSystemMessageCount: 2))
        XCTAssertFalse(AppStore.shouldAutoRecoverMissingGatewaySession(localNonSystemMessageCount: 8))
    }

    func testRetrySourceTextUsesPrecedingUserMessageForAssistantMessage() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Retry Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Retry Session") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "Explain gradient descent simply")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        let messages = store.messages(for: session.id)
        guard
            let assistant = messages.last(where: { $0.role == .assistant }),
            let originalUser = messages.first(where: { $0.role == .user })
        else {
            XCTFail("Expected user and assistant messages")
            return
        }

        let source = store.retrySourceText(for: assistant.id, in: session.id)
        XCTAssertEqual(source, originalUser.text)
    }

    func testRetryMessageFromAssistantRegeneratesWithoutDuplicatingUserMessage() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Retry Model Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Retry Model Session") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "What is overfitting?")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        let before = store.messages(for: session.id)
        guard let assistant = before.last(where: { $0.role == .assistant }) else {
            XCTFail("Expected assistant message")
            return
        }

        store.retryMessage(
            projectID: project.id,
            sessionID: session.id,
            fromMessageID: assistant.id,
            modelIdOverride: "openai/gpt-4o-mini"
        )

        let afterRetry = store.messages(for: session.id)
        XCTAssertEqual(afterRetry.filter { $0.role == .user }.count, before.filter { $0.role == .user }.count)
        XCTAssertEqual(afterRetry.filter { $0.role == .assistant }.count, 0)
        XCTAssertEqual(afterRetry.last(where: { $0.role == .user })?.text, before.first(where: { $0.role == .user })?.text)
        XCTAssertEqual(store.selectedModelId(for: session.id), "openai/gpt-4o-mini")

        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        let finalMessages = store.messages(for: session.id)
        XCTAssertEqual(finalMessages.filter { $0.role == .user }.count, before.filter { $0.role == .user }.count)
    }

    func testRetryMessageFromAssistantPreservesOriginalAttachmentRefs() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Retry Attachment Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Retry Attachment Session") else {
            XCTFail("Session was not created")
            return
        }

        let attachment = ComposerAttachment(
            displayName: "chart.png",
            mimeType: "image/png",
            inlineDataBase64: "ZmFrZS1pbWFnZS1kYXRh",
            byteCount: 16
        )
        store.sendMessage(
            projectID: project.id,
            sessionID: session.id,
            text: "What does this chart show?",
            attachments: [attachment]
        )

        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        let beforeRetry = store.messages(for: session.id)
        guard let assistant = beforeRetry.last(where: { $0.role == .assistant }) else {
            XCTFail("Expected assistant message")
            return
        }
        guard let sourceUser = beforeRetry.first(where: { $0.role == .user }) else {
            XCTFail("Expected source user message")
            return
        }
        XCTAssertEqual(sourceUser.artifactRefs.count, 1)

        store.retryMessage(
            projectID: project.id,
            sessionID: session.id,
            fromMessageID: assistant.id,
            modelIdOverride: nil
        )

        let afterRetry = store.messages(for: session.id)
        guard let regeneratedUser = afterRetry.first(where: { $0.id == sourceUser.id }) else {
            XCTFail("Expected regenerated user message to keep original message ID")
            return
        }
        XCTAssertEqual(regeneratedUser.artifactRefs.count, 1)
        XCTAssertEqual(regeneratedUser.artifactRefs.first?.displayText, "chart.png")
        XCTAssertEqual(regeneratedUser.artifactRefs.first?.mimeType, "image/png")
        XCTAssertEqual(regeneratedUser.artifactRefs.first?.inlineDataBase64, "ZmFrZS1pbWFnZS1kYXRh")
        XCTAssertEqual(regeneratedUser.artifactRefs.first?.byteCount, 16)
    }

    func testMergeArtifactRefsPreservesInlinePayloadFromLocalEchoWhenGatewayStripsInline() {
        let projectID = UUID()
        let artifactID = UUID()

        let local = [
            ChatArtifactReference(
                displayText: "photo-1.jpeg",
                projectID: projectID,
                path: "session_attachments/s-1/photo-1.jpeg",
                artifactID: artifactID,
                scope: "session",
                mimeType: "image/jpeg",
                sourceName: "photo-1.jpeg",
                inlineDataBase64: "ZmFrZS1pbWFnZS1ieXRlcw==",
                byteCount: 16
            ),
        ]

        let remote = [
            ChatArtifactReference(
                displayText: "photo-1.jpeg",
                projectID: projectID,
                path: "session_attachments/s-1/photo-1.jpeg",
                artifactID: artifactID,
                scope: "session",
                mimeType: "image/jpeg",
                sourceName: "photo-1.jpeg",
                inlineDataBase64: nil,
                byteCount: 16
            ),
        ]

        let merged = AppStore.mergeArtifactRefsPreservingInlineForGatewayEcho(
            remoteArtifactRefs: remote,
            localArtifactRefs: local
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.inlineDataBase64, "ZmFrZS1pbWFnZS1ieXRlcw==")
        XCTAssertEqual(merged.first?.byteCount, 16)
    }

    func testRetryMessageFromUserStillAppendsAnotherUserMessage() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Retry User Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Retry User Session") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "Repeat me")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        let before = store.messages(for: session.id)
        guard let user = before.first(where: { $0.role == .user }) else {
            XCTFail("Expected user message")
            return
        }

        store.retryMessage(
            projectID: project.id,
            sessionID: session.id,
            fromMessageID: user.id,
            modelIdOverride: nil
        )

        let after = store.messages(for: session.id)
        XCTAssertEqual(after.filter { $0.role == .user }.count, before.filter { $0.role == .user }.count + 1)
    }

    func testBranchFromAssistantCreatesNewSessionAndResendsPrompt() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Branch Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Branch Source") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "Summarize this paper")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        let sourceMessages = store.messages(for: session.id)
        guard
            let assistant = sourceMessages.last(where: { $0.role == .assistant }),
            let originalUser = sourceMessages.first(where: { $0.role == .user })
        else {
            XCTFail("Expected user and assistant messages")
            return
        }

        let branched = await store.branchFromMessage(
            projectID: project.id,
            sessionID: session.id,
            fromMessageID: assistant.id
        )
        XCTAssertNotNil(branched)
        guard let branched else { return }

        XCTAssertEqual(store.sessions(for: project.id).count, 2)
        XCTAssertEqual(store.activeSessionID, branched.id)
        XCTAssertEqual(store.messages(for: branched.id).last(where: { $0.role == .user })?.text, originalUser.text)
    }

    func testOverwriteUserMessageResendsWithoutDuplicatingUserMessage() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Edit Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Edit Session") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "Teach me to write Python code")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        guard let originalUser = store.messages(for: session.id).first(where: { $0.role == .user }) else {
            XCTFail("Expected original user message")
            return
        }

        store.overwriteUserMessage(
            projectID: project.id,
            sessionID: session.id,
            messageID: originalUser.id,
            text: "Teach me to write C# code"
        )

        let afterOverwrite = store.messages(for: session.id)
        XCTAssertEqual(afterOverwrite.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(afterOverwrite.filter { $0.role == .assistant }.count, 0)
        XCTAssertEqual(afterOverwrite.last(where: { $0.role == .user })?.text, "Teach me to write C# code")

        try await waitUntil(timeoutSeconds: 2.0) {
            store.messages(for: session.id).contains(where: { $0.role == .assistant })
        }

        let finalMessages = store.messages(for: session.id)
        XCTAssertEqual(finalMessages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(finalMessages.last(where: { $0.role == .user })?.text, "Teach me to write C# code")
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
