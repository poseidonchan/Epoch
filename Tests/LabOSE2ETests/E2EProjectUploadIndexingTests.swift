import Foundation
import XCTest

final class E2EProjectUploadIndexingTests: XCTestCase {
    @MainActor
    func testUploadedFileGetsIndexedAndGroundsAssistantReply() async throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        let config = try E2ELiveGatewayConfig.required()
        let probe = E2EHubProbe(wsURL: config.wsURL, token: config.token)
        defer { probe.disconnect() }

        var projectID: UUID?

        try await runner.stepAsync("connect-live-hub") {
            E2EUIHelpers.ensureGatewayConnected(app: app, config: config)
            try await probe.connect()
        }

        let projectName = try await createProjectViaUI(app: app, runner: runner, namePrefix: "E2E-Indexing")

        try await runner.stepAsync("resolve-project-id") {
            projectID = try await waitForProjectID(named: projectName, probe: probe, timeout: 25)
        }

        guard let projectID else {
            throw NSError(
                domain: "E2EProjectUploadIndexingTests",
                code: -70,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve project ID for \(projectName)."]
            )
        }

        let marker = "LABOS-INDEX-MARKER-\(UUID().uuidString.prefix(8))"
        let secretCode = "LABOS-INDEX-CODE-\(Int(Date().timeIntervalSince1970))"
        let fileName = "indexing-\(Int(Date().timeIntervalSince1970)).txt"
        let uploadedPath = try await probe.uploadProjectFile(
            projectID: projectID,
            fileName: fileName,
            data: Data("""
            Retrieval fixture for LabOS E2E.
            marker: \(marker)
            code: \(secretCode)
            """.utf8),
            mimeType: "text/plain"
        )

        try await runner.stepAsync("wait-for-artifact-indexed") {
            try await waitForArtifactIndexed(projectID: projectID, artifactPath: uploadedPath, probe: probe, timeout: 120)
        }

        let prompt = "Use indexed project uploads only. Return exactly: MARKER=<marker>;CODE=<code>. Marker is \(marker). If unavailable return UNKNOWN."
        let finalAnswerQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "codex.final.answer.")
        )
        let copyActionQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "codex.message.copy."))
        let baselineFinalAnswerCount = finalAnswerQuery.count

        try await runner.stepAsync("send-grounding-query") {
            let input = app.textFields["composer.input"]
            guard input.waitForExistence(timeout: 8) else {
                throw stepError("Composer input missing before retrieval query.")
            }

            E2EUIHelpers.replaceText(in: input, with: prompt, app: app)
            E2EUIHelpers.dismissKeyboardIfVisible(app: app)

            let send = app.buttons["composer.send"]
            guard send.waitForExistence(timeout: 5), send.isEnabled else {
                throw stepError("Send unavailable for retrieval query.")
            }
            if !send.isHittable {
                app.swipeDown()
                E2EUIHelpers.dismissKeyboardIfVisible(app: app)
            }
            guard send.isHittable else {
                throw stepError("Send button not hittable for retrieval query.")
            }
            send.tap()
        }

        try await runner.stepAsync("assert-assistant-uses-indexed-file-content") {
            try E2EWait.until(
                timeout: 180,
                pollInterval: 0.5,
                description: "assistant response containing indexed secret"
            ) {
                finalAnswerQuery.count > baselineFinalAnswerCount
                    && copyActionQuery.firstMatch.exists
                    && app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", secretCode)).firstMatch.exists
            }

            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", secretCode)).firstMatch.exists,
                "Assistant reply did not include indexed secret code."
            )
            XCTAssertFalse(
                app.otherElements["session.pending.process"].exists,
                "Pending process indicator should clear after assistant response."
            )
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

    @MainActor
    private func waitForProjectID(named projectName: String, probe: E2EHubProbe, timeout: TimeInterval) async throws -> UUID {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            let projects = try await probe.listProjects()
            if let project = projects.first(where: { $0.name == projectName }) {
                return project.id
            }
            try await Task.sleep(for: .milliseconds(300))
        }

        throw NSError(
            domain: "E2EProjectUploadIndexingTests",
            code: -71,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for project '\(projectName)' to appear."]
        )
    }

    @MainActor
    private func waitForArtifactIndexed(
        projectID: UUID,
        artifactPath: String,
        probe: E2EHubProbe,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            let artifacts = try await probe.listArtifacts(projectID: projectID)
            if let artifact = artifacts.first(where: { $0.path == artifactPath }) {
                if artifact.indexStatus == .indexed {
                    return
                }
                if artifact.indexStatus == .failed {
                    throw NSError(
                        domain: "E2EProjectUploadIndexingTests",
                        code: -72,
                        userInfo: [NSLocalizedDescriptionKey: "Artifact indexing failed for \(artifactPath)."]
                    )
                }
            }
            try await Task.sleep(for: .milliseconds(700))
        }

        throw NSError(
            domain: "E2EProjectUploadIndexingTests",
            code: -73,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for artifact indexing: \(artifactPath)"]
        )
    }

    private func stepError(_ message: String) -> NSError {
        NSError(
            domain: "E2EProjectUploadIndexingTests",
            code: -76,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
