import Foundation
import XCTest

final class E2EPhotoAttachmentTests: XCTestCase {
    @MainActor
    func testPhotoAttachmentShowsThumbnailBeforeSend() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABOS_E2E_ENABLE_TEST_PHOTO"] = "1"
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        let config = try E2ELiveGatewayConfig.required()

        try await runner.stepAsync("connect-live-hub") {
            E2EUIHelpers.ensureGatewayConnected(app: app, config: config)
        }

        _ = try await createProjectViaUI(app: app, runner: runner, namePrefix: "E2E-PhotoThumb")

        try await runner.stepAsync("attach-test-photo-from-session-sheet") {
            let plusButton = app.buttons["composer.plus"]
            XCTAssertTrue(plusButton.waitForExistence(timeout: 8))
            plusButton.tap()

            let addAttachments = app.buttons["composer.plus.attachments"]
            XCTAssertTrue(addAttachments.waitForExistence(timeout: 5))
            addAttachments.tap()

            let title = app.staticTexts["composer.attachments.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 8))

            let testPhoto = app.buttons["composer.attachments.testPhoto"]
            guard testPhoto.waitForExistence(timeout: 5) else {
                XCTFail("Missing test-only photo action in attachment sheet.")
                return
            }
            testPhoto.tap()
        }

        try await runner.stepAsync("verify-thumbnail-preview-before-send") {
            let thumbnail = app.descendants(matching: .any).matching(identifier: "composer.attachment.thumbnail.0").firstMatch
            XCTAssertTrue(thumbnail.waitForExistence(timeout: 8), "Thumbnail preview did not appear above the composer input.")
        }
    }

    @MainActor
    func testPhotoMessageGetsGroundedAssistantReply() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LABOS_E2E_ENABLE_TEST_PHOTO"] = "1"
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        let config = try E2ELiveGatewayConfig.required()

        try await runner.stepAsync("connect-live-hub") {
            E2EUIHelpers.ensureGatewayConnected(app: app, config: config)
        }

        _ = try await createProjectViaUI(app: app, runner: runner, namePrefix: "E2E-PhotoGrounding")

        try await runner.stepAsync("attach-photo-and-verify-thumbnail") {
            let plusButton = app.buttons["composer.plus"]
            XCTAssertTrue(plusButton.waitForExistence(timeout: 8))
            plusButton.tap()

            let addAttachments = app.buttons["composer.plus.attachments"]
            XCTAssertTrue(addAttachments.waitForExistence(timeout: 5))
            addAttachments.tap()

            let testPhoto = app.buttons["composer.attachments.testPhoto"]
            guard testPhoto.waitForExistence(timeout: 5) else {
                XCTFail("Missing test-only photo action in attachment sheet.")
                return
            }
            testPhoto.tap()

            let thumbnail = app.descendants(matching: .any).matching(identifier: "composer.attachment.thumbnail.0").firstMatch
            XCTAssertTrue(thumbnail.waitForExistence(timeout: 8), "Thumbnail preview did not appear before send.")
        }

        let prompt = "Describe this image in one short sentence. Mention one color and the main object."
        let finalAnswerQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "codex.final.answer.")
        )
        let baselineFinalAnswerCount = finalAnswerQuery.count

        try await runner.stepAsync("send-photo-prompt") {
            let input = app.textFields["composer.input"]
            guard input.waitForExistence(timeout: 6) else {
                throw stepError("Composer input is missing.")
            }
            E2EUIHelpers.replaceText(in: input, with: prompt, app: app)
            E2EUIHelpers.dismissKeyboardIfVisible(app: app)

            let send = app.buttons["composer.send"]
            guard send.waitForExistence(timeout: 5) else {
                throw stepError("Send button is missing.")
            }
            guard send.isEnabled else {
                throw stepError("Send button is disabled after entering prompt.")
            }

            if !send.isHittable {
                app.swipeDown()
                E2EUIHelpers.dismissKeyboardIfVisible(app: app)
            }

            guard send.isHittable else {
                throw stepError("Send button is not hittable after dismissing keyboard.")
            }
            send.tap()
        }

        try await runner.stepAsync("wait-for-assistant-finalized-response") {
            try E2EWait.until(
                timeout: 150,
                pollInterval: 0.5,
                description: "assistant finalized response for photo prompt"
            ) {
                finalAnswerQuery.count > baselineFinalAnswerCount
                    && app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.message.copy.")).firstMatch.exists
            }

            XCTAssertFalse(
                app.otherElements["session.pending.process"].exists,
                "Pending process indicator should clear after assistant response."
            )
        }
    }

    @MainActor
    private func createProjectViaUI(app: XCUIApplication, runner: E2EStepRunner, namePrefix: String) async throws -> String {
        let projectName = "\(namePrefix)-\(Int(Date().timeIntervalSince1970))"

        try await runner.stepAsync("create-project-\(namePrefix.lowercased())") {
            E2EUIHelpers.openProjectsDrawer(app: app)

            let createButton = app.buttons["drawer.project.create"]
            XCTAssertTrue(createButton.waitForExistence(timeout: 8))
            createButton.tap()

            let field = app.textFields["namePrompt.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            E2EUIHelpers.replaceText(in: field, with: projectName, app: app)

            let confirm = app.buttons["namePrompt.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()

            XCTAssertTrue(app.buttons["project.files.badge"].waitForExistence(timeout: 12))
        }

        return projectName
    }

    @MainActor
    private func waitForProjectID(named projectName: String, probe: E2EHubProbe, timeout: TimeInterval) async throws -> UUID {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            let projects = try await probe.listProjects()
            if let project = projects.first(where: { $0.name == projectName }) {
                return project.id
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        throw NSError(
            domain: "E2EPhotoAttachmentTests",
            code: -40,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for project '\(projectName)' to appear."]
        )
    }

    @MainActor
    private func waitForLatestSessionID(projectID: UUID, probe: E2EHubProbe, timeout: TimeInterval) async throws -> UUID {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            let sessions = try await probe.listSessions(projectID: projectID, includeArchived: true)
                .sorted { $0.updatedAt > $1.updatedAt }
            if let first = sessions.first {
                return first.id
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        throw NSError(
            domain: "E2EPhotoAttachmentTests",
            code: -42,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for session creation in project \(projectID.uuidString)."]
        )
    }

    @MainActor
    private func waitForAssistantReply(
        projectID: UUID,
        sessionID: UUID,
        probe: E2EHubProbe,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            let messages = try await probe.chatHistory(projectID: projectID, sessionID: sessionID, limit: 200)
            guard let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
                try await Task.sleep(for: .milliseconds(700))
                continue
            }
            if latestUserIndex + 1 < messages.count {
                let trailing = messages[(latestUserIndex + 1)..<messages.count]
                if let assistant = trailing.first(where: { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return assistant.text
                }
            }

            try await Task.sleep(for: .milliseconds(700))
        }

        throw NSError(
            domain: "E2EPhotoAttachmentTests",
            code: -41,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for grounded assistant reply in project \(projectID.uuidString)."]
        )
    }

    @MainActor
    private func waitForCondition(
        timeout: TimeInterval,
        interval: TimeInterval,
        description: String,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }

        throw NSError(
            domain: "E2EPhotoAttachmentTests",
            code: -43,
            userInfo: [NSLocalizedDescriptionKey: "Timed out after \(timeout)s waiting for \(description)."]
        )
    }

    private func stepError(_ message: String) -> NSError {
        NSError(
            domain: "E2EPhotoAttachmentTests",
            code: -44,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
