import Foundation
import XCTest

final class E2EThinkingLifecycleRegressionTests: XCTestCase {
    @MainActor
    func testNoStuckThinkingAfterLeaveAndReturn() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        let config = try E2ELiveGatewayConfig.required()
        let probe = E2EHubProbe(wsURL: config.wsURL, token: config.token)
        defer { probe.disconnect() }

        try await runner.stepAsync("connect-live-hub") {
            E2EUIHelpers.ensureGatewayConnected(app: app, config: config)
            try await probe.connect()
        }

        let projectName = try await createProjectViaUI(app: app, runner: runner, namePrefix: "E2E-Thinking")
        let projectID = try await waitForProjectID(named: projectName, probe: probe, timeout: 25)
        let prompt = "Reply with exactly one word: pong."
        var sessionID: UUID?

        try await runner.stepAsync("send-project-message") {
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
                throw stepError("Send button is not hittable.")
            }
            send.tap()
        }

        try await runner.stepAsync("wait-for-assistant-reply") {
            sessionID = try await waitForLatestSessionID(projectID: projectID, probe: probe, timeout: 25)
            guard let sessionID else {
                throw stepError("Session ID missing after send.")
            }
            let assistantText = try await waitForAssistantReply(projectID: projectID, sessionID: sessionID, probe: probe, timeout: 90)
            XCTAssertFalse(assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        try await runner.stepAsync("leave-and-return-session") {
            guard let sessionID else {
                throw stepError("Session ID missing before leave/reopen.")
            }

            // Sending from the project composer opens the new session.
            // Normalize back to project view before searching for session rows.
            let backToProject = app.buttons["session.back.project"]
            if backToProject.waitForExistence(timeout: 2) {
                backToProject.tap()
                guard app.buttons["project.files.badge"].waitForExistence(timeout: 8) else {
                    throw stepError("Project view did not appear after leaving session.")
                }
            }

            let rowID = "project.session.row.\(sessionID.uuidString.lowercased())"
            let row = app.buttons[rowID]
            guard row.waitForExistence(timeout: 15) else {
                throw stepError("Session row did not appear in project list.")
            }
            try await openSessionFromProjectRow(app: app, rowID: rowID, timeout: 12)

            let back = app.buttons["session.back.project"]
            guard back.waitForExistence(timeout: 2) else {
                throw stepError("Session view failed to open.")
            }
            back.tap()

            let rowAgain = app.buttons[rowID]
            guard rowAgain.waitForExistence(timeout: 15) else {
                throw stepError("Session row did not reappear after leaving session.")
            }
            try await openSessionFromProjectRow(app: app, rowID: rowID, timeout: 12)
        }

        try await runner.stepAsync("assert-no-stuck-thinking-indicator") {
            let pendingProcess = app.otherElements["session.pending.process"]
            XCTAssertFalse(
                pendingProcess.waitForExistence(timeout: 5),
                "Pending process indicator is still visible after assistant reply and reopen."
            )
            XCTAssertFalse(
                app.staticTexts["Thinking..."].exists,
                "Thinking indicator text is still visible after assistant reply and reopen."
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
            domain: "E2EThinkingLifecycleRegressionTests",
            code: -50,
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
            domain: "E2EThinkingLifecycleRegressionTests",
            code: -51,
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
            domain: "E2EThinkingLifecycleRegressionTests",
            code: -52,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for assistant reply in project \(projectID.uuidString)."]
        )
    }

    private func stepError(_ message: String) -> NSError {
        NSError(
            domain: "E2EThinkingLifecycleRegressionTests",
            code: -53,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    @MainActor
    private func openSessionFromProjectRow(app: XCUIApplication, rowID: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let back = app.buttons["session.back.project"]
        let row = app.buttons[rowID]

        while Date() <= deadline {
            if back.exists {
                return
            }

            guard row.waitForExistence(timeout: 2) else {
                throw stepError("Session row disappeared before it could be opened.")
            }

            if !row.isHittable {
                E2EUIHelpers.scrollToElement(row, in: app, maxSwipes: 2)
            }

            row.tap()
            if back.waitForExistence(timeout: 1.8) {
                return
            }

            try await Task.sleep(for: .milliseconds(450))
        }

        throw stepError("Session view failed to open.")
    }
}
