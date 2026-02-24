#if os(iOS)
import LabOSCore
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SessionChatView: View {
    let projectID: UUID
    let sessionID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var composerText = ""
    @State private var renameSessionPresented = false
    @State private var deleteSessionPresented = false
    @State private var showFileSheet = false
    @State private var showPhotoPicker = false
    @State private var showCameraCapture = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var importErrorMessage: String?
    @State private var editingMessageID: UUID?
    @State private var composerHeight: CGFloat = 0
    @State private var runProgressHeight: CGFloat = 0
    @State private var isRunProgressExpanded = false
    @State private var planCardHeight: CGFloat = 0
    @State private var isPlanCardExpanded = false
    @State private var autoScrollEnabled = true
    @State private var scrollViewHeight: CGFloat = 0
    @State private var bottomDistance: CGFloat = 0
    @State private var isUserDragging = false
    @State private var autoScrollWork: DispatchWorkItem?
    @State private var lastAutoScrollAt: Date = .distantPast

    private let bottomAnchorID = "__bottom__"
    private let scrollCoordinateSpace = "__chatScroll__"
    private let bottomProximityThreshold: CGFloat = 44
    private let maxInlineAttachmentBytes = 900 * 1024
    private let maxInlinePhotoDimension: CGFloat = 1_536

    private var activeBackendEngine: String {
        normalizedBackendEngine(
            store.backendEngine(for: sessionID) ?? session?.backendEngine ?? store.preferredBackendEngine
        )
    }

    private var session: Session? {
        store.sessions(for: projectID).first(where: { $0.id == sessionID })
    }

    private var messages: [ChatMessage] {
        store.messages(for: sessionID)
    }

    private var codexItems: [CodexThreadItem] {
        store.codexItems(for: sessionID)
    }

    private var isCodexSession: Bool {
        store.sessionUsesCodex(sessionID: sessionID)
    }

    private var codexApprovals: [CodexPendingApproval] {
        store.codexPendingApprovals(for: sessionID)
    }

    private var codexPrompt: CodexPendingPrompt? {
        store.codexPendingPrompt(for: sessionID)
    }

    private var codexStatusText: String? {
        displayCodexStatus(store.codexStatusText(for: sessionID))
    }

    private var activeRun: RunRecord? {
        store.runs(for: projectID).first { run in
            run.sessionID == sessionID && (run.status == .queued || run.status == .running)
        }
    }

    private var runProgressAnimation: Animation {
        .interactiveSpring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.12)
    }

    private var runProgressContentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
                .combined(with: .offset(y: -6)),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }

    private var bottomOverlayPadding: CGFloat {
        composerHeight + runProgressHeight + planCardHeight + 20
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isCodexSession {
                            CodexItemTimelineView(
                                items: codexItems,
                                statusText: codexStatusText,
                                isStreaming: store.streamingSessions.contains(sessionID),
                                modelOptions: store.availableModels,
                                selectedModelId: store.selectedModelId(for: sessionID),
                                showAssistantActionBar: true,
                                onEditUserMessage: { item in
                                    editCodexUserMessage(item)
                                },
                                onRetryAgentMessage: { item, modelIdOverride in
                                    retryCodexAgentMessage(item, modelIdOverride: modelIdOverride)
                                },
                                onBranchAgentMessage: { item in
                                    branchFromCodexAgentMessage(item)
                                }
                            )
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                            if codexItems.isEmpty {
                                Text("Codex session ready.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                            }
                        } else {
                            ForEach(messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    modelOptions: store.availableModels,
                                    onArtifactTap: { ref in
                                        store.openArtifactReference(ref)
                                    },
                                    onEditMessage: { msg in
                                        editMessage(msg)
                                    },
                                    onRetryMessage: { msg, modelId in
                                        retryMessage(msg, modelIdOverride: modelId)
                                    },
                                    onBranchMessage: { msg in
                                        branchFromMessage(msg)
                                    },
                                    showAssistantActionBar: !store.sessionUsesCodex(sessionID: sessionID)
                                )
                            }

                            if let pendingProcess = store.pendingInlineProcess(for: sessionID),
                               let activeLine = pendingProcess.activeLine {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        AssistantProcessInlineView(
                                            activeLine: activeLine,
                                            isBlinking: pendingProcess.phase == .thinking,
                                            summary: nil
                                        )
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .accessibilityIdentifier("session.pending.process")
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ChatBottomAnchorMaxYPreferenceKey.self,
                                        value: proxy.frame(in: .named(scrollCoordinateSpace)).maxY
                                    )
                                }
                            )
                    }
                    .padding(.top, 10)
                    .padding(.bottom, bottomOverlayPadding)
                }
                .coordinateSpace(name: scrollCoordinateSpace)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ChatScrollViewHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
                .onPreferenceChange(ChatScrollViewHeightPreferenceKey.self) { scrollViewHeight = $0 }
                .onPreferenceChange(ChatBottomAnchorMaxYPreferenceKey.self) { bottomMaxY in
                    let distance = bottomMaxY - scrollViewHeight
                    bottomDistance = distance
                    if !isUserDragging, distance <= bottomProximityThreshold {
                        autoScrollEnabled = true
                    }
                    if AppStore.shouldAutoScrollOnIncomingDelta(),
                       autoScrollEnabled,
                       !isUserDragging,
                       distance > bottomProximityThreshold + 1 {
                        requestAutoScroll(proxy: proxy, animated: false)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if value.translation.height > 8 {
                                isUserDragging = true
                                autoScrollEnabled = false
                            }
                        }
                        .onEnded { _ in
                            isUserDragging = false
                            if bottomDistance <= bottomProximityThreshold {
                                autoScrollEnabled = true
                            }
                        }
                )
                .onChange(of: messages.count) { _, _ in
                    guard AppStore.shouldAutoScrollOnIncomingMessage() else { return }
                    guard autoScrollEnabled else { return }
                    requestAutoScroll(proxy: proxy, animated: false)
                }
                .onChange(of: codexItems.count) { _, _ in
                    guard isCodexSession else { return }
                    guard autoScrollEnabled else { return }
                    requestAutoScroll(proxy: proxy, animated: false)
                }
                .onChange(of: messages.last?.text) { _, _ in
                    guard AppStore.shouldAutoScrollOnIncomingDelta() else { return }
                    guard autoScrollEnabled else { return }
                    guard store.streamingAssistantMessageIDBySession[sessionID] == messages.last?.id else { return }
                    requestAutoScroll(proxy: proxy, animated: false)
                }
                .onChange(of: store.streamingAssistantMessageIDBySession[sessionID]) { _, newValue in
                    guard AppStore.shouldAutoScrollWhenStreamingCompletes() else { return }
                    guard autoScrollEnabled else { return }
                    guard newValue == nil else { return }
                    requestAutoScroll(proxy: proxy, animated: false)
                }
                .onAppear {
                    guard AppStore.shouldAutoScrollOnInitialAppear(hasMessages: !messages.isEmpty) else { return }
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: autoScrollEnabled) { _, enabled in
                    if !enabled {
                        autoScrollWork?.cancel()
                        autoScrollWork = nil
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let run = activeRun {
                    runProgressCard(run)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: RunProgressHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                } else if !isCodexSession, let plan = store.livePlanBySession[sessionID] {
                    agentPlanCard(plan)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: AgentPlanHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                }

                ForEach(codexApprovals) { approval in
                    codexApprovalCard(approval)
                        .padding(.horizontal, 12)
                }

                sessionComposer
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 2)
            }
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { composerHeight = $0 }
        .onPreferenceChange(RunProgressHeightPreferenceKey.self) { value in
            let nextHeight = activeRun == nil ? 0 : value
            guard abs(runProgressHeight - nextHeight) > 0.5 else { return }
            withAnimation(runProgressAnimation) {
                runProgressHeight = nextHeight
            }
        }
        .onPreferenceChange(AgentPlanHeightPreferenceKey.self) { value in
            let nextHeight = !isCodexSession && activeRun == nil && store.livePlanBySession[sessionID] != nil ? value : 0
            guard abs(planCardHeight - nextHeight) > 0.5 else { return }
            withAnimation(runProgressAnimation) {
                planCardHeight = nextHeight
            }
        }
        .onChange(of: activeRun?.id) { _, runID in
            withAnimation(runProgressAnimation) {
                isRunProgressExpanded = false
                isPlanCardExpanded = false
                if runID == nil {
                    runProgressHeight = 0
                }
            }
        }
        .onChange(of: activeRun?.status) { _, status in
            guard status == nil else { return }
            withAnimation(runProgressAnimation) {
                isRunProgressExpanded = false
                runProgressHeight = 0
            }
        }
        .sheet(isPresented: $renameSessionPresented) {
            NamePromptSheet(
                title: "Rename Session",
                placeholder: "Session title",
                confirmLabel: "Save",
                initialValue: session?.title ?? "",
                onConfirm: { value in
                    store.renameSession(projectID: projectID, sessionID: sessionID, newTitle: value)
                    renameSessionPresented = false
                },
                onCancel: {
                    renameSessionPresented = false
                }
            )
        }
        .sheet(isPresented: $deleteSessionPresented) {
            if let session {
                SessionDeleteSheet(session: session) {
                    store.deleteSession(projectID: projectID, sessionID: sessionID)
                    deleteSessionPresented = false
                } onCancel: {
                    deleteSessionPresented = false
                }
            }
        }
        .sheet(item: pendingApprovalBinding) { pending in
            PlanConfirmationSheet(
                plan: pending.plan,
                judgment: pending.judgment,
                onRun: { responses in
                    store.approvePlan(sessionID: sessionID, judgmentResponses: responses)
                },
                onCancel: {
                    store.cancelPlan(sessionID: sessionID)
                }
            )
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showFileSheet) {
            ComposerAttachmentsSheet(
                title: "Session Attachments",
                pendingAttachments: store.pendingComposerAttachments(for: sessionID),
                selectedRecentPhotoTokens: Set(store.pendingComposerAttachments(for: sessionID).compactMap(\.sourceToken)),
                onTakePhoto: {
                    showFileSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCameraCapture = true
                        } else {
                            importErrorMessage = "Camera is unavailable on this device."
                        }
                    }
                },
                onAddPhotos: {
                    showFileSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showPhotoPicker = true
                    }
                },
                onSelectRecentPhoto: { token in
                    toggleRecentPhotoAttachment(selectionToken: token)
                },
                onAddFiles: {
                    showFileSheet = false
                    showFileImporter = true
                },
                onAddTestPhoto: E2ETestAttachmentFactory.isEnabled ? {
                    if let attachment = E2ETestAttachmentFactory.makeFixturePhotoAttachment() {
                        store.addPendingComposerAttachments(sessionID: sessionID, attachments: [attachment])
                    }
                    showFileSheet = false
                } : nil,
                onDeleteAttachment: { id in
                    store.removePendingComposerAttachment(sessionID: sessionID, attachmentID: id)
                },
                onClose: {
                    showFileSheet = false
                }
            )
        }
        .sheet(isPresented: $showCameraCapture) {
            CameraCaptureSheet(
                onCapture: { image in
                    showCameraCapture = false
                    addCameraCaptureAttachment(image)
                },
                onCancel: {
                    showCameraCapture = false
                }
            )
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 20,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            let selected = items
            selectedPhotoItems = []
            Task {
                let attachments = await makePhotoAttachments(from: selected)
                await MainActor.run {
                    if attachments.count < selected.count {
                        importErrorMessage = "Some photos were skipped because they were too large to send inline."
                    }
                    let existingTokens = Set(store.pendingComposerAttachments(for: sessionID).compactMap(\.sourceToken))
                    let uniqueAttachments = attachments.filter { attachment in
                        guard let token = attachment.sourceToken else { return true }
                        return !existingTokens.contains(token)
                    }
                    if !uniqueAttachments.isEmpty {
                        store.addPendingComposerAttachments(sessionID: sessionID, attachments: uniqueAttachments)
                    }
                    showFileSheet = true
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .alert("Couldn’t import files", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "Unknown error")
        }
    }

    private func requestAutoScroll(proxy: ScrollViewProxy, animated: Bool) {
        let minInterval: TimeInterval = 0.08
        let now = Date()
        let elapsed = now.timeIntervalSince(lastAutoScrollAt)
        let delay = max(0, minInterval - elapsed)

        if delay == 0 {
            autoScrollWork?.cancel()
            autoScrollWork = nil
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            lastAutoScrollAt = Date()
            return
        }

        guard autoScrollWork == nil else { return }

        let work = DispatchWorkItem {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            lastAutoScrollAt = Date()
            autoScrollWork = nil
        }
        autoScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func displayCodexStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        switch lower {
        case "completed", "failed":
            return nil
        case "inprogress", "in_progress", "running", "thinking":
            return "Thinking..."
        default:
            if lower.contains("waiting for updates")
                || lower.contains("waiting for response")
                || lower == "reasoning" {
                return "Thinking..."
            }
            return trimmed
        }
    }

    @ViewBuilder
    private var sessionComposer: some View {
        if let prompt = codexPrompt {
            codexPromptComposer(prompt)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ComposerHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
        } else {
            InlineComposerView(
                placeholder: "Ask LabOS",
                text: $composerText,
                isPlanModeEnabled: Binding(
                    get: { store.planModeEnabled(for: sessionID) },
                    set: { store.setPlanModeEnabled(for: sessionID, enabled: $0) }
                ),
                selectedModelId: Binding(
                    get: { store.selectedModelId(for: sessionID) },
                    set: { store.setSelectedModelId(for: sessionID, modelId: $0) }
                ),
                selectedThinkingLevel: Binding(
                    get: { store.selectedThinkingLevel(for: sessionID) },
                    set: { store.setSelectedThinkingLevel(for: sessionID, level: $0) }
                ),
                selectedPermissionLevel: Binding(
                    get: {
                        if isCodexSession {
                            return store.codexFullAccessEnabled(for: sessionID) ? .full : .default
                        }
                        return store.permissionLevel(for: sessionID)
                    },
                    set: { level in
                        if !isCodexSession {
                            store.setPermissionLevel(projectID: projectID, sessionID: sessionID, level: level)
                        }
                    }
                ),
                submitLabel: editingMessageID == nil ? "Send" : "Update",
                style: .chatGPT,
                statusText: editingMessageID == nil ? nil : "Editing",
                statusIconSystemName: "pencil",
                statusAction: editingMessageID == nil ? nil : {
                    editingMessageID = nil
                    composerText = ""
                    store.clearPendingComposerAttachments(sessionID: sessionID)
                },
                attachmentAction: {
                    showFileSheet = true
                },
                pendingAttachments: store.pendingComposerAttachments(for: sessionID),
                onRemoveAttachment: { attachmentID in
                    store.removePendingComposerAttachment(sessionID: sessionID, attachmentID: attachmentID)
                },
                modelOptions: store.availableModels,
                thinkingLevelOptions: store.availableThinkingLevels.isEmpty ? ThinkingLevel.allCases : store.availableThinkingLevels,
                contextRemainingFraction: store.contextRemainingFraction(for: sessionID),
                contextWindowTokens: store.contextWindowTokens(for: sessionID) ?? 258_000,
                useEstimatedContextFallback: !isCodexSession
            ) {
                let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachments = store.pendingComposerAttachments(for: sessionID)
                guard !text.isEmpty || !attachments.isEmpty else { return }
                    if let editingMessageID {
                        store.overwriteUserMessage(
                            projectID: projectID,
                            sessionID: sessionID,
                            messageID: editingMessageID,
                            text: text
                        )
                        self.editingMessageID = nil
                    } else {
                        store.sendMessage(projectID: projectID, sessionID: sessionID, text: text, attachments: attachments)
                    }
                composerText = ""
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ComposerHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
        }
    }

    private func codexPromptComposer(_ prompt: CodexPendingPrompt) -> some View {
        let quickQuestion = codexQuickPromptQuestion(prompt)
        return VStack(alignment: .leading, spacing: 10) {
            Text(prompt.prompt ?? "Codex is waiting for input")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let quickQuestion, !quickQuestion.options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !quickQuestion.prompt.isEmpty {
                        Text(quickQuestion.prompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(quickQuestion.options, id: \.id) { option in
                        Button(option.label) {
                            store.respondToCodexPrompt(
                                sessionID: sessionID,
                                requestID: prompt.requestID,
                                answers: [quickQuestion.id: option.label]
                            )
                            composerText = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            TextField("Type your response", text: $composerText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Cancel") {
                    store.respondToCodexPrompt(sessionID: sessionID, requestID: prompt.requestID, answers: [:])
                    composerText = ""
                }
                .buttonStyle(.bordered)

                Button("Send Response") {
                    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.respondToCodexPrompt(
                        sessionID: sessionID,
                        requestID: prompt.requestID,
                        answers: codexPromptTextAnswer(prompt, text: text)
                    )
                    composerText = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private struct CodexPromptOption {
        var id: String
        var label: String
    }

    private struct CodexPromptQuestion {
        var id: String
        var prompt: String
        var options: [CodexPromptOption]
    }

    private func codexQuickPromptQuestion(_ prompt: CodexPendingPrompt) -> CodexPromptQuestion? {
        guard case let .object(params)? = prompt.rawParams else { return nil }
        guard case let .array(questions)? = params["questions"], questions.count == 1 else { return nil }
        guard case let .object(question)? = questions.first else { return nil }

        let id = codexPromptString(question["id"]) ?? "response"
        let promptText = codexPromptString(question["question"]) ?? ""
        let options: [CodexPromptOption] = {
            guard case let .array(rawOptions)? = question["options"] else { return [] }
            return rawOptions.compactMap { value -> CodexPromptOption? in
                guard case let .object(object) = value else { return nil }
                guard let label = codexPromptString(object["label"]), !label.isEmpty else {
                    return nil
                }
                let optionId = codexPromptString(object["id"]) ?? label
                return CodexPromptOption(id: optionId, label: label)
            }
        }()
        guard !options.isEmpty else { return nil }
        return CodexPromptQuestion(id: id, prompt: promptText, options: options)
    }

    private func codexPromptString(_ value: JSONValue?) -> String? {
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
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func codexPromptTextAnswer(_ prompt: CodexPendingPrompt, text: String) -> [String: String] {
        if let question = codexQuickPromptQuestion(prompt) {
            return [question.id: text]
        }
        return ["response": text]
    }

    private func codexApprovalCard(_ approval: CodexPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.kind == .commandExecution ? "Command approval needed" : "File change approval needed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
            }
            if let command = approval.command, !command.isEmpty {
                Text(command)
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            HStack(spacing: 8) {
                Button("Accept Once") {
                    store.respondToCodexApproval(sessionID: sessionID, requestID: approval.requestID, decision: "accept")
                }
                .buttonStyle(.borderedProminent)
                Button("Accept Similar") {
                    store.respondToCodexApproval(sessionID: sessionID, requestID: approval.requestID, decision: "acceptForSession")
                }
                .buttonStyle(.bordered)
                Button("Reject") {
                    store.respondToCodexApproval(sessionID: sessionID, requestID: approval.requestID, decision: "decline")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            let valid = urls.compactMap(makeFileAttachment(from:))
                .filter { !$0.displayName.isEmpty }
            if valid.count < urls.count {
                importErrorMessage = "Some files were skipped because each attachment must be 4 MB or smaller."
            }
            guard !valid.isEmpty else { return }
            store.addPendingComposerAttachments(sessionID: sessionID, attachments: valid)
        case let .failure(error):
            importErrorMessage = error.localizedDescription
        }
    }

    private func makePhotoAttachments(from items: [PhotosPickerItem]) async -> [ComposerAttachment] {
        let timestamp = Int(Date().timeIntervalSince1970)
        var results: [ComposerAttachment] = []
        var cacheSeeds: [CachedInlinePhotoSeed] = []
        results.reserveCapacity(items.count)
        cacheSeeds.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let selectionToken = photoSelectionToken(for: item, index: index)
            let mimeType = item.supportedContentTypes.first?.preferredMIMEType
            let data = try? await item.loadTransferable(type: Data.self)
            let preferredExt = item.supportedContentTypes.first?.preferredFilenameExtension
            guard let normalized = normalizedInlinePayload(
                from: data,
                mimeType: mimeType,
                fileExtension: preferredExt
            ) else { continue }
            let finalExt = normalized.fileExtension ?? "jpg"
            results.append(
                ComposerAttachment(
                    displayName: "photo-\(timestamp)-\(index + 1).\(finalExt)",
                    mimeType: normalized.mimeType ?? "image/jpeg",
                    inlineDataBase64: normalized.data.base64EncodedString(),
                    byteCount: normalized.data.count,
                    sourceToken: selectionToken
                )
            )
            cacheSeeds.append(
                CachedInlinePhotoSeed(
                    token: selectionToken,
                    sourceIdentifier: item.itemIdentifier,
                    data: normalized.data,
                    mimeType: normalized.mimeType ?? "image/jpeg",
                    fileExtension: finalExt,
                    thumbnailData: normalized.data
                )
            )
        }
        await RecentInlinePhotoCache.shared.remember(cacheSeeds)
        return results
    }

    private func addCameraCaptureAttachment(_ image: UIImage) {
        guard let seedData = image.jpegData(compressionQuality: 0.92),
              let normalized = normalizedInlinePayload(from: seedData, mimeType: "image/jpeg", fileExtension: "jpg")
        else {
            importErrorMessage = "The captured photo was too large to attach."
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let attachment = ComposerAttachment(
            displayName: "camera-\(timestamp).\(normalized.fileExtension ?? "jpg")",
            mimeType: normalized.mimeType ?? "image/jpeg",
            inlineDataBase64: normalized.data.base64EncodedString(),
            byteCount: normalized.data.count
        )
        store.addPendingComposerAttachments(sessionID: sessionID, attachments: [attachment])
    }

    private func toggleRecentPhotoAttachment(selectionToken: String) {
        if let existing = store.pendingComposerAttachments(for: sessionID).first(where: { $0.sourceToken == selectionToken }) {
            store.removePendingComposerAttachment(sessionID: sessionID, attachmentID: existing.id)
            return
        }

        Task {
            if let cached = await RecentInlinePhotoCache.shared.payload(for: selectionToken),
               let normalized = normalizedInlinePayload(
                from: cached.data,
                mimeType: cached.mimeType,
                fileExtension: cached.fileExtension
               ) {
                let timestamp = Int(Date().timeIntervalSince1970)
                let ext = normalized.fileExtension ?? cached.fileExtension ?? "jpg"
                let attachment = ComposerAttachment(
                    displayName: "photo-\(timestamp).\(ext)",
                    mimeType: normalized.mimeType ?? "image/jpeg",
                    inlineDataBase64: normalized.data.base64EncodedString(),
                    byteCount: normalized.data.count,
                    sourceToken: selectionToken
                )

                await MainActor.run {
                    if store.pendingComposerAttachments(for: sessionID).contains(where: { $0.sourceToken == selectionToken }) {
                        return
                    }
                    store.addPendingComposerAttachments(sessionID: sessionID, attachments: [attachment])
                }
                return
            }

            let assetLocalIdentifier = selectionToken.hasPrefix("asset:")
                ? String(selectionToken.dropFirst("asset:".count))
                : selectionToken

            guard let payload = await loadPhotoAsset(localIdentifier: assetLocalIdentifier),
                  let normalized = normalizedInlinePayload(
                    from: payload.data,
                    mimeType: payload.mimeType,
                    fileExtension: payload.fileExtension
                  )
            else {
                await MainActor.run {
                    importErrorMessage = "The selected photo could not be added."
                }
                return
            }

            let timestamp = Int(Date().timeIntervalSince1970)
            let ext = normalized.fileExtension ?? payload.fileExtension ?? "jpg"
            let attachment = ComposerAttachment(
                displayName: "photo-\(timestamp).\(ext)",
                mimeType: normalized.mimeType ?? "image/jpeg",
                inlineDataBase64: normalized.data.base64EncodedString(),
                byteCount: normalized.data.count,
                sourceToken: selectionToken
            )

            await MainActor.run {
                if store.pendingComposerAttachments(for: sessionID).contains(where: { $0.sourceToken == selectionToken }) {
                    return
                }
                store.addPendingComposerAttachments(sessionID: sessionID, attachments: [attachment])
            }
        }
    }

    private func photoSelectionToken(for item: PhotosPickerItem, index: Int) -> String {
        if let identifier = item.itemIdentifier, !identifier.isEmpty {
            return "asset:\(identifier)"
        }
        return "inline:picker-\(Int(Date().timeIntervalSince1970))-\(index)-\(UUID().uuidString.lowercased())"
    }

    private func loadPhotoAsset(localIdentifier: String) async -> (data: Data, mimeType: String?, fileExtension: String?)? {
        await withCheckedContinuation { continuation in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = assets.firstObject else {
                continuation.resume(returning: nil)
                return
            }

            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current

            var didResume = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                guard !didResume else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                didResume = true

                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }

                let type = uti.flatMap { UTType($0) }
                continuation.resume(returning: (data, type?.preferredMIMEType, type?.preferredFilenameExtension))
            }
        }
    }

    private func makeFileAttachment(from url: URL) -> ComposerAttachment? {
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try? Data(contentsOf: url)
        guard let normalized = normalizedInlinePayload(from: data, mimeType: mimeType, fileExtension: url.pathExtension) else {
            return nil
        }
        let displayName = adjustedAttachmentDisplayName(
            original: url.lastPathComponent,
            preferredExtension: normalized.fileExtension
        )
        return ComposerAttachment(
            displayName: displayName,
            mimeType: normalized.mimeType,
            inlineDataBase64: normalized.data.base64EncodedString(),
            byteCount: normalized.data.count
        )
    }

    private struct NormalizedInlinePayload {
        var data: Data
        var mimeType: String?
        var fileExtension: String?
    }

    private func normalizedInlinePayload(from data: Data?, mimeType: String?, fileExtension: String?) -> NormalizedInlinePayload? {
        guard let data, !data.isEmpty else { return nil }

        let loweredMime = (mimeType ?? "").lowercased()
        let loweredExt = (fileExtension ?? "").lowercased()
        let isImage = loweredMime.hasPrefix("image/")
            || ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif"].contains(loweredExt)

        guard isImage else {
            guard data.count <= maxInlineAttachmentBytes else { return nil }
            return NormalizedInlinePayload(
                data: data,
                mimeType: mimeType,
                fileExtension: loweredExt.isEmpty ? nil : loweredExt
            )
        }

        let isHeicLike = loweredMime.contains("heic")
            || loweredMime.contains("heif")
            || loweredExt == "heic"
            || loweredExt == "heif"

        if data.count <= maxInlineAttachmentBytes && !isHeicLike {
            return NormalizedInlinePayload(
                data: data,
                mimeType: mimeType,
                fileExtension: loweredExt.isEmpty ? nil : loweredExt
            )
        }

        guard let image = UIImage(data: data),
              let normalizedJPEG = compressedImageDataForInlineSend(image) else {
            return nil
        }
        return NormalizedInlinePayload(
            data: normalizedJPEG,
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )
    }

    private func adjustedAttachmentDisplayName(original: String, preferredExtension: String?) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "attachment" }
        guard let preferredExtension, !preferredExtension.isEmpty else { return trimmed }
        let url = URL(fileURLWithPath: trimmed)
        let currentExt = url.pathExtension.lowercased()
        guard currentExt != preferredExtension.lowercased() else { return trimmed }
        let stem = url.deletingPathExtension().lastPathComponent
        let baseName = stem.isEmpty ? "attachment" : stem
        return "\(baseName).\(preferredExtension)"
    }

    private func compressedImageDataForInlineSend(_ image: UIImage) -> Data? {
        var working = resizedImageIfNeeded(image, maxDimension: maxInlinePhotoDimension)
        var compression: CGFloat = 0.82

        while compression >= 0.24 {
            if let encoded = working.jpegData(compressionQuality: compression),
               encoded.count <= maxInlineAttachmentBytes {
                return encoded
            }
            compression -= 0.12
        }

        while max(working.size.width, working.size.height) > 320 {
            let nextSize = CGSize(width: max(320, floor(working.size.width * 0.8)),
                                  height: max(320, floor(working.size.height * 0.8)))
            working = resizedImage(working, targetSize: nextSize)
            compression = 0.72
            while compression >= 0.2 {
                if let encoded = working.jpegData(compressionQuality: compression),
                   encoded.count <= maxInlineAttachmentBytes {
                    return encoded
                }
                compression -= 0.12
            }
        }

        return nil
    }

    private func resizedImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: max(1, floor(image.size.width * scale)),
                            height: max(1, floor(image.size.height * scale)))
        return resizedImage(image, targetSize: target)
    }

    private func resizedImage(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func editMessage(_ message: ChatMessage) {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editingMessageID = message.role == .user ? message.id : nil
        composerText = trimmed
    }

    private func editCodexUserMessage(_ item: CodexUserMessageItem) {
        let text = codexUserText(from: item.content)
        let attachments = codexComposerAttachments(from: item.content)
        editingMessageID = nil
        composerText = text
        store.clearPendingComposerAttachments(sessionID: sessionID)
        if !attachments.isEmpty {
            store.addPendingComposerAttachments(sessionID: sessionID, attachments: attachments)
        }
    }

    private func retryMessage(_ message: ChatMessage, modelIdOverride: String?) {
        store.retryMessage(
            projectID: projectID,
            sessionID: sessionID,
            fromMessageID: message.id,
            modelIdOverride: modelIdOverride
        )
    }

    private func retryCodexAgentMessage(_ item: CodexAgentMessageItem, modelIdOverride: String?) {
        if let modelIdOverride {
            let normalizedModel = modelIdOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedModel.isEmpty {
                store.setSelectedModelId(for: sessionID, modelId: normalizedModel)
            }
        }

        guard let source = codexRetrySource(for: item.id) else { return }
        store.sendMessage(
            projectID: projectID,
            sessionID: sessionID,
            text: source.text,
            attachments: source.attachments
        )
    }

    private func branchFromMessage(_ message: ChatMessage) {
        Task {
            _ = await store.branchFromMessage(
                projectID: projectID,
                sessionID: sessionID,
                fromMessageID: message.id
            )
        }
    }

    private func branchFromCodexAgentMessage(_ item: CodexAgentMessageItem) {
        Task {
            guard let source = codexRetrySource(for: item.id) else { return }

            let sourceTitle = session?.title
            let branchTitle = sourceTitle.map { "\($0) (Branch)" }

            guard let branched = await store.createSession(projectID: projectID, title: branchTitle) else { return }

            let selectedModel = store.selectedModelId(for: sessionID)
            let selectedThinking = store.selectedThinkingLevel(for: sessionID)
            let selectedPlanMode = store.planModeEnabled(for: sessionID)
            let selectedPermission = store.permissionLevel(for: sessionID)

            if !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.setSelectedModelId(for: branched.id, modelId: selectedModel)
            }
            store.setSelectedThinkingLevel(for: branched.id, level: selectedThinking)
            store.setPlanModeEnabled(for: branched.id, enabled: selectedPlanMode)
            store.setPermissionLevel(projectID: branched.projectID, sessionID: branched.id, level: selectedPermission)

            store.sendMessage(
                projectID: branched.projectID,
                sessionID: branched.id,
                text: source.text,
                attachments: source.attachments
            )
        }
    }

    private func codexRetrySource(for assistantItemID: String) -> (text: String, attachments: [ComposerAttachment])? {
        let assistantIndex = codexItems.lastIndex(where: { $0.id == assistantItemID })
        let candidateItems: ArraySlice<CodexThreadItem>
        if let assistantIndex {
            candidateItems = codexItems[..<assistantIndex]
        } else {
            candidateItems = codexItems[...]
        }

        let userItem = candidateItems.reversed().compactMap { item -> CodexUserMessageItem? in
            if case let .userMessage(userItem) = item {
                return userItem
            }
            return nil
        }.first

        guard let userItem else { return nil }

        let text = codexUserText(from: userItem.content)
        let attachments = codexComposerAttachments(from: userItem.content)
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        return (text: text, attachments: attachments)
    }

    private func codexUserText(from content: [CodexUserInput]) -> String {
        content
            .compactMap { input in
                if input.type.lowercased() == "text" {
                    return input.text
                }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func codexComposerAttachments(from content: [CodexUserInput]) -> [ComposerAttachment] {
        var attachments: [ComposerAttachment] = []

        let imageInputs = content.filter { input in
            let type = input.type.lowercased()
            if type == "localimage" { return true }
            if type == "image" {
                return input.path != nil || input.url != nil
            }
            return false
        }

        for (index, input) in imageInputs.enumerated() {
            guard let fileURL = codexInputFileURL(input) else { continue }
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }

            let fileExtension = fileURL.pathExtension
            let mimeType = UTType(filenameExtension: fileExtension.lowercased())?.preferredMIMEType
            guard let normalized = normalizedInlinePayload(
                from: fileData,
                mimeType: mimeType,
                fileExtension: fileExtension
            ) else { continue }

            let fallbackName = fileURL.lastPathComponent.isEmpty
                ? "image-\(index + 1).\(normalized.fileExtension ?? "jpg")"
                : fileURL.lastPathComponent
            let displayName = adjustedAttachmentDisplayName(
                original: fallbackName,
                preferredExtension: normalized.fileExtension
            )

            attachments.append(
                ComposerAttachment(
                    displayName: displayName,
                    mimeType: normalized.mimeType ?? "image/jpeg",
                    inlineDataBase64: normalized.data.base64EncodedString(),
                    byteCount: normalized.data.count
                )
            )
        }

        return attachments
    }

    private func codexInputFileURL(_ input: CodexUserInput) -> URL? {
        if let rawPath = input.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            return URL(fileURLWithPath: rawPath)
        }

        if let rawURL = input.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawURL.isEmpty,
           let parsed = URL(string: rawURL),
           parsed.isFileURL {
            return parsed
        }

        return nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                store.backToProject()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session.back.project")

            Text("LabOS")
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button("Results") {
                store.openResults()
            }
            .buttonStyle(.bordered)

            Menu {
                Menu("Backend") {
                    backendMenuButton(title: "Pi Adapter", value: "pi")
                    backendMenuButton(title: "Codex App Server", value: "codex-app-server")
                }

                Button("Rename Session") {
                    renameSessionPresented = true
                }

                if session?.lifecycle == .active {
                    Button("Archive Session") {
                        store.archiveSession(projectID: projectID, sessionID: sessionID)
                        store.backToProject()
                    }
                } else {
                    Button("Unarchive Session") {
                        store.unarchiveSession(projectID: projectID, sessionID: sessionID)
                    }
                }

                Button("Delete Session", role: .destructive) {
                    deleteSessionPresented = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var pendingApprovalBinding: Binding<PendingApproval?> {
        Binding<PendingApproval?>(
            get: { isCodexSession ? nil : store.pendingApproval(for: sessionID) },
            set: { newValue in
                guard newValue == nil else { return }
                guard !isCodexSession else { return }
                if store.pendingApproval(for: sessionID) != nil {
                    store.cancelPlan(sessionID: sessionID)
                }
            }
        )
    }

    @ViewBuilder
    private func backendMenuButton(title: String, value: String) -> some View {
        let normalizedValue = normalizedBackendEngine(value)
        Button {
            applyBackendSelection(normalizedValue)
        } label: {
            HStack {
                Text(title)
                if activeBackendEngine == normalizedValue {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func applyBackendSelection(_ backend: String) {
        let normalized = normalizedBackendEngine(backend)
        store.savePreferredBackendEngine(normalized)
        Task { @MainActor in
            await store.updateSessionBackend(
                projectID: projectID,
                sessionID: sessionID,
                backendEngine: normalized
            )
        }
    }

    private func normalizedBackendEngine(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized == "codex" || normalized == "codex-app-server" {
            return "codex-app-server"
        }
        return "pi"
    }

    private func agentPlanCard(_ payload: AgentPlanUpdatedPayload) -> some View {
        let items = payload.plan
        let total = max(items.count, 1)
        let completed = items.filter { $0.status.lowercased() == "completed" }.count
        let fraction = min(max(Double(completed) / Double(total), 0), 1)
        let currentIndex = items.firstIndex { $0.status.lowercased() == "in_progress" }
        let currentTitle = currentIndex.flatMap { items.indices.contains($0) ? items[$0].step : nil } ?? "Waiting for execution"

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(runProgressAnimation) {
                    isPlanCardExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)

                    Text("Plan · \(completed)/\(total) completed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isPlanCardExpanded ? 90 : 0))
                        .animation(runProgressAnimation, value: isPlanCardExpanded)
                }
            }
            .buttonStyle(.plain)

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.blue)

            if isPlanCardExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current step")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(currentTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if let explanation = payload.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !explanation.isEmpty {
                            Text(explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Steps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            let status = item.status.lowercased()
                            HStack(spacing: 8) {
                                Image(systemName: planStatusIcon(status))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(planStatusColor(status))
                                    .frame(width: 14, height: 14)

                                Text("Step \(index + 1) · \(item.step)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                    }
                }
                .padding(.top, 2)
                .clipped()
                .transition(runProgressContentTransition)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func planStatusIcon(_ status: String) -> String {
        switch status {
        case "completed":
            return "checkmark.circle.fill"
        case "in_progress":
            return "clock.fill"
        case "pending":
            return "circle"
        default:
            return "questionmark.circle"
        }
    }

    private func planStatusColor(_ status: String) -> Color {
        switch status {
        case "completed":
            return .green
        case "in_progress":
            return .blue
        case "pending":
            return .secondary
        default:
            return .secondary
        }
    }

    private func runProgressCard(_ run: RunRecord) -> some View {
        let total = max(run.totalSteps, 1)
        let completed = completedSteps(run)
        let fraction = min(max(Double(completed) / Double(total), 0), 1)
        let currentIndex = currentStepIndex(run: run)
        let stepCount = max(run.stepTitles.count, total)
        let currentTitle = currentIndex.flatMap { index in
            run.stepTitles.indices.contains(index) ? run.stepTitles[index] : nil
        } ?? "Waiting for execution"
        let currentDetail = currentIndex.flatMap { index in
            run.stepDetails.indices.contains(index) ? run.stepDetails[index] : nil
        } ?? "Queued and waiting for available compute."
        let recentActivity = Array(run.activity.suffix(6).reversed())

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(runProgressAnimation) {
                    isRunProgressExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)

                    Text("\(completed)/\(total) steps completed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isRunProgressExpanded ? 90 : 0))
                        .animation(runProgressAnimation, value: isRunProgressExpanded)
                }
            }
            .buttonStyle(.plain)

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.blue)

            if isRunProgressExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current step")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(currentTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(currentDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, recentActivity.isEmpty ? 0 : 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Plan · \(stepCount) steps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(0..<stepCount, id: \.self) { index in
                            let stepTitle = run.stepTitles.indices.contains(index)
                                ? run.stepTitles[index]
                                : "Step \(index + 1)"
                            let state = planStepState(run: run, stepIndex: index)

                            HStack(spacing: 8) {
                                Image(systemName: planStepIcon(for: state))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(planStepColor(for: state))
                                    .frame(width: 14, height: 14)

                                Text("Step \(index + 1) · \(stepTitle)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                    }

                    if !recentActivity.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Live activity")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(recentActivity) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: activityIcon(for: event.type))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(activityColor(for: event.type))
                                        .frame(width: 16, height: 16)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(event.summary)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(event.detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                            }
                        }
                    }
                }
                .padding(.top, 2)
                .clipped()
                .transition(runProgressContentTransition)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func completedSteps(_ run: RunRecord) -> Int {
        switch run.status {
        case .queued:
            return 0
        case .running:
            return max(run.currentStep - 1, 0)
        case .succeeded:
            return max(run.totalSteps, 1)
        case .failed, .canceled:
            return max(run.currentStep - 1, 0)
        }
    }

    private func currentStepIndex(run: RunRecord) -> Int? {
        switch run.status {
        case .queued:
            return 0
        case .running, .failed, .canceled:
            let step = max(min(run.currentStep, max(run.totalSteps, 1)), 1)
            return step - 1
        case .succeeded:
            return nil
        }
    }

    private func planStepState(run: RunRecord, stepIndex: Int) -> PlanStepState {
        let stepNumber = stepIndex + 1
        let total = max(run.totalSteps, 1)
        let current = max(min(run.currentStep, total), 1)

        switch run.status {
        case .queued:
            return .pending
        case .running:
            if stepNumber < current { return .completed }
            if stepNumber == current { return .current }
            return .pending
        case .succeeded:
            return .completed
        case .failed:
            if stepNumber < current { return .completed }
            if stepNumber == current { return .failed }
            return .pending
        case .canceled:
            if stepNumber < current { return .completed }
            if stepNumber == current { return .canceled }
            return .pending
        }
    }

    private func planStepIcon(for state: PlanStepState) -> String {
        switch state {
        case .completed:
            return "checkmark.circle.fill"
        case .current:
            return "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .pending:
            return "circle"
        case .failed:
            return "xmark.circle.fill"
        case .canceled:
            return "minus.circle.fill"
        }
    }

    private func planStepColor(for state: PlanStepState) -> Color {
        switch state {
        case .completed:
            return .green
        case .current:
            return .blue
        case .pending:
            return .secondary
        case .failed:
            return .red
        case .canceled:
            return .orange
        }
    }

    private func activityIcon(for type: RunActionType) -> String {
        switch type {
        case .toolCall:
            return "wrench.and.screwdriver"
        case .command:
            return "terminal"
        case .output:
            return "doc.badge.plus"
        case .info:
            return "info.circle"
        }
    }

    private func activityColor(for type: RunActionType) -> Color {
        switch type {
        case .toolCall:
            return .blue
        case .command:
            return .orange
        case .output:
            return .green
        case .info:
            return .secondary
        }
    }

    private enum PlanStepState {
        case completed
        case current
        case pending
        case failed
        case canceled
    }
}

private struct RunProgressHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AgentPlanHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChatScrollViewHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatBottomAnchorMaxYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
#endif
