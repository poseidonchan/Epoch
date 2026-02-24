import Foundation
import XCTest

final class E2ECodexTrajectoryCollapseTests: XCTestCase {
    @MainActor
    func testTrajectoryHierarchyAndAutoCollapse() async throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        let config = try E2ELiveGatewayConfig.required()

        try await runner.stepAsync("connect-live-hub") {
            E2EUIHelpers.ensureGatewayConnected(app: app, config: config)
        }

        _ = try await createProjectViaUI(app: app, runner: runner, namePrefix: "E2E-Trajectory")

        try await runner.stepAsync("send-tool-heavy-prompt") {
            let input = app.textFields["composer.input"]
            guard input.waitForExistence(timeout: 8) else {
                throw stepError("Composer input is missing.")
            }

            let prompt = "Run one command to print working directory and list files, then answer in 2 short lines."
            E2EUIHelpers.replaceText(in: input, with: prompt, app: app)
            E2EUIHelpers.dismissKeyboardIfVisible(app: app)

            let send = app.buttons["composer.send"]
            guard send.waitForExistence(timeout: 5), send.isEnabled else {
                throw stepError("Send button is unavailable.")
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

        let summaryQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.trajectory.summary."))
        let groupQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.trajectory.group.toggle."))
        let leafQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.trajectory.leaf.toggle."))
        let leafDetailQuery = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.trajectory.leaf.detail."))
        let copyActionQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.message.copy."))
        let branchActionQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.message.branch."))
        let retryActionQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.message.retry."))
        let retryModelMenuQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.message.retry.modelMenu."))
        let finalAnswerQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "codex.final.answer.")
        )
        var finalAnswerCount = finalAnswerQuery.count
        var hasTrajectorySummary = false

        try await runner.stepAsync("wait-summary-and-expanded-state") {
            let summary = summaryQuery.firstMatch
            hasTrajectorySummary = summary.waitForExistence(timeout: 90)
            guard hasTrajectorySummary else {
                return
            }

            let groupToggle = groupQuery.firstMatch
            XCTAssertTrue(
                groupToggle.waitForExistence(timeout: 20),
                "Trajectory groups were not visible while the turn was active (expected default expanded state)."
            )
        }

        try await runner.stepAsync("wait-for-first-assistant-final") {
            try E2EWait.until(
                timeout: 180,
                pollInterval: 0.5,
                description: "first assistant final response"
            ) {
                finalAnswerQuery.count > finalAnswerCount && copyActionQuery.firstMatch.exists
            }
            finalAnswerCount = finalAnswerQuery.count
        }

        try await runner.stepAsync("assert-auto-collapse-after-final") {
            guard hasTrajectorySummary else { return }
            let groupToggle = groupQuery.firstMatch
            XCTAssertFalse(
                groupToggle.waitForExistence(timeout: 4),
                "Trajectory should auto-collapse after final answer is completed."
            )
        }

        try await runner.stepAsync("expand-summary-group-and-leaf") {
            guard hasTrajectorySummary else { return }
            let summary = summaryQuery.firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 10), "Trajectory summary disappeared unexpectedly.")
            summary.tap()

            let groupToggle = groupQuery.firstMatch
            XCTAssertTrue(groupToggle.waitForExistence(timeout: 8), "Group toggle did not appear after expanding summary.")
            groupToggle.tap()

            let leafToggle = leafQuery.firstMatch
            XCTAssertTrue(leafToggle.waitForExistence(timeout: 8), "Leaf toggle did not appear after expanding group.")

            XCTAssertFalse(
                leafDetailQuery.firstMatch.exists,
                "Leaf detail should remain collapsed by default after opening group."
            )

            leafToggle.tap()
            XCTAssertTrue(
                leafDetailQuery.firstMatch.waitForExistence(timeout: 8),
                "Leaf detail did not appear after expanding command leaf."
            )
        }

        try await runner.stepAsync("no-raw-reasoning-text") {
            XCTAssertFalse(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "chain of thought")).firstMatch.exists,
                "Raw reasoning text leaked into trajectory details."
            )
        }

        try await runner.stepAsync("assistant-action-bar-hides-retry-actions") {
            XCTAssertTrue(copyActionQuery.firstMatch.waitForExistence(timeout: 10), "Copy action was not visible for final agent message.")
            XCTAssertTrue(branchActionQuery.firstMatch.waitForExistence(timeout: 6), "Branch action was not visible for final agent message.")
            XCTAssertFalse(retryActionQuery.firstMatch.waitForExistence(timeout: 1.2), "Regenerate action should not appear for codex agent message.")
            XCTAssertFalse(retryModelMenuQuery.firstMatch.waitForExistence(timeout: 1.2), "Retry model menu should not appear for codex agent message.")
        }

        try await runner.stepAsync("history-turn-has-own-summary") {
            let input = app.textFields["composer.input"]
            guard input.waitForExistence(timeout: 8) else {
                throw stepError("Composer input missing for second prompt.")
            }

            E2EUIHelpers.replaceText(in: input, with: "Run one quick search and return one sentence.", app: app)
            E2EUIHelpers.dismissKeyboardIfVisible(app: app)
            let send = app.buttons["composer.send"]
            guard send.waitForExistence(timeout: 5), send.isEnabled else {
                throw stepError("Send unavailable for second prompt.")
            }
            send.tap()

            try E2EWait.until(
                timeout: 180,
                pollInterval: 0.5,
                description: "second assistant final response"
            ) {
                finalAnswerQuery.count > finalAnswerCount && copyActionQuery.firstMatch.exists
            }
            finalAnswerCount = finalAnswerQuery.count

            if hasTrajectorySummary {
                XCTAssertGreaterThanOrEqual(
                    summaryQuery.count,
                    1,
                    "Expected trajectory summary bar to remain available in history."
                )
            }
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
            domain: "E2ECodexTrajectoryCollapseTests",
            code: -213,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
