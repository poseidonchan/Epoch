import Combine
import Foundation

@MainActor
internal final class ChatSessionService {
    private weak var store: AppStore?

    // MARK: - Private Types

    private struct CodexTurnStartParams: Codable, Sendable {
        var threadId: String
        var input: [CodexTurnInputPart]
        var model: String?
        var planMode: Bool
    }

    private struct CodexTurnSteerParams: Codable, Sendable {
        var threadId: String
        var turnId: String
        var input: [CodexTurnInputPart]?
        var text: String?
    }

    private struct CodexTurnInterruptParams: Codable, Sendable {
        var threadId: String
        var turnId: String
    }

    private struct CodexThreadReadParams: Codable, Sendable {
        var threadId: String
        var includeTurns: Bool
    }

    private struct CodexSessionReadParams: Codable, Sendable {
        var projectId: String
        var sessionId: String
        var includeTurns: Bool
    }

    private struct CodexSessionReadPendingInputPayload: Decodable, Sendable {
        var requestId: CodexRequestID
        var method: String
        var kind: String?
        var params: JSONValue?
        var createdAt: Int?
    }

    private struct CodexSessionReadActivePlanPayload: Decodable, Sendable {
        struct Step: Decodable, Sendable {
            var step: String
            var status: String
        }

        var turnId: String
        var explanation: String?
        var plan: [Step]
        var updatedAt: Int?
    }

    private struct CodexTurnInputPart: Codable, Sendable {
        var type: String
        var text: String?
        var url: String?
        var path: String?
        var name: String?
        var mimeType: String?
        var inlineDataBase64: String?

        init(
            type: String,
            text: String? = nil,
            url: String? = nil,
            path: String? = nil,
            name: String? = nil,
            mimeType: String? = nil,
            inlineDataBase64: String? = nil
        ) {
            self.type = type
            self.text = text
            self.url = url
            self.path = path
            self.name = name
            self.mimeType = mimeType
            self.inlineDataBase64 = inlineDataBase64
        }
    }

    struct CodexRegeneratePlan: Sendable {
        var sourceInput: [CodexUserInput]
        var numTurnsToRollback: Int
    }

    // MARK: - Session History State

    var sessionHistoryRequestsInFlight: Set<UUID> = []
    var sessionHistoryLastFetchedAtBySession: [UUID: Date] = [:]
    var sessionHistoryPrefetchTasksByProject: [UUID: Task<Void, Never>] = [:]
    private let sessionHistoryPrefetchCooldown: TimeInterval = 45
    private let sessionHistoryInteractiveFreshnessWindow: TimeInterval = 8
    private var steerOptimisticEchoIDByQueueItemID: [UUID: String] = [:]

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Session Cleanup

    func clearSession(sessionID: UUID) {
        guard let store else { return }
        store.messagesBySession[sessionID] = nil
        store.streamingSessions.remove(sessionID)
        store.streamingAssistantMessageIDBySession[sessionID] = nil
        store.codexActiveTurnIDBySession[sessionID] = nil
        store.codexQueuedInputsBySession[sessionID] = nil
        store.codexQueuedInputsLoadedSessions.remove(sessionID)
        store.codexTurnDiffBySession[sessionID] = nil
        store.codexPendingApprovalsBySession[sessionID] = nil
        store.codexPendingPromptBySession[sessionID] = nil
        store.sessionContextBySession[sessionID] = nil
        store.liveAgentEventsBySession[sessionID] = nil
        store.activeInlineProcessBySession[sessionID] = nil
        store.planModeEnabledBySession[sessionID] = nil
        store.selectedModelIdBySession[sessionID] = nil
        store.selectedThinkingLevelBySession[sessionID] = nil
        store.permissionLevelBySession[sessionID] = nil
        store.clearCodexTurnLifecycleState(sessionID: sessionID, threadID: store.codexThreadBySession[sessionID])
        store.composerService.clearPendingPermissionSync(sessionID: sessionID)
        store.livePlanBySession[sessionID] = nil
        sessionHistoryLastFetchedAtBySession[sessionID] = nil
    }

    // MARK: - Message Accessors

    func messages(for sessionID: UUID) -> [ChatMessage] {
        guard let store else { return [] }
        return (store.messagesBySession[sessionID] ?? []).sorted(by: AppStore.messageDisplayOrder)
    }

    func liveAgentEvents(for sessionID: UUID) -> [AgentLiveEvent] {
        guard let store else { return [] }
        return (store.liveAgentEventsBySession[sessionID] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func activeInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        guard let store else { return nil }
        return store.activeInlineProcessBySession[sessionID]
    }

    func pendingInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        guard let store else { return nil }
        guard let process = store.activeInlineProcessBySession[sessionID],
              process.assistantMessageID == nil
        else { return nil }
        return process
    }

    func activeInlineProcess(for sessionID: UUID, assistantMessageID: UUID) -> ActiveInlineProcess? {
        guard let store else { return nil }
        guard let process = store.activeInlineProcessBySession[sessionID],
              process.assistantMessageID == assistantMessageID
        else { return nil }
        return process
    }

    func persistedProcessSummary(for assistantMessageID: UUID) -> AssistantProcessSummary? {
        guard let store else { return nil }
        return store.persistedProcessSummaryByMessageID[assistantMessageID]
    }

    // MARK: - Send / Retry

    func sendMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachments: [ComposerAttachment]? = nil
    ) {
        guard let store else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let effectiveAttachments = attachments ?? store.composerService.pendingComposerAttachments(for: sessionID)
        let hasAttachments = !effectiveAttachments.isEmpty
        let usesCodex = store.sessionUsesCodex(sessionID: sessionID)

        guard hasText || hasAttachments else { return }
        if !usesCodex, !hasText {
            store.lastGatewayErrorMessage = "Text is required for the current backend."
            return
        }
        if usesCodex {
            store.dismissImplementConfirmationPrompt(sessionID: sessionID)
        }

        let attachmentRefs = store.composerService.makeSessionAttachmentReferences(
            projectID: projectID,
            sessionID: sessionID,
            attachments: effectiveAttachments
        )

        if usesCodex, store.codexTurnInFlight(sessionID: sessionID) {
            enqueueCodexQueuedInput(sessionID: sessionID, text: trimmed, attachments: effectiveAttachments)
            store.clearPendingComposerAttachments(sessionID: sessionID)
            return
        }

        beginInlineProcess(sessionID: sessionID, runID: UUID())
        clearLiveAgentEvents(sessionID: sessionID)

        if usesCodex {
            sendCodexTurnMessage(
                projectID: projectID,
                sessionID: sessionID,
                text: trimmed,
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
    }

    func steerQueuedCodexInput(sessionID: UUID, queueItemID: UUID) {
        guard let store else { return }
        guard store.sessionUsesCodex(sessionID: sessionID) else { return }
        store.dismissImplementConfirmationPrompt(sessionID: sessionID)
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        let queue = store.codexQueuedInputsBySession[sessionID] ?? []
        guard let item = queue.first(where: { $0.id == queueItemID }) else { return }

        let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !item.attachments.isEmpty else {
            updateCodexQueuedInput(sessionID: sessionID, itemID: queueItemID) { queued in
                queued.status = .failed
                queued.error = "Steer input cannot be empty."
            }
            return
        }

        guard let threadId = store.codexThreadBySession[sessionID],
              let turnId = store.codexActiveTurnIDBySession[sessionID]
        else {
            updateCodexQueuedInput(sessionID: sessionID, itemID: queueItemID) { queued in
                queued.status = .failed
                queued.error = "No active turn is available yet. Retry once the turn starts."
            }
            return
        }

        moveQueuedCodexInputToFront(sessionID: sessionID, itemID: queueItemID)
        updateCodexQueuedInput(sessionID: sessionID, itemID: queueItemID) { queued in
            queued.status = .sending
            queued.error = nil
        }

        let payloads = loadQueuedAttachmentPayloads(item.attachments)
        let localEchoContent = makeLocalEchoContent(text: trimmedText, queuedAttachments: payloads)
        let localEchoID = appendLocalCodexUserEcho(sessionID: sessionID, content: localEchoContent)
        rememberSteerOptimisticEcho(queueItemID: queueItemID, localEchoID: localEchoID)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let store = self.store else { return }

            let hasAttachments = !payloads.isEmpty
            let inputParts = self.makeCodexSteerInputParts(text: trimmedText, queuedAttachments: payloads)

            do {
                _ = try await store.requestCodex(
                    method: "turn/steer",
                    params: CodexTurnSteerParams(
                        threadId: threadId,
                        turnId: turnId,
                        input: inputParts.isEmpty ? nil : inputParts,
                        text: nil
                    )
                )
                store.lastGatewayErrorMessage = nil
                self.removeQueuedCodexInput(sessionID: sessionID, queueItemID: queueItemID, deleteAttachmentFiles: true)
                self.finalizeSteerOptimisticEcho(queueItemID: queueItemID)
            } catch {
                if self.isUnsupportedSteerMethodError(error) {
                    self.performSteerFallbackInterrupt(
                        sessionID: sessionID,
                        queueItemID: queueItemID,
                        threadId: threadId,
                        turnId: turnId
                    )
                } else if !hasAttachments, !trimmedText.isEmpty {
                    // Retry with text-only steer when the backend rejects the `input` shape.
                    do {
                        _ = try await store.requestCodex(
                            method: "turn/steer",
                            params: CodexTurnSteerParams(
                                threadId: threadId,
                                turnId: turnId,
                                input: nil,
                                text: trimmedText
                            )
                        )
                        store.lastGatewayErrorMessage = nil
                        self.removeQueuedCodexInput(sessionID: sessionID, queueItemID: queueItemID, deleteAttachmentFiles: true)
                    } catch {
                        if self.isUnsupportedSteerMethodError(error) {
                            self.performSteerFallbackInterrupt(
                                sessionID: sessionID,
                                queueItemID: queueItemID,
                                threadId: threadId,
                                turnId: turnId
                            )
                        } else {
                            store.lastGatewayErrorMessage = error.localizedDescription
                            self.rollbackSteerOptimisticEcho(sessionID: sessionID, queueItemID: queueItemID)
                            self.updateCodexQueuedInput(sessionID: sessionID, itemID: queueItemID) { queued in
                                queued.status = .failed
                                queued.error = error.localizedDescription
                            }
                        }
                    }
                } else {
                    // Attachment steer requires `input`; fallback to interrupt when steer fails.
                    self.performSteerFallbackInterrupt(
                        sessionID: sessionID,
                        queueItemID: queueItemID,
                        threadId: threadId,
                        turnId: turnId
                    )
                }
            }
        }
    }

    private func performSteerFallbackInterrupt(sessionID: UUID, queueItemID: UUID, threadId: String, turnId: String) {
        guard let store else { return }
        store.suppressCodexTurn(sessionID: sessionID, turnID: turnId)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let store = self.store else { return }
            do {
                _ = try await store.requestCodex(
                    method: "turn/interrupt",
                    params: CodexTurnInterruptParams(threadId: threadId, turnId: turnId)
                )
                store.lastGatewayErrorMessage = nil
            } catch {
                store.unsuppressCodexTurn(sessionID: sessionID, turnID: turnId)
                store.lastGatewayErrorMessage = error.localizedDescription
                self.rollbackSteerOptimisticEcho(sessionID: sessionID, queueItemID: queueItemID)
                self.updateCodexQueuedInput(sessionID: sessionID, itemID: queueItemID) { queued in
                    queued.status = .failed
                    queued.error = error.localizedDescription
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await MainActor.run {
                guard let store = self.store else { return }
                guard store.streamingSessions.contains(sessionID) else { return }
                guard store.codexActiveTurnID(for: sessionID) == turnId else { return }
                guard store.isCodexTurnSuppressed(sessionID: sessionID, turnID: turnId) else { return }

                store.unsuppressCodexTurn(sessionID: sessionID, turnID: turnId)
                self.rollbackSteerOptimisticEcho(sessionID: sessionID, queueItemID: queueItemID)
                self.updateCodexQueuedInput(sessionID: sessionID, itemID: queueItemID) { queued in
                    queued.status = .failed
                    queued.error = "Interrupt timed out."
                }
            }
        }
    }

    func removeQueuedCodexInput(sessionID: UUID, queueItemID: UUID) {
        removeQueuedCodexInput(sessionID: sessionID, queueItemID: queueItemID, deleteAttachmentFiles: true)
    }

    func drainCodexQueueIfPossible(projectID: UUID, sessionID: UUID) {
        guard let store else { return }
        guard store.sessionUsesCodex(sessionID: sessionID) else { return }
        guard !store.codexTurnInFlight(sessionID: sessionID) else { return }
        guard !store.sessionNeedsUserInput(sessionID: sessionID) else { return }

        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        guard let next = store.codexQueuedInputs(for: sessionID).first else { return }
        guard next.status != .failed else { return }

        sendCodexQueuedInputAsNextTurn(projectID: projectID, sessionID: sessionID, queuedItemID: next.id)
    }

    func interruptCodexTurn(sessionID: UUID) {
        guard let store else { return }
        guard store.sessionUsesCodex(sessionID: sessionID) else { return }
        guard let threadId = store.codexThreadBySession[sessionID],
              let turnId = store.codexActiveTurnIDBySession[sessionID]
        else {
            store.lastGatewayErrorMessage = "No active turn is available yet."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard let store = self.store else { return }
            do {
                _ = try await store.requestCodex(
                    method: "turn/interrupt",
                    params: CodexTurnInterruptParams(threadId: threadId, turnId: turnId)
                )
            } catch {
                await MainActor.run {
                    store.lastGatewayErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func enqueueCodexQueuedInput(sessionID: UUID, text: String, attachments: [ComposerAttachment]) {
        guard let store else { return }
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        let queueItemID = UUID()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedAttachments = stageQueuedAttachments(sessionID: sessionID, queuedItemID: queueItemID, attachments: attachments)
        guard !trimmed.isEmpty || !stagedAttachments.isEmpty else { return }

        let existing = store.codexQueuedInputsBySession[sessionID] ?? []
        let nextIndex = (existing.map(\.sortIndex).max() ?? (existing.count - 1)) + 1

        let item = CodexQueuedUserInputItem(
            id: queueItemID,
            sessionID: sessionID,
            text: trimmed,
            attachments: stagedAttachments,
            createdAt: .now,
            sortIndex: nextIndex,
            status: .queued,
            error: nil
        )

        store.codexQueuedInputsBySession[sessionID] = existing + [item]
        store.persistCodexQueuedInputs(sessionID: sessionID)
    }

    private struct QueuedAttachmentPayload: Sendable {
        var attachment: CodexQueuedAttachment
        var data: Data
        var base64: String
    }

    private func updateCodexQueuedInput(
        sessionID: UUID,
        itemID: UUID,
        mutate: (inout CodexQueuedUserInputItem) -> Void
    ) {
        guard let store else { return }
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        var queue = store.codexQueuedInputsBySession[sessionID] ?? []
        guard let index = queue.firstIndex(where: { $0.id == itemID }) else { return }
        var item = queue[index]
        mutate(&item)
        queue[index] = item
        store.codexQueuedInputsBySession[sessionID] = queue
        store.persistCodexQueuedInputs(sessionID: sessionID)
    }

    private func removeQueuedCodexInput(
        sessionID: UUID,
        queueItemID: UUID,
        deleteAttachmentFiles: Bool
    ) {
        guard let store else { return }
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        var queue = store.codexQueuedInputsBySession[sessionID] ?? []
        guard let index = queue.firstIndex(where: { $0.id == queueItemID }) else { return }
        let removed = queue.remove(at: index)
        if deleteAttachmentFiles {
            deleteQueuedAttachmentFiles(removed.attachments)
        }
        store.codexQueuedInputsBySession[sessionID] = queue.isEmpty ? nil : queue
        store.persistCodexQueuedInputs(sessionID: sessionID)
    }

    private func rememberSteerOptimisticEcho(queueItemID: UUID, localEchoID: String?) {
        guard let localEchoID else {
            steerOptimisticEchoIDByQueueItemID.removeValue(forKey: queueItemID)
            return
        }
        steerOptimisticEchoIDByQueueItemID[queueItemID] = localEchoID
    }

    private func rollbackSteerOptimisticEcho(sessionID: UUID, queueItemID: UUID) {
        guard let localEchoID = steerOptimisticEchoIDByQueueItemID.removeValue(forKey: queueItemID) else { return }
        removeLocalCodexUserEcho(sessionID: sessionID, itemID: localEchoID)
    }

    private func finalizeSteerOptimisticEcho(queueItemID: UUID) {
        steerOptimisticEchoIDByQueueItemID.removeValue(forKey: queueItemID)
    }

    private func moveQueuedCodexInputToFront(sessionID: UUID, itemID: UUID) {
        guard let store else { return }
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        var ordered = store.codexQueuedInputs(for: sessionID)
        guard let index = ordered.firstIndex(where: { $0.id == itemID }) else { return }
        let selected = ordered.remove(at: index)
        ordered.insert(selected, at: 0)
        store.codexQueuedInputsBySession[sessionID] = ordered.enumerated().map { idx, item in
            var updated = item
            updated.sortIndex = idx
            return updated
        }
        store.persistCodexQueuedInputs(sessionID: sessionID)
    }

    private func isUnsupportedSteerMethodError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        if message.contains("method not found") || message.contains("unknown method") {
            return true
        }
        if message.contains("unknown variant") {
            return true
        }
        if message.contains("turn/steer") && message.contains("unknown variant") {
            return true
        }
        if message.contains("turn/steer") && message.contains("method not found") {
            return true
        }
        if message.contains("does not support turn/steer") {
            return true
        }
        return false
    }

    private func deleteQueuedAttachmentFiles(_ attachments: [CodexQueuedAttachment]) {
        for attachment in attachments {
            let stored = attachment.storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stored.isEmpty else { continue }
            try? FileManager.default.removeItem(atPath: stored)
        }
    }

    private func queuedAttachmentCacheDirectory(sessionID: UUID, queuedItemID: UUID) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("epoch-codex-queued-inputs", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(queuedItemID.uuidString.lowercased(), isDirectory: true)
    }

    private func sanitizeQueuedAttachmentFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "attachment" }
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if cleaned.count > 180 {
            return String(cleaned.suffix(180))
        }
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private func stageQueuedAttachments(
        sessionID: UUID,
        queuedItemID: UUID,
        attachments: [ComposerAttachment]
    ) -> [CodexQueuedAttachment] {
        guard !attachments.isEmpty else { return [] }
        let destinationDir = queuedAttachmentCacheDirectory(sessionID: sessionID, queuedItemID: queuedItemID)
        do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        } catch {
            return []
        }

        var staged: [CodexQueuedAttachment] = []
        staged.reserveCapacity(attachments.count)

        for attachment in attachments {
            guard let base64 = attachment.inlineDataBase64,
                  let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
                  !data.isEmpty
            else { continue }

            let safeName = sanitizeQueuedAttachmentFileName(attachment.displayName)
            let destination = destinationDir.appendingPathComponent("\(attachment.id.uuidString.lowercased())-\(safeName)")

            do {
                try data.write(to: destination, options: [.atomic])
            } catch {
                continue
            }

            staged.append(
                CodexQueuedAttachment(
                    id: attachment.id,
                    displayName: attachment.displayName,
                    mimeType: attachment.mimeType,
                    byteCount: attachment.byteCount ?? data.count,
                    storedPath: destination.path
                )
            )
        }

        return staged
    }

    private func loadQueuedAttachmentPayloads(_ attachments: [CodexQueuedAttachment]) -> [QueuedAttachmentPayload] {
        guard !attachments.isEmpty else { return [] }
        var payloads: [QueuedAttachmentPayload] = []
        payloads.reserveCapacity(attachments.count)

        for attachment in attachments {
            let stored = attachment.storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stored.isEmpty else { continue }
            let url = URL(fileURLWithPath: stored)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            payloads.append(
                QueuedAttachmentPayload(
                    attachment: attachment,
                    data: data,
                    base64: data.base64EncodedString()
                )
            )
        }
        return payloads
    }

    private func makeLocalEchoContent(text: String, queuedAttachments: [QueuedAttachmentPayload]) -> [CodexUserInput] {
        var content: [CodexUserInput] = []

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            content.append(CodexUserInput(type: "text", text: trimmed, url: nil, path: nil))
        }

        for payload in queuedAttachments {
            let mimeType = (payload.attachment.mimeType ?? "").lowercased()
            if mimeType.hasPrefix("image/"),
               let localPath = stageAttachmentImageLocally(data: payload.data, fileName: payload.attachment.displayName) {
                content.append(CodexUserInput(type: "localImage", text: nil, url: nil, path: localPath))
            } else {
                let name = payload.attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = name.isEmpty ? "attachment" : name
                content.append(CodexUserInput(type: "text", text: "[Attachment] \(label)", url: nil, path: nil))
            }
        }

        return content
    }

    private func makeLocalEchoContent(text: String, composerAttachments: [ComposerAttachment]) -> [CodexUserInput] {
        var content: [CodexUserInput] = []

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            content.append(CodexUserInput(type: "text", text: trimmed, url: nil, path: nil))
        }

        for attachment in composerAttachments {
            guard let base64 = attachment.inlineDataBase64,
                  let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
                  !data.isEmpty
            else { continue }

            let mimeType = (attachment.mimeType ?? "").lowercased()
            if mimeType.hasPrefix("image/"),
               let localPath = stageAttachmentImageLocally(data: data, fileName: attachment.displayName) {
                content.append(CodexUserInput(type: "localImage", text: nil, url: nil, path: localPath))
            } else {
                let name = attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = name.isEmpty ? "attachment" : name
                content.append(CodexUserInput(type: "text", text: "[Attachment] \(label)", url: nil, path: nil))
            }
        }

        return content
    }

    private func makeCodexSteerInputParts(text: String, queuedAttachments: [QueuedAttachmentPayload]) -> [CodexTurnInputPart] {
        var parts: [CodexTurnInputPart] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(
                CodexTurnInputPart(
                    type: "text",
                    text: trimmed,
                    url: nil,
                    path: nil,
                    name: nil,
                    mimeType: nil,
                    inlineDataBase64: nil
                )
            )
        }

        for payload in queuedAttachments {
            let name = payload.attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = name.isEmpty ? "attachment" : name
            parts.append(
                CodexTurnInputPart(
                    type: "attachment",
                    text: nil,
                    url: nil,
                    path: nil,
                    name: safeName,
                    mimeType: payload.attachment.mimeType,
                    inlineDataBase64: payload.base64
                )
            )
        }

        return parts
    }

    private func sendCodexQueuedInputAsNextTurn(projectID: UUID, sessionID: UUID, queuedItemID: UUID) {
        guard let store else { return }
        store.ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        let queue = store.codexQueuedInputsBySession[sessionID] ?? []
        guard let item = queue.first(where: { $0.id == queuedItemID }) else { return }

        let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloads = loadQueuedAttachmentPayloads(item.attachments)
        let composerAttachments = payloads.map { payload in
            ComposerAttachment(
                id: payload.attachment.id,
                displayName: payload.attachment.displayName,
                mimeType: payload.attachment.mimeType,
                inlineDataBase64: payload.base64,
                byteCount: payload.data.count
            )
        }

        guard !trimmedText.isEmpty || !composerAttachments.isEmpty else {
            updateCodexQueuedInput(sessionID: sessionID, itemID: queuedItemID) { queued in
                queued.status = .failed
                queued.error = "Queued input is empty."
            }
            return
        }

        updateCodexQueuedInput(sessionID: sessionID, itemID: queuedItemID) { queued in
            queued.status = .sending
            queued.error = nil
        }

        let storedPaths = item.attachments.map(\.storedPath)
        sendCodexTurnMessage(
            projectID: projectID,
            sessionID: sessionID,
            text: trimmedText,
            attachments: composerAttachments,
            drainingQueuedItem: (id: queuedItemID, attachmentPaths: storedPaths)
        )
    }

    private func sendCodexTurnMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachments: [ComposerAttachment],
        drainingQueuedItem: (id: UUID, attachmentPaths: [String])? = nil
    ) {
        guard let store else { return }
        store.streamingSessions.insert(sessionID)
        store.codexStatusTextBySession[sessionID] = "connecting"
        store.codexPendingThreadBindingSessions.insert(sessionID)

        Task { [weak self] in
            guard let self else { return }
            guard let store = self.store else { return }
            let codexReady = await store.ensureCodexConnectedForChat()
            guard codexReady else {
                store.lastGatewayErrorMessage = "Codex backend is selected, but /codex is not connected."
                store.codexStatusTextBySession[sessionID] = "failed"
                store.codexActiveTurnIDBySession[sessionID] = nil
                if let draining = drainingQueuedItem {
                    self.rollbackSteerOptimisticEcho(sessionID: sessionID, queueItemID: draining.id)
                    self.updateCodexQueuedInput(sessionID: sessionID, itemID: draining.id) { queued in
                        queued.status = .failed
                        queued.error = "Codex backend is not connected."
                    }
                }
                store.streamingSessions.remove(sessionID)
                store.codexPendingThreadBindingSessions.remove(sessionID)
                return
            }

            guard let threadId = await self.resolveCodexThreadId(projectID: projectID, sessionID: sessionID) else {
                store.lastGatewayErrorMessage = "Session is missing codex thread mapping."
                store.codexStatusTextBySession[sessionID] = "failed"
                store.codexActiveTurnIDBySession[sessionID] = nil
                if let draining = drainingQueuedItem {
                    self.rollbackSteerOptimisticEcho(sessionID: sessionID, queueItemID: draining.id)
                    self.updateCodexQueuedInput(sessionID: sessionID, itemID: draining.id) { queued in
                        queued.status = .failed
                        queued.error = "Session is missing codex thread mapping."
                    }
                }
                store.streamingSessions.remove(sessionID)
                store.codexPendingThreadBindingSessions.remove(sessionID)
                return
            }

            store.codexThreadBySession[sessionID] = threadId
            store.codexSessionByThread[threadId] = sessionID

            let input = await self.makeCodexInputParts(text: text, attachments: attachments)
            guard !input.isEmpty else {
                store.lastGatewayErrorMessage = "No Codex-compatible input was provided."
                store.codexStatusTextBySession[sessionID] = "failed"
                store.codexActiveTurnIDBySession[sessionID] = nil
                if let draining = drainingQueuedItem {
                    self.rollbackSteerOptimisticEcho(sessionID: sessionID, queueItemID: draining.id)
                    self.updateCodexQueuedInput(sessionID: sessionID, itemID: draining.id) { queued in
                        queued.status = .failed
                        queued.error = "No Codex-compatible input was provided."
                    }
                }
                store.streamingSessions.remove(sessionID)
                store.codexPendingThreadBindingSessions.remove(sessionID)
                return
            }

            let localEcho = self.makeLocalEchoContent(text: text, composerAttachments: attachments)
            let localEchoID = self.appendLocalCodexUserEcho(sessionID: sessionID, content: localEcho)
            let model = store.selectedModelId(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
            let planMode = store.planModeEnabled(for: sessionID)
            do {
                await store.composerService.awaitPendingPermissionSync(sessionID: sessionID)
                let response = try await store.requestCodex(
                    method: "turn/start",
                    params: CodexTurnStartParams(
                        threadId: threadId,
                        input: input,
                        model: model.isEmpty ? nil : model,
                        planMode: planMode
                    )
                )
                if let payload = response.result?.objectValue {
                    if let returnedThreadId = payload["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !returnedThreadId.isEmpty {
                        let previousThreadId = store.codexThreadBySession[sessionID]
                        if let previousThreadId, previousThreadId != returnedThreadId {
                            store.codexSessionByThread[previousThreadId] = nil
                        }
                        store.codexThreadBySession[sessionID] = returnedThreadId
                        store.codexSessionByThread[returnedThreadId] = sessionID
                    }
                    if let turn = payload["turn"]?.objectValue,
                       let status = turn["status"]?.stringValue {
                        store.codexStatusTextBySession[sessionID] = status
                    }
                    if let turn = payload["turn"]?.objectValue,
                       let turnId = turn["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !turnId.isEmpty {
                        store.codexActiveTurnIDBySession[sessionID] = turnId
                    }
                }
                store.codexPendingThreadBindingSessions.remove(sessionID)

                if let draining = drainingQueuedItem {
                    await MainActor.run {
                        self.removeQueuedCodexInput(
                            sessionID: sessionID,
                            queueItemID: draining.id,
                            deleteAttachmentFiles: true
                        )
                        self.finalizeSteerOptimisticEcho(queueItemID: draining.id)
                    }
                }
            } catch {
                if let localEchoID {
                    self.removeLocalCodexUserEcho(sessionID: sessionID, itemID: localEchoID)
                }
                store.lastGatewayErrorMessage = error.localizedDescription
                store.codexStatusTextBySession[sessionID] = "failed"
                store.codexActiveTurnIDBySession[sessionID] = nil
                if let draining = drainingQueuedItem {
                    await MainActor.run {
                        self.rollbackSteerOptimisticEcho(sessionID: sessionID, queueItemID: draining.id)
                        self.updateCodexQueuedInput(sessionID: sessionID, itemID: draining.id) { queued in
                            queued.status = .failed
                            queued.error = error.localizedDescription
                        }
                    }
                }
                store.streamingSessions.remove(sessionID)
                store.codexPendingThreadBindingSessions.remove(sessionID)
            }
        }
    }

    private func resolveCodexThreadId(projectID: UUID, sessionID: UUID) async -> String? {
        guard let store else { return nil }
        if let mapped = store.codexThreadBySession[sessionID], !mapped.isEmpty {
            return mapped
        }
        if let thread = store.sessions(for: projectID).first(where: { $0.id == sessionID })?.codexThreadId,
           !thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return thread
        }

        do {
            let response = try await store.requestCodex(
                method: "epoch/session/read",
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
            parts.append(
                CodexTurnInputPart(
                    type: "text",
                    text: trimmedText,
                    url: nil,
                    path: nil,
                    name: nil,
                    mimeType: nil,
                    inlineDataBase64: nil
                )
            )
        }

        for attachment in attachments {
            let base64 = attachment.inlineDataBase64?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !base64.isEmpty else { continue }
            let name = attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = name.isEmpty ? "attachment" : name
            parts.append(
                CodexTurnInputPart(
                    type: "attachment",
                    text: nil,
                    url: nil,
                    path: nil,
                    name: safeName,
                    mimeType: attachment.mimeType,
                    inlineDataBase64: base64
                )
            )
        }

        return parts
    }

    @discardableResult
    private func appendLocalCodexUserEcho(sessionID: UUID, content: [CodexUserInput]) -> String? {
        guard let store else { return nil }
        guard !content.isEmpty else { return nil }
        let localItemID = "\(AppStore.codexLocalUserItemPrefix)\(UUID().uuidString.lowercased())"

        let item = CodexThreadItem.userMessage(
            CodexUserMessageItem(
                type: "userMessage",
                id: localItemID,
                content: content
            )
        )

        let existing = store.codexItemsBySession[sessionID] ?? []
        store.codexItemsBySession[sessionID] = AppStore.upsertCodexItemPreservingLocalEchoes(
            items: existing,
            incoming: item
        )
        return localItemID
    }

    private func removeLocalCodexUserEcho(sessionID: UUID, itemID: String) {
        guard let store else { return }
        guard itemID.hasPrefix(AppStore.codexLocalUserItemPrefix) else { return }
        var items = store.codexItemsBySession[sessionID] ?? []
        items.removeAll { item in
            guard case let .userMessage(userMessage) = item else { return false }
            return userMessage.id == itemID
        }
        store.codexItemsBySession[sessionID] = items
    }

    private func stageAttachmentImageLocally(data: Data, fileName: String) -> String? {
        let cleaned = fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let ext = URL(fileURLWithPath: cleaned).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: cleaned).pathExtension
        let stem = URL(fileURLWithPath: cleaned).deletingPathExtension().lastPathComponent
        let finalName = "\(stem.isEmpty ? "image" : stem)-\(UUID().uuidString).\(ext)"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("epoch-codex-inputs").appendingPathComponent(finalName)
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
        guard let store else { return }
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

        store.livePlanBySession[sessionID] = nil
        store.activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
        store.streamingSessions.remove(sessionID)
        store.streamingAssistantMessageIDBySession[sessionID] = nil
    }

    func retryMessage(
        projectID: UUID,
        sessionID: UUID,
        fromMessageID messageID: UUID,
        modelIdOverride: String? = nil
    ) {
        guard let store else { return }
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
        guard let store else { return nil }
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
        guard let store else { return }
        var msgs = store.messagesBySession[sessionID, default: []]
        let resolvedMessage = message

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

    // MARK: - Session History

    func scheduleSessionHistoryPrefetch(projectID: UUID) {
        guard let store else { return }
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
        guard let store else { return }
        guard let gatewayClient = store.gatewayClient else { return }
        let now = Date()
        let hasLocalMessages = !(store.messagesBySession[sessionID]?.isEmpty ?? true)
        let hasStreamingState = store.streamingSessions.contains(sessionID)
        let hasInProgressStatus = false
        let hasTransientIncomplete = store.streamingAssistantMessageIDBySession[sessionID] != nil
        if AppStore.shouldSkipSessionHistoryRefresh(
            trigger: trigger,
            hasInFlightRequest: sessionHistoryRequestsInFlight.contains(sessionID),
            hasLocalMessages: hasLocalMessages,
            hasStreamingState: hasStreamingState,
            hasInProgressStatus: hasInProgressStatus,
            hasTransientIncomplete: hasTransientIncomplete,
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
        guard let store else { return }
        let now = Date()
        let hasLocalItems = !(store.codexItemsBySession[sessionID]?.isEmpty ?? true)
        let hasStreamingState = store.streamingSessions.contains(sessionID)
        let statusRaw = store.codexStatusTextBySession[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasInProgressStatus = statusRaw == "inprogress" || statusRaw == "in_progress" || statusRaw == "thinking"
        let hasTransientIncomplete =
            store.streamingAssistantMessageIDBySession[sessionID] != nil
            || store.codexPendingPromptBySession[sessionID] != nil
            || !(store.codexPendingApprovalsBySession[sessionID] ?? []).isEmpty
        if AppStore.shouldSkipSessionHistoryRefresh(
            trigger: trigger,
            hasInFlightRequest: sessionHistoryRequestsInFlight.contains(sessionID),
            hasLocalMessages: hasLocalItems,
            hasStreamingState: hasStreamingState,
            hasInProgressStatus: hasInProgressStatus,
            hasTransientIncomplete: hasTransientIncomplete,
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
                method: "epoch/session/read",
                params: CodexSessionReadParams(
                    projectId: AppStore.gatewayID(projectID),
                    sessionId: AppStore.gatewayID(sessionID),
                    includeTurns: true
                )
            )

            var session: Session = try store.decodeCodexResult(response.result, key: "session")
            let resultObject = response.result?.objectValue ?? [:]
            var thread: CodexThread?
            if let threadValue = resultObject["thread"] {
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
                let fetchedItems = AppStore.sanitizeCodexItemsForDisplay(Self.flattenCodexTurns(thread.turns))
                let existingItems = store.codexItemsBySession[sessionID] ?? []
                let latestTurnStatus = thread.turns.last?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let fetchedTurnInProgress = latestTurnStatus == "inprogress" || latestTurnStatus == "in_progress"
                let keepLocalInFlightItems =
                    fetchedTurnInProgress
                    || (latestTurnStatus == nil && store.streamingSessions.contains(sessionID))
                store.codexItemsBySession[sessionID] = keepLocalInFlightItems
                    ? Self.mergeHistoryItemsPreservingInFlightLocals(local: existingItems, fetched: fetchedItems)
                    : fetchedItems
                store.stageCodexImagesForDisplay(
                    sessionID: sessionID,
                    items: store.codexItemsBySession[sessionID] ?? []
                )
                if let lastStatus = thread.turns.last?.status {
                    store.codexStatusTextBySession[sessionID] = lastStatus
                    let normalizedStatus = lastStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if normalizedStatus == "inprogress" || normalizedStatus == "in_progress" {
                        store.streamingSessions.insert(sessionID)
                        if let activeTurnID = thread.turns.last?.id.trimmingCharacters(in: .whitespacesAndNewlines),
                           !activeTurnID.isEmpty {
                            store.codexActiveTurnIDBySession[sessionID] = activeTurnID
                        }
                    } else {
                        store.streamingSessions.remove(sessionID)
                        store.streamingAssistantMessageIDBySession[sessionID] = nil
                        store.codexActiveTurnIDBySession[sessionID] = nil
                    }
                } else if !keepLocalInFlightItems {
                    store.streamingSessions.remove(sessionID)
                    store.streamingAssistantMessageIDBySession[sessionID] = nil
                    store.codexActiveTurnIDBySession[sessionID] = nil
                }
            } else {
                store.codexItemsBySession[sessionID] = store.codexItemsBySession[sessionID] ?? []
                store.stageCodexImagesForDisplay(
                    sessionID: sessionID,
                    items: store.codexItemsBySession[sessionID] ?? []
                )
            }

            let contextPayload: SessionContextState? = {
                guard let payload = resultObject["context"] else { return nil }
                guard let data = try? store.gatewayJSONEncoder.encode(payload) else { return nil }
                return try? store.gatewayJSONDecoder.decode(SessionContextState.self, from: data)
            }()
            if let contextPayload {
                store.sessionContextBySession[sessionID] = contextPayload
                if let level = AppStore.parsePermissionLevel(contextPayload.permissionLevel) {
                    store.permissionLevelBySession[sessionID] = level
                }

                let usageThreadId = (
                    thread?.id
                    ?? session.codexThreadId
                    ?? store.codexThreadBySession[sessionID]
                    ?? store.codexTokenUsageBySession[sessionID]?.threadId
                    ?? ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !usageThreadId.isEmpty {
                    store.codexTokenUsageBySession[sessionID] = CodexTokenUsage(
                        threadId: usageThreadId,
                        inputTokens: contextPayload.usedInputTokens,
                        outputTokens: nil,
                        totalTokens: contextPayload.usedTokens,
                        contextWindowTokens: contextPayload.contextWindowTokens,
                        remainingTokens: contextPayload.remainingTokens,
                        model: contextPayload.modelId
                    )
                }
            }

            let pendingInputs: [CodexSessionReadPendingInputPayload] = {
                guard let payload = resultObject["pendingUserInputs"] else { return [] }
                guard let data = try? store.gatewayJSONEncoder.encode(payload) else { return [] }
                return (try? store.gatewayJSONDecoder.decode([CodexSessionReadPendingInputPayload].self, from: data)) ?? []
            }()
            var hydratedPrompts: [CodexPendingPrompt] = []
            var hydratedApprovals: [CodexPendingApproval] = []
            for pending in pendingInputs {
                let kind = pending.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
                switch pending.method {
                case "item/tool/requestUserInput":
                    let paramsObject = pending.params?.objectValue ?? [:]
                    let promptThreadID =
                        paramsObject["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? thread?.id
                        ?? session.codexThreadId
                        ?? store.codexThreadBySession[sessionID]
                        ?? ""
                    let questions = Self.decodeCodexPromptQuestions(from: paramsObject)
                    hydratedPrompts.append(
                        CodexPendingPrompt(
                            requestID: pending.requestId,
                            sessionID: sessionID,
                            threadId: promptThreadID,
                            turnId: paramsObject["turnId"]?.stringValue,
                            kind: (kind?.isEmpty ?? true) ? "prompt" : kind!,
                            prompt: paramsObject["prompt"]?.stringValue ?? paramsObject["message"]?.stringValue,
                            questions: questions,
                            rawParams: pending.params
                        )
                    )
                case CodexApprovalKind.commandExecution.rawValue, CodexApprovalKind.fileChange.rawValue:
                    let paramsObject = pending.params?.objectValue ?? [:]
                    let approvalKind: CodexApprovalKind = pending.method == CodexApprovalKind.commandExecution.rawValue
                        ? .commandExecution
                        : .fileChange
                    hydratedApprovals.append(
                        CodexPendingApproval(
                            requestID: pending.requestId,
                            kind: approvalKind,
                            sessionID: sessionID,
                            threadId: paramsObject["threadId"]?.stringValue ?? (thread?.id ?? session.codexThreadId ?? ""),
                            turnId: paramsObject["turnId"]?.stringValue,
                            itemId: paramsObject["itemId"]?.stringValue,
                            reason: paramsObject["reason"]?.stringValue,
                            command: paramsObject["command"]?.stringValue,
                            cwd: paramsObject["cwd"]?.stringValue,
                            grantRoot: paramsObject["grantRoot"]?.stringValue,
                            rawParams: pending.params
                        )
                    )
                default:
                    continue
                }
            }
            store.codexPendingPromptBySession[sessionID] = hydratedPrompts.isEmpty ? nil : hydratedPrompts
            store.codexPendingApprovalsBySession[sessionID] = hydratedApprovals
            store.refreshSessionPendingUserInputMetadata(sessionID: sessionID)

            let activePlanPayload: CodexSessionReadActivePlanPayload? = {
                guard let payload = resultObject["activePlan"] else { return nil }
                guard let data = try? store.gatewayJSONEncoder.encode(payload) else { return nil }
                return try? store.gatewayJSONDecoder.decode(CodexSessionReadActivePlanPayload.self, from: data)
            }()
            if let activePlanPayload, !activePlanPayload.plan.isEmpty {
                let normalizedSteps = activePlanPayload.plan.map { step in
                    AgentPlanUpdatedPayload.PlanItem(
                        step: step.step,
                        status: Self.normalizeCodexPlanStatus(step.status)
                    )
                }
                store.livePlanBySession[sessionID] = AgentPlanUpdatedPayload(
                    agentRunId: UUID(),
                    projectId: projectID,
                    sessionId: sessionID,
                    explanation: activePlanPayload.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
                    plan: normalizedSteps
                )
            } else if let existingPlan = store.livePlanBySession[sessionID],
                      AppStore.codexPlanIsTerminal(existingPlan) {
                store.livePlanBySession[sessionID] = nil
            }
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
        guard let store else { return }
        let sortedMessages = messages.sorted(by: AppStore.messageDisplayOrder)
        store.messagesBySession[sessionID] = sortedMessages
        store.composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: Set(sortedMessages.map(\.id)))
        sessionHistoryLastFetchedAtBySession[sessionID] = fetchedAt
        reconcileInlineProcessAfterHistorySync(projectID: projectID, sessionID: sessionID, messages: sortedMessages)
    }

    // MARK: - Private Helpers

    private static func decodeCodexPromptQuestions(from params: [String: JSONValue]) -> [CodexPromptQuestion] {
        guard let questions = params["questions"]?.arrayValue else { return [] }
        return questions.compactMap { value -> CodexPromptQuestion? in
            guard let questionObject = value.objectValue else { return nil }
            let questionID = codexPromptString(questionObject["id"]) ?? "response"
            let questionHeader = codexPromptString(questionObject["header"])
            let questionPrompt = codexPromptString(questionObject["question"])
                ?? codexPromptString(questionObject["prompt"])
                ?? ""
            let questionIsOther = questionObject["isOther"]?.boolValue ?? false

            let options: [CodexPromptOption] = {
                guard let rawOptions = questionObject["options"]?.arrayValue else { return [] }
                return rawOptions.compactMap { optionValue -> CodexPromptOption? in
                    guard let optionObject = optionValue.objectValue else { return nil }
                    guard let label = codexPromptString(optionObject["label"]), !label.isEmpty else { return nil }
                    let optionID = codexPromptString(optionObject["id"]) ?? label
                    let description = codexPromptString(optionObject["description"])
                    let isOther = optionObject["isOther"]?.boolValue ?? false
                    return CodexPromptOption(
                        id: optionID,
                        label: label,
                        description: description,
                        isOther: isOther
                    )
                }
            }()

            return CodexPromptQuestion(
                id: questionID,
                header: questionHeader,
                prompt: questionPrompt,
                isOther: questionIsOther,
                options: options
            )
        }
    }

    private static func codexPromptString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let raw: String
        switch value {
        case let .string(text):
            raw = text
        case let .number(number):
            raw = String(number)
        case let .bool(flag):
            raw = flag ? "true" : "false"
        default:
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeCodexPlanStatus(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "inprogress", "in_progress":
            return "in_progress"
        case "completed":
            return "completed"
        default:
            return "pending"
        }
    }

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
            return thread.turns.lastIndex(where: { turn in
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
                    mostRecentUserInput = AppStore.sanitizeCodexUserContentForDisplay(user.content)
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
                    return AppStore.sanitizeCodexUserContentForDisplay(user.content)
                }
            }
        }

        return []
    }

    private static func codexTurnInputParts(from inputs: [CodexUserInput]) -> [CodexTurnInputPart] {
        var parts: [CodexTurnInputPart] = []
        for input in AppStore.sanitizeCodexUserContentForDisplay(inputs) {
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

    private static func codexUserInputs(from inputParts: [CodexTurnInputPart]) -> [CodexUserInput] {
        var result: [CodexUserInput] = []
        for part in inputParts {
            let type = part.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch type {
            case "text":
                let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    result.append(CodexUserInput(type: "text", text: text, url: nil, path: nil))
                }
            case "localimage":
                let path = part.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty {
                    result.append(CodexUserInput(type: "localImage", text: nil, url: nil, path: path))
                }
            case "image":
                let url = part.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !url.isEmpty {
                    result.append(CodexUserInput(type: "image", text: nil, url: url, path: nil))
                }
            default:
                continue
            }
        }
        return result
    }

    internal static func mergeHistoryItemsPreservingInFlightLocals(
        local: [CodexThreadItem],
        fetched: [CodexThreadItem]
    ) -> [CodexThreadItem] {
        guard !local.isEmpty else { return fetched }
        guard !fetched.isEmpty else { return local }

        var merged = fetched
        let fetchedIDs = Set(fetched.map(\.id))
        let fetchedUserSignatures = Set(
            fetched.compactMap { item -> String? in
                guard case let .userMessage(user) = item else { return nil }
                let signature = AppStore.codexUserContentSignature(user.content)
                return signature.isEmpty ? nil : signature
            }
        )

        for localItem in local {
            if fetchedIDs.contains(localItem.id) {
                guard case let .agentMessage(localAgent) = localItem,
                      let fetchedIndex = merged.firstIndex(where: { $0.id == localItem.id }),
                      case let .agentMessage(fetchedAgent) = merged[fetchedIndex],
                      localAgent.text.count > fetchedAgent.text.count
                else { continue }
                merged[fetchedIndex] = .agentMessage(localAgent)
                continue
            }

            if case let .userMessage(localUser) = localItem,
               localUser.id.hasPrefix(AppStore.codexLocalUserItemPrefix) {
                let signature = AppStore.codexUserContentSignature(localUser.content)
                if !signature.isEmpty, fetchedUserSignatures.contains(signature) {
                    continue
                }
            }

            merged.append(localItem)
        }
        return merged
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
        guard let store else { return }
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

    private func clearLiveAgentEvents(sessionID: UUID) {
        guard let store else { return }
        store.liveAgentEventsBySession[sessionID] = []
    }

    private func beginInlineProcess(sessionID: UUID, runID: UUID) {
        guard let store else { return }
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

    private func finalizeInlineProcess(
        sessionID: UUID,
        failed: Bool,
        assistantMessageIDFallback: UUID? = nil
    ) {
        guard let store else { return }
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
        guard let store else { return }
        guard store.activeInlineProcessBySession[sessionID] != nil else { return }
        guard !hasActiveRun(projectID: projectID, sessionID: sessionID) else { return }

        if let assistantMessageID = AppStore.latestAssistantReplyID(in: messages) {
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

        if let lastMessage = messages.last, lastMessage.role == .user {
            return
        }

        store.streamingAssistantMessageIDBySession[sessionID] = nil
        store.streamingSessions.remove(sessionID)
        store.activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
    }

    private func hasActiveRun(projectID: UUID, sessionID: UUID) -> Bool {
        guard let store else { return false }
        return store.projectService.hasActiveRun(projectID: projectID, sessionID: sessionID)
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

}
