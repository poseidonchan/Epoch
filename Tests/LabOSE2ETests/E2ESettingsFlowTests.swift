import XCTest

final class E2ESettingsFlowTests: XCTestCase {
    @MainActor
    func testHubAndHpcSettingsSaveConnectAndPersist() throws {
        let app = XCUIApplication()
        app.launch()
        let runner = E2EStepRunner(testCase: self, app: app)

        let wsURLFromEnv = ProcessInfo.processInfo.environment["LABOS_E2E_WS_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenFromEnv = ProcessInfo.processInfo.environment["LABOS_E2E_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let partition = "labos-e2e-partition"
        let account = "labos-e2e-account"
        let qos = "labos-e2e-qos"

        try runner.step("open-settings") {
            let settingsButton = app.buttons["home.settings.button"]
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
            settingsButton.tap()
            XCTAssertTrue(app.textFields["settings.gateway.url"].waitForExistence(timeout: 6))
        }

        let wsURLField = app.textFields["settings.gateway.url"]
        let tokenField = app.secureTextFields["settings.gateway.token"]
        let gatewaySaveButton = app.buttons["settings.gateway.save"]
        let gatewayConnectButton = app.buttons["settings.gateway.connect"]
        let gatewayDisconnectButton = app.buttons["settings.gateway.disconnect"]

        let wsURLTarget: String = {
            if let wsURLFromEnv, !wsURLFromEnv.isEmpty { return wsURLFromEnv }
            if let current = textValue(of: wsURLField), !current.isEmpty, current != "ws://host:8787/ws" {
                return current
            }
            return "ws://127.0.0.1:8787/ws"
        }()

        try runner.step("save-gateway-settings") {
            replaceText(in: wsURLField, with: wsURLTarget, app: app)

            if let tokenFromEnv, !tokenFromEnv.isEmpty {
                replaceText(in: tokenField, with: tokenFromEnv, app: app)
            }

            XCTAssertTrue(gatewaySaveButton.exists)
            gatewaySaveButton.tap()
        }

        try runner.step("connect-gateway") {
            if gatewayDisconnectButton.waitForExistence(timeout: 3) {
                gatewayDisconnectButton.tap()
                XCTAssertTrue(gatewayConnectButton.waitForExistence(timeout: 12))
            } else {
                XCTAssertTrue(gatewayConnectButton.waitForExistence(timeout: 12))
            }

            gatewayConnectButton.tap()
            XCTAssertTrue(gatewayDisconnectButton.waitForExistence(timeout: 20))
        }

        try runner.step("save-hpc-settings") {
            let hpcPartitionField = app.textFields["settings.hpc.partition"]
            scrollToElement(hpcPartitionField, in: app, maxSwipes: 6)
            XCTAssertTrue(hpcPartitionField.waitForExistence(timeout: 5))

            replaceText(in: hpcPartitionField, with: partition, app: app)
            replaceText(in: app.textFields["settings.hpc.account"], with: account, app: app)
            replaceText(in: app.textFields["settings.hpc.qos"], with: qos, app: app)

            let hpcSaveButton = app.buttons["settings.hpc.save"]
            XCTAssertTrue(hpcSaveButton.exists)
            hpcSaveButton.tap()
        }

        try runner.step("close-settings") {
            let doneButton = app.buttons["settings.done"]
            if !doneButton.exists {
                app.swipeDown()
            }
            XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
            doneButton.tap()
            XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 6))
        }

        try runner.step("reopen-and-verify-persistence") {
            let settingsButton = app.buttons["home.settings.button"]
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
            settingsButton.tap()
            XCTAssertTrue(wsURLField.waitForExistence(timeout: 5))

            XCTAssertEqual(textValue(of: wsURLField), wsURLTarget)

            let hpcPartitionField = app.textFields["settings.hpc.partition"]
            scrollToElement(hpcPartitionField, in: app, maxSwipes: 6)
            XCTAssertTrue(hpcPartitionField.waitForExistence(timeout: 5))
            XCTAssertEqual(textValue(of: hpcPartitionField), partition)
            XCTAssertEqual(textValue(of: app.textFields["settings.hpc.account"]), account)
            XCTAssertEqual(textValue(of: app.textFields["settings.hpc.qos"]), qos)
        }
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with text: String, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()

        if let current = textValue(of: element), !current.isEmpty, current != placeholderValue(of: element) {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }

        if app.menuItems["Select All"].waitForExistence(timeout: 0.6) {
            app.menuItems["Select All"].tap()
            element.typeText(XCUIKeyboardKey.delete.rawValue)
        }

        element.typeText(text)
    }

    @MainActor
    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int) {
        if element.exists { return }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.exists { return }
        }
    }

    @MainActor
    private func textValue(of element: XCUIElement) -> String? {
        guard let raw = element.value as? String else { return nil }
        return raw == placeholderValue(of: element) ? "" : raw
    }

    @MainActor
    private func placeholderValue(of element: XCUIElement) -> String? {
        switch element.identifier {
        case "settings.gateway.url":
            return "ws://host:8787/ws"
        case "settings.gateway.token":
            return "Shared token"
        case "settings.hpc.partition":
            return "Partition"
        case "settings.hpc.account":
            return "Account"
        case "settings.hpc.qos":
            return "QoS"
        default:
            return nil
        }
    }
}
