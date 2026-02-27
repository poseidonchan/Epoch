import Foundation

@MainActor
internal final class ComposerService {
    private unowned let store: AppStore

    // Private state migrated from AppStore
    private var attachmentPayloadsBySessionMessageID: [UUID: [UUID: [ComposerAttachment]]] = [:]
    private var pendingPermissionSyncTaskBySession: [UUID: Task<Void, Never>] = [:]
    private var permissionSyncGenerationBySession: [UUID: Int] = [:]
    private var pendingOpenAIHubSync: (apiKey: String?, clear: Bool, ocrModel: String?, setOcrModel: Bool)?

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Initialization helpers

    func loadHpcSettings() {
        store.hpcPartition = store.defaults.string(forKey: AppStore.DefaultsKey.hpcPartition) ?? ""
        store.hpcAccount = store.defaults.string(forKey: AppStore.DefaultsKey.hpcAccount) ?? ""
        store.hpcQos = store.defaults.string(forKey: AppStore.DefaultsKey.hpcQos) ?? ""
    }

    func loadNotificationSettings() {
        if store.defaults.object(forKey: AppStore.DefaultsKey.runCompletionNotificationsEnabled) == nil {
            store.runCompletionNotificationsEnabled = true
            return
        }
        store.runCompletionNotificationsEnabled = store.defaults.bool(
            forKey: AppStore.DefaultsKey.runCompletionNotificationsEnabled
        )
    }

    // MARK: - Notification prefs

    func setRunCompletionNotificationsEnabled(_ enabled: Bool) {
        store.runCompletionNotificationsEnabled = enabled
        store.defaults.set(enabled, forKey: AppStore.DefaultsKey.runCompletionNotificationsEnabled)
    }

    // MARK: - HPC settings

    func saveHpcSettings(partition: String, account: String, qos: String) {
        let partitionValue = partition.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountValue = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let qosValue = qos.trimmingCharacters(in: .whitespacesAndNewlines)
        store.hpcPartition = partitionValue
        store.hpcAccount = accountValue
        store.hpcQos = qosValue
        store.defaults.set(partitionValue, forKey: AppStore.DefaultsKey.hpcPartition)
        store.defaults.set(accountValue, forKey: AppStore.DefaultsKey.hpcAccount)
        store.defaults.set(qosValue, forKey: AppStore.DefaultsKey.hpcQos)
    }

    func pushHpcPreferencesToGateway() {
        guard store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return }
        struct Params: Codable, Sendable {
            var partition: String?
            var account: String?
            var qos: String?
        }
        Task {
            _ = try? await gatewayClient.request(
                method: "hpc.prefs.set",
                params: Params(
                    partition: store.normalizedOptionalString(store.hpcPartition),
                    account: store.normalizedOptionalString(store.hpcAccount),
                    qos: store.normalizedOptionalString(store.hpcQos)
                )
            )
        }
    }

    func refreshOpenAISettingsFromGateway() {
        guard store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return }
        struct EmptyParams: Codable, Sendable {}
        Task {
            do {
                let response = try await gatewayClient.request(method: "settings.openai.get", params: EmptyParams())
                let status: OpenAIHubSettingsStatus = try store.decodeGatewayPayloadObject(response.payload)
                store.openAIHubSettingsStatus = status
                if let ocrModel = status.ocrModel?.trimmingCharacters(in: .whitespacesAndNewlines), !ocrModel.isEmpty {
                    store.openAIOcrModel = ocrModel
                    store.defaults.set(ocrModel, forKey: AppStore.DefaultsKey.openAIOcrModel)
                }
                store.lastGatewayErrorMessage = nil
                await flushPendingOpenAIHubSyncIfNeeded()
            } catch {
                store.lastGatewayErrorMessage = error.localizedDescription
            }
        }
    }

    func syncOpenAISettingsToGateway(apiKey: String?, clear: Bool, ocrModel: String? = nil, setOcrModel: Bool = false) {
        pendingOpenAIHubSync = (apiKey: apiKey, clear: clear, ocrModel: ocrModel, setOcrModel: setOcrModel)
        Task {
            await flushPendingOpenAIHubSyncIfNeeded()
        }
    }

    @MainActor
    private func flushPendingOpenAIHubSyncIfNeeded() async {
        guard let pending = pendingOpenAIHubSync else { return }
        guard store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return }

        struct Params: Encodable, Sendable {
            var apiKey: String?
            var clear: Bool?
            var source: String
            var ocrModel: String?
            var setOcrModel: Bool

            enum CodingKeys: String, CodingKey {
                case apiKey
                case clear
                case source
                case ocrModel
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let apiKey {
                    try container.encode(apiKey, forKey: .apiKey)
                }
                if let clear {
                    try container.encode(clear, forKey: .clear)
                }
                try container.encode(source, forKey: .source)
                if setOcrModel {
                    if let ocrModel {
                        try container.encode(ocrModel, forKey: .ocrModel)
                    } else {
                        try container.encodeNil(forKey: .ocrModel)
                    }
                }
            }
        }

        do {
            let response = try await gatewayClient.request(
                method: "settings.openai.set",
                params: Params(
                    apiKey: pending.apiKey,
                    clear: pending.clear ? true : nil,
                    source: "labos-ios",
                    ocrModel: pending.ocrModel,
                    setOcrModel: pending.setOcrModel
                )
            )
            let status: OpenAIHubSettingsStatus = try store.decodeGatewayPayloadObject(response.payload)
            store.openAIHubSettingsStatus = status
            if let ocrModel = status.ocrModel?.trimmingCharacters(in: .whitespacesAndNewlines), !ocrModel.isEmpty {
                store.openAIOcrModel = ocrModel
                store.defaults.set(ocrModel, forKey: AppStore.DefaultsKey.openAIOcrModel)
            }
            pendingOpenAIHubSync = nil
            store.lastGatewayErrorMessage = nil
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Model refresh

    func refreshModelsFromGateway() async {
        guard let gatewayClient = store.gatewayClient else { return }
        struct EmptyParams: Codable, Sendable {}
        do {
            let res = try await gatewayClient.request(method: "models.current", params: EmptyParams())
            let models: ModelsCurrentResponse = try store.decodeGatewayPayloadObject(res.payload)
            store.activeProvider = models.provider
            store.availableModels = models.models
            store.defaultModelId = models.defaultModelId.isEmpty ? nil : models.defaultModelId
            store.availableThinkingLevels = models.thinkingLevels
        } catch {
            store.activeProvider = nil
            store.availableModels = []
            store.defaultModelId = nil
            store.availableThinkingLevels = []
        }
    }

    // MARK: - Model/thinking level preferences

    func selectedModelId(for sessionID: UUID) -> String {
        store.selectedModelIdBySession[sessionID] ?? store.defaultModelId ?? store.availableModels.first?.id ?? ""
    }

    func setSelectedModelId(for sessionID: UUID, modelId: String) {
        store.selectedModelIdBySession[sessionID] = modelId
        normalizeThinkingPrefs(sessionID: sessionID)
    }

    func selectedModelInfo(for sessionID: UUID) -> GatewayModelInfo? {
        let id = selectedModelId(for: sessionID)
        return store.availableModels.first(where: { $0.id == id })
    }

    func selectedThinkingLevel(for sessionID: UUID) -> ThinkingLevel? {
        store.selectedThinkingLevelBySession[sessionID]
    }

    func setSelectedThinkingLevel(for sessionID: UUID, level: ThinkingLevel?) {
        guard selectedModelInfo(for: sessionID)?.reasoning == true else {
            store.selectedThinkingLevelBySession[sessionID] = nil
            return
        }
        if let level {
            store.selectedThinkingLevelBySession[sessionID] = level
        } else {
            store.selectedThinkingLevelBySession[sessionID] = nil
        }
    }

    func contextRemainingFraction(for sessionID: UUID) -> Double? {
        guard let total = store.sessionContextBySession[sessionID]?.contextWindowTokens,
              let remaining = store.sessionContextBySession[sessionID]?.remainingTokens,
              total > 0
        else { return nil }
        return min(max(Double(remaining) / Double(total), 0), 1)
    }

    func contextWindowTokens(for sessionID: UUID) -> Int? {
        store.sessionContextBySession[sessionID]?.contextWindowTokens
    }

    func ensureComposerPrefs(sessionID: UUID) {
        if store.planModeEnabledBySession[sessionID] == nil {
            store.planModeEnabledBySession[sessionID] = false
        }
        if store.permissionLevelBySession[sessionID] == nil {
            store.permissionLevelBySession[sessionID] = .default
        }
        if store.selectedModelIdBySession[sessionID] == nil {
            if let modelId = store.defaultModelId ?? store.availableModels.first?.id {
                if !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.selectedModelIdBySession[sessionID] = modelId
                }
            }
        }
        normalizeThinkingPrefs(sessionID: sessionID)
    }

    private func normalizeThinkingPrefs(sessionID: UUID) {
        let modelId = store.selectedModelIdBySession[sessionID]
            ?? store.defaultModelId
            ?? store.availableModels.first?.id
        let supportsReasoning = modelId.flatMap { id in
            store.availableModels.first(where: { $0.id == id })?.reasoning
        } ?? false

        guard supportsReasoning else {
            store.selectedThinkingLevelBySession[sessionID] = nil
            return
        }

        if store.selectedThinkingLevelBySession[sessionID] == nil {
            store.selectedThinkingLevelBySession[sessionID] = store.availableThinkingLevels.first ?? .medium
        }

        if let selected = store.selectedThinkingLevelBySession[sessionID],
           !store.availableThinkingLevels.isEmpty,
           !store.availableThinkingLevels.contains(selected) {
            store.selectedThinkingLevelBySession[sessionID] = store.availableThinkingLevels.first ?? .medium
        }
    }

    // MARK: - Permission level

    func permissionLevel(for sessionID: UUID) -> SessionPermissionLevel {
        store.permissionLevelBySession[sessionID] ?? .default
    }

    func setPermissionLevel(projectID: UUID, sessionID: UUID, level: SessionPermissionLevel) {
        store.permissionLevelBySession[sessionID] = level
        store.codexFullAccessBySession[sessionID] = (level == .full)
        store.projectService.applyProjectPermissionLevelLocally(projectID: projectID, level: level)

        let generation = (permissionSyncGenerationBySession[sessionID] ?? 0) + 1
        permissionSyncGenerationBySession[sessionID] = generation
        let previousTask = pendingPermissionSyncTaskBySession[sessionID]
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.permissionSyncGenerationBySession[sessionID] == generation {
                    self.pendingPermissionSyncTaskBySession[sessionID] = nil
                }
            }
            if let previousTask {
                _ = await previousTask.result
            }
            guard !Task.isCancelled else { return }
            await self.syncPermissionRemotely(projectID: projectID, sessionID: sessionID, level: level)
        }
        pendingPermissionSyncTaskBySession[sessionID] = task
    }

    func handleSessionPermissionUpdated(_ payload: SessionPermissionUpdatedPayload) {
        if let level = AppStore.parsePermissionLevel(payload.level) {
            store.permissionLevelBySession[payload.sessionId] = level
            store.codexFullAccessBySession[payload.sessionId] = (level == .full)
        }
    }

    func awaitPendingPermissionSync(sessionID: UUID) async {
        guard let task = pendingPermissionSyncTaskBySession[sessionID] else { return }
        _ = await task.result
    }

    func clearPendingPermissionSync(sessionID: UUID) {
        pendingPermissionSyncTaskBySession[sessionID]?.cancel()
        pendingPermissionSyncTaskBySession[sessionID] = nil
        permissionSyncGenerationBySession[sessionID] = nil
    }

    private func syncPermissionRemotely(projectID: UUID, sessionID: UUID, level: SessionPermissionLevel) async {
        await syncSessionPermissionRemotely(projectID: projectID, sessionID: sessionID, level: level)
        await syncSessionPermissionEventRemotely(projectID: projectID, sessionID: sessionID, level: level)
        await store.projectService.syncProjectPermissionLevelRemotely(projectID: projectID, level: level)
    }

    private func syncSessionPermissionRemotely(projectID: UUID, sessionID: UUID, level: SessionPermissionLevel) async {
        let codexSandbox = AppStore.codexSandbox(for: level)
        let codexApprovalPolicy = AppStore.codexApprovalPolicyForPermissionChange

        if store.shouldUseCodexRPC {
            struct Params: Codable, Sendable {
                var projectId: String
                var sessionId: String
                var codexApprovalPolicy: String
                var codexSandbox: JSONValue
            }
            do {
                let response = try await store.requestCodex(
                    method: "labos/session/update",
                    params: Params(
                        projectId: AppStore.gatewayID(projectID),
                        sessionId: AppStore.gatewayID(sessionID),
                        codexApprovalPolicy: codexApprovalPolicy,
                        codexSandbox: codexSandbox
                    )
                )
                if let session: Session = try? store.decodeCodexResult(response.result, key: "session") {
                    applyUpdatedSessionFromPermissionSync(session)
                }
                store.lastGatewayErrorMessage = nil
                return
            } catch {
                store.lastGatewayErrorMessage = error.localizedDescription
            }
        }

        guard store.isGatewayConfigured else { return }
        let connected = await store.ensureGatewayConnectedForChat()
        guard connected, store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return }

        struct Params: Codable, Sendable {
            var projectId: String
            var sessionId: String
            var codexApprovalPolicy: String
            var codexSandbox: JSONValue
        }

        do {
            let response = try await gatewayClient.request(
                method: "sessions.update",
                params: Params(
                    projectId: AppStore.gatewayID(projectID),
                    sessionId: AppStore.gatewayID(sessionID),
                    codexApprovalPolicy: codexApprovalPolicy,
                    codexSandbox: codexSandbox
                )
            )
            if let session: Session = try? store.decodeGatewayPayload(response.payload, key: "session") {
                applyUpdatedSessionFromPermissionSync(session)
            }
            store.lastGatewayErrorMessage = nil
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
        }
    }

    private func syncSessionPermissionEventRemotely(projectID: UUID, sessionID: UUID, level: SessionPermissionLevel) async {
        guard store.isGatewayConfigured else { return }
        let connected = await store.ensureGatewayConnectedForChat()
        guard connected, store.isGatewayConnected, let gatewayClient = store.gatewayClient else { return }

        struct Params: Codable, Sendable {
            var projectId: String
            var sessionId: String
            var level: SessionPermissionLevel
        }

        do {
            _ = try await gatewayClient.request(
                method: "sessions.permission.set",
                params: Params(
                    projectId: AppStore.gatewayID(projectID),
                    sessionId: AppStore.gatewayID(sessionID),
                    level: level
                )
            )
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
        }
    }

    private func applyUpdatedSessionFromPermissionSync(_ session: Session) {
        store.projectService.upsertSession(session)

        let previousThreadId = store.codexThreadBySession[session.id]
        if let rawThreadId = session.codexThreadId,
           let threadId = store.normalizedOptionalString(rawThreadId),
           !threadId.isEmpty {
            if let previousThreadId, previousThreadId != threadId {
                store.codexSessionByThread[previousThreadId] = nil
            }
            store.codexThreadBySession[session.id] = threadId
            store.codexSessionByThread[threadId] = session.id
            store.codexPendingThreadBindingSessions.remove(session.id)
        } else {
            store.codexThreadBySession[session.id] = nil
            if let previousThreadId {
                store.codexSessionByThread[previousThreadId] = nil
            }
        }

        let level = AppStore.permissionLevel(forCodexSandbox: session.codexSandbox) ?? .default
        store.permissionLevelBySession[session.id] = level
        store.codexFullAccessBySession[session.id] = (level == .full)
    }

    // MARK: - Plan mode

    func planModeEnabled(for sessionID: UUID) -> Bool {
        store.planModeEnabledBySession[sessionID] ?? false
    }

    func setPlanModeEnabled(for sessionID: UUID, enabled: Bool) {
        store.planModeEnabledBySession[sessionID] = enabled
    }

    // MARK: - Pending composer attachments

    func pendingComposerAttachments(for sessionID: UUID) -> [ComposerAttachment] {
        store.pendingComposerAttachmentsBySession[sessionID] ?? []
    }

    func addPendingComposerAttachments(sessionID: UUID, attachments: [ComposerAttachment]) {
        let cleaned = attachments.filter {
            !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !cleaned.isEmpty else { return }
        var existing = store.pendingComposerAttachmentsBySession[sessionID] ?? []
        existing.append(contentsOf: cleaned)
        store.pendingComposerAttachmentsBySession[sessionID] = existing
    }

    func removePendingComposerAttachment(sessionID: UUID, attachmentID: UUID) {
        guard var existing = store.pendingComposerAttachmentsBySession[sessionID] else { return }
        existing.removeAll { $0.id == attachmentID }
        store.pendingComposerAttachmentsBySession[sessionID] = existing.isEmpty ? nil : existing
    }

    func clearPendingComposerAttachments(sessionID: UUID) {
        store.pendingComposerAttachmentsBySession[sessionID] = nil
    }

    // MARK: - Attachment payloads (used by ChatSessionService)

    func attachmentPayload(for sessionID: UUID, messageID: UUID) -> [ComposerAttachment] {
        attachmentPayloadsBySessionMessageID[sessionID]?[messageID] ?? []
    }

    func setAttachmentPayload(for sessionID: UUID, messageID: UUID, attachments: [ComposerAttachment]) {
        var byMessage = attachmentPayloadsBySessionMessageID[sessionID] ?? [:]
        if attachments.isEmpty {
            byMessage[messageID] = nil
        } else {
            byMessage[messageID] = attachments
        }
        attachmentPayloadsBySessionMessageID[sessionID] = byMessage.isEmpty ? nil : byMessage
    }

    func pruneAttachmentPayloads(for sessionID: UUID, keptMessageIDs: Set<UUID>) {
        guard var byMessage = attachmentPayloadsBySessionMessageID[sessionID] else { return }
        byMessage = byMessage.filter { keptMessageIDs.contains($0.key) }
        attachmentPayloadsBySessionMessageID[sessionID] = byMessage.isEmpty ? nil : byMessage
    }

    func attachmentsFromArtifactRefs(_ refs: [ChatArtifactReference]) -> [ComposerAttachment] {
        refs.compactMap { ref in
            let scope = (ref.scope ?? "session").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard scope.isEmpty || scope == "session" else { return nil }
            let displayName = (ref.sourceName ?? ref.displayText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else { return nil }
            return ComposerAttachment(
                id: ref.artifactID ?? UUID(),
                displayName: displayName,
                mimeType: ref.mimeType,
                inlineDataBase64: ref.inlineDataBase64,
                byteCount: ref.byteCount
            )
        }
    }

    // MARK: - Session attachment references

    func makeSessionAttachmentReferences(
        projectID: UUID,
        sessionID: UUID,
        attachments: [ComposerAttachment]
    ) -> [ChatArtifactReference] {
        attachments.map { attachment in
            let safeName = Self.sanitizeAttachmentPathComponent(attachment.displayName)
            return ChatArtifactReference(
                displayText: attachment.displayName,
                projectID: projectID,
                path: "session_attachments/\(sessionID.uuidString)/\(safeName)",
                artifactID: attachment.id,
                scope: "session",
                mimeType: attachment.mimeType,
                sourceName: attachment.displayName,
                inlineDataBase64: attachment.inlineDataBase64,
                byteCount: attachment.byteCount
            )
        }
    }

    private static func sanitizeAttachmentPathComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "attachment" }
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return cleaned.isEmpty ? "attachment" : cleaned
    }
}
