import XCTest

final class E2ESmokeTests: XCTestCase {
    func testLaunchesHome() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 8))
    }
}
