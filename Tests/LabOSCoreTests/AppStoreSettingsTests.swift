import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreSettingsTests: XCTestCase {
    func testPreferredBackendDefaultsToCodexAppServer() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertEqual(store.preferredBackendEngine, "codex-app-server")
    }

    func testSavingLegacyPiBackendNormalizesToCodexAppServer() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        store.savePreferredBackendEngine("pi")
        XCTAssertEqual(store.preferredBackendEngine, "codex-app-server")
    }

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

    func testOpenAIVoiceSettingsPersistModelPromptAndApiKeyState() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keyStore = InMemoryOpenAIAPIKeyStore()
        let store = AppStore(
            bootstrapDemo: false,
            userDefaults: defaults,
            openAIAPIKeyStore: keyStore
        )

        XCTAssertFalse(store.openAIAPIKeyConfigured)
        XCTAssertEqual(store.openAIVoiceTranscriptionModel, .gpt4oMiniTranscribe)

        store.saveOpenAIVoiceSettings(
            apiKey: "  sk-test-voice  ",
            transcriptionModel: .gpt4oTranscribe,
            transcriptionPrompt: "  normalize this speech  "
        )

        XCTAssertTrue(store.openAIAPIKeyConfigured)
        XCTAssertEqual(store.openAIVoiceTranscriptionModel, .gpt4oTranscribe)
        XCTAssertEqual(store.openAIVoiceTranscriptionPrompt, "normalize this speech")
        XCTAssertEqual(keyStore.apiKey, "sk-test-voice")

        let store2 = AppStore(
            bootstrapDemo: false,
            userDefaults: defaults,
            openAIAPIKeyStore: keyStore
        )
        XCTAssertTrue(store2.openAIAPIKeyConfigured)
        XCTAssertEqual(store2.openAIVoiceTranscriptionModel, .gpt4oTranscribe)
        XCTAssertEqual(store2.openAIVoiceTranscriptionPrompt, "normalize this speech")
    }

    func testSavingOpenAIVoiceSettingsWithEmptyApiKeyPreservesExistingKey() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keyStore = InMemoryOpenAIAPIKeyStore()
        let store = AppStore(
            bootstrapDemo: false,
            userDefaults: defaults,
            openAIAPIKeyStore: keyStore
        )

        store.saveOpenAIVoiceSettings(
            apiKey: "sk-initial",
            transcriptionModel: .gpt4oMiniTranscribe,
            transcriptionPrompt: "initial prompt"
        )
        store.saveOpenAIVoiceSettings(
            apiKey: "  ",
            transcriptionModel: .gpt4oTranscribe,
            transcriptionPrompt: "updated prompt"
        )

        XCTAssertEqual(keyStore.apiKey, "sk-initial")
        XCTAssertTrue(store.openAIAPIKeyConfigured)
        XCTAssertEqual(store.openAIVoiceTranscriptionModel, .gpt4oTranscribe)
        XCTAssertEqual(store.openAIVoiceTranscriptionPrompt, "updated prompt")
    }

    func testClearOpenAIApiKeyRemovesConfiguredState() {
        let suiteName = "LabOSCoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keyStore = InMemoryOpenAIAPIKeyStore()
        let store = AppStore(
            bootstrapDemo: false,
            userDefaults: defaults,
            openAIAPIKeyStore: keyStore
        )
        store.saveOpenAIVoiceSettings(
            apiKey: "sk-to-clear",
            transcriptionModel: .gpt4oMiniTranscribe,
            transcriptionPrompt: "prompt"
        )
        XCTAssertTrue(store.openAIAPIKeyConfigured)

        store.clearOpenAIAPIKey()

        XCTAssertFalse(store.openAIAPIKeyConfigured)
        XCTAssertNil(keyStore.apiKey)
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

    func testSessionSandboxTypeDangerFullAccessMapsToFullPermissionState() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()

        store.projects = [Project(id: projectID, name: "Sandbox Parse Project")]

        store._receiveGatewayEventForTesting(
            .sessionsUpdated(
                Session(
                    id: sessionID,
                    projectID: projectID,
                    title: "Sandbox Parse Session",
                    backendEngine: "codex-app-server",
                    codexThreadId: "thread_sandbox_parse",
                    codexSandbox: .object(["type": .string("dangerFullAccess")])
                ),
                change: "updated"
            )
        )

        XCTAssertEqual(store.permissionLevel(for: sessionID), .full)
        XCTAssertTrue(store.codexFullAccessEnabled(for: sessionID))
    }

    func testSetProjectPermissionLevelSyncsCodexProjectUpdateAndMutatesLocalState() async throws {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let now = "2026-02-25T00:00:00.000Z"

        store.projects = [
            Project(
                id: projectID,
                name: "Project Permission",
                backendEngine: "codex-app-server",
                codexApprovalPolicy: "on-request",
                codexSandbox: .object(["mode": .string("workspace-write")])
            ),
        ]
        store.codexConnectionState = .connected

        var capturedMethod: String?
        var capturedParams: JSONValue?
        store.codexRequestOverrideForTests = { method, params in
            capturedMethod = method
            capturedParams = params
            return CodexRPCResponse(
                id: .string("project_update"),
                result: .object([
                    "project": .object([
                        "id": .string(projectID.uuidString.lowercased()),
                        "name": .string("Project Permission"),
                        "createdAt": .string(now),
                        "updatedAt": .string(now),
                        "backendEngine": .string("codex-app-server"),
                        "codexModelProvider": .string("openai"),
                        "codexModel": .string("gpt-5.3-codex"),
                        "codexApprovalPolicy": .string("on-request"),
                        "codexSandbox": .object(["mode": .string("danger-full-access")]),
                        "hpcWorkspacePath": .null,
                        "hpcWorkspaceState": .string("queued"),
                    ]),
                ]),
                error: nil
            )
        }

        store.setProjectPermissionLevel(projectID: projectID, level: .full)

        try await waitUntil(timeoutSeconds: 1.0) {
            capturedMethod == "labos/project/update"
        }

        XCTAssertEqual(
            capturedParams,
            .object([
                "projectId": .string(projectID.uuidString.lowercased()),
                "codexApprovalPolicy": .string("on-request"),
                "codexSandbox": .object(["mode": .string("danger-full-access")]),
            ])
        )
        XCTAssertEqual(store.projectPermissionLevel(for: projectID), .full)
    }

    func testNormalizeGatewayErrorMessageFormatsMissingWorkspaceRootError() {
        let store = AppStore(bootstrapDemo: false)
        let technicalDetail = "CAPABILITY_MISSING: node workspaceRoot is unavailable"
        let formatted = store.normalizeGatewayErrorMessage(
            NSError(
                domain: "LabOS",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: technicalDetail]
            )
        )
        XCTAssertEqual(
            formatted,
            """
            HPC workspace is not available yet. Ensure HPC Bridge is connected, then retry.

            Technical detail: \(technicalDetail)
            """
        )
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

private final class InMemoryOpenAIAPIKeyStore: OpenAIAPIKeyStoring {
    var apiKey: String?

    func loadAPIKey() -> String? {
        apiKey
    }

    @discardableResult
    func saveAPIKey(_ apiKey: String) -> Bool {
        self.apiKey = apiKey
        return true
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        apiKey = nil
        return true
    }
}
