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
    @State private var codexPromptCurrentQuestionIndex = 0
    @State private var codexPromptSelectedOptionByQuestionID: [String: String] = [:]
    @State private var codexPromptFreeformByQuestionID: [String: String] = [:]
    @State private var renameSessionPresented = false
    @State private var deleteSessionPresented = false
    @State private var showFileSheet = false
    @State private var showPhotoPicker = false
    @State private var showCameraCapture = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var importErrorMessage: String?
    @State private var editingMessageID: UUID?
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

    private var codexTrajectoryDurationByTurnID: [String: Int] {
        store.codexTrajectoryDurations(sessionID: sessionID)
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
                                persistedDurationByTurnID: codexTrajectoryDurationByTurnID,
                                startedAtByTurnID: store.codexTrajectoryStartedAtBySession[sessionID] ?? [:],
                                isPlanModeEnabled: store.planModeEnabled(for: sessionID),
                                interruptedTurnIDs: store.codexInterruptedTurnIDs(sessionID: sessionID),
                                proposedPlanTextByTurnID: store.codexProposedPlanTextBySession[sessionID] ?? [:],
                                isSessionInFlight: store.codexTurnInFlight(sessionID: sessionID),
                                isStreaming: store.streamingSessions.contains(sessionID),
                                showAssistantActionBar: true,
                                onEditUserMessage: { item in
                                    editCodexUserMessage(item)
                                },
                                onBranchAgentMessage: { item in
                                    branchFromCodexAgentMessage(item)
                                },
                                onFinalizeTurnDuration: { turnID, durationMs in
                                    store.setCodexTrajectoryDuration(
                                        sessionID: sessionID,
                                        turnID: turnID,
                                        durationMs: durationMs
                                    )
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
                                    onArtifactTap: { ref in
                                        store.openArtifactReference(ref)
                                    },
                                    onEditMessage: { msg in
                                        editMessage(msg)
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
                            .allowsHitTesting(false)
                            .frame(height: 1)
                            .id(bottomAnchorID)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .allowsHitTesting(false)
                                        .preference(
                                            key: ChatBottomAnchorMaxYPreferenceKey.self,
                                            value: proxy.frame(in: .named(scrollCoordinateSpace)).maxY
                                        )
                                }
                            )
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                }
                .coordinateSpace(name: scrollCoordinateSpace)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .allowsHitTesting(false)
                            .preference(key: ChatScrollViewHeightPreferenceKey.self, value: proxy.size.height)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CodexDockView(
                showsShelf: true,
                showsFooter: false,
                shelf: {
                    SessionShelfView(projectID: projectID, sessionID: sessionID, renderMode: .dock)
                },
                composer: {
                    sessionComposer
                },
                footer: {
                    EmptyView()
                }
            )
        }
        .onAppear {
            loadCodexPromptDraftIfNeeded(prompt: codexPrompt)
        }
        .onChange(of: codexPrompt?.id) { _, _ in
            loadCodexPromptDraftIfNeeded(prompt: codexPrompt)
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
        case "websearch", "web search":
            return "Searching web..."
        case "inprogress", "in_progress", "running", "thinking":
            return "Thinking..."
        default:
            if lower.contains("websearch")
                || lower.contains("web search")
                || lower.contains("web.search") {
                return "Searching web..."
            }
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
        } else {
            let isInFlight = store.codexTurnInFlight(sessionID: sessionID)
            let canInterrupt = store.canInterruptCodexTurn(sessionID: sessionID)
            let pendingAttachments = store.pendingComposerAttachments(for: sessionID)
            let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasContent = !trimmed.isEmpty || !pendingAttachments.isEmpty

            let primaryAction: InlineComposerView.PrimaryAction = {
                if editingMessageID != nil { return .update }
                if isInFlight && !hasContent && canInterrupt { return .stop }
                return .send
            }()

            let submitLabel: String = {
                switch primaryAction {
                case .send:
                    return "Send"
                case .stop:
                    return "Stop"
                case .update:
                    return "Update"
                }
            }()

            let submitDisabled = primaryAction == .stop && !canInterrupt

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
                    get: { store.permissionLevel(for: sessionID) },
                    set: { level in
                        store.setPermissionLevel(projectID: projectID, sessionID: sessionID, level: level)
                    }
                ),
                submitLabel: submitLabel,
                style: .chatGPT,
                chatComposerChrome: .embeddedInDock,
                primaryAction: primaryAction,
                submitDisabled: submitDisabled,
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
                let attachments = store.pendingComposerAttachments(for: sessionID)
                let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasContent = !text.isEmpty || !attachments.isEmpty

                if editingMessageID == nil,
                   store.codexTurnInFlight(sessionID: sessionID),
                   store.canInterruptCodexTurn(sessionID: sessionID),
                   !hasContent {
                    store.interruptCodexTurn(sessionID: sessionID)
                    return
                }

                guard hasContent else { return }

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
        }
    }

    private func codexPromptComposer(_ prompt: CodexPendingPrompt) -> some View {
        let questions = codexPromptQuestions(prompt)
        let header = prompt.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? prompt.prompt!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Codex is waiting for input"
        let safeIndex = min(max(codexPromptCurrentQuestionIndex, 0), max(questions.count - 1, 0))
        let question = questions[safeIndex]
        let displayOptions = codexPromptDisplayOptions(for: question)
        let selectedOptionID = codexPromptSelectedOptionByQuestionID[question.id]
        let selectedOption = displayOptions.first(where: { $0.id == selectedOptionID })
        let allowsFreeform = displayOptions.isEmpty || selectedOption?.isOther == true
        let currentQuestionAnswered = codexPromptAnswer(for: question, options: displayOptions) != nil
        let allAnswers = codexPromptAnswerMap(prompt: prompt)
        let canSubmit = allAnswers != nil
        let isLastQuestion = safeIndex >= max(questions.count - 1, 0)
        let actionTitle = isLastQuestion ? "Submit" : "Next"

        return VStack(alignment: .leading, spacing: 12) {
            Text(header)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if questions.count > 1 {
                Text("Question \(safeIndex + 1) of \(questions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let header = question.header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !question.prompt.isEmpty {
                Text(question.prompt)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !displayOptions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(displayOptions.enumerated()), id: \.element.id) { index, option in
                        Button {
                            codexPromptSelectedOptionByQuestionID[question.id] = option.id
                            saveCodexPromptDraft(prompt: prompt)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedOptionID == option.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedOptionID == option.id ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(index + 1). \(option.label)")
                                        .foregroundStyle(.primary)
                                    if let description = option.description,
                                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedOptionID == option.id ? Color.accentColor.opacity(0.1) : Color(.tertiarySystemFill))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "session.codexPrompt.option.\(codexPromptOptionIdentifier(question.id))_\(codexPromptOptionIdentifier(option.id))"
                        )
                    }
                }
            }

            if allowsFreeform {
                TextField(
                    "Type your response",
                    text: Binding(
                        get: { codexPromptFreeformByQuestionID[question.id] ?? "" },
                        set: { newValue in
                            codexPromptFreeformByQuestionID[question.id] = newValue
                            saveCodexPromptDraft(prompt: prompt)
                        }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("session.codexPrompt.freeform")
            }

            HStack(spacing: 8) {
                Button("Dismiss") {
                    store.respondToCodexPrompt(sessionID: sessionID, requestID: prompt.requestID, answers: [:])
                    store.clearCodexPromptDraft(sessionID: sessionID, requestID: prompt.requestID)
                    codexPromptCurrentQuestionIndex = 0
                    codexPromptSelectedOptionByQuestionID = [:]
                    codexPromptFreeformByQuestionID = [:]
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("session.codexPrompt.dismiss")

                if questions.count > 1, safeIndex > 0 {
                    Button("Back") {
                        codexPromptCurrentQuestionIndex = max(0, safeIndex - 1)
                        saveCodexPromptDraft(prompt: prompt)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("session.codexPrompt.back")
                }

                Button(actionTitle) {
                    if !isLastQuestion {
                        guard currentQuestionAnswered else { return }
                        codexPromptCurrentQuestionIndex = min(questions.count - 1, safeIndex + 1)
                        saveCodexPromptDraft(prompt: prompt)
                        return
                    }
                    guard let answers = allAnswers else { return }
                    store.respondToCodexPrompt(
                        sessionID: sessionID,
                        requestID: prompt.requestID,
                        answers: answers
                    )
                    store.clearCodexPromptDraft(sessionID: sessionID, requestID: prompt.requestID)
                    codexPromptCurrentQuestionIndex = 0
                    codexPromptSelectedOptionByQuestionID = [:]
                    codexPromptFreeformByQuestionID = [:]
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLastQuestion ? !canSubmit : !currentQuestionAnswered)
                .accessibilityIdentifier("session.codexPrompt.submit")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .accessibilityIdentifier("session.codexPrompt.card")
    }

    private func codexPromptQuestions(_ prompt: CodexPendingPrompt) -> [CodexPromptQuestion] {
        let source = prompt.questions.isEmpty ? codexPromptQuestionsFromRaw(prompt.rawParams) : prompt.questions
        if !source.isEmpty {
            return source
        }
        let fallbackPrompt = prompt.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Provide your response."
        return [
            CodexPromptQuestion(
                id: "response",
                prompt: fallbackPrompt,
                isOther: true,
                options: []
            ),
        ]
    }

    private func codexPromptQuestionsFromRaw(_ rawParams: JSONValue?) -> [CodexPromptQuestion] {
        guard case let .object(params)? = rawParams else { return [] }
        guard case let .array(rawQuestions)? = params["questions"] else { return [] }
        return rawQuestions.compactMap { questionValue in
            guard case let .object(questionObject) = questionValue else { return nil }
            let questionID = codexPromptString(questionObject["id"]) ?? "response"
            let header = codexPromptString(questionObject["header"])
            let questionPrompt = codexPromptString(questionObject["question"])
                ?? codexPromptString(questionObject["prompt"])
                ?? ""
            let questionIsOther: Bool = {
                if case let .bool(flag)? = questionObject["isOther"] {
                    return flag
                }
                return false
            }()
            let options: [CodexPromptOption] = {
                guard case let .array(rawOptions)? = questionObject["options"] else { return [] }
                return rawOptions.compactMap { optionValue in
                    guard case let .object(optionObject) = optionValue else { return nil }
                    guard let label = codexPromptString(optionObject["label"]), !label.isEmpty else { return nil }
                    return CodexPromptOption(
                        id: codexPromptString(optionObject["id"]) ?? label,
                        label: label,
                        description: codexPromptString(optionObject["description"]),
                        isOther: {
                            if case let .bool(flag)? = optionObject["isOther"] {
                                return flag
                            }
                            return false
                        }()
                    )
                }
            }()
            return CodexPromptQuestion(
                id: questionID,
                header: header,
                prompt: questionPrompt,
                isOther: questionIsOther,
                options: options
            )
        }
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

    private func codexPromptDisplayOptions(for question: CodexPromptQuestion) -> [CodexPromptOption] {
        if question.id == "labos_plan_implementation_decision" {
            return question.options
        }
        var options = question.options
        if options.contains(where: { $0.isOther }) {
            return options
        }
        if options.isEmpty {
            return options
        }
        options.append(
            CodexPromptOption(
                id: "__codex_other__",
                label: "No, and tell Codex what to do differently",
                description: nil,
                isOther: true
            )
        )
        return options
    }

    private func codexPromptAnswerMap(prompt: CodexPendingPrompt) -> [String: String]? {
        let questions = codexPromptQuestions(prompt)
        var answers: [String: String] = [:]
        for question in questions {
            let options = codexPromptDisplayOptions(for: question)
            guard let answer = codexPromptAnswer(for: question, options: options) else {
                return nil
            }
            answers[question.id] = answer
        }
        return answers.isEmpty ? nil : answers
    }

    private func codexPromptAnswer(
        for question: CodexPromptQuestion,
        options: [CodexPromptOption]
    ) -> String? {
        let selectedOption = options.first { $0.id == codexPromptSelectedOptionByQuestionID[question.id] }
        if let selectedOption {
            if selectedOption.isOther {
                let typed = (codexPromptFreeformByQuestionID[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return typed.isEmpty ? nil : typed
            }
            return selectedOption.label
        }

        if !options.isEmpty {
            return nil
        }

        let typed = (codexPromptFreeformByQuestionID[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : typed
    }

    private func loadCodexPromptDraftIfNeeded(prompt: CodexPendingPrompt?) {
        guard let prompt else {
            codexPromptCurrentQuestionIndex = 0
            codexPromptSelectedOptionByQuestionID = [:]
            codexPromptFreeformByQuestionID = [:]
            return
        }

        let questions = codexPromptQuestions(prompt)
        if let draft = store.codexPromptDraft(sessionID: sessionID, requestID: prompt.requestID) {
            codexPromptCurrentQuestionIndex = min(max(draft.questionIndex, 0), max(questions.count - 1, 0))
            codexPromptSelectedOptionByQuestionID = draft.selectedOptionByQuestionID
            codexPromptFreeformByQuestionID = draft.freeformByQuestionID
            return
        }

        codexPromptCurrentQuestionIndex = 0
        codexPromptSelectedOptionByQuestionID = [:]
        codexPromptFreeformByQuestionID = [:]
    }

    private func saveCodexPromptDraft(prompt: CodexPendingPrompt) {
        store.saveCodexPromptDraft(
            sessionID: sessionID,
            requestID: prompt.requestID,
            draft: AppStore.CodexPromptDraftState(
                questionIndex: codexPromptCurrentQuestionIndex,
                selectedOptionByQuestionID: codexPromptSelectedOptionByQuestionID,
                freeformByQuestionID: codexPromptFreeformByQuestionID
            )
        )
    }

    private func codexPromptOptionIdentifier(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let chars = lowered.map { char -> Character in
            switch char {
            case "a"..."z", "0"..."9":
                return char
            default:
                return "_"
            }
        }
        return String(chars)
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
