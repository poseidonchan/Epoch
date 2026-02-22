import Foundation
import XCTest

final class E2EProjectLifecycleTests: XCTestCase {
    @MainActor
    func testProjectDeletionRemovesDiskFolderRecursively() async throws {
        let app = XCUIApplication()
        app.launch()
        let runner = E2EStepRunner(testCase: self, app: app)
        let config = try E2ELiveGatewayConfig.required()
        let probe = E2EHubProbe(wsURL: config.wsURL, token: config.token)
        let projectName = "E2E-Lifecycle-\(Int(Date().timeIntervalSince1970))"
        var projectID: UUID?
        defer { probe.disconnect() }

        try await runner.stepAsync("connect-live-hub") {
            E2EUIHelpers.ensureGatewayConnected(app: app, config: config)
            try await probe.connect()
        }

        try await runner.stepAsync("create-project") {
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

        try await runner.stepAsync("resolve-project-id-and-verify-folder-created") {
            let resolved = try await waitForProjectID(named: projectName, probe: probe, timeout: 25)
            projectID = resolved

            let dir = probe.localProjectDirectory(projectID: resolved)
            try await waitForCondition(timeout: 25, interval: 0.4, description: "project directory exists") {
                FileManager.default.fileExists(atPath: dir.path)
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bootstrap").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("uploads").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions").path))
        }

        guard let projectID else {
            throw NSError(
                domain: "E2EProjectLifecycleTests",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve project ID for \(projectName)."]
            )
        }
        let projectDir = probe.localProjectDirectory(projectID: projectID)

        try await runner.stepAsync("delete-project-via-context-menu") {
            E2EUIHelpers.openProjectsDrawer(app: app)

            let rowIdentifier = "drawer.project.row.\(projectID.uuidString.lowercased())"
            let projectRow = app.buttons[rowIdentifier]
            XCTAssertTrue(projectRow.waitForExistence(timeout: 10), "Missing project row: \(rowIdentifier)")
            projectRow.press(forDuration: 1.2)

            if app.buttons["Delete Project"].waitForExistence(timeout: 3) {
                app.buttons["Delete Project"].tap()
            } else {
                let menuItem = app.menuItems["Delete Project"]
                XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "Delete Project context action did not appear.")
                menuItem.tap()
            }

            let confirmField = app.textFields["drawer.project.delete.confirmationField"]
            XCTAssertTrue(confirmField.waitForExistence(timeout: 8))
            E2EUIHelpers.replaceText(in: confirmField, with: projectName, app: app)

            let confirmButton = app.buttons["drawer.project.delete.confirm"]
            XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
            XCTAssertTrue(confirmButton.isEnabled, "Delete confirmation button is disabled.")
            confirmButton.tap()
        }

        try await runner.stepAsync("verify-project-removed-remotely-and-on-disk") {
            try await waitForCondition(timeout: 30, interval: 0.5, description: "project removal from Hub listing") {
                let projects = try await probe.listProjects()
                return projects.contains(where: { $0.id == projectID }) == false
            }

            try await waitForCondition(timeout: 30, interval: 0.5, description: "project folder removed from stateDir") {
                !FileManager.default.fileExists(atPath: projectDir.path)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir.path))
        }
    }

    @MainActor
    private func waitForProjectID(
        named projectName: String,
        probe: E2EHubProbe,
        timeout: TimeInterval
    ) async throws -> UUID {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            let projects = try await probe.listProjects()
            if let project = projects.first(where: { $0.name == projectName }) {
                return project.id
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        throw NSError(
            domain: "E2EProjectLifecycleTests",
            code: -21,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for project '\(projectName)' to appear in Hub."]
        )
    }

    @MainActor
    private func waitForCondition(
        timeout: TimeInterval,
        interval: TimeInterval,
        description: String,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }

        throw NSError(
            domain: "E2EProjectLifecycleTests",
            code: -22,
            userInfo: [NSLocalizedDescriptionKey: "Timed out after \(timeout)s waiting for \(description)."]
        )
    }
}
