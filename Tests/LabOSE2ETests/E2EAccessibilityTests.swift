import XCTest

final class E2EAccessibilityTests: XCTestCase {
    @MainActor
    func testCriticalControlsHaveStableIdentifiers() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["home.settings.button"].waitForExistence(timeout: 8))
        app.buttons["home.settings.button"].tap()

        XCTAssertTrue(app.textFields["settings.gateway.url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["settings.gateway.token"].exists)
        XCTAssertTrue(app.buttons["settings.gateway.save"].exists)

        let hpcPartitionField = app.textFields["settings.hpc.partition"]
        if !hpcPartitionField.exists {
            for _ in 0..<4 {
                app.swipeUp()
                if hpcPartitionField.exists { break }
            }
        }
        XCTAssertTrue(hpcPartitionField.exists)
    }
}
