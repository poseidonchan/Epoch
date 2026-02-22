import Foundation
import XCTest

struct E2ELiveGatewayConfig {
    let wsURLString: String
    let token: String

    var wsURL: URL {
        URL(string: wsURLString)!
    }

    static func required() throws -> E2ELiveGatewayConfig {
        let env = ProcessInfo.processInfo.environment
        let rawURL = env["LABOS_E2E_WS_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wsURLString = (rawURL?.isEmpty == false) ? rawURL! : "ws://127.0.0.1:8787/ws"

        guard URL(string: wsURLString) != nil else {
            throw NSError(
                domain: "E2EUIHelpers",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid LABOS_E2E_WS_URL: \(wsURLString)"]
            )
        }

        let envToken = env["LABOS_E2E_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = envToken.isEmpty ? (tokenFromLocalHubConfig() ?? "") : envToken
        guard !token.isEmpty else {
            throw NSError(
                domain: "E2EUIHelpers",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Missing LABOS_E2E_TOKEN for live E2E (and no token found in ~/.labos/config.json)."]
            )
        }

        return E2ELiveGatewayConfig(wsURLString: wsURLString, token: token)
    }

    private static func tokenFromLocalHubConfig() -> String? {
        let env = ProcessInfo.processInfo.environment
        let hostHome = env["SIMULATOR_HOST_HOME"] ?? env["HOME"] ?? ""
        guard !hostHome.isEmpty else { return nil }
        let configURL = URL(fileURLWithPath: hostHome, isDirectory: true)
            .appendingPathComponent(".labos/config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = raw["token"] as? String
        else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum E2EUIHelpers {
    static func ensureGatewayConnected(app: XCUIApplication, config: E2ELiveGatewayConfig) {
        navigateToHome(app: app)

        let settingsButton = app.buttons["home.settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Home settings button not found.")
        settingsButton.tap()

        let wsURLField = app.textFields["settings.gateway.url"]
        let tokenField = app.secureTextFields["settings.gateway.token"]
        let gatewaySaveButton = app.buttons["settings.gateway.save"]
        let gatewayConnectButton = app.buttons["settings.gateway.connect"]
        let gatewayDisconnectButton = app.buttons["settings.gateway.disconnect"]

        XCTAssertTrue(wsURLField.waitForExistence(timeout: 8), "Gateway URL field not found.")
        replaceText(in: wsURLField, with: config.wsURLString, app: app)
        replaceText(in: tokenField, with: config.token, app: app)

        XCTAssertTrue(gatewaySaveButton.exists, "Gateway Save button missing.")
        gatewaySaveButton.tap()

        if !gatewayDisconnectButton.waitForExistence(timeout: 2) {
            XCTAssertTrue(gatewayConnectButton.waitForExistence(timeout: 10), "Gateway Connect button missing.")
            gatewayConnectButton.tap()
            XCTAssertTrue(gatewayDisconnectButton.waitForExistence(timeout: 25), "Gateway failed to connect.")
        }

        let doneButton = app.buttons["settings.done"]
        if !doneButton.exists {
            app.swipeDown()
        }
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.tap()
    }

    static func navigateToHome(app: XCUIApplication) {
        if app.buttons["home.settings.button"].exists {
            return
        }

        let backToProject = app.buttons["session.back.project"]
        if backToProject.waitForExistence(timeout: 1.5) {
            backToProject.tap()
        }

        if app.buttons["home.settings.button"].exists {
            return
        }

        openProjectsDrawer(app: app)
        let homeButton = app.buttons["drawer.home.button"]
        if homeButton.waitForExistence(timeout: 3) {
            homeButton.tap()
        }
    }

    static func openProjectsDrawer(app: XCUIApplication) {
        let homeSidebarButton = app.buttons["home.sidebar.button"]
        if homeSidebarButton.waitForExistence(timeout: 2) {
            homeSidebarButton.tap()
            return
        }

        let projectSidebarButton = app.buttons["project.sidebar.button"]
        if projectSidebarButton.waitForExistence(timeout: 2) {
            projectSidebarButton.tap()
            return
        }

        XCTFail("Unable to find a sidebar button to open projects drawer.")
    }

    static func replaceText(in element: XCUIElement, with text: String, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 6), "Text field not found: \(element.identifier)")
        element.tap()

        if app.menuItems["Select All"].waitForExistence(timeout: 0.6) {
            app.menuItems["Select All"].tap()
            element.typeText(XCUIKeyboardKey.delete.rawValue)
        } else if let current = textValue(of: element), !current.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(current.count, 16)))
        }

        element.typeText(text)
    }

    static func dismissKeyboardIfVisible(app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 0.2) else { return }

        let dismissalLabels = [
            "return",
            "Return",
            "done",
            "Done",
            "dismiss keyboard",
            "Dismiss keyboard",
            "hide keyboard",
            "Hide keyboard"
        ]

        for label in dismissalLabels {
            let key = keyboard.keys[label]
            if key.exists && key.isHittable {
                key.tap()
                if !keyboard.waitForExistence(timeout: 0.6) {
                    return
                }
            }

            let button = keyboard.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                if !keyboard.waitForExistence(timeout: 0.6) {
                    return
                }
            }
        }

        if keyboard.exists {
            keyboard.swipeDown()
        }
    }

    static func scrollToElement(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) {
        if element.exists { return }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.exists { return }
        }
    }

    static func textValue(of element: XCUIElement) -> String? {
        guard let raw = element.value as? String else { return nil }
        let placeholder = placeholderValue(of: element)
        if raw == placeholder {
            return ""
        }
        return raw
    }

    private static func placeholderValue(of element: XCUIElement) -> String? {
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
