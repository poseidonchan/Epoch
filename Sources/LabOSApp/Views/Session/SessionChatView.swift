#if os(iOS)
import LabOSCore
import PhotosUI
import SwiftUI
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

    private var session: Session? {
        store.sessions(for: projectID).first(where: { $0.id == sessionID })
    }

    private var messages: [ChatMessage] {
        store.messages(for: sessionID)
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
                                }
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
                } else if let plan = store.livePlanBySession[sessionID] {
                    agentPlanCard(plan)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: AgentPlanHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
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
            let nextHeight = activeRun == nil && store.livePlanBySession[sessionID] != nil ? value : 0
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
            ProjectFilesSheet(
                title: "Project Files",
                uploadedFiles: store.uploadedArtifacts(for: projectID),
                onAddPhotos: {
                    showFileSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showPhotoPicker = true
                    }
                },
                onAddFiles: {
                    showFileSheet = false
                    showFileImporter = true
                },
                onDeleteFile: { path in
                    store.removeUploadedFile(projectID: projectID, path: path)
                },
                onClose: {
                    showFileSheet = false
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
            let timestamp = Int(Date().timeIntervalSince1970)
            let fileNames = items.enumerated().map { index, item in
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                return "photo-\(timestamp)-\(index + 1).\(ext)"
            }
            store.addUploadedFiles(projectID: projectID, fileNames: fileNames, createdBySessionID: sessionID)
            selectedPhotoItems = []
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

    private var sessionComposer: some View {
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
                set: { store.setPermissionLevel(projectID: projectID, sessionID: sessionID, level: $0) }
            ),
            submitLabel: editingMessageID == nil ? "Send" : "Update",
            style: .chatGPT,
            statusText: editingMessageID == nil ? nil : "Editing",
            statusIconSystemName: "pencil",
            statusAction: editingMessageID == nil ? nil : {
                editingMessageID = nil
                composerText = ""
            },
	            attachmentAction: {
	                showFileSheet = true
	            },
	            modelOptions: store.availableModels,
	            thinkingLevelOptions: store.availableThinkingLevels.isEmpty ? ThinkingLevel.allCases : store.availableThinkingLevels,
	            contextRemainingFraction: store.contextRemainingFraction(for: sessionID),
	            contextWindowTokens: store.contextWindowTokens(for: sessionID) ?? 258_000
	        ) {
	            let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
	            guard !text.isEmpty else { return }
                if let editingMessageID {
                    store.overwriteUserMessage(
                        projectID: projectID,
                        sessionID: sessionID,
                        messageID: editingMessageID,
                        text: text
                    )
                    self.editingMessageID = nil
                } else {
                    store.sendMessage(projectID: projectID, sessionID: sessionID, text: text)
                }
            composerText = ""
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ComposerHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            let fileNames = urls.map(\.lastPathComponent)
            store.addUploadedFiles(projectID: projectID, fileNames: fileNames, createdBySessionID: sessionID)
        case let .failure(error):
            importErrorMessage = error.localizedDescription
        }
    }

    private func editMessage(_ message: ChatMessage) {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editingMessageID = message.role == .user ? message.id : nil
        composerText = trimmed
    }

    private func retryMessage(_ message: ChatMessage, modelIdOverride: String?) {
        store.retryMessage(
            projectID: projectID,
            sessionID: sessionID,
            fromMessageID: message.id,
            modelIdOverride: modelIdOverride
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

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                store.backToProject()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.plain)

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
            get: { store.pendingApproval(for: sessionID) },
            set: { newValue in
                guard newValue == nil else { return }
                if store.pendingApproval(for: sessionID) != nil {
                    store.cancelPlan(sessionID: sessionID)
                }
            }
        )
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
