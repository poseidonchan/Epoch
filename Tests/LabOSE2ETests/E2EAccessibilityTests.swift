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

    @MainActor
    func testUserMessageContextMenuHidesRetryActions() {
        let app = XCUIApplication()
        app.launch()

        let projectName = createProjectViaUI(app: app, namePrefix: "E2E-Menu")
        XCTAssertFalse(projectName.isEmpty)

        let composerInput = app.textFields["composer.input"]
        XCTAssertTrue(composerInput.waitForExistence(timeout: 8))
        composerInput.tap()
        composerInput.typeText("E2E user menu check")

        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let bubbleText = app.staticTexts["E2E user menu check"]
        XCTAssertTrue(bubbleText.waitForExistence(timeout: 10))
        bubbleText.press(forDuration: 1.0)

        XCTAssertTrue(
            app.buttons["Edit"].waitForExistence(timeout: 4)
                || app.menuItems["Edit"].waitForExistence(timeout: 4)
        )

        XCTAssertFalse(app.menuItems["Retry"].waitForExistence(timeout: 1.2))
        XCTAssertFalse(app.menuItems["Retry With Different Model"].waitForExistence(timeout: 1.2))
    }

    @MainActor
    func testSessionAttachmentSheetShowsCameraTileAndRecentPhotosRail() {
        let app = XCUIApplication()
        app.launch()

        _ = createProjectViaUI(app: app, namePrefix: "E2E-AttachUI")

        let plusButton = app.buttons["composer.plus"]
        XCTAssertTrue(plusButton.waitForExistence(timeout: 8))
        plusButton.tap()

        let addAttachments = app.buttons["composer.plus.attachments"]
        XCTAssertTrue(addAttachments.waitForExistence(timeout: 5))
        addAttachments.tap()

        let allPhotosVisible =
            app.buttons["composer.attachments.allPhotos"].waitForExistence(timeout: 8)
            || app.buttons["All Photos"].waitForExistence(timeout: 8)
        XCTAssertTrue(allPhotosVisible)

        let cameraTileVisible =
            app.buttons["composer.attachments.cameraTile"].waitForExistence(timeout: 5)
            || app.buttons["Take Photo"].waitForExistence(timeout: 5)
            || app.staticTexts["Take Photo"].waitForExistence(timeout: 5)
        XCTAssertTrue(cameraTileVisible)

        let recentRailVisible =
            app.scrollViews["composer.attachments.recentRail"].waitForExistence(timeout: 5)
            || app.otherElements["composer.attachments.recentRail"].waitForExistence(timeout: 5)
        XCTAssertTrue(recentRailVisible)
    }

    @MainActor
    private func createProjectViaUI(app: XCUIApplication, namePrefix: String) -> String {
        let projectName = "\(namePrefix)-\(Int(Date().timeIntervalSince1970))"

        let sidebarButton = app.buttons["home.sidebar.button"]
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: 8))
        sidebarButton.tap()

        let createButton = app.buttons["drawer.project.create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 8))
        createButton.tap()

        let field = app.textFields["namePrompt.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(projectName)

        let confirm = app.buttons["namePrompt.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.buttons["project.files.badge"].waitForExistence(timeout: 12))
        return projectName
    }
}
