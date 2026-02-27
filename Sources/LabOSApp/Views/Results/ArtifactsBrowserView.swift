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

    private var visibleEntries: [WorkspaceEntry] {
        var entries = workspaceEntries

        if generatedOnly {
            let generatedFiles = entries
                .filter { $0.type == .file }
                .filter { isGeneratedPath($0.path) }
                .map(\.path)

            let generatedSet = Set(generatedFiles)
            var visibleDirs = Set<String>()
            for filePath in generatedSet {
                let components = filePath.split(separator: "/")
                guard components.count > 1 else { continue }
                var prefix = ""
                for component in components.dropLast() {
                    let value = String(component)
                    prefix = prefix.isEmpty ? value : "\(prefix)/\(value)"
                    visibleDirs.insert(prefix)
                }
            }

            entries = entries.filter { entry in
                if entry.type == .file {
                    return generatedSet.contains(entry.path)
                }
                return visibleDirs.contains(entry.path)
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            entries = entries.filter { $0.path.localizedCaseInsensitiveContains(query) }
        }

        return entries.sorted { $0.path < $1.path }
    }

    private var fileEntries: [WorkspaceEntry] {
        visibleEntries.filter { $0.type == .file }
    }

    private var sections: [WorkspaceSection] {
        let grouped = Dictionary(grouping: visibleEntries) { entry in
            entry.path.components(separatedBy: "/").first ?? "root"
        }
        return grouped.keys.sorted().map { key in
            WorkspaceSection(name: key, entries: grouped[key, default: []].sorted { $0.path < $1.path })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter workspace files...", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))

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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if sections.isEmpty {
                            ContentUnavailableView(
                                visibleEntries.isEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "No workspace files yet"
                                    : "No matching files",
                                systemImage: "folder",
                                description: Text(
                                    visibleEntries.isEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "Workspace is empty or bridge is not connected."
                                        : "Try a different filter."
                                )
                            )
                            .padding(.top, 40)
                        } else {
                            sourceHeader(title: "Workspace Files", systemImage: "folder")
                            sectionList(sections)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .onAppear {
                    Task { await store.refreshWorkspace(projectID: projectID, includeHidden: includeHidden) }
                    handleDeepLinkSelection(proxy: proxy)
                }
                .onChange(of: store.selectedArtifactPath) { _, _ in
                    handleDeepLinkSelection(proxy: proxy)
                }
                .onChange(of: includeHidden) { _, value in
                    Task { await store.refreshWorkspace(projectID: projectID, includeHidden: value) }
                }
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

    private func isGeneratedPath(_ path: String) -> Bool {
        if let artifact = artifactByPath[path] {
            return artifact.origin == .generated
        }
        return path.hasPrefix("artifacts/") || path.hasPrefix("runs/") || path.hasPrefix("logs/")
    }

    private func workspaceRow(_ entry: WorkspaceEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(entry.type == .dir ? "Directory" : "File")
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHighlightColor(for: entry.path))
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
    private func sectionList(_ sections: [WorkspaceSection]) -> some View {
        ForEach(sections) { section in
            HStack {
                Text("\(section.name)/")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            ForEach(section.entries) { entry in
                if entry.type == .file {
                    Button {
                        selectEntry(entry)
                    } label: {
                        workspaceRow(entry)
                    }
                    .buttonStyle(.plain)
                    .id(entry.path)
                } else {
                    workspaceRow(entry)
                        .id(entry.path)
                }
            }
        }
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

    private func handleDeepLinkSelection(proxy: ScrollViewProxy) {
        guard let path = store.selectedArtifactPath,
              let target = fileEntries.first(where: { $0.path == path })
        else {
            if let selectedArtifact,
               !fileEntries.contains(where: { $0.path == selectedArtifact.path }) {
                self.selectedArtifact = nil
                self.selectedContent = ""
                self.selectedImage = nil
                self.selectedNotebook = nil
                self.loadingContent = false
                self.previewTask?.cancel()
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(path, anchor: .center)
        }

        if selectedArtifact?.path != path {
            selectEntry(target)
        }
    }

    private func icon(for entry: WorkspaceEntry) -> String {
        if entry.type == .dir {
            return "folder"
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

private struct WorkspaceSection: Identifiable {
    let name: String
    let entries: [WorkspaceEntry]

    var id: String { name }
}

private struct ArtifactPreviewPayload {
    var text: String
    var image: UIImage?
    var notebook: NotebookDocument?
}
#endif
