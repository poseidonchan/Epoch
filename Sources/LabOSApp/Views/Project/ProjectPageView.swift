#if os(iOS)
import LabOSCore
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProjectPageView: View {
    let projectID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var seedPrompt = ""
    @State private var showArchived = false
    @State private var showProjectFilesSheet = false
    @State private var showComposerAttachmentSheet = false
    @State private var showPhotoPicker = false
    @State private var showCameraCapture = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var importErrorMessage: String?
    @State private var sendErrorMessage: String?
    @State private var voiceErrorMessage: String?
    @State private var voiceErrorShowsSystemSettingsAction = false
    @State private var composerCursorUTF16Offset = 0
    @State private var composerDraftSessionID = UUID()
    @StateObject private var voiceController = VoiceComposerController()
    private let maxInlineAttachmentBytes = 900 * 1024
    private let maxInlinePhotoDimension: CGFloat = 1_536

    @State private var showAddLinkSheet = false
    @State private var renameProjectPresented = false
    @State private var renameSession: Session?
    @State private var deleteSession: Session?

    private enum ImportTarget {
        case projectFiles
        case composer
    }

    @State private var importTarget: ImportTarget = .projectFiles

    private var project: Project? {
        store.projects.first(where: { $0.id == projectID })
    }

    private var sessions: [Session] {
        store.sessions(for: projectID)
    }

    private var activeSessions: [Session] {
        sessions.filter { $0.lifecycle == .active }
    }

    private var archivedSessions: [Session] {
        sessions.filter { $0.lifecycle == .archived }
    }

    private var projectFileCount: Int {
        store.uploadedArtifacts(for: projectID).count
    }

    private var fileBadgeLabel: String {
        if projectFileCount == 0 { return "Add new files" }
        if projectFileCount == 1 { return "1 uploaded file" }
        return "\(projectFileCount) uploaded files"
    }

    private var projectCodexSkillsState: CodexSkillsListState {
        store.codexSkillsState(for: composerDraftSessionID)
    }

    private var projectComposerSkillOptions: [InlineComposerView.SkillOption] {
        projectCodexSkillsState.inlineComposerSkillOptions()
    }

    private var projectSkillLoadCwds: [String]? {
        guard let workspacePath = project?.hpcWorkspacePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty
        else {
            return nil
        }
        return [workspacePath]
    }

    private var projectSkillSuggestions: ComposerSkillSuggestionState? {
        ComposerSkillSuggestionState.make(
            text: seedPrompt,
            skillOptions: projectComposerSkillOptions,
            skillsAreLoading: projectCodexSkillsState.isLoading,
            skillsErrorText: projectCodexSkillsState.error,
            canRefresh: true
        )
    }

    private var showsProjectSkillSuggestionShelf: Bool {
        projectSkillSuggestions?.isVisible == true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            projectTitleRow

            List {
                Section("Sessions") {
                    if activeSessions.isEmpty {
                        Text("No active sessions")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activeSessions) { sessionRow($0) }
                    }
                }

                if !archivedSessions.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showArchived) {
                            ForEach(archivedSessions) { sessionRow($0) }
                        } label: {
                            Text("Archived (\(archivedSessions.count))")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CodexDockView(
                showsShelf: showsProjectSkillSuggestionShelf,
                showsFooter: false,
                shelf: {
                    if let projectSkillSuggestions, projectSkillSuggestions.isVisible {
                        SkillSuggestionShelfView(
                            state: projectSkillSuggestions,
                            onSelect: { option in
                                guard let updated = ComposerSkillSuggestionState.replacingTrailingToken(
                                    in: seedPrompt,
                                    with: option
                                ) else { return }
                                seedPrompt = updated
                            },
                            onRefresh: {
                                store.refreshCodexSkills(
                                    sessionID: composerDraftSessionID,
                                    cwds: projectSkillLoadCwds,
                                    forceReload: true
                                )
                            },
                            accessibilityPrefix: "project.shelf.skillSuggestions"
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    } else {
                        EmptyView()
                    }
                },
                composer: {
                    projectComposer
                },
                footer: {
                    EmptyView()
                }
            )
        }
        .onAppear {
            configureVoiceController()
            guard projectCodexSkillsState.updatedAt == nil,
                  !projectCodexSkillsState.isLoading
            else { return }
            store.refreshCodexSkills(sessionID: composerDraftSessionID, cwds: projectSkillLoadCwds)
        }
        .onDisappear {
            voiceController.cancelAll()
        }
        .onChange(of: voiceController.lastErrorMessage) { _, message in
            guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            voiceErrorMessage = normalizedVoiceErrorMessage(message)
            voiceErrorShowsSystemSettingsAction = voiceController.lastErrorRequiresSystemSettings
            voiceController.lastErrorMessage = nil
            voiceController.lastErrorRequiresSystemSettings = false
        }
        .sheet(isPresented: $renameProjectPresented) {
            NamePromptSheet(
                title: "Rename Project",
                placeholder: "Project name",
                confirmLabel: "Save",
                initialValue: project?.name ?? "",
                onConfirm: { name in
                    store.renameProject(projectID: projectID, newName: name)
                    renameProjectPresented = false
                },
                onCancel: {
                    renameProjectPresented = false
                }
            )
        }
        .sheet(item: $renameSession) { session in
            NamePromptSheet(
                title: "Rename Session",
                placeholder: "Session title",
                confirmLabel: "Save",
                initialValue: session.title,
                onConfirm: { name in
                    store.renameSession(projectID: projectID, sessionID: session.id, newTitle: name)
                    renameSession = nil
                },
                onCancel: {
                    renameSession = nil
                }
            )
        }
        .sheet(item: $deleteSession) { session in
            SessionDeleteSheet(session: session) {
                store.deleteSession(projectID: projectID, sessionID: session.id)
                deleteSession = nil
            } onCancel: {
                deleteSession = nil
            }
        }
        .sheet(isPresented: $showProjectFilesSheet) {
            ProjectFilesSheet(
                title: "Project Files",
                uploadedFiles: store.uploadedArtifacts(for: projectID),
                onAddPhotos: {
                    importTarget = .projectFiles
                    showProjectFilesSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showPhotoPicker = true
                    }
                },
                onAddFiles: {
                    importTarget = .projectFiles
                    showProjectFilesSheet = false
                    showFileImporter = true
                },
                onAddLink: {
                    showProjectFilesSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showAddLinkSheet = true
                    }
                },
                onDeleteFile: { path in
                    store.removeUploadedFile(projectID: projectID, path: path)
                },
                onClose: {
                    showProjectFilesSheet = false
                }
            )
        }
        .sheet(isPresented: $showAddLinkSheet) {
            AddLinkSheet(projectID: projectID) {
                showAddLinkSheet = false
            }
        }
        .sheet(isPresented: $showComposerAttachmentSheet) {
            ComposerAttachmentsSheet(
                title: "Session Attachments",
                pendingAttachments: store.pendingComposerAttachments(for: composerDraftSessionID),
                selectedRecentPhotoTokens: Set(store.pendingComposerAttachments(for: composerDraftSessionID).compactMap(\.sourceToken)),
                onTakePhoto: {
                    importTarget = .composer
                    showComposerAttachmentSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCameraCapture = true
                        } else {
                            importErrorMessage = "Camera is unavailable on this device."
                        }
                    }
                },
                onAddPhotos: {
                    importTarget = .composer
                    showComposerAttachmentSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showPhotoPicker = true
                    }
                },
                onSelectRecentPhoto: { token in
                    toggleRecentPhotoAttachment(selectionToken: token)
                },
                onAddFiles: {
                    importTarget = .composer
                    showComposerAttachmentSheet = false
                    showFileImporter = true
                },
                onAddTestPhoto: E2ETestAttachmentFactory.isEnabled ? {
                    if let attachment = E2ETestAttachmentFactory.makeFixturePhotoAttachment() {
                        store.addPendingComposerAttachments(sessionID: composerDraftSessionID, attachments: [attachment])
                    }
                    showComposerAttachmentSheet = false
                } : nil,
                onDeleteAttachment: { id in
                    store.removePendingComposerAttachment(sessionID: composerDraftSessionID, attachmentID: id)
                },
                onClose: {
                    showComposerAttachmentSheet = false
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
            switch importTarget {
            case .projectFiles:
                Task {
                    let uploads = await makePhotoProjectUploads(from: selected)
                    guard !uploads.isEmpty else { return }
                    await store.uploadProjectFiles(
                        projectID: projectID,
                        files: uploads,
                        createdBySessionID: nil
                    )
                }
            case .composer:
                Task {
                    let attachments = await makePhotoAttachments(from: selected)
                    await MainActor.run {
                        if attachments.count < selected.count {
                            importErrorMessage = "Some photos were skipped because they were too large to send inline."
                        }
                        let existingTokens = Set(store.pendingComposerAttachments(for: composerDraftSessionID).compactMap(\.sourceToken))
                        let uniqueAttachments = attachments.filter { attachment in
                            guard let token = attachment.sourceToken else { return true }
                            return !existingTokens.contains(token)
                        }
                        if !uniqueAttachments.isEmpty {
                            store.addPendingComposerAttachments(sessionID: composerDraftSessionID, attachments: uniqueAttachments)
                        }
                        showComposerAttachmentSheet = true
                    }
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
        .alert("Couldn’t send message", isPresented: Binding(
            get: { sendErrorMessage != nil },
            set: { if !$0 { sendErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendErrorMessage ?? "Unknown error")
        }
        .alert("Voice input failed", isPresented: Binding(
            get: { voiceErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    voiceErrorMessage = nil
                    voiceErrorShowsSystemSettingsAction = false
                }
            }
        )) {
            if voiceErrorShowsSystemSettingsAction {
                Button("Open iOS Settings") {
                    openSystemSettings()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(voiceErrorMessage ?? "Unknown error")
        }
    }

    private var projectTitleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(project?.name ?? "Project")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Button {
                showProjectFilesSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: projectFileCount == 0 ? "plus.circle.fill" : "doc.on.doc.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(fileBadgeLabel)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(.secondarySystemFill))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project.files.badge")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var projectComposer: some View {
        InlineComposerView(
            placeholder: "Ask LabOS",
            text: $seedPrompt,
            isPlanModeEnabled: Binding(
                get: { store.planModeEnabled(for: composerDraftSessionID) },
                set: { store.setPlanModeEnabled(for: composerDraftSessionID, enabled: $0) }
            ),
            selectedModelId: Binding(
                get: { store.selectedModelId(for: composerDraftSessionID) },
                set: { store.setSelectedModelId(for: composerDraftSessionID, modelId: $0) }
            ),
            selectedThinkingLevel: Binding(
                get: { store.selectedThinkingLevel(for: composerDraftSessionID) },
                set: { store.setSelectedThinkingLevel(for: composerDraftSessionID, level: $0) }
            ),
            selectedPermissionLevel: Binding(
                get: { store.projectPermissionLevel(for: projectID) },
                set: { store.setProjectPermissionLevel(projectID: projectID, level: $0) }
            ),
            submitLabel: "Send",
            style: .chatGPT,
            chatComposerChrome: .embeddedInDock,
            submitDisabled: voiceController.isTranscribing,
            attachmentAction: {
                showComposerAttachmentSheet = true
            },
            pendingAttachments: store.pendingComposerAttachments(for: composerDraftSessionID),
            onRemoveAttachment: { attachmentID in
                store.removePendingComposerAttachment(sessionID: composerDraftSessionID, attachmentID: attachmentID)
            },
            voiceState: voiceController.voiceState(isConfigured: store.openAIAPIKeyConfigured),
            onVoiceUnavailableTap: {
                store.openSettings()
            },
            onVoicePressBegan: {
                guard store.openAIAPIKeyConfigured else {
                    store.openSettings()
                    return
                }
                voiceController.beginRecording()
            },
            onVoiceCancelArmedChanged: { cancelArmed in
                voiceController.setCancelArmed(cancelArmed)
            },
            onVoicePressEnded: { cancelled, pressDuration in
                voiceController.endRecording(cancelledByGesture: cancelled, pressDuration: pressDuration)
            },
            onCursorUTF16OffsetChanged: { offset in
                composerCursorUTF16Offset = offset
            },
            modelOptions: store.availableModels,
            thinkingLevelOptions: {
                let levels = store.thinkingLevels(for: composerDraftSessionID)
                return levels.isEmpty ? ThinkingLevel.allCases : levels
            }(),
            skillOptions: projectComposerSkillOptions,
            skillsAreLoading: projectCodexSkillsState.isLoading,
            skillsErrorText: projectCodexSkillsState.error,
            onRefreshSkills: {
                store.refreshCodexSkills(
                    sessionID: composerDraftSessionID,
                    cwds: projectSkillLoadCwds,
                    forceReload: true
                )
            },
            contextRemainingFraction: store.contextRemainingFraction(for: composerDraftSessionID),
            contextWindowTokens: store.contextWindowTokens(for: composerDraftSessionID) ?? 258_000
        ) {
            let pendingDraftAttachments = store.pendingComposerAttachments(for: composerDraftSessionID)
            let message = seedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty || !pendingDraftAttachments.isEmpty else { return }
            store.clearPendingComposerAttachments(sessionID: composerDraftSessionID)

            let planModeEnabled = store.planModeEnabled(for: composerDraftSessionID)
            let modelId = store.selectedModelId(for: composerDraftSessionID)
            let thinkingLevel = store.selectedThinkingLevel(for: composerDraftSessionID)
            let permissionLevel = store.projectPermissionLevel(for: projectID)

            // Clear immediately for snappy UI; if creation fails we restore it.
            seedPrompt = ""
            composerCursorUTF16Offset = 0

            Task { @MainActor in
                guard let session = await store.createSession(projectID: projectID, title: nil) else {
                    seedPrompt = message
                    store.addPendingComposerAttachments(sessionID: composerDraftSessionID, attachments: pendingDraftAttachments)
                    sendErrorMessage = store.lastGatewayErrorMessage ?? "Failed to create a session on the Hub."
                    return
                }
                store.setPlanModeEnabled(for: session.id, enabled: planModeEnabled)
                if !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.setSelectedModelId(for: session.id, modelId: modelId)
                }
                store.setSelectedThinkingLevel(for: session.id, level: thinkingLevel)
                store.setPermissionLevel(projectID: session.projectID, sessionID: session.id, level: permissionLevel)
                store.sendMessage(
                    projectID: session.projectID,
                    sessionID: session.id,
                    text: message,
                    attachments: pendingDraftAttachments
                )
            }
        }
    }

    private func configureVoiceController() {
        voiceController.configure(
            transcribeAction: { audioURL in
                try await store.transcribeOpenAIAudio(fileURL: audioURL)
            },
            onTranscription: { text in
                insertTranscriptionTextAtCursor(text)
            }
        )
    }

    private func insertTranscriptionTextAtCursor(_ transcribedText: String) {
        let insertion = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertion.isEmpty else { return }

        let utf16Count = seedPrompt.utf16.count
        let clampedOffset = min(max(composerCursorUTF16Offset, 0), utf16Count)
        let insertionIndex: String.Index = {
            let utf16Index = seedPrompt.utf16.index(seedPrompt.utf16.startIndex, offsetBy: clampedOffset)
            return String.Index(utf16Index, within: seedPrompt) ?? seedPrompt.endIndex
        }()

        seedPrompt.insert(contentsOf: insertion, at: insertionIndex)
        composerCursorUTF16Offset = clampedOffset + insertion.utf16.count
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func normalizedVoiceErrorMessage(_ message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()
        if lowercased.contains("corrupt")
            || lowercased.contains("unsupported")
            || lowercased.contains("recording file is invalid") {
            return "Recording file is invalid or unsupported. Please retry and hold a bit longer before release."
        }
        return normalized
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            switch importTarget {
            case .projectFiles:
                let uploads = urls.compactMap(makeProjectUploadFile(from:))
                guard !uploads.isEmpty else { return }
                Task {
                    await store.uploadProjectFiles(
                        projectID: projectID,
                        files: uploads,
                        createdBySessionID: nil
                    )
                }
            case .composer:
                let valid = urls.compactMap(makeFileAttachment(from:))
                    .filter { !$0.displayName.isEmpty }
                if valid.count < urls.count {
                    importErrorMessage = "Some files were skipped because they were too large to send inline."
                }
                guard !valid.isEmpty else { return }
                store.addPendingComposerAttachments(sessionID: composerDraftSessionID, attachments: valid)
            }
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
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let mimeType = item.supportedContentTypes.first?.preferredMIMEType
            let data = try? await item.loadTransferable(type: Data.self)
            guard let normalizedData = normalizedInlineData(from: data, mimeType: mimeType) else { continue }
            results.append(
                ComposerAttachment(
                    displayName: "photo-\(timestamp)-\(index + 1).\(ext)",
                    mimeType: "image/jpeg",
                    inlineDataBase64: normalizedData.base64EncodedString(),
                    byteCount: normalizedData.count,
                    sourceToken: selectionToken
                )
            )
            cacheSeeds.append(
                CachedInlinePhotoSeed(
                    token: selectionToken,
                    sourceIdentifier: item.itemIdentifier,
                    data: normalizedData,
                    mimeType: "image/jpeg",
                    fileExtension: "jpg",
                    thumbnailData: normalizedData
                )
            )
        }
        await RecentInlinePhotoCache.shared.remember(cacheSeeds)
        return results
    }

    private func addCameraCaptureAttachment(_ image: UIImage) {
        guard let seedData = image.jpegData(compressionQuality: 0.92),
              let normalizedData = normalizedInlineData(from: seedData, mimeType: "image/jpeg")
        else {
            importErrorMessage = "The captured photo was too large to attach."
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let attachment = ComposerAttachment(
            displayName: "camera-\(timestamp).jpg",
            mimeType: "image/jpeg",
            inlineDataBase64: normalizedData.base64EncodedString(),
            byteCount: normalizedData.count
        )
        store.addPendingComposerAttachments(sessionID: composerDraftSessionID, attachments: [attachment])
    }

    private func toggleRecentPhotoAttachment(selectionToken: String) {
        if let existing = store.pendingComposerAttachments(for: composerDraftSessionID).first(where: { $0.sourceToken == selectionToken }) {
            store.removePendingComposerAttachment(sessionID: composerDraftSessionID, attachmentID: existing.id)
            return
        }

        Task {
            if let cached = await RecentInlinePhotoCache.shared.payload(for: selectionToken),
               let normalizedData = normalizedInlineData(from: cached.data, mimeType: cached.mimeType) {
                let timestamp = Int(Date().timeIntervalSince1970)
                let ext = cached.fileExtension ?? "jpg"
                let attachment = ComposerAttachment(
                    displayName: "photo-\(timestamp).\(ext)",
                    mimeType: cached.mimeType ?? "image/jpeg",
                    inlineDataBase64: normalizedData.base64EncodedString(),
                    byteCount: normalizedData.count,
                    sourceToken: selectionToken
                )

                await MainActor.run {
                    if store.pendingComposerAttachments(for: composerDraftSessionID).contains(where: { $0.sourceToken == selectionToken }) {
                        return
                    }
                    store.addPendingComposerAttachments(sessionID: composerDraftSessionID, attachments: [attachment])
                }
                return
            }

            let assetLocalIdentifier = selectionToken.hasPrefix("asset:")
                ? String(selectionToken.dropFirst("asset:".count))
                : selectionToken

            guard let payload = await loadPhotoAsset(localIdentifier: assetLocalIdentifier),
                  let normalizedData = normalizedInlineData(from: payload.data, mimeType: payload.mimeType)
            else {
                await MainActor.run {
                    importErrorMessage = "The selected photo could not be added."
                }
                return
            }

            let timestamp = Int(Date().timeIntervalSince1970)
            let ext = payload.fileExtension ?? "jpg"
            let attachment = ComposerAttachment(
                displayName: "photo-\(timestamp).\(ext)",
                mimeType: payload.mimeType ?? "image/jpeg",
                inlineDataBase64: normalizedData.base64EncodedString(),
                byteCount: normalizedData.count,
                sourceToken: selectionToken
            )

            await MainActor.run {
                if store.pendingComposerAttachments(for: composerDraftSessionID).contains(where: { $0.sourceToken == selectionToken }) {
                    return
                }
                store.addPendingComposerAttachments(sessionID: composerDraftSessionID, attachments: [attachment])
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

    private func makePhotoProjectUploads(from items: [PhotosPickerItem]) async -> [AppStore.ProjectUploadFile] {
        let timestamp = Int(Date().timeIntervalSince1970)
        var results: [AppStore.ProjectUploadFile] = []
        results.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  !data.isEmpty else { continue }

            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let mimeType = item.supportedContentTypes.first?.preferredMIMEType
            results.append(
                AppStore.ProjectUploadFile(
                    fileName: "photo-\(timestamp)-\(index + 1).\(ext)",
                    data: data,
                    mimeType: mimeType
                )
            )
        }

        return results
    }

    private func makeProjectUploadFile(from url: URL) -> AppStore.ProjectUploadFile? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        return AppStore.ProjectUploadFile(
            fileName: url.lastPathComponent,
            data: data,
            mimeType: mimeType
        )
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
        guard let normalizedData = normalizedInlineData(from: data, mimeType: mimeType) else { return nil }
        return ComposerAttachment(
            displayName: url.lastPathComponent,
            mimeType: mimeType,
            inlineDataBase64: normalizedData.base64EncodedString(),
            byteCount: normalizedData.count
        )
    }

    private func normalizedInlineData(from data: Data?, mimeType: String?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        if data.count <= maxInlineAttachmentBytes {
            return data
        }

        guard (mimeType ?? "").lowercased().hasPrefix("image/"),
              let image = UIImage(data: data) else {
            return nil
        }

        return compressedImageDataForInlineSend(image)
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

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                store.openLeftPanel()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("project.sidebar.button")

            HStack(spacing: 6) {
                Text(project?.name ?? "Project")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(project?.name ?? "Project")

            Spacer(minLength: 0)

            Button {
                store.openResults()
            } label: {
                Label("Workspace", systemImage: "folder")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.blue)

            Menu {
                Button("Rename Project") {
                    renameProjectPresented = true
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

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let needsResponse = store.sessionNeedsUserInput(sessionID: session.id)

        Button {
            store.openSession(projectID: projectID, sessionID: session.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Updated \(AppFormatters.relativeDate.localizedString(for: session.updatedAt, relativeTo: .now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    if needsResponse {
                        Text("Awaiting response")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.green.opacity(0.92))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.green.opacity(0.18))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.green.opacity(0.45))
                            )
                            .accessibilityIdentifier("project.session.awaiting.\(session.id.uuidString.lowercased())")
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project.session.row.\(session.id.uuidString.lowercased())")
        .contextMenu {
            Button("Rename") {
                renameSession = session
            }

            if session.lifecycle == .active {
                Button("Archive") {
                    store.archiveSession(projectID: projectID, sessionID: session.id)
                }
            } else {
                Button("Unarchive") {
                    store.unarchiveSession(projectID: projectID, sessionID: session.id)
                }
            }

            Button("Delete Session", role: .destructive) {
                deleteSession = session
            }
        }
    }

}
#endif
