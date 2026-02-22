import Foundation
import XCTest

final class E2EProjectUploadBoundaryTests: XCTestCase {
    @MainActor
    func testProjectBadgeOwnsProjectUploadsAndComposerPlusIsSessionScoped() async throws {
        let app = XCUIApplication()
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        let config = try E2ELiveGatewayConfig.required()
        let probe = E2EHubProbe(wsURL: config.wsURL, token: config.token)
        defer { probe.disconnect() }

        let projectName = "E2E-Boundary-\(Int(Date().timeIntervalSince1970))"
        var projectID: UUID?

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

        try await runner.stepAsync("resolve-project-id") {
            let resolved = try await waitForProjectID(named: projectName, probe: probe, timeout: 25)
            projectID = resolved
        }

        guard let projectID else {
            throw NSError(
                domain: "E2EProjectUploadBoundaryTests",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve project ID for \(projectName)."]
            )
        }

        let badge = app.buttons["project.files.badge"]

        try await runner.stepAsync("upload-project-file-via-live-hub-and-observe-badge") {
            let payload = Data("boundary-check \(Date())".utf8)
            _ = try await probe.uploadProjectFile(
                projectID: projectID,
                fileName: "boundary-\(Int(Date().timeIntervalSince1970)).txt",
                data: payload,
                mimeType: "text/plain"
            )

            try await waitForCondition(timeout: 25, interval: 0.5, description: "project badge reflects one uploaded file") {
                badge.waitForExistence(timeout: 1) && badge.label.localizedCaseInsensitiveContains("uploaded file")
            }
            XCTAssertTrue(badge.label.localizedCaseInsensitiveContains("uploaded file"))
        }

        let badgeLabelBeforeComposer = badge.label

        try await runner.stepAsync("open-session-attachments-from-composer-plus") {
            let plusButton = app.buttons["composer.plus"]
            XCTAssertTrue(plusButton.waitForExistence(timeout: 8))
            plusButton.tap()

            let addAttachments = app.buttons["composer.plus.attachments"]
            XCTAssertTrue(addAttachments.waitForExistence(timeout: 5))
            addAttachments.tap()

            let title = app.staticTexts["composer.attachments.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["Items added here stay in this session only."].exists)

            let closeButton = app.buttons["composer.attachments.close"]
            guard closeButton.waitForExistence(timeout: 5) else {
                XCTFail("Missing composer attachment close button.")
                return
            }
            closeButton.tap()
        }

        try await runner.stepAsync("verify-project-badge-count-unchanged-after-composer-flow") {
            XCTAssertTrue(badge.waitForExistence(timeout: 5))
            XCTAssertEqual(badge.label, badgeLabelBeforeComposer)
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
            domain: "E2EProjectUploadBoundaryTests",
            code: -31,
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
            domain: "E2EProjectUploadBoundaryTests",
            code: -32,
            userInfo: [NSLocalizedDescriptionKey: "Timed out after \(timeout)s waiting for \(description)."]
        )
    }
}
