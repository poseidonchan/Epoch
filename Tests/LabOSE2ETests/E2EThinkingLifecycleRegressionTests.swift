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

        try await runner.stepAsync("connect-live-hub") {
            E2EUIHelpers.ensureGatewayConnected(app: app, config: config)
        }

        _ = try await createProjectViaUI(app: app, runner: runner, namePrefix: "E2E-Thinking")
        let prompt = "Reply with exactly one word: pong."
        var projectSessionRowID: String?
        let finalAnswerQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "codex.final.answer.")
        )
        let copyActionQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.message.copy."))
        let baselineFinalAnswerCount = finalAnswerQuery.count

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
            try E2EWait.until(
                timeout: 150,
                pollInterval: 0.5,
                description: "assistant reply to complete"
            ) {
                finalAnswerQuery.count > baselineFinalAnswerCount && copyActionQuery.firstMatch.exists
            }
            XCTAssertFalse(
                app.otherElements["session.pending.process"].exists,
                "Pending process indicator should clear once response is complete."
            )
        }

        try await runner.stepAsync("leave-and-return-session") {
            // Sending from the project composer opens the new session.
            // Normalize back to project view before searching for session rows.
            let backToProject = app.buttons["session.back.project"]
            if backToProject.waitForExistence(timeout: 2) {
                backToProject.tap()
                guard app.buttons["project.files.badge"].waitForExistence(timeout: 8) else {
                    throw stepError("Project view did not appear after leaving session.")
                }
            }

            let sessionRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project.session.row."))
            let row = sessionRows.firstMatch
            guard row.waitForExistence(timeout: 15) else {
                throw stepError("Session row did not appear in project list.")
            }
            projectSessionRowID = row.identifier
            guard let rowID = projectSessionRowID, rowID.hasPrefix("project.session.row.") else {
                throw stepError("Session row identifier is invalid: \(row.identifier)")
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
