#if os(iOS)
import EpochCore
import SwiftUI
import UIKit

struct ArtifactsBrowserView: View {
    let projectID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var searchText = ""
    @State private var includeHidden = false
    @State private var expandedDirectoryPaths: Set<String> = ["."]
    @State private var pendingExternalSelectionPath: String?
    @State private var lastHandledExternalSelectionPath: String?
    @State private var suppressSelectedArtifactPathSync = false

    @State private var selectedArtifact: Artifact?
    @State private var selectedContent = ""
    @State private var selectedImage: UIImage?
    @State private var selectedNotebook: NotebookDocument?
    @State private var loadingContent = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewSheetPresented = false
    @State private var previewSheetDetent: PresentationDetent = .fraction(0.42)

    private var workspaceEntries: [WorkspaceEntry] {
        store.workspaceEntries(for: projectID)
    }

    private var allFileEntriesInWorkspace: [WorkspaceEntry] {
        workspaceEntries.filter { $0.type == .file }
    }

    private var artifactByPath: [String: Artifact] {
        Dictionary(uniqueKeysWithValues: store.artifacts(for: projectID).map { ($0.path, $0) })
    }

    private var workspaceRefreshKey: String {
        "\(projectID.uuidString)|\(includeHidden)"
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var treePresentation: WorkspaceTreePresentation {
        buildTreePresentation()
    }

    var body: some View {
        let presentation = treePresentation

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter files in workspace...", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    includeHidden.toggle()
                } label: {
                    Image(systemName: includeHidden ? "eye" : "eye.slash")
                        .font(.subheadline)
                        .foregroundStyle(includeHidden ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(includeHidden ? "Hide hidden files" : "Show hidden files")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if presentation.visibleNodes.isEmpty {
                        emptyState
                    } else {
                        treeList(
                            presentation.visibleNodes,
                            expandedPaths: presentation.effectiveExpandedDirectoryPaths
                        )
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
                    path: ".",
                    recursive: true,
                    limit: 20_000
                )
                reconcileSelectionForWorkspace()
                resolvePendingExternalSelectionIfPossible()
            }
            .refreshable {
                await store.refreshWorkspace(
                    projectID: projectID,
                    includeHidden: includeHidden,
                    path: ".",
                    recursive: true,
                    limit: 20_000
                )
            }
            .onAppear {
                handleExternalSelectionChange(store.selectedArtifactPath)
            }
            .onChange(of: store.selectedArtifactPath) { _, value in
                if suppressSelectedArtifactPathSync {
                    suppressSelectedArtifactPathSync = false
                    return
                }
                handleExternalSelectionChange(value)
            }
            .onChange(of: workspaceEntries) { _, _ in
                reconcileSelectionForWorkspace()
                resolvePendingExternalSelectionIfPossible()
            }
            .onChange(of: projectID) { _, _ in
                expandedDirectoryPaths = ["."]
                clearSelection()
                pendingExternalSelectionPath = nil
                lastHandledExternalSelectionPath = nil
            }
        }
        .sheet(isPresented: $previewSheetPresented) {
            previewSheetContent
        }
        .onChange(of: previewSheetPresented) { _, presented in
            if !presented {
                previewSheetDetent = .fraction(0.42)
            }
        }
    }

    @ViewBuilder
    private func treeList(_ nodes: [WorkspaceTreeNode], expandedPaths: Set<String>) -> some View {
        ForEach(nodes) { node in
            Button {
                handleNodeTap(node)
            } label: {
                workspaceRow(node, expandedPaths: expandedPaths)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var previewSheetContent: some View {
        Group {
            if let selectedArtifact {
                ArtifactPreviewView(
                    artifact: selectedArtifact,
                    content: selectedContent,
                    image: selectedImage,
                    notebook: selectedNotebook,
                    isLoading: loadingContent
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.fraction(0.42), .large], selection: $previewSheetDetent)
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
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
        let query = normalizedSearchQuery
        if workspaceEntries.isEmpty {
            return (
                title: "Workspace is empty",
                subtitle: "Generate files or run tasks to populate this workspace."
            )
        }
        if !query.isEmpty {
            return (
                title: "No matching files in workspace",
                subtitle: "Try a different filter keyword."
            )
        }
        return (
            title: "No files to display",
            subtitle: "Adjust filters and try again."
        )
    }

    private func workspaceRow(_ node: WorkspaceTreeNode, expandedPaths: Set<String>) -> some View {
        let isDirectory = node.type == .dir
        let isExpanded = isDirectory && expandedPaths.contains(node.path)

        return HStack(spacing: 10) {
            if isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            } else {
                Color.clear
                    .frame(width: 12, height: 12)
            }

            Image(systemName: icon(for: node))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(isDirectory ? "Folder" : "File")
                    if let modifiedAt = node.entry?.modifiedAt {
                        Text(AppFormatters.shortDate.string(from: modifiedAt))
                    }
                    if let sizeBytes = node.entry?.sizeBytes {
                        Text(AppFormatters.byteCount.string(fromByteCount: Int64(sizeBytes)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.leading, 8 + CGFloat(node.depth) * 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHighlightColor(for: node.path))
        )
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

    private func handleNodeTap(_ node: WorkspaceTreeNode) {
        if node.type == .dir {
            toggleDirectoryExpansion(path: node.path)
            return
        }
        selectEntry(node.entry ?? WorkspaceEntry(path: node.path, type: .file))
    }

    private func toggleDirectoryExpansion(path: String) {
        let normalized = normalizedRelativePath(path)
        guard normalized != "." else { return }

        if expandedDirectoryPaths.contains(normalized) {
            expandedDirectoryPaths.remove(normalized)
        } else {
            expandedDirectoryPaths.insert(normalized)
        }
    }

    private func normalizedRelativePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return "." }
        let normalized = trimmed
            .split(separator: "/")
            .filter { $0 != "." && !$0.isEmpty }
            .map(String.init)
            .joined(separator: "/")
        return normalized.isEmpty ? "." : normalized
    }

    private func parentDirectoryPath(for path: String) -> String {
        let normalized = normalizedRelativePath(path)
        guard normalized != "." else { return "." }
        let components = normalized.split(separator: "/")
        guard components.count > 1 else { return "." }
        return components.dropLast().map(String.init).joined(separator: "/")
    }

    private func displayName(forPath path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func buildTreePresentation() -> WorkspaceTreePresentation {
        let entryByPath = Dictionary(uniqueKeysWithValues: workspaceEntries.map { (normalizedRelativePath($0.path), $0) })
        let query = normalizedSearchQuery

        var matchedPaths = Set<String>()
        for entry in workspaceEntries {
            let normalizedPath = normalizedRelativePath(entry.path)
            guard normalizedPath != "." else { continue }

            if query.isEmpty || matchesSearch(entry, query: query) {
                matchedPaths.insert(normalizedPath)
            }
        }

        guard !matchedPaths.isEmpty else {
            return WorkspaceTreePresentation(visibleNodes: [], effectiveExpandedDirectoryPaths: ["."])
        }

        var includedPaths = Set<String>()
        var nodeTypeByPath: [String: WorkspaceEntryType] = [:]
        var nodeEntryByPath: [String: WorkspaceEntry] = [:]

        func includePathAndAncestors(_ inputPath: String) {
            var cursor = normalizedRelativePath(inputPath)
            guard cursor != "." else { return }

            while cursor != "." {
                if includedPaths.insert(cursor).inserted {
                    if let known = entryByPath[cursor] {
                        nodeTypeByPath[cursor] = known.type
                        nodeEntryByPath[cursor] = known
                    } else {
                        nodeTypeByPath[cursor] = .dir
                    }
                }

                let parent = parentDirectoryPath(for: cursor)
                if parent == "." { break }
                cursor = parent
            }
        }

        for path in matchedPaths {
            includePathAndAncestors(path)
        }

        var childrenByParent: [String: [String]] = [:]
        for path in includedPaths {
            let parent = parentDirectoryPath(for: path)
            childrenByParent[parent, default: []].append(path)
        }

        for (parent, children) in childrenByParent {
            childrenByParent[parent] = children.sorted { lhs, rhs in
                let lhsType = nodeTypeByPath[lhs] ?? .dir
                let rhsType = nodeTypeByPath[rhs] ?? .dir
                if lhsType != rhsType {
                    return lhsType == .dir
                }
                return displayName(forPath: lhs).localizedCaseInsensitiveCompare(displayName(forPath: rhs)) == .orderedAscending
            }
        }

        func makeNodes(parentPath: String, depth: Int) -> [WorkspaceTreeNode] {
            let childPaths = childrenByParent[parentPath] ?? []
            return childPaths.map { childPath in
                let childType = nodeTypeByPath[childPath] ?? .dir
                let childChildren = childType == .dir ? makeNodes(parentPath: childPath, depth: depth + 1) : []
                return WorkspaceTreeNode(
                    path: childPath,
                    name: displayName(forPath: childPath),
                    type: childType,
                    depth: depth,
                    entry: nodeEntryByPath[childPath],
                    children: childChildren
                )
            }
        }

        let rootChildren = makeNodes(parentPath: ".", depth: 0)
        let effectiveExpandedPaths = effectiveExpandedDirectoryPaths(
            nodeTypeByPath: nodeTypeByPath,
            searchMatchedPaths: matchedPaths
        )

        var visibleNodes: [WorkspaceTreeNode] = []
        func appendVisible(_ nodes: [WorkspaceTreeNode]) {
            for node in nodes {
                visibleNodes.append(node)
                if node.type == .dir, effectiveExpandedPaths.contains(node.path) {
                    appendVisible(node.children)
                }
            }
        }

        appendVisible(rootChildren)

        return WorkspaceTreePresentation(
            visibleNodes: visibleNodes,
            effectiveExpandedDirectoryPaths: effectiveExpandedPaths
        )
    }

    private func effectiveExpandedDirectoryPaths(
        nodeTypeByPath: [String: WorkspaceEntryType],
        searchMatchedPaths: Set<String>
    ) -> Set<String> {
        var expanded = expandedDirectoryPaths
        expanded.insert(".")

        guard !normalizedSearchQuery.isEmpty else {
            return expanded
        }

        for path in searchMatchedPaths {
            let normalized = normalizedRelativePath(path)
            let type = nodeTypeByPath[normalized] ?? .file
            var cursor = type == .dir ? normalized : parentDirectoryPath(for: normalized)

            while cursor != "." {
                expanded.insert(cursor)
                cursor = parentDirectoryPath(for: cursor)
            }
        }

        return expanded
    }

    private func matchesSearch(_ entry: WorkspaceEntry, query: String) -> Bool {
        let name = displayName(forPath: entry.path)
        return name.localizedCaseInsensitiveContains(query)
            || entry.path.localizedCaseInsensitiveContains(query)
    }

    private func isGeneratedPath(_ path: String) -> Bool {
        if let artifact = artifactByPath[path] {
            return artifact.origin == .generated
        }
        return path.hasPrefix("artifacts/") || path.hasPrefix("runs/") || path.hasPrefix("logs/")
    }

    private func setSelectedArtifactPathWithoutSync(_ path: String?) {
        suppressSelectedArtifactPathSync = true
        store.selectedArtifactPath = path
    }

    private func clearSelection() {
        selectedArtifact = nil
        selectedContent = ""
        selectedImage = nil
        selectedNotebook = nil
        loadingContent = false
        previewSheetPresented = false
        previewTask?.cancel()
    }

    private func reconcileSelectionForWorkspace() {
        guard let selectedArtifact else { return }
        if !allFileEntriesInWorkspace.contains(where: { normalizedRelativePath($0.path) == normalizedRelativePath(selectedArtifact.path) }) {
            clearSelection()
        }
    }

    private func expandAncestorsForPath(_ path: String) {
        var cursor = parentDirectoryPath(for: path)
        while cursor != "." {
            expandedDirectoryPaths.insert(cursor)
            cursor = parentDirectoryPath(for: cursor)
        }
        expandedDirectoryPaths.insert(".")
    }

    private func handleExternalSelectionChange(_ selectedPath: String?) {
        guard let selectedPath = selectedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedPath.isEmpty
        else {
            pendingExternalSelectionPath = nil
            lastHandledExternalSelectionPath = nil
            return
        }

        let normalizedPath = normalizedRelativePath(selectedPath)
        guard normalizedPath != "." else {
            pendingExternalSelectionPath = nil
            lastHandledExternalSelectionPath = nil
            return
        }

        if normalizedPath == lastHandledExternalSelectionPath {
            return
        }

        pendingExternalSelectionPath = normalizedPath
        expandAncestorsForPath(normalizedPath)
        resolvePendingExternalSelectionIfPossible()
    }

    private func resolvePendingExternalSelectionIfPossible() {
        guard let pendingPath = pendingExternalSelectionPath else { return }

        let externalSelectedPath = normalizedRelativePath(store.selectedArtifactPath ?? "")
        guard externalSelectedPath == pendingPath else {
            pendingExternalSelectionPath = nil
            return
        }

        guard let target = allFileEntriesInWorkspace.first(where: {
            normalizedRelativePath($0.path) == pendingPath
        }) else {
            return
        }

        if normalizedRelativePath(selectedArtifact?.path ?? "") != pendingPath {
            selectEntry(target)
        } else {
            loadingContent = false
        }

        lastHandledExternalSelectionPath = pendingPath
        pendingExternalSelectionPath = nil
    }

    private func selectEntry(_ entry: WorkspaceEntry) {
        let artifact = syntheticArtifact(from: entry)
        selectedArtifact = artifact
        if store.selectedArtifactPath != entry.path {
            setSelectedArtifactPathWithoutSync(entry.path)
        }
        if !previewSheetPresented {
            previewSheetDetent = .fraction(0.42)
            previewSheetPresented = true
        }

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

    private func icon(for node: WorkspaceTreeNode) -> String {
        if node.type == .dir {
            return "folder"
        }
        if HighlightedCodeWebView.languageForFilePath(node.path) != nil {
            return "chevron.left.forwardslash.chevron.right"
        }
        return icon(for: ArtifactKind.infer(from: node.path))
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

private struct WorkspaceTreeNode: Identifiable {
    let path: String
    let name: String
    let type: WorkspaceEntryType
    let depth: Int
    let entry: WorkspaceEntry?
    let children: [WorkspaceTreeNode]

    var id: String { path }
}

private struct WorkspaceTreePresentation {
    let visibleNodes: [WorkspaceTreeNode]
    let effectiveExpandedDirectoryPaths: Set<String>
}

private struct ArtifactPreviewPayload {
    var text: String
    var image: UIImage?
    var notebook: NotebookDocument?
}
#endif
