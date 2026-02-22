import XCTest

final class E2EHarnessTests: XCTestCase {
    @MainActor
    func testStepRunnerCapturesScreenshotAndLog() throws {
        let app = XCUIApplication()
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        try runner.step("home-visible") {
            XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 5))
        }

        XCTAssertTrue(runner.lastStepArtifactsContain("home-visible"))
    }
}
