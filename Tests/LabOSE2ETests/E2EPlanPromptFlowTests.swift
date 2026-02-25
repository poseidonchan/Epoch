import Foundation
import XCTest

final class E2EPlanPromptFlowTests: XCTestCase {
    private let fixtureSessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    @MainActor
    func testPlanPromptOverlaysComposerAndSessionAwaitingStateClearsAfterSubmit() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LABOS_E2E_FIXTURE_PLAN_PROMPT_FLOW"] = "1"
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        let rowID = "project.session.row.\(fixtureSessionID.uuidString.lowercased())"
        let awaitingID = "project.session.awaiting.\(fixtureSessionID.uuidString.lowercased())"

        try runner.step("project-row-shows-awaiting-response") {
            let row = app.buttons[rowID]
            XCTAssertTrue(row.waitForExistence(timeout: 8), "Fixture session row not found in project page.")
            XCTAssertTrue(app.staticTexts[awaitingID].waitForExistence(timeout: 3), "Awaiting response badge was not visible.")
        }

        try runner.step("open-session-and-verify-prompt-overlays-composer") {
            app.buttons[rowID].tap()
            XCTAssertTrue(app.otherElements["session.codexPrompt.card"].waitForExistence(timeout: 8))
            XCTAssertFalse(app.textFields["composer.input"].exists, "Composer input should be replaced by pending prompt UI.")
        }

        try runner.step("select-option-and-submit") {
            let option = app.buttons["session.codexPrompt.option.execution_mode_proceed_now"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()

            let submit = app.buttons["session.codexPrompt.submit"]
            XCTAssertTrue(submit.waitForExistence(timeout: 5))
            XCTAssertTrue(submit.isEnabled)
            submit.tap()
        }

        try runner.step("verify-plan-progress-card-appears-above-composer") {
            XCTAssertFalse(
                app.otherElements["session.codexPrompt.card"].waitForExistence(timeout: 2),
                "Prompt card should be dismissed after submit."
            )

            let planCard = app.otherElements["session.plan.progress.card"]
            XCTAssertTrue(planCard.waitForExistence(timeout: 8), "Plan progress card did not appear.")

            let composer = app.textFields["composer.input"]
            XCTAssertTrue(composer.waitForExistence(timeout: 8), "Composer input did not return after prompt submit.")
            XCTAssertLessThanOrEqual(planCard.frame.maxY, composer.frame.minY + 2, "Plan progress card should render above composer.")
        }

        try runner.step("return-to-project-and-awaiting-badge-clears") {
            let back = app.buttons["session.back.project"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()

            XCTAssertTrue(app.buttons[rowID].waitForExistence(timeout: 8))
            XCTAssertFalse(
                app.staticTexts[awaitingID].waitForExistence(timeout: 2),
                "Awaiting response badge should clear after prompt response."
            )
        }
    }
}
