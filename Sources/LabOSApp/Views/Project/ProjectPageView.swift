#if os(iOS)
import LabOSCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ProjectPageView: View {
    let projectID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var seedPrompt = ""
    @State private var showArchived = false
    @State private var showFileSheet = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var importErrorMessage: String?
    @State private var sendErrorMessage: String?
    @State private var composerHeight: CGFloat = 0
    @State private var composerDraftSessionID = UUID()

    @State private var renameProjectPresented = false
    @State private var renameSession: Session?
    @State private var deleteSession: Session?

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
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: composerHeight + 8)
            }
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottom) {
            projectComposer
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 2)
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { composerHeight = $0 }
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
            store.addUploadedFiles(projectID: projectID, fileNames: fileNames, createdBySessionID: nil)
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
        .alert("Couldn’t send message", isPresented: Binding(
            get: { sendErrorMessage != nil },
            set: { if !$0 { sendErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendErrorMessage ?? "Unknown error")
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
                showFileSheet = true
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
                get: { store.permissionLevel(for: composerDraftSessionID) },
                set: { store.setPermissionLevel(projectID: projectID, sessionID: composerDraftSessionID, level: $0) }
            ),
            submitLabel: "Send",
            style: .chatGPT,
	            attachmentAction: {
	                showFileSheet = true
	            },
	            modelOptions: store.availableModels,
	            thinkingLevelOptions: store.availableThinkingLevels.isEmpty ? ThinkingLevel.allCases : store.availableThinkingLevels,
	            contextRemainingFraction: store.contextRemainingFraction(for: composerDraftSessionID),
	            contextWindowTokens: store.contextWindowTokens(for: composerDraftSessionID) ?? 258_000
	        ) {
	            let message = seedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
	            guard !message.isEmpty else { return }

            let planModeEnabled = store.planModeEnabled(for: composerDraftSessionID)
            let modelId = store.selectedModelId(for: composerDraftSessionID)
            let thinkingLevel = store.selectedThinkingLevel(for: composerDraftSessionID)
            let permissionLevel = store.permissionLevel(for: composerDraftSessionID)

            // Clear immediately for snappy UI; if creation fails we restore it.
            seedPrompt = ""

            Task { @MainActor in
                guard let session = await store.createSession(projectID: projectID, title: nil) else {
                    seedPrompt = message
                    sendErrorMessage = store.lastGatewayErrorMessage ?? "Failed to create a session on the Hub."
                    return
                }
                store.setPlanModeEnabled(for: session.id, enabled: planModeEnabled)
                if !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.setSelectedModelId(for: session.id, modelId: modelId)
                }
                store.setSelectedThinkingLevel(for: session.id, level: thinkingLevel)
                store.setPermissionLevel(projectID: session.projectID, sessionID: session.id, level: permissionLevel)
                store.sendMessage(projectID: session.projectID, sessionID: session.id, text: message)
            }
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
            store.addUploadedFiles(projectID: projectID, fileNames: fileNames, createdBySessionID: nil)
        case let .failure(error):
            importErrorMessage = error.localizedDescription
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

            Button("Results") {
                store.openResults()
            }
            .buttonStyle(.bordered)

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
        let needsApproval = store.pendingApproval(for: session.id) != nil

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
                    if needsApproval {
                        Text("Awaiting Approval")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.blue.opacity(0.14))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.blue.opacity(0.3))
                            )
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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
