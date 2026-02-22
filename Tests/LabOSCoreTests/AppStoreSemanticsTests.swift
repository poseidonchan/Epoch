import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreSemanticsTests: XCTestCase {
    func testDeleteSessionKeepsArtifacts() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project A") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session A") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "download data and run analysis")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.pendingPlan(for: session.id) != nil
        }

        XCTAssertEqual(store.runs(for: project.id).count, 0, "Run should not exist until plan is approved")

        store.approvePlan(sessionID: session.id)
        try await waitUntil(timeoutSeconds: 5.0) {
            store.runs(for: project.id).contains(where: { $0.status == .succeeded })
        }

        let artifactsBeforeDelete = store.artifacts(for: project.id)
        XCTAssertFalse(artifactsBeforeDelete.isEmpty)

        store.deleteSession(projectID: project.id, sessionID: session.id)

        let artifactsAfterDelete = store.artifacts(for: project.id)
        XCTAssertEqual(artifactsAfterDelete.count, artifactsBeforeDelete.count)
        XCTAssertTrue(store.sessions(for: project.id).isEmpty)
        XCTAssertTrue(store.messages(for: session.id).isEmpty)

        let detachedRuns = store.runs(for: project.id)
        XCTAssertTrue(detachedRuns.allSatisfy { $0.sessionID == nil }, "Run references should be detached from deleted session")
    }

    func testDeleteProjectWipesSessionsRunsAndArtifacts() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project B") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session B") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "run full analysis")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.pendingPlan(for: session.id) != nil
        }
        store.approvePlan(sessionID: session.id)

        try await waitUntil(timeoutSeconds: 5.0) {
            store.runs(for: project.id).contains(where: { $0.status == .succeeded })
        }

        XCTAssertFalse(store.sessions(for: project.id).isEmpty)
        XCTAssertFalse(store.artifacts(for: project.id).isEmpty)
        XCTAssertFalse(store.runs(for: project.id).isEmpty)

        store.deleteProject(projectID: project.id)

        XCTAssertFalse(store.projects.contains(where: { $0.id == project.id }))
        XCTAssertTrue(store.sessions(for: project.id).isEmpty)
        XCTAssertTrue(store.artifacts(for: project.id).isEmpty)
        XCTAssertTrue(store.runs(for: project.id).isEmpty)
    }

    func testCancelPlanDoesNotCreateRun() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project C") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session C") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "execute pipeline")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.pendingPlan(for: session.id) != nil
        }

        store.cancelPlan(sessionID: session.id)

        XCTAssertNil(store.pendingPlan(for: session.id))
        XCTAssertTrue(store.runs(for: project.id).isEmpty)
    }

    func testUploadedFilesAreSeparatedFromGeneratedResults() async throws {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Project D") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Session D") else {
            XCTFail("Session was not created")
            return
        }

        store.addUploadedFiles(
            projectID: project.id,
            fileNames: ["dataset.csv", "nested/path/notes.txt"],
            createdBySessionID: session.id
        )

        let uploadedBeforeRun = store.uploadedArtifacts(for: project.id)
        XCTAssertEqual(uploadedBeforeRun.count, 2)
        XCTAssertTrue(uploadedBeforeRun.allSatisfy { $0.path.hasPrefix("uploads/") })
        XCTAssertTrue(store.generatedArtifacts(for: project.id).isEmpty)

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "download and run analysis")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.pendingPlan(for: session.id) != nil
        }
        store.approvePlan(sessionID: session.id)

        try await waitUntil(timeoutSeconds: 5.0) {
            store.runs(for: project.id).contains(where: { $0.status == .succeeded })
        }

        let uploadedAfterRun = store.uploadedArtifacts(for: project.id)
        let generatedAfterRun = store.generatedArtifacts(for: project.id)

        XCTAssertEqual(uploadedAfterRun.count, 2, "Generated outputs should not be counted as uploaded files")
        XCTAssertFalse(generatedAfterRun.isEmpty)
        XCTAssertTrue(generatedAfterRun.contains { $0.path == "uploads/source.csv" }, "Generated files can still live under uploads/ but must not be treated as user uploads")
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval,
        pollEvery interval: TimeInterval = 0.05,
        condition: @escaping () -> Bool
    ) async throws {
        let timeoutDate = Date().addingTimeInterval(timeoutSeconds)
        while Date() < timeoutDate {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        XCTFail("Condition timed out after \(timeoutSeconds)s")
    }
}
