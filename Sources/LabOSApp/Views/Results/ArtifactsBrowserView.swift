#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit

struct ArtifactsBrowserView: View {
    let projectID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var searchText = ""
    @State private var includeHidden = false
    @State private var generatedOnly = false
    @State private var currentDirectoryPath = "."

    @State private var selectedArtifact: Artifact?
    @State private var selectedContent = ""
    @State private var selectedImage: UIImage?
    @State private var selectedNotebook: NotebookDocument?
    @State private var loadingContent = false
    @State private var previewTask: Task<Void, Never>?

    private var workspaceEntries: [WorkspaceEntry] {
        store.workspaceEntries(for: projectID)
    }

    private var artifactByPath: [String: Artifact] {
        Dictionary(uniqueKeysWithValues: store.artifacts(for: projectID).map { ($0.path, $0) })
    }

    private var workspaceRefreshKey: String {
        "\(projectID.uuidString)|\(normalizedDirectoryPath(currentDirectoryPath))|\(includeHidden)"
    }

    private var visibleEntries: [WorkspaceEntry] {
        var entries = workspaceEntries

        if generatedOnly {
            entries = entries.filter { isGeneratedEntry($0) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            entries = entries.filter { entry in
                displayName(for: entry).localizedCaseInsensitiveContains(query)
                    || entry.path.localizedCaseInsensitiveContains(query)
            }
        }

        return entries.sorted { lhs, rhs in
            if lhs.type != rhs.type {
                return lhs.type == .dir
            }
            return displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }
    }

    private var directoryEntries: [WorkspaceEntry] {
        visibleEntries.filter { $0.type == .dir }
    }

    private var fileEntries: [WorkspaceEntry] {
        visibleEntries.filter { $0.type == .file }
    }

    private var allFileEntriesInCurrentDirectory: [WorkspaceEntry] {
        workspaceEntries.filter { $0.type == .file }
    }

    private var breadcrumbSegments: [WorkspaceBreadcrumbSegment] {
        let normalizedPath = normalizedDirectoryPath(currentDirectoryPath)
        var segments: [WorkspaceBreadcrumbSegment] = [
            WorkspaceBreadcrumbSegment(path: ".", title: "Workspace")
        ]
        guard normalizedPath != "." else { return segments }

        var prefix = ""
        for component in normalizedPath.split(separator: "/") {
            let value = String(component)
            prefix = prefix.isEmpty ? value : "\(prefix)/\(value)"
            segments.append(WorkspaceBreadcrumbSegment(path: prefix, title: value))
        }
        return segments
    }

    private var canNavigateBack: Bool {
        normalizedDirectoryPath(currentDirectoryPath) != "."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter files in this folder...", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))

                folderNavigationBar

                HStack(spacing: 12) {
                    Toggle("Generated only", isOn: $generatedOnly)
                        .toggleStyle(.switch)
                    Spacer()
                    Toggle("Hidden", isOn: $includeHidden)
                        .toggleStyle(.switch)
                }
                .font(.caption)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visibleEntries.isEmpty {
                        emptyState
                    } else {
                        if !directoryEntries.isEmpty {
                            sourceHeader(title: "Folders", systemImage: "folder")
                            directoryList(directoryEntries)
                        }

                        if !fileEntries.isEmpty {
                            sourceHeader(title: "Files", systemImage: "doc")
                            fileList(fileEntries)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .task(id: workspaceRefreshKey) {
                await store.refreshWorkspace(
                    projectID: projectID,
                    includeHidden: includeHidden,
                    path: normalizedDirectoryPath(currentDirectoryPath),
                    recursive: false,
                    limit: 2_000
                )
                reconcileSelectionForCurrentDirectory()
                syncSelectionWithExternalPath()
            }
            .onAppear {
                syncSelectionWithExternalPath()
            }
            .onChange(of: store.selectedArtifactPath) { _, _ in
                syncSelectionWithExternalPath()
            }
            .onChange(of: workspaceEntries) { _, _ in
                reconcileSelectionForCurrentDirectory()
                syncSelectionWithExternalPath()
            }
            .onChange(of: projectID) { _, _ in
                currentDirectoryPath = "."
                clearSelection()
            }

            Divider()

            if let selectedArtifact {
                ArtifactPreviewView(
                    artifact: selectedArtifact,
                    content: selectedContent,
                    image: selectedImage,
                    notebook: selectedNotebook,
                    isLoading: loadingContent
                )
            } else {
                VStack(spacing: 6) {
                    Text("Select a file to preview")
                        .font(.subheadline)
                    Text("Supports images, text/code files, and notebooks with graceful fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(18)
            }
        }
    }

    private var folderNavigationBar: some View {
        HStack(spacing: 8) {
            Button {
                navigateToParentDirectory()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canNavigateBack)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(breadcrumbSegments.indices), id: \.self) { index in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        let segment = breadcrumbSegments[index]
                        Button {
                            jumpToDirectory(segment.path)
                        } label: {
                            Text(segment.title)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(segment.path == normalizedDirectoryPath(currentDirectoryPath) ? .primary : .secondary)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        let copy = emptyStateCopy()

        return ContentUnavailableView(
            copy.title,
            systemImage: "folder",
            description: Text(copy.subtitle)
        )
        .padding(.top, 40)
    }

    private func emptyStateCopy() -> (title: String, subtitle: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspaceEntries.isEmpty {
            return (
                title: "This folder is empty",
                subtitle: "Try a different folder or generate files in this workspace."
            )
        }
        if !query.isEmpty {
            return (title: "No matching files", subtitle: "Try a different filter.")
        }
        if generatedOnly {
            return (
                title: "No generated files in this folder",
                subtitle: "Turn off the filter or open a different folder."
            )
        }
        return (
            title: "This folder is empty",
            subtitle: "Try a different folder or generate files in this workspace."
        )
    }

    private func sourceHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func directoryList(_ entries: [WorkspaceEntry]) -> some View {
        ForEach(entries) { entry in
            Button {
                enterDirectory(entry)
            } label: {
                workspaceRow(entry, showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func fileList(_ entries: [WorkspaceEntry]) -> some View {
        ForEach(entries) { entry in
            Button {
                selectEntry(entry)
            } label: {
                workspaceRow(entry, showsChevron: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func workspaceRow(_ entry: WorkspaceEntry, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(for: entry))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(entry.type == .dir ? "Folder" : "File")
                    if let modifiedAt = entry.modifiedAt {
                        Text(AppFormatters.shortDate.string(from: modifiedAt))
                    }
                    if let sizeBytes = entry.sizeBytes {
                        Text(AppFormatters.byteCount.string(fromByteCount: Int64(sizeBytes)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHighlightColor(for: entry.path))
        )
    }

    private func displayName(for entry: WorkspaceEntry) -> String {
        URL(fileURLWithPath: entry.path).lastPathComponent
    }

    private func isGeneratedEntry(_ entry: WorkspaceEntry) -> Bool {
        if entry.type == .dir {
            return isGeneratedDirectoryPath(entry.path)
        }
        return isGeneratedPath(entry.path)
    }

    private func isGeneratedDirectoryPath(_ path: String) -> Bool {
        path == "artifacts"
            || path == "runs"
            || path == "logs"
            || path.hasPrefix("artifacts/")
            || path.hasPrefix("runs/")
            || path.hasPrefix("logs/")
    }

    private func isGeneratedPath(_ path: String) -> Bool {
        if let artifact = artifactByPath[path] {
            return artifact.origin == .generated
        }
        return path.hasPrefix("artifacts/") || path.hasPrefix("runs/") || path.hasPrefix("logs/")
    }

    private func rowHighlightColor(for path: String) -> Color {
        if store.highlightedArtifactPath == path {
            return Color.yellow.opacity(0.24)
        }
        if selectedArtifact?.path == path {
            return Color.blue.opacity(0.16)
        }
        return Color.clear
    }

    private func enterDirectory(_ entry: WorkspaceEntry) {
        guard entry.type == .dir else { return }
        let target = normalizedDirectoryPath(entry.path)
        guard target != normalizedDirectoryPath(currentDirectoryPath) else { return }
        currentDirectoryPath = target
        clearSelectionIfOutsideDirectory(target)
    }

    private func jumpToDirectory(_ path: String) {
        let target = normalizedDirectoryPath(path)
        guard target != normalizedDirectoryPath(currentDirectoryPath) else { return }
        currentDirectoryPath = target
        clearSelectionIfOutsideDirectory(target)
    }

    private func navigateToParentDirectory() {
        guard canNavigateBack else { return }
        jumpToDirectory(parentDirectoryPath(for: currentDirectoryPath))
    }

    private func parentDirectoryPath(for path: String) -> String {
        let normalized = normalizedDirectoryPath(path)
        guard normalized != "." else { return "." }
        let components = normalized.split(separator: "/")
        guard components.count > 1 else { return "." }
        return components.dropLast().map(String.init).joined(separator: "/")
    }

    private func normalizedDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return "." }
        let normalized = trimmed
            .split(separator: "/")
            .filter { $0 != "." && !$0.isEmpty }
            .map(String.init)
            .joined(separator: "/")
        return normalized.isEmpty ? "." : normalized
    }

    private func clearSelectionIfOutsideDirectory(_ directoryPath: String) {
        guard let selectedPath = selectedArtifact?.path else { return }
        if !isPath(selectedPath, insideDirectory: directoryPath) {
            clearSelection()
        }
    }

    private func isPath(_ path: String, insideDirectory directoryPath: String) -> Bool {
        let normalizedDirectory = normalizedDirectoryPath(directoryPath)
        if normalizedDirectory == "." { return true }
        return path == normalizedDirectory || path.hasPrefix("\(normalizedDirectory)/")
    }

    private func clearSelection() {
        selectedArtifact = nil
        selectedContent = ""
        selectedImage = nil
        selectedNotebook = nil
        loadingContent = false
        previewTask?.cancel()
    }

    private func reconcileSelectionForCurrentDirectory() {
        guard let selectedArtifact else { return }
        if !allFileEntriesInCurrentDirectory.contains(where: { $0.path == selectedArtifact.path }) {
            clearSelection()
        }
    }

    private func syncSelectionWithExternalPath() {
        guard let selectedPath = store.selectedArtifactPath else { return }
        let targetDirectory = parentDirectoryPath(for: selectedPath)
        if targetDirectory != normalizedDirectoryPath(currentDirectoryPath) {
            currentDirectoryPath = targetDirectory
            return
        }

        guard let target = allFileEntriesInCurrentDirectory.first(where: { $0.path == selectedPath }) else { return }
        if selectedArtifact?.path != selectedPath {
            selectEntry(target)
        }
    }

    private func selectEntry(_ entry: WorkspaceEntry) {
        let artifact = syntheticArtifact(from: entry)
        selectedArtifact = artifact
        store.selectedArtifactPath = entry.path

        loadingContent = true
        selectedContent = ""
        selectedImage = nil
        selectedNotebook = nil

        previewTask?.cancel()
        let requestedPath = entry.path
        previewTask = Task {
            let preview = await loadPreview(artifact: artifact)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard selectedArtifact?.path == requestedPath else { return }
                selectedContent = preview.text
                selectedImage = preview.image
                selectedNotebook = preview.notebook
                loadingContent = false
            }
        }
    }

    private func syntheticArtifact(from entry: WorkspaceEntry) -> Artifact {
        if let known = artifactByPath[entry.path] {
            return known
        }
        return Artifact(
            projectID: projectID,
            path: entry.path,
            kind: ArtifactKind.infer(from: entry.path),
            origin: isGeneratedPath(entry.path) ? .generated : .userUpload,
            modifiedAt: entry.modifiedAt ?? .now,
            sizeBytes: entry.sizeBytes,
            createdBySessionID: nil,
            createdByRunID: nil,
            indexStatus: nil,
            indexSummary: nil,
            indexedAt: nil
        )
    }

    private func loadPreview(artifact: Artifact) async -> ArtifactPreviewPayload {
        switch artifact.kind {
        case .image:
            let data = await store.fetchWorkspaceData(projectID: projectID, path: artifact.path)
            let image = data.flatMap { UIImage(data: $0) }
            return ArtifactPreviewPayload(text: artifact.path, image: image, notebook: nil)

        case .notebook:
            let jsonText = await loadTextPreferRawIfLarge(artifact: artifact)
            let notebook = try? NotebookDocument.decode(from: jsonText)
            return ArtifactPreviewPayload(text: jsonText, image: nil, notebook: notebook)

        case .python:
            let source = await loadTextPreferRawIfLarge(artifact: artifact)
            return ArtifactPreviewPayload(text: source, image: nil, notebook: nil)

        case .text, .json, .log, .unknown:
            if HighlightedCodeWebView.languageForFilePath(artifact.path) != nil {
                let source = await loadTextPreferRawIfLarge(artifact: artifact)
                return ArtifactPreviewPayload(text: source, image: nil, notebook: nil)
            }
            let content = await store.fetchWorkspaceContent(projectID: projectID, path: artifact.path)
            return ArtifactPreviewPayload(text: content, image: nil, notebook: nil)
        }
    }

    private func loadTextPreferRawIfLarge(artifact: Artifact) async -> String {
        if let size = artifact.sizeBytes, size > 1_048_576,
           let data = await store.fetchWorkspaceData(projectID: projectID, path: artifact.path) {
            return String(decoding: data, as: UTF8.self)
        }
        return await store.fetchWorkspaceContent(projectID: projectID, path: artifact.path)
    }

    private func icon(for entry: WorkspaceEntry) -> String {
        if entry.type == .dir {
            return "folder"
        }
        if HighlightedCodeWebView.languageForFilePath(entry.path) != nil {
            return "chevron.left.forwardslash.chevron.right"
        }
        return icon(for: ArtifactKind.infer(from: entry.path))
    }

    private func icon(for kind: ArtifactKind) -> String {
        switch kind {
        case .image:
            return "photo"
        case .notebook:
            return "book"
        case .python:
            return "chevron.left.forwardslash.chevron.right"
        case .log:
            return "doc.plaintext"
        case .json:
            return "curlybraces"
        case .text:
            return "text.alignleft"
        case .unknown:
            return "doc"
        }
    }
}

private struct WorkspaceBreadcrumbSegment: Identifiable {
    let path: String
    let title: String

    var id: String { path }
}

private struct ArtifactPreviewPayload {
    var text: String
    var image: UIImage?
    var notebook: NotebookDocument?
}
#endif
