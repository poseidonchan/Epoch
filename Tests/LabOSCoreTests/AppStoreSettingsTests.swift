import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreSettingsTests: XCTestCase {
    func testGatewaySettingsAreNormalizedTrimmedAndPersisted() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        store.saveGatewaySettings(wsURLString: "127.0.0.1:8787", token: "  abc123 \n")

        XCTAssertEqual(store.gatewayWSURLString, "ws://127.0.0.1:8787/ws")
        XCTAssertEqual(store.gatewayToken, "abc123")

        let store2 = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertEqual(store2.gatewayWSURLString, "ws://127.0.0.1:8787/ws")
        XCTAssertEqual(store2.gatewayToken, "abc123")
    }

    func testHpcSettingsAreTrimmedAndPersisted() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        store.saveHpcSettings(partition: "  gpu  ", account: "  lab\t", qos: "  normal\n")

        XCTAssertEqual(store.hpcPartition, "gpu")
        XCTAssertEqual(store.hpcAccount, "lab")
        XCTAssertEqual(store.hpcQos, "normal")

        let store2 = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertEqual(store2.hpcPartition, "gpu")
        XCTAssertEqual(store2.hpcAccount, "lab")
        XCTAssertEqual(store2.hpcQos, "normal")
    }

    func testRunCompletionNotificationsPreferencePersists() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertTrue(store.runCompletionNotificationsEnabled)
        store.setRunCompletionNotificationsEnabled(false)
        XCTAssertFalse(store.runCompletionNotificationsEnabled)

        let store2 = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertFalse(store2.runCompletionNotificationsEnabled)
    }

    func testResourcePollingPublishesOnlyForChangedHomeContextUpdates() {
        let baseline = ResourceStatus(
            computeConnected: true,
            queueDepth: 1,
            storageUsedPercent: 22,
            storageTotalBytes: 1000,
            storageUsedBytes: 220,
            storageAvailableBytes: 780,
            cpuPercent: 10,
            ramPercent: 30,
            hpc: nil
        )
        let changed = ResourceStatus(
            computeConnected: true,
            queueDepth: 4,
            storageUsedPercent: 25,
            storageTotalBytes: 1000,
            storageUsedBytes: 250,
            storageAvailableBytes: 750,
            cpuPercent: 13,
            ramPercent: 36,
            hpc: nil
        )

        XCTAssertFalse(
            AppStore.shouldPublishResourceStatusUpdate(
                context: .session(projectID: UUID(), sessionID: UUID()),
                previous: baseline,
                incoming: changed
            )
        )
        XCTAssertFalse(
            AppStore.shouldPublishResourceStatusUpdate(
                context: .project(projectID: UUID()),
                previous: baseline,
                incoming: changed
            )
        )
        XCTAssertFalse(
            AppStore.shouldPublishResourceStatusUpdate(
                context: .home,
                previous: baseline,
                incoming: baseline
            )
        )
        XCTAssertTrue(
            AppStore.shouldPublishResourceStatusUpdate(
                context: .home,
                previous: baseline,
                incoming: changed
            )
        )
    }

    func testArtifactStorageBreakdownAggregatesFromArtifacts() async {
        let store = AppStore(bootstrapDemo: false)
        guard let project = await store.createProject(name: "Storage Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Storage Session") else {
            XCTFail("Session was not created")
            return
        }

        store.addUploadedFiles(
            projectID: project.id,
            fileNames: ["data.csv", "notes.txt", "preview.png"],
            createdBySessionID: session.id
        )

        let artifacts = store.artifacts(for: project.id)
        let expectedByKind = Dictionary(grouping: artifacts, by: \.kind)
            .mapValues { rows in
                rows.reduce(0) { partial, artifact in
                    partial + max(artifact.sizeBytes ?? 0, 0)
                }
            }

        let breakdownByKind = Dictionary(uniqueKeysWithValues: store.artifactStorageBreakdown.map { ($0.kind, $0.bytes) })

        for (kind, expected) in expectedByKind {
            XCTAssertEqual(breakdownByKind[kind], expected)
        }

        let expectedTotal = expectedByKind.values.reduce(0, +)
        XCTAssertEqual(store.totalArtifactStorageBytes, expectedTotal)
    }

    func testRunCompletionSignalEmitsWhenRunFinishes() async throws {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        guard let project = await store.createProject(name: "Notif Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Notif Session") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "run a pipeline")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.pendingPlan(for: session.id) != nil
        }
        store.approvePlan(sessionID: session.id)

        try await waitUntil(timeoutSeconds: 8.0) {
            store.latestRunCompletionSignal != nil
        }

        let signal = store.latestRunCompletionSignal
        XCTAssertEqual(signal?.projectID, project.id)
        XCTAssertEqual(signal?.status, .succeeded)
        XCTAssertNotNil(signal?.runID)
    }

    func testRunCompletionSignalRespectsNotificationPreference() async throws {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        store.setRunCompletionNotificationsEnabled(false)

        guard let project = await store.createProject(name: "Notif Disabled Project") else {
            XCTFail("Project was not created")
            return
        }
        guard let session = await store.createSession(projectID: project.id, title: "Notif Disabled Session") else {
            XCTFail("Session was not created")
            return
        }

        store.sendMessage(projectID: project.id, sessionID: session.id, text: "run a pipeline")
        try await waitUntil(timeoutSeconds: 2.0) {
            store.pendingPlan(for: session.id) != nil
        }
        store.approvePlan(sessionID: session.id)

        try await waitUntil(timeoutSeconds: 8.0) {
            store.runs(for: project.id).contains(where: { $0.status == .succeeded })
        }

        XCTAssertNil(store.latestRunCompletionSignal)
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
