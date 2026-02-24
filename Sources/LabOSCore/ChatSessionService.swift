import Combine
import Foundation

@MainActor
internal final class ChatSessionService {
    private unowned let store: AppStore

    // MARK: - Private Types

    private struct PendingLocalUserEcho: Sendable {
        var localId: UUID
        var text: String
        var createdAt: Date
        var artifactRefs: [ChatArtifactReference]
        var attachments: [ComposerAttachment]
    }

    private struct GatewayChatSendParams: Codable, Sendable {
        var projectId: String
        var sessionId: String
        var text: String
        var overwriteMessageId: String?
        var attachments: [GatewayChatAttachment]?
        var modelId: String?
        var thinkingLevel: ThinkingLevel?
        var planMode: Bool
        var permissionLevel: SessionPermissionLevel
    }

    private struct GatewayChatAttachment: Codable, Sendable {
        var id: String
        var scope: String
        var name: String
        var path: String
        var mimeType: String?
        var inlineDataBase64: String?
        var byteCount: Int?
    }

    private struct CodexTurnStartParams: Codable, Sendable {
        var threadId: String
        var input: [CodexTurnInputPart]
        var model: String?
    }

    private struct CodexThreadReadParams: Codable, Sendable {
        var threadId: String
        var includeTurns: Bool
    }

    private struct CodexThreadRollbackParams: Codable, Sendable {
        var threadId: String
        var numTurns: Int
    }

    private struct CodexSessionReadParams: Codable, Sendable {
        var projectId: String
        var sessionId: String
        var includeTurns: Bool
    }

    private struct CodexTurnInputPart: Codable, Sendable {
        var type: String
        var text: String?
        var url: String?
        var path: String?
    }

    struct CodexRegeneratePlan: Sendable {
        var sourceInput: [CodexUserInput]
        var numTurnsToRollback: Int
    }

    // MARK: - Session History State

    private var pendingLocalUserEchosBySession: [UUID: [PendingLocalUserEcho]] = [:]
    var sessionHistoryRequestsInFlight: Set<UUID> = []
    var sessionHistoryLastFetchedAtBySession: [UUID: Date] = [:]
    var sessionHistoryPrefetchTasksByProject: [UUID: Task<Void, Never>] = [:]
    private let sessionHistoryPrefetchCooldown: TimeInterval = 45
    private let sessionHistoryInteractiveFreshnessWindow: TimeInterval = 8

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Session Cleanup

    func clearSession(sessionID: UUID) {
        store.messagesBySession[sessionID] = nil
        store.streamingSessions.remove(sessionID)
        store.streamingAssistantMessageIDBySession[sessionID] = nil
        store.sessionContextBySession[sessionID] = nil
        store.liveAgentEventsBySession[sessionID] = nil
        store.activeInlineProcessBySession[sessionID] = nil
        store.planModeEnabledBySession[sessionID] = nil
        store.selectedModelIdBySession[sessionID] = nil
        store.selectedThinkingLevelBySession[sessionID] = nil
        store.permissionLevelBySession[sessionID] = nil
        store.livePlanBySession[sessionID] = nil
        pendingLocalUserEchosBySession[sessionID] = nil
        sessionHistoryLastFetchedAtBySession[sessionID] = nil
    }

    // MARK: - Message Accessors

    func messages(for sessionID: UUID) -> [ChatMessage] {
        (store.messagesBySession[sessionID] ?? []).sorted(by: AppStore.messageDisplayOrder)
    }

    func liveAgentEvents(for sessionID: UUID) -> [AgentLiveEvent] {
        (store.liveAgentEventsBySession[sessionID] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func activeInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        store.activeInlineProcessBySession[sessionID]
    }

    func pendingInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        guard let process = store.activeInlineProcessBySession[sessionID],
              process.assistantMessageID == nil
        else { return nil }
        return process
    }

    func activeInlineProcess(for sessionID: UUID, assistantMessageID: UUID) -> ActiveInlineProcess? {
        guard let process = store.activeInlineProcessBySession[sessionID],
              process.assistantMessageID == assistantMessageID
        else { return nil }
        return process
    }

    func persistedProcessSummary(for assistantMessageID: UUID) -> AssistantProcessSummary? {
        store.persistedProcessSummaryByMessageID[assistantMessageID]
    }

    // MARK: - Send / Retry

    func sendMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachments: [ComposerAttachment]? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let effectiveAttachments = attachments ?? store.composerService.pendingComposerAttachments(for: sessionID)
        let hasAttachments = !effectiveAttachments.isEmpty

        guard hasText || hasAttachments else { return }
        if !store.sessionUsesCodex(sessionID: sessionID), !hasText {
            store.lastGatewayErrorMessage = "Text is required for the current backend."
            return
        }

        let attachmentRefs = store.composerService.makeSessionAttachmentReferences(
            projectID: projectID,
            sessionID: sessionID,
            attachments: effectiveAttachments
        )

        beginInlineProcess(sessionID: sessionID, runID: UUID())
        clearLiveAgentEvents(sessionID: sessionID)

        if store.sessionUsesCodex(sessionID: sessionID) {
            sendCodexTurnMessage(
                projectID: projectID,
                sessionID: sessionID,
                text: trimmed,
                attachments: effectiveAttachments
            )
            store.clearPendingComposerAttachments(sessionID: sessionID)
            return
        }

        if store.isGatewayConfigured {
            let localUserMessage = ChatMessage(sessionID: sessionID, role: .user, text: trimmed, artifactRefs: attachmentRefs)
            store.messagesBySession[sessionID, default: []].append(localUserMessage)
            pendingLocalUserEchosBySession[sessionID, default: []].append(
                PendingLocalUserEcho(
                    localId: localUserMessage.id,
                    text: trimmed,
                    createdAt: localUserMessage.createdAt,
                    artifactRefs: attachmentRefs,
                    attachments: effectiveAttachments
                )
            )
            store.composerService.setAttachmentPayload(
                for: sessionID,
                messageID: localUserMessage.id,
                attachments: effectiveAttachments
            )
            sendGatewayChatMessage(
                projectID: projectID,
                sessionID: sessionID,
                text: trimmed,
                attachmentRefs: attachmentRefs,
                attachments: effectiveAttachments
            )
            store.clearPendingComposerAttachments(sessionID: sessionID)
            return
        }

        let userMessage = ChatMessage(sessionID: sessionID, role: .user, text: trimmed, artifactRefs: attachmentRefs)
        store.messagesBySession[sessionID, default: []].append(userMessage)
        store.composerService.setAttachmentPayload(
            for: sessionID,
            messageID: userMessage.id,
            attachments: effectiveAttachments
        )
        store.clearPendingComposerAttachments(sessionID: sessionID)

        let existingArtifacts = store.artifactsByProject[projectID] ?? []

        Task { [weak self] in
            guard let self else { return }
            let response = await self.store.backend.generateAssistantResponse(
                projectID: projectID,
                sessionID: sessionID,
                userText: trimmed,
                existingArtifacts: existingArtifacts
            )
            self.applyAssistantResponse(projectID: projectID, sessionID: sessionID, response: response)
        }
    }

    private func sendCodexTurnMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachments: [ComposerAttachment]
    ) {
        store.streamingSessions.insert(sessionID)
        store.codexStatusTextBySession[sessionID] = "connecting"

        Task { [weak self] in
            guard let self else { return }
            let codexReady = await self.store.ensureCodexConnectedForChat()
            guard codexReady else {
                self.store.lastGatewayErrorMessage = "Codex backend is selected, but /codex is not connected."
                self.store.codexStatusTextBySession[sessionID] = "failed"
                self.store.streamingSessions.remove(sessionID)
                return
            }

            guard let threadId = await self.resolveCodexThreadId(projectID: projectID, sessionID: sessionID) else {
                self.store.lastGatewayErrorMessage = "Session is missing codex thread mapping."
                self.store.codexStatusTextBySession[sessionID] = "failed"
                self.store.streamingSessions.remove(sessionID)
                return
            }

            self.store.codexThreadBySession[sessionID] = threadId
            self.store.codexSessionByThread[threadId] = sessionID

            let input = await self.makeCodexInputParts(text: text, attachments: attachments)
            guard !input.isEmpty else {
                self.store.lastGatewayErrorMessage = "No Codex-compatible input was provided."
                self.store.codexStatusTextBySession[sessionID] = "failed"
                self.store.streamingSessions.remove(sessionID)
                return
            }
            let model = self.store.selectedModelId(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let response = try await self.store.requestCodex(
                    method: "turn/start",
                    params: CodexTurnStartParams(
                        threadId: threadId,
                        input: input,
                        model: model.isEmpty ? nil : model
                    )
                )
                if let payload = response.result?.objectValue {
                    if let returnedThreadId = payload["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !returnedThreadId.isEmpty {
                        let previousThreadId = self.store.codexThreadBySession[sessionID]
                        if let previousThreadId, previousThreadId != returnedThreadId {
                            self.store.codexSessionByThread[previousThreadId] = nil
                        }
                        self.store.codexThreadBySession[sessionID] = returnedThreadId
                        self.store.codexSessionByThread[returnedThreadId] = sessionID
                    }
                    if let turn = payload["turn"]?.objectValue,
                       let status = turn["status"]?.stringValue {
                        self.store.codexStatusTextBySession[sessionID] = status
                    }
                }
            } catch {
                self.store.lastGatewayErrorMessage = error.localizedDescription
                self.store.codexStatusTextBySession[sessionID] = "failed"
                self.store.streamingSessions.remove(sessionID)
            }
        }
    }

    private func resolveCodexThreadId(projectID: UUID, sessionID: UUID) async -> String? {
        if let mapped = store.codexThreadBySession[sessionID], !mapped.isEmpty {
            return mapped
        }
        if let thread = store.sessions(for: projectID).first(where: { $0.id == sessionID })?.codexThreadId,
           !thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return thread
        }

        do {
            let response = try await store.requestCodex(
                method: "labos/session/read",
                params: CodexSessionReadParams(
                    projectId: AppStore.gatewayID(projectID),
                    sessionId: AppStore.gatewayID(sessionID),
                    includeTurns: false
                )
            )
            var session: Session = try store.decodeCodexResult(response.result, key: "session")
            if session.codexThreadId == nil,
               let resultObject = response.result?.objectValue,
               let threadObject = resultObject["thread"]?.objectValue,
               let threadId = threadObject["id"]?.stringValue,
               !threadId.isEmpty {
                session.codexThreadId = threadId
            }
            store.projectService.upsertSession(session)
            if let thread = session.codexThreadId, !thread.isEmpty {
                store.codexThreadBySession[sessionID] = thread
                store.codexSessionByThread[thread] = sessionID
                return thread
            }
        } catch {
            return nil
        }
        return nil
    }

    private func makeCodexInputParts(text: String, attachments: [ComposerAttachment]) async -> [CodexTurnInputPart] {
        var parts: [CodexTurnInputPart] = []
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            parts.append(CodexTurnInputPart(type: "text", text: trimmedText, url: nil, path: nil))
        }

        for attachment in attachments {
            guard (attachment.mimeType ?? "").lowercased().hasPrefix("image/") else { continue }
            guard let base64 = attachment.inlineDataBase64,
                  let data = Data(base64Encoded: base64),
                  let localPath = stageAttachmentImageLocally(data: data, fileName: attachment.displayName)
            else { continue }
            parts.append(CodexTurnInputPart(type: "localImage", text: nil, url: nil, path: localPath))
        }

        return parts
    }

    private func stageAttachmentImageLocally(data: Data, fileName: String) -> String? {
        let cleaned = fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let ext = URL(fileURLWithPath: cleaned).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: cleaned).pathExtension
        let stem = URL(fileURLWithPath: cleaned).deletingPathExtension().lastPathComponent
        let finalName = "\(stem.isEmpty ? "image" : stem)-\(UUID().uuidString).\(ext)"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("labos-codex-inputs").appendingPathComponent(finalName)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic])
            return destination.path
        } catch {
            return nil
        }
    }

    func overwriteUserMessage(
        projectID: UUID,
        sessionID: UUID,
        messageID: UUID,
        text: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if store.sessionUsesCodex(sessionID: sessionID) {
            sendCodexTurnMessage(projectID: projectID, sessionID: sessionID, text: trimmed, attachments: [])
            return
        }

        var msgs = messages(for: sessionID)
        guard let editIndex = msgs.firstIndex(where: { $0.id == messageID }) else { return }
        guard msgs[editIndex].role == .user else { return }
        let existingArtifactRefs = msgs[editIndex].artifactRefs
        let existingAttachments = store.composerService.attachmentPayload(for: sessionID, messageID: messageID)
        let effectiveAttachments = existingAttachments.isEmpty
            ? store.composerService.attachmentsFromArtifactRefs(existingArtifactRefs)
            : existingAttachments

        msgs[editIndex].text = trimmed
        msgs[editIndex].artifactRefs = existingArtifactRefs
        msgs[editIndex].proposedPlan = nil

        let keptMessages = Array(msgs.prefix(editIndex + 1))
        let keptIDs = Set(keptMessages.map(\.id))
        store.messagesBySession[sessionID] = keptMessages
        store.composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: keptIDs)
        store.composerService.setAttachmentPayload(for: sessionID, messageID: messageID, attachments: effectiveAttachments)
        store.persistedProcessSummaryByMessageID = store.persistedProcessSummaryByMessageID.filter { summary in
            if summary.value.sessionID != sessionID {
                return true
            }
            return keptIDs.contains(summary.key)
        }

        store.planService.pendingApprovalsBySession[sessionID] = nil
        store.livePlanBySession[sessionID] = nil
        store.activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
        for (planID, mappedSessionID) in store.planService.planSessionByPlanID where mappedSessionID == sessionID {
            store.planService.planSessionByPlanID[planID] = nil
        }
        store.streamingSessions.remove(sessionID)
        store.streamingAssistantMessageIDBySession[sessionID] = nil

        var pendingEchos = pendingLocalUserEchosBySession[sessionID] ?? []
        pendingEchos.removeAll { !keptIDs.contains($0.localId) }
        if store.isGatewayConfigured {
            pendingEchos.removeAll { $0.localId == messageID }
            pendingEchos.append(
                PendingLocalUserEcho(
                    localId: messageID,
                    text: trimmed,
                    createdAt: .now,
                    artifactRefs: existingArtifactRefs,
                    attachments: effectiveAttachments
                )
            )
        }
        pendingLocalUserEchosBySession[sessionID] = pendingEchos.isEmpty ? nil : pendingEchos

        if store.isGatewayConfigured {
            sendGatewayChatMessage(
                projectID: projectID,
                sessionID: sessionID,
                text: trimmed,
                attachmentRefs: existingArtifactRefs,
                attachments: effectiveAttachments,
                overwriteMessageID: messageID
            )
            return
        }

        let existingArtifacts = store.artifactsByProject[projectID] ?? []
        Task { [weak self] in
            guard let self else { return }
            let response = await self.store.backend.generateAssistantResponse(
                projectID: projectID,
                sessionID: sessionID,
                userText: trimmed,
                existingArtifacts: existingArtifacts
            )
            self.applyAssistantResponse(projectID: projectID, sessionID: sessionID, response: response)
        }
    }

    func retryMessage(
        projectID: UUID,
        sessionID: UUID,
        fromMessageID messageID: UUID,
        modelIdOverride: String? = nil
    ) {
        if let modelIdOverride {
            let trimmed = modelIdOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                store.setSelectedModelId(for: sessionID, modelId: trimmed)
            }
        }

        guard let source = retrySource(for: messageID, in: sessionID) else { return }
        if let userMessageID = source.userMessageID {
            overwriteUserMessage(
                projectID: projectID,
                sessionID: sessionID,
                messageID: userMessageID,
                text: source.text
            )
            return
        }
        sendMessage(projectID: projectID, sessionID: sessionID, text: source.text)
    }

    func retryCodexAgentMessage(
        projectID: UUID,
        sessionID: UUID,
        assistantItemID: String,
        assistantText: String? = nil,
        modelIdOverride: String? = nil
    ) {
        if let modelIdOverride {
            let trimmed = modelIdOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                store.setSelectedModelId(for: sessionID, modelId: trimmed)
            }
        }

        let normalizedAssistantItemID = assistantItemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAssistantItemID.isEmpty else { return }

        beginInlineProcess(sessionID: sessionID, runID: UUID())
        clearLiveAgentEvents(sessionID: sessionID)
        store.streamingSessions.insert(sessionID)
        store.codexStatusTextBySession[sessionID] = "thinking"

        Task { [weak self] in
            guard let self else { return }

            let codexReady = await self.store.ensureCodexConnectedForChat()
            guard codexReady else {
                self.store.lastGatewayErrorMessage = "Codex backend is selected, but /codex is not connected."
                self.store.codexStatusTextBySession[sessionID] = "failed"
                self.store.streamingSessions.remove(sessionID)
                return
            }

            guard let threadId = await self.resolveCodexThreadId(projectID: projectID, sessionID: sessionID) else {
                self.store.lastGatewayErrorMessage = "Session is missing codex thread mapping."
                self.store.codexStatusTextBySession[sessionID] = "failed"
                self.store.streamingSessions.remove(sessionID)
                return
            }

            do {
                let threadResponse = try await self.store.requestCodex(
                    method: "thread/read",
                    params: CodexThreadReadParams(threadId: threadId, includeTurns: true)
                )
                let thread: CodexThread = try self.store.decodeCodexResult(threadResponse.result, key: "thread")

                guard let plan = Self.codexRegeneratePlan(
                    thread: thread,
                    assistantItemID: normalizedAssistantItemID,
                    assistantText: assistantText
                ) else {
                    self.store.lastGatewayErrorMessage = "Unable to regenerate from the selected message."
                    self.store.codexStatusTextBySession[sessionID] = "failed"
                    self.store.streamingSessions.remove(sessionID)
                    return
                }

                let rollbackResponse = try await self.store.requestCodex(
                    method: "thread/rollback",
                    params: CodexThreadRollbackParams(
                        threadId: thread.id,
                        numTurns: plan.numTurnsToRollback
                    )
                )
                let rolledThread: CodexThread = try self.store.decodeCodexResult(rollbackResponse.result, key: "thread")

                if thread.id != rolledThread.id {
                    self.store.codexSessionByThread[thread.id] = nil
                }
                self.store.codexThreadBySession[sessionID] = rolledThread.id
                self.store.codexSessionByThread[rolledThread.id] = sessionID
                self.store.codexItemsBySession[sessionID] = Self.flattenCodexTurns(rolledThread.turns)
                self.store.codexPendingApprovalsBySession[sessionID] = []
                self.store.codexPendingPromptBySession[sessionID] = nil

                let turnInput = Self.codexTurnInputParts(from: plan.sourceInput)
                guard !turnInput.isEmpty else {
                    self.store.lastGatewayErrorMessage = "Regenerate source input was empty."
                    self.store.codexStatusTextBySession[sessionID] = "failed"
                    self.store.streamingSessions.remove(sessionID)
                    return
                }

                let model = self.store.selectedModelId(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
                let response = try await self.store.requestCodex(
                    method: "turn/start",
                    params: CodexTurnStartParams(
                        threadId: rolledThread.id,
                        input: turnInput,
                        model: model.isEmpty ? nil : model
                    )
                )
                if let payload = response.result?.objectValue {
                    if let returnedThreadId = payload["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !returnedThreadId.isEmpty {
                        let previousThreadId = self.store.codexThreadBySession[sessionID]
                        if let previousThreadId, previousThreadId != returnedThreadId {
                            self.store.codexSessionByThread[previousThreadId] = nil
                        }
                        self.store.codexThreadBySession[sessionID] = returnedThreadId
                        self.store.codexSessionByThread[returnedThreadId] = sessionID
                    }
                    if let turn = payload["turn"]?.objectValue,
                       let status = turn["status"]?.stringValue {
                        self.store.codexStatusTextBySession[sessionID] = status
                    }
                }
            } catch {
                self.store.lastGatewayErrorMessage = error.localizedDescription
                self.store.codexStatusTextBySession[sessionID] = "failed"
                self.store.streamingSessions.remove(sessionID)
            }
        }
    }

    func retrySourceText(for messageID: UUID, in sessionID: UUID) -> String? {
        retrySource(for: messageID, in: sessionID)?.text
    }

    @discardableResult
    func branchFromMessage(
        projectID: UUID,
        sessionID: UUID,
        fromMessageID messageID: UUID,
        modelIdOverride: String? = nil
    ) async -> Session? {
        guard let text = retrySourceText(for: messageID, in: sessionID) else { return nil }

        let sourceTitle = store.sessions(for: projectID).first(where: { $0.id == sessionID })?.title
        let branchTitle = sourceTitle.map { "\($0) (Branch)" }

        guard let branched = await store.createSession(projectID: projectID, title: branchTitle) else { return nil }

        let selectedModel = store.selectedModelId(for: sessionID)
        let selectedThinking = store.selectedThinkingLevel(for: sessionID)
        let selectedPlanMode = store.planModeEnabled(for: sessionID)
        let selectedPermission = store.permissionLevel(for: sessionID)

        if let modelIdOverride {
            let trimmed = modelIdOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                store.setSelectedModelId(for: branched.id, modelId: trimmed)
            } else if !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.setSelectedModelId(for: branched.id, modelId: selectedModel)
            }
        } else if !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.setSelectedModelId(for: branched.id, modelId: selectedModel)
        }

        store.setSelectedThinkingLevel(for: branched.id, level: selectedThinking)
        store.setPlanModeEnabled(for: branched.id, enabled: selectedPlanMode)
        store.setPermissionLevel(projectID: branched.projectID, sessionID: branched.id, level: selectedPermission)

        sendMessage(projectID: branched.projectID, sessionID: branched.id, text: text)
        return branched
    }

    // MARK: - Gateway Event Handlers

    func applyRemoteMessage(sessionID: UUID, message: ChatMessage) {
        var msgs = store.messagesBySession[sessionID, default: []]
        var resolvedMessage = message

        if resolvedMessage.role == .user {
            let normalized = resolvedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, var pending = pendingLocalUserEchosBySession[sessionID] {
                let matchIdx =
                    pending.firstIndex(where: { $0.text == normalized && abs($0.createdAt.timeIntervalSince(resolvedMessage.createdAt)) < 30 })
                    ?? pending.firstIndex(where: { $0.text == normalized })
                if let matchIdx {
                    let pendingEcho = pending[matchIdx]
                    resolvedMessage.artifactRefs = AppStore.mergeArtifactRefsPreservingInlineForGatewayEcho(
                        remoteArtifactRefs: resolvedMessage.artifactRefs,
                        localArtifactRefs: pendingEcho.artifactRefs
                    )
                    let localId = pendingEcho.localId
                    let transferredAttachments = pendingEcho.attachments.isEmpty
                        ? store.composerService.attachmentPayload(for: sessionID, messageID: localId)
                        : pendingEcho.attachments
                    if !transferredAttachments.isEmpty {
                        store.composerService.setAttachmentPayload(
                            for: sessionID,
                            messageID: resolvedMessage.id,
                            attachments: transferredAttachments
                        )
                    }
                    if localId != resolvedMessage.id {
                        store.composerService.setAttachmentPayload(for: sessionID, messageID: localId, attachments: [])
                    }
                    msgs.removeAll { $0.id == localId }
                    pending.remove(at: matchIdx)
                    pendingLocalUserEchosBySession[sessionID] = pending.isEmpty ? nil : pending
                }
            }
        }

        if let idx = msgs.firstIndex(where: { $0.id == resolvedMessage.id }) {
            msgs[idx] = resolvedMessage
        } else {
            msgs.append(resolvedMessage)
        }
        store.messagesBySession[sessionID] = msgs.sorted(by: AppStore.messageDisplayOrder)

        if resolvedMessage.role == .assistant,
           var process = store.activeInlineProcessBySession[sessionID],
           process.assistantMessageID == nil {
            process.assistantMessageID = resolvedMessage.id
            store.activeInlineProcessBySession[sessionID] = process
        }

        if resolvedMessage.role == .assistant {
            store.streamingSessions.remove(sessionID)
            store.streamingAssistantMessageIDBySession[sessionID] = nil
            finalizeInlineProcess(sessionID: sessionID, failed: false, assistantMessageIDFallback: resolvedMessage.id)
            clearLiveAgentEvents(sessionID: sessionID)
        }
    }

    func applyAssistantDelta(_ payload: AssistantDeltaPayload) {
        let sessionID = payload.sessionId
        var msgs = store.messagesBySession[sessionID, default: []]

        store.streamingSessions.insert(sessionID)
        store.streamingAssistantMessageIDBySession[sessionID] = payload.messageId
        transitionInlineProcessToResponding(sessionID: sessionID, messageID: payload.messageId)

        if let idx = msgs.firstIndex(where: { $0.id == payload.messageId }) {
            msgs[idx].text += payload.delta
        } else {
            var msg = ChatMessage(
                id: payload.messageId,
                sessionID: sessionID,
                role: .assistant,
                text: payload.delta,
                createdAt: .now
            )
            msg.proposedPlan = nil
            msgs.append(msg)
        }

        store.messagesBySession[sessionID] = msgs.sorted(by: AppStore.messageDisplayOrder)
    }

    func applyToolEvent(_ payload: ToolEventPayload) {
        let phase = payload.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if shouldIgnoreLateToolEvent(payload: payload, phase: phase) {
            return
        }

        let summary = payload.summary.isEmpty ? "\(payload.tool) · \(payload.phase)" : payload.summary
        let detail = formattedJSONDetail(payload.detail)
        if let runID = payload.runId {
            store.projectService.mutateRun(projectID: payload.projectId, runID: runID) { run in
                run.activity.append(RunActionEvent(type: .toolCall, summary: summary, detail: detail))
            }
        }

        applyInlineToolEvent(payload, fallbackSummary: summary)

        let liveSummary = switch phase {
        case "start":
            "Calling tool: \(payload.tool)"
        case "update":
            "Tool update: \(payload.tool)"
        case "end":
            "Tool finished: \(payload.tool)"
        case "error":
            "Tool failed: \(payload.tool)"
        default:
            "Tool event: \(payload.tool)"
        }

        let liveDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : detail
        appendLiveAgentEvent(
            sessionID: payload.sessionId,
            type: .toolCall,
            summary: liveSummary,
            detail: liveDetail
        )
        store.streamingSessions.insert(payload.sessionId)
    }

    func applyLifecycle(_ payload: LifecyclePayload) {
        let phase = payload.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch phase {
        case "start":
            store.streamingSessions.insert(payload.sessionId)
            beginInlineProcess(sessionID: payload.sessionId, runID: payload.agentRunId)
        case "end", "error":
            store.streamingSessions.remove(payload.sessionId)
            store.streamingAssistantMessageIDBySession[payload.sessionId] = nil
            if phase == "error", let err = payload.error {
                let text = "Run failed (\(err.code)): \(err.message)"
                store.messagesBySession[payload.sessionId, default: []].append(
                    ChatMessage(sessionID: payload.sessionId, role: .system, text: text)
                )
            }
            finalizeInlineProcess(sessionID: payload.sessionId, failed: phase == "error")
            clearLiveAgentEvents(sessionID: payload.sessionId)
        default:
            break
        }
    }

    // MARK: - Session History

    func scheduleSessionHistoryPrefetch(projectID: UUID) {
        guard store.isGatewayConnected else { return }
        let loadedSessionIDs = Set(
            store.messagesBySession.compactMap { sessionID, messages in
                messages.isEmpty ? nil : sessionID
            }
        )
        let candidates = AppStore.sessionHistoryPrefetchCandidates(
            sessions: store.sessions(for: projectID),
            activeSessionID: store.activeSessionID,
            loadedMessageSessionIDs: loadedSessionIDs,
            inFlightSessionIDs: sessionHistoryRequestsInFlight,
            lastFetchedAtBySession: sessionHistoryLastFetchedAtBySession,
            now: .now,
            cooldown: sessionHistoryPrefetchCooldown
        )
        guard !candidates.isEmpty else { return }
        let targetSessionIDs = Array(candidates.prefix(8))

        sessionHistoryPrefetchTasksByProject[projectID]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sessionHistoryPrefetchTasksByProject[projectID] = nil }
            for sessionID in targetSessionIDs {
                guard !Task.isCancelled else { return }
                await self.refreshSessionHistoryFromGateway(projectID: projectID, sessionID: sessionID, trigger: .prefetch)
            }
        }
        sessionHistoryPrefetchTasksByProject[projectID] = task
    }

    func refreshSessionHistoryFromGateway(
        projectID: UUID,
        sessionID: UUID,
        trigger: AppStore.SessionHistoryRefreshTrigger = .interactive
    ) async {
        guard let gatewayClient = store.gatewayClient else { return }
        let now = Date()
        let hasLocalMessages = !(store.messagesBySession[sessionID]?.isEmpty ?? true)
        if AppStore.shouldSkipSessionHistoryRefresh(
            trigger: trigger,
            hasInFlightRequest: sessionHistoryRequestsInFlight.contains(sessionID),
            hasLocalMessages: hasLocalMessages,
            lastFetchedAt: sessionHistoryLastFetchedAtBySession[sessionID],
            now: now,
            prefetchCooldown: sessionHistoryPrefetchCooldown,
            interactiveFreshnessWindow: sessionHistoryInteractiveFreshnessWindow
        ) {
            return
        }

        sessionHistoryRequestsInFlight.insert(sessionID)
        defer { sessionHistoryRequestsInFlight.remove(sessionID) }

        struct HistoryParams: Codable, Sendable {
            var projectId: String
            var sessionId: String
            var beforeTs: Date?
            var limit: Int
        }
        struct ContextParams: Codable, Sendable {
            var projectId: String
            var sessionId: String
        }

        do {
            let res = try await gatewayClient.request(
                method: "chat.history",
                params: HistoryParams(projectId: AppStore.gatewayID(projectID), sessionId: AppStore.gatewayID(sessionID), beforeTs: nil, limit: 200)
            )
            let messages: [ChatMessage] = try store.decodeGatewayPayload(res.payload, key: "messages")
            applySessionHistorySnapshot(
                projectID: projectID,
                sessionID: sessionID,
                messages: messages,
                fetchedAt: now
            )

            if let contextRes = try? await gatewayClient.request(
                method: "sessions.context.get",
                params: ContextParams(projectId: AppStore.gatewayID(projectID), sessionId: AppStore.gatewayID(sessionID))
            ) {
                if let context: SessionContextState = try? store.decodeGatewayPayload(contextRes.payload, key: "context") {
                    store.sessionContextBySession[sessionID] = context
                    if let level = AppStore.parsePermissionLevel(context.permissionLevel) {
                        store.permissionLevelBySession[sessionID] = level
                    }
                }
            }
        } catch {
            store.gatewayConnectionState = .failed(message: error.localizedDescription)
        }
    }

    func refreshSessionHistoryFromCodex(
        projectID: UUID,
        sessionID: UUID,
        trigger: AppStore.SessionHistoryRefreshTrigger = .interactive
    ) async {
        let now = Date()
        let hasLocalItems = !(store.codexItemsBySession[sessionID]?.isEmpty ?? true)
        if AppStore.shouldSkipSessionHistoryRefresh(
            trigger: trigger,
            hasInFlightRequest: sessionHistoryRequestsInFlight.contains(sessionID),
            hasLocalMessages: hasLocalItems,
            lastFetchedAt: sessionHistoryLastFetchedAtBySession[sessionID],
            now: now,
            prefetchCooldown: sessionHistoryPrefetchCooldown,
            interactiveFreshnessWindow: sessionHistoryInteractiveFreshnessWindow
        ) {
            return
        }

        sessionHistoryRequestsInFlight.insert(sessionID)
        defer { sessionHistoryRequestsInFlight.remove(sessionID) }

        if !store.isCodexConnected {
            let ready = await store.ensureCodexConnectedForChat()
            guard ready else { return }
        }

        do {
            let response = try await store.requestCodex(
                method: "labos/session/read",
                params: CodexSessionReadParams(
                    projectId: AppStore.gatewayID(projectID),
                    sessionId: AppStore.gatewayID(sessionID),
                    includeTurns: true
                )
            )

            var session: Session = try store.decodeCodexResult(response.result, key: "session")
            var thread: CodexThread?
            if let resultObject = response.result?.objectValue,
               let threadValue = resultObject["thread"] {
                let threadData = try store.gatewayJSONEncoder.encode(threadValue)
                thread = try store.gatewayJSONDecoder.decode(CodexThread.self, from: threadData)
            }

            if (session.codexThreadId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               let threadId = thread?.id.trimmingCharacters(in: .whitespacesAndNewlines),
               !threadId.isEmpty {
                session.codexThreadId = threadId
            }
            store.projectService.upsertSession(session)

            let shouldFallbackToThreadRead: Bool = {
                if thread == nil { return true }
                guard session.backendEngine == "codex-app-server" else { return false }
                guard let thread else { return true }
                return thread.turns.isEmpty
            }()

            if shouldFallbackToThreadRead,
               let threadId = (thread?.id ?? session.codexThreadId)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !threadId.isEmpty {
                let threadResponse = try await store.requestCodex(
                    method: "thread/read",
                    params: CodexThreadReadParams(threadId: threadId, includeTurns: true)
                )
                thread = try store.decodeCodexResult(threadResponse.result, key: "thread")
            }

            if let thread {
                if let previousThread = store.codexThreadBySession[sessionID], previousThread != thread.id {
                    store.codexSessionByThread[previousThread] = nil
                }
                store.codexThreadBySession[sessionID] = thread.id
                store.codexSessionByThread[thread.id] = sessionID
                store.codexItemsBySession[sessionID] = Self.flattenCodexTurns(thread.turns)
                if let lastStatus = thread.turns.last?.status {
                    store.codexStatusTextBySession[sessionID] = lastStatus
                    if lastStatus == "inProgress" {
                        store.streamingSessions.insert(sessionID)
                    } else {
                        store.streamingSessions.remove(sessionID)
                    }
                }
            } else {
                store.codexItemsBySession[sessionID] = store.codexItemsBySession[sessionID] ?? []
            }

            store.codexPendingApprovalsBySession[sessionID] = []
            store.codexPendingPromptBySession[sessionID] = nil
            sessionHistoryLastFetchedAtBySession[sessionID] = now
            store.lastGatewayErrorMessage = nil
        } catch {
            store.lastGatewayErrorMessage = error.localizedDescription
            store.codexStatusTextBySession[sessionID] = "failed"
        }
    }

    func applySessionHistorySnapshot(
        projectID: UUID,
        sessionID: UUID,
        messages: [ChatMessage],
        fetchedAt: Date
    ) {
        let sortedMessages = messages.sorted(by: AppStore.messageDisplayOrder)
        store.messagesBySession[sessionID] = sortedMessages
        store.composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: Set(sortedMessages.map(\.id)))
        sessionHistoryLastFetchedAtBySession[sessionID] = fetchedAt
        reconcileInlineProcessAfterHistorySync(projectID: projectID, sessionID: sessionID, messages: sortedMessages)
    }

    // MARK: - Private Helpers

    static func codexRegeneratePlan(
        thread: CodexThread,
        assistantItemID: String,
        assistantText: String? = nil
    ) -> CodexRegeneratePlan? {
        let normalizedAssistantItemID = assistantItemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thread.turns.isEmpty else { return nil }

        let normalizedAssistantText = normalizeAssistantRegenerateText(assistantText)

        let targetTurnIndexByID: Int? = {
            guard !normalizedAssistantItemID.isEmpty else { return nil }
            return thread.turns.firstIndex(where: { turn in
                turn.items.contains { item in
                    if case let .agentMessage(agent) = item {
                        return agent.id.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedAssistantItemID
                    }
                    return false
                }
            })
        }()

        let targetTurnIndexByText: Int? = {
            guard let normalizedAssistantText, !normalizedAssistantText.isEmpty else { return nil }
            return thread.turns.lastIndex(where: { turn in
                turn.items.contains { item in
                    guard case let .agentMessage(agent) = item else { return false }
                    let candidate = normalizeAssistantRegenerateText(agent.text) ?? ""
                    guard !candidate.isEmpty else { return false }
                    return candidate == normalizedAssistantText
                        || candidate.contains(normalizedAssistantText)
                        || normalizedAssistantText.contains(candidate)
                }
            })
        }()

        let targetTurnIndex: Int? = targetTurnIndexByID ?? targetTurnIndexByText
            ?? thread.turns.lastIndex(where: { turn in
                turn.items.contains { item in
                    guard case let .agentMessage(agent) = item else { return false }
                    return !agent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            })

        guard let targetTurnIndex else {
            return nil
        }

        let targetTurn = thread.turns[targetTurnIndex]
        let sourceInput = resolveRegenerateSourceInput(
            targetTurn: targetTurn,
            assistantItemID: normalizedAssistantItemID,
            priorTurns: Array(thread.turns.prefix(targetTurnIndex))
        )
        guard !sourceInput.isEmpty else { return nil }

        return CodexRegeneratePlan(
            sourceInput: sourceInput,
            numTurnsToRollback: max(0, thread.turns.count - targetTurnIndex)
        )
    }

    private static func normalizeAssistantRegenerateText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.lowercased()
    }

    private static func resolveRegenerateSourceInput(
        targetTurn: CodexTurn,
        assistantItemID: String,
        priorTurns: [CodexTurn]
    ) -> [CodexUserInput] {
        var mostRecentUserInput: [CodexUserInput]? = nil

        for item in targetTurn.items {
            switch item {
            case let .userMessage(user):
                if !user.content.isEmpty {
                    mostRecentUserInput = user.content
                }
            case let .agentMessage(agent):
                if agent.id.trimmingCharacters(in: .whitespacesAndNewlines) == assistantItemID,
                   let mostRecentUserInput,
                   !mostRecentUserInput.isEmpty {
                    return mostRecentUserInput
                }
            default:
                break
            }
        }

        if let mostRecentUserInput, !mostRecentUserInput.isEmpty {
            return mostRecentUserInput
        }

        for turn in priorTurns.reversed() {
            for item in turn.items.reversed() {
                if case let .userMessage(user) = item, !user.content.isEmpty {
                    return user.content
                }
            }
        }

        return []
    }

    private static func codexTurnInputParts(from inputs: [CodexUserInput]) -> [CodexTurnInputPart] {
        var parts: [CodexTurnInputPart] = []
        for input in inputs {
            let type = input.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch type {
            case "text":
                let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    parts.append(CodexTurnInputPart(type: "text", text: text, url: nil, path: nil))
                }
            case "localimage":
                let path = input.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty {
                    parts.append(CodexTurnInputPart(type: "localImage", text: nil, url: nil, path: path))
                }
            case "image":
                let url = input.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !url.isEmpty {
                    parts.append(CodexTurnInputPart(type: "image", text: nil, url: url, path: nil))
                    continue
                }
                let path = input.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty {
                    parts.append(CodexTurnInputPart(type: "localImage", text: nil, url: nil, path: path))
                }
            default:
                continue
            }
        }
        return parts
    }

    private static func flattenCodexTurns(_ turns: [CodexTurn]) -> [CodexThreadItem] {
        turns.flatMap(\.items)
    }

    private func retrySource(for messageID: UUID, in sessionID: UUID) -> (text: String, userMessageID: UUID?)? {
        let sessionMessages = messages(for: sessionID)
        guard let index = sessionMessages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let message = sessionMessages[index]

        let source: String
        let sourceUserMessageID: UUID?
        switch message.role {
        case .user:
            source = message.text
            sourceUserMessageID = nil
        case .assistant:
            let previous = sessionMessages[..<index].last(where: { $0.role == .user })
            source = previous?.text ?? message.text
            sourceUserMessageID = previous?.id
        case .tool, .system:
            source = message.text
            sourceUserMessageID = nil
        }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, sourceUserMessageID)
    }

    private func appendLiveAgentEvent(
        sessionID: UUID,
        type: AgentLiveEventType,
        summary: String,
        detail: String? = nil
    ) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        var events = store.liveAgentEventsBySession[sessionID] ?? []
        if let last = events.last,
           last.type == type,
           last.summary == trimmedSummary,
           last.detail == normalizedDetail {
            return
        }

        events.append(
            AgentLiveEvent(
                sessionID: sessionID,
                type: type,
                summary: trimmedSummary,
                detail: normalizedDetail
            )
        )

        if events.count > 12 {
            events.removeFirst(events.count - 12)
        }
        store.liveAgentEventsBySession[sessionID] = events
    }

    private func shouldIgnoreLateToolEvent(payload: ToolEventPayload, phase: String) -> Bool {
        guard phase == "start" || phase == "update" || phase == "end" || phase == "error" else {
            return false
        }
        guard store.activeInlineProcessBySession[payload.sessionId] == nil else {
            return false
        }
        guard pendingLocalUserEchosBySession[payload.sessionId]?.isEmpty ?? true else {
            return false
        }
        guard !hasActiveRun(projectID: payload.projectId, sessionID: payload.sessionId) else {
            return false
        }

        let latestTurnRole = messages(for: payload.sessionId)
            .last(where: { $0.role == .user || $0.role == .assistant })?
            .role
        return latestTurnRole == .assistant
    }

    private func clearLiveAgentEvents(sessionID: UUID) {
        store.liveAgentEventsBySession[sessionID] = []
    }

    private func formattedJSONDetail(_ detail: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(detail),
              let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: detail)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 1_500 {
            return String(trimmed.prefix(1_500)) + "\n…"
        }
        return trimmed
    }

    private func beginInlineProcess(sessionID: UUID, runID: UUID) {
        store.activeInlineProcessBySession[sessionID] = ActiveInlineProcess(
            sessionID: sessionID,
            agentRunID: runID,
            assistantMessageID: nil,
            phase: .thinking,
            activeLine: nil,
            entries: [],
            familyCounts: [:]
        )
    }

    private func transitionInlineProcessToResponding(sessionID: UUID, messageID: UUID) {
        guard var process = store.activeInlineProcessBySession[sessionID] else { return }
        if process.assistantMessageID == nil {
            process.assistantMessageID = messageID
        }
        process.phase = .responding
        process.activeLine = nil
        store.activeInlineProcessBySession[sessionID] = process
    }

    private func applyInlineToolEvent(_ payload: ToolEventPayload, fallbackSummary: String) {
        let phase = payload.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var process = store.activeInlineProcessBySession[payload.sessionId]
            ?? ActiveInlineProcess(
                sessionID: payload.sessionId,
                agentRunID: payload.agentRunId,
                phase: .thinking,
                activeLine: nil,
                entries: [],
                familyCounts: [:]
            )

        let family = toolActionFamily(tool: payload.tool, summary: fallbackSummary)
        let activeText = activeToolPhrase(family: family, fallback: fallbackSummary)
        let completedText = completedToolPhrase(family: family, fallback: fallbackSummary)

        switch phase {
        case "start", "update":
            if let idx = process.entries.lastIndex(where: {
                $0.toolCallID == payload.toolCallId && $0.state == .active
            }) {
                process.entries[idx].family = family
                process.entries[idx].activeText = activeText
                process.entries[idx].completedText = completedText
            } else {
                process.entries.append(
                    ProcessEntry(
                        toolCallID: payload.toolCallId,
                        family: family,
                        activeText: activeText,
                        completedText: completedText,
                        state: .active
                    )
                )
            }
            process.phase = .toolCalling
            process.activeLine = activeText
        case "end":
            if let idx = process.entries.lastIndex(where: {
                $0.toolCallID == payload.toolCallId && $0.state == .active
            }) {
                process.entries[idx].state = .completed
                process.entries[idx].completedText = completedText
                process.familyCounts[family, default: 0] += 1
            } else {
                process.entries.append(
                    ProcessEntry(
                        toolCallID: payload.toolCallId,
                        family: family,
                        activeText: activeText,
                        completedText: completedText,
                        state: .completed
                    )
                )
                process.familyCounts[family, default: 0] += 1
            }

            if process.assistantMessageID == nil {
                process.phase = .thinking
                process.activeLine = nil
            } else {
                process.phase = .responding
                process.activeLine = nil
            }
        case "error":
            if let idx = process.entries.lastIndex(where: {
                $0.toolCallID == payload.toolCallId && $0.state == .active
            }) {
                process.entries[idx].state = .failed
                process.entries[idx].completedText = completedText
            } else {
                process.entries.append(
                    ProcessEntry(
                        toolCallID: payload.toolCallId,
                        family: family,
                        activeText: activeText,
                        completedText: completedText,
                        state: .failed
                    )
                )
            }
            if process.assistantMessageID == nil {
                process.phase = .thinking
                process.activeLine = nil
            } else {
                process.phase = .responding
                process.activeLine = nil
            }
        default:
            break
        }

        store.activeInlineProcessBySession[payload.sessionId] = process
    }

    private func finalizeInlineProcess(
        sessionID: UUID,
        failed: Bool,
        assistantMessageIDFallback: UUID? = nil
    ) {
        guard var process = store.activeInlineProcessBySession[sessionID] else { return }
        if process.assistantMessageID == nil, let assistantMessageIDFallback {
            process.assistantMessageID = assistantMessageIDFallback
        }
        process.phase = failed ? .failed : .completed

        if let assistantMessageID = process.assistantMessageID,
           !process.entries.isEmpty {
            let headline = summaryHeadline(from: process.familyCounts, fallbackEntryCount: process.entries.count)
            store.persistedProcessSummaryByMessageID[assistantMessageID] = AssistantProcessSummary(
                sessionID: sessionID,
                assistantMessageID: assistantMessageID,
                headline: headline,
                entries: process.entries,
                familyCounts: process.familyCounts
            )
        }

        store.activeInlineProcessBySession[sessionID] = nil
    }

    private func reconcileInlineProcessAfterHistorySync(
        projectID: UUID,
        sessionID: UUID,
        messages: [ChatMessage]
    ) {
        guard store.activeInlineProcessBySession[sessionID] != nil else { return }
        let hasPendingLocalEcho = !(pendingLocalUserEchosBySession[sessionID]?.isEmpty ?? true)
        guard !hasActiveRun(projectID: projectID, sessionID: sessionID) else { return }

        if let assistantMessageID = AppStore.latestAssistantReplyID(in: messages) {
            if hasPendingLocalEcho {
                pendingLocalUserEchosBySession[sessionID] = nil
            }
            if var process = store.activeInlineProcessBySession[sessionID] {
                let currentlyBoundAssistantID = process.assistantMessageID
                let isBoundAssistantStillPresent = currentlyBoundAssistantID.map { currentID in
                    messages.contains { $0.id == currentID }
                } ?? false
                if !isBoundAssistantStillPresent {
                    process.assistantMessageID = assistantMessageID
                    store.activeInlineProcessBySession[sessionID] = process
                }
            }
            finalizeInlineProcess(
                sessionID: sessionID,
                failed: false,
                assistantMessageIDFallback: assistantMessageID
            )
            store.streamingAssistantMessageIDBySession[sessionID] = nil
            store.streamingSessions.remove(sessionID)
            clearLiveAgentEvents(sessionID: sessionID)
            return
        }

        if hasPendingLocalEcho {
            return
        }

        if let lastMessage = messages.last, lastMessage.role == .user {
            return
        }

        store.streamingAssistantMessageIDBySession[sessionID] = nil
        store.streamingSessions.remove(sessionID)
        store.activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
    }

    private func hasActiveRun(projectID: UUID, sessionID: UUID) -> Bool {
        store.projectService.hasActiveRun(projectID: projectID, sessionID: sessionID)
    }

    private func summaryHeadline(
        from familyCounts: [ProcessActionFamily: Int],
        fallbackEntryCount: Int
    ) -> String {
        let displayOrder: [ProcessActionFamily] = [.search, .list, .read, .write, .exec, .other]
        let parts = displayOrder.compactMap { family -> String? in
            guard let count = familyCounts[family], count > 0 else { return nil }
            return "\(count) \(label(for: family, count: count))"
        }
        if parts.isEmpty {
            return "Explored \(fallbackEntryCount) steps"
        }
        return "Explored " + parts.joined(separator: ", ")
    }

    private func label(for family: ProcessActionFamily, count: Int) -> String {
        switch family {
        case .search:
            return count == 1 ? "search" : "searches"
        case .list:
            return count == 1 ? "list" : "lists"
        case .read:
            return count == 1 ? "read" : "reads"
        case .write:
            return count == 1 ? "write" : "writes"
        case .exec:
            return count == 1 ? "command" : "commands"
        case .other:
            return count == 1 ? "step" : "steps"
        }
    }

    private func toolActionFamily(tool: String, summary: String) -> ProcessActionFamily {
        let text = "\(tool) \(summary)".lowercased()
        if text.contains("search") || text.contains("query") || text.contains("find") {
            return .search
        }
        if text.contains("list") || text.contains("ls") || text.contains("scan") {
            return .list
        }
        if text.contains("read") || text.contains("open") || text.contains("cat") {
            return .read
        }
        if text.contains("write") || text.contains("patch") || text.contains("edit") {
            return .write
        }
        if text.contains("exec") || text.contains("shell") || text.contains("python") || text.contains("command") {
            return .exec
        }
        return .other
    }

    private func activeToolPhrase(family: ProcessActionFamily, fallback: String) -> String {
        switch family {
        case .search:
            return "Searching..."
        case .list:
            return "Listing files..."
        case .read:
            return "Reading files..."
        case .write:
            return "Writing changes..."
        case .exec:
            return "Running command..."
        case .other:
            return normalizeActiveFallback(fallback)
        }
    }

    private func completedToolPhrase(family: ProcessActionFamily, fallback: String) -> String {
        switch family {
        case .search:
            return "Searched ..."
        case .list:
            return "Listed files ..."
        case .read:
            return "Read files ..."
        case .write:
            return "Wrote changes ..."
        case .exec:
            return "Ran command ..."
        case .other:
            return normalizeCompletedFallback(fallback)
        }
    }

    private func normalizeActiveFallback(_ fallback: String) -> String {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Exploring..." }
        if trimmed.hasSuffix("...") { return trimmed }
        return trimmed + "..."
    }

    private func normalizeCompletedFallback(_ fallback: String) -> String {
        let active = normalizeActiveFallback(fallback)
        let lower = active.lowercased()
        if lower.hasSuffix("ing..."), active.count > 6 {
            let stem = String(active.dropLast(6))
            return stem + "ed ..."
        }
        if active.hasSuffix("..."), active.count > 3 {
            let stem = String(active.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stem.isEmpty {
                return "Completed \(stem) ..."
            }
        }
        return "Completed ..."
    }

    private func applyAssistantResponse(projectID: UUID, sessionID: UUID, response: AssistantResponse) {
        clearLiveAgentEvents(sessionID: sessionID)
        let assistant = ChatMessage(
            sessionID: sessionID,
            role: .assistant,
            text: response.text,
            artifactRefs: response.artifactRefs,
            proposedPlan: response.proposedPlan
        )

        store.messagesBySession[sessionID, default: []].append(assistant)
        finalizeInlineProcess(sessionID: sessionID, failed: false, assistantMessageIDFallback: assistant.id)
        if let plan = response.proposedPlan {
            let pending = PendingApproval(
                planId: plan.id,
                projectId: projectID,
                sessionId: sessionID,
                agentRunId: UUID(),
                plan: plan,
                required: true,
                judgment: nil
            )
            store.planService.pendingApprovalsBySession[sessionID] = pending
        }
    }

    private func sendGatewayChatMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachmentRefs: [ChatArtifactReference] = [],
        attachments: [ComposerAttachment] = [],
        overwriteMessageID: UUID? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let connected = await self.store.ensureGatewayConnectedForChat()
            guard connected, self.store.isGatewayConnected, let gatewayClient = self.store.gatewayClient else {
                self.appendGatewayConnectionError(sessionID: sessionID)
                return
            }

            let params = self.makeGatewayChatParams(
                projectID: projectID,
                sessionID: sessionID,
                text: text,
                attachmentRefs: attachmentRefs,
                attachments: attachments,
                overwriteMessageID: overwriteMessageID
            )
            do {
                _ = try await gatewayClient.request(
                    method: "chat.send",
                    params: params
                )
                self.store.lastGatewayErrorMessage = nil
            } catch {
                self.store.lastGatewayErrorMessage = error.localizedDescription
                let recovered = await self.recoverMissingGatewaySessionAndResend(
                    error: error,
                    projectID: projectID,
                    sessionID: sessionID,
                    text: text,
                    attachmentRefs: attachmentRefs,
                    attachments: attachments,
                    overwriteMessageID: overwriteMessageID,
                    gatewayClient: gatewayClient
                )
                guard !recovered else { return }
                self.finalizeInlineProcess(sessionID: sessionID, failed: true)
                self.clearLiveAgentEvents(sessionID: sessionID)
                let sys = ChatMessage(
                    sessionID: sessionID,
                    role: .system,
                    text: "Send failed: \(error.localizedDescription)"
                )
                self.store.messagesBySession[sessionID, default: []].append(sys)
            }
        }
    }

    private func makeGatewayChatParams(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachmentRefs: [ChatArtifactReference] = [],
        attachments: [ComposerAttachment] = [],
        overwriteMessageID: UUID? = nil
    ) -> GatewayChatSendParams {
        let modelIdRaw = store.selectedModelId(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = modelIdRaw.isEmpty ? nil : modelIdRaw
        let thinking = store.selectedThinkingLevel(for: sessionID)
        let planMode = store.planModeEnabled(for: sessionID)
        let permLevel = store.permissionLevel(for: sessionID)
        let payloadAttachments: [GatewayChatAttachment]? = attachmentRefs.isEmpty ? nil : attachmentRefs.enumerated().map { index, ref in
            let source: ComposerAttachment? = {
                if let artifactID = ref.artifactID {
                    if let direct = attachments.first(where: { $0.id == artifactID }) {
                        return direct
                    }
                }
                if attachments.indices.contains(index) {
                    return attachments[index]
                }
                return attachments.first(where: { $0.displayName == ref.displayText })
            }()
            return GatewayChatAttachment(
                id: ref.artifactID?.uuidString ?? source?.id.uuidString ?? UUID().uuidString,
                scope: ref.scope ?? "session",
                name: ref.displayText,
                path: ref.path,
                mimeType: source?.mimeType ?? ref.mimeType,
                inlineDataBase64: source?.inlineDataBase64 ?? ref.inlineDataBase64,
                byteCount: source?.byteCount ?? ref.byteCount
            )
        }
        return GatewayChatSendParams(
            projectId: AppStore.gatewayID(projectID),
            sessionId: AppStore.gatewayID(sessionID),
            text: text,
            overwriteMessageId: overwriteMessageID.map(AppStore.gatewayID),
            attachments: payloadAttachments,
            modelId: modelId,
            thinkingLevel: thinking,
            planMode: planMode,
            permissionLevel: permLevel
        )
    }

    private func appendGatewayConnectionError(sessionID: UUID) {
        store.activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
        let detail: String
        switch store.gatewayConnectionState {
        case .disconnected:
            detail = "Disconnected"
        case .connecting:
            detail = "Connecting…"
        case let .failed(message):
            detail = "Failed: \(message)"
        case .connected:
            detail = "Connected"
        }
        let sys = ChatMessage(
            sessionID: sessionID,
            role: .system,
            text: "Gateway not connected (\(detail)). Open Settings and connect to your Hub (e.g. ws://127.0.0.1:8787/ws)."
        )
        store.messagesBySession[sessionID, default: []].append(sys)
    }

    private func recoverMissingGatewaySessionAndResend(
        error: Error,
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachmentRefs: [ChatArtifactReference],
        attachments: [ComposerAttachment],
        overwriteMessageID: UUID?,
        gatewayClient: GatewayClient
    ) async -> Bool {
        guard store.isGatewaySessionNotFoundError(error) else { return false }
        _ = overwriteMessageID
        let nonSystemMessageCount = localNonSystemMessageCount(for: sessionID)
        guard AppStore.shouldAutoRecoverMissingGatewaySession(localNonSystemMessageCount: nonSystemMessageCount) else {
            return false
        }

        let previousActiveProjectID = store.activeProjectID
        let previousActiveSessionID = store.activeSessionID

        let title = store.sessions(for: projectID).first(where: { $0.id == sessionID })?.title
        let modelId = store.selectedModelId(for: sessionID)
        let thinking = store.selectedThinkingLevel(for: sessionID)
        let planMode = store.planModeEnabled(for: sessionID)
        let permission = store.permissionLevel(for: sessionID)

        guard let recovered = await store.createSession(projectID: projectID, title: title) else {
            return false
        }

        if !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.setSelectedModelId(for: recovered.id, modelId: modelId)
        }
        store.setSelectedThinkingLevel(for: recovered.id, level: thinking)
        store.setPlanModeEnabled(for: recovered.id, enabled: planMode)
        store.setPermissionLevel(projectID: recovered.projectID, sessionID: recovered.id, level: permission)

        let params = makeGatewayChatParams(
            projectID: recovered.projectID,
            sessionID: recovered.id,
            text: text,
            attachmentRefs: attachmentRefs,
            attachments: attachments,
            overwriteMessageID: nil
        )
        do {
            _ = try await gatewayClient.request(method: "chat.send", params: params)
            store.messagesBySession[recovered.id, default: []].append(
                ChatMessage(
                    sessionID: recovered.id,
                    role: .system,
                    text: "Recovered broken session state and resent your message."
                )
            )
            return true
        } catch {
            if store.activeSessionID == recovered.id {
                store.activeProjectID = previousActiveProjectID
                store.activeSessionID = previousActiveSessionID
            }
            return false
        }
    }

    private func localNonSystemMessageCount(for sessionID: UUID) -> Int {
        (store.messagesBySession[sessionID] ?? []).reduce(into: 0) { count, message in
            if message.role != .system {
                count += 1
            }
        }
    }
}
