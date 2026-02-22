#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit

struct ArtifactsBrowserView: View {
    let projectID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var searchText = ""
    @State private var selectedArtifact: Artifact?
    @State private var selectedContent = ""
    @State private var selectedImage: UIImage?
    @State private var selectedNotebook: NotebookDocument?
    @State private var loadingContent = false
    @State private var previewTask: Task<Void, Never>?

    private var resultsArtifacts: [Artifact] {
        store.generatedArtifacts(for: projectID)
    }

    private func filterArtifacts(_ artifacts: [Artifact]) -> [Artifact] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return artifacts }
        return artifacts.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var filteredResults: [Artifact] {
        filterArtifacts(resultsArtifacts)
    }

    private var resultSections: [ArtifactSection] {
        let grouped = Dictionary(grouping: filteredResults) { artifact in
            artifact.path.components(separatedBy: "/").first ?? "root"
        }

        return grouped.keys.sorted().map { key in
            ArtifactSection(folder: key, artifacts: grouped[key, default: []].sorted { $0.path < $1.path })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter files...", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if resultSections.isEmpty {
                            ContentUnavailableView(
                                filteredResults.isEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "No generated results yet"
                                    : "No matching results",
                                systemImage: "sparkles.rectangle.stack",
                                description: Text(
                                    filteredResults.isEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "Run a plan to generate result files."
                                        : "Try a different filter."
                                )
                            )
                            .padding(.top, 40)
                        } else {
                            sourceHeader(title: "Generated Results", systemImage: "sparkles")
                            sectionList(resultSections)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .onAppear {
                    handleDeepLinkSelection(proxy: proxy)
                }
                .onChange(of: store.selectedArtifactPath) { _, _ in
                    handleDeepLinkSelection(proxy: proxy)
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

    private func artifactRow(_ artifact: Artifact) -> some View {
        Button {
            selectArtifact(artifact)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: artifact.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(fileURLWithPath: artifact.path).lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(AppFormatters.shortDate.string(from: artifact.modifiedAt))
                        if let sizeBytes = artifact.sizeBytes {
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
                    .fill(rowHighlightColor(for: artifact))
            )
        }
        .buttonStyle(.plain)
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
    private func sectionList(_ sections: [ArtifactSection]) -> some View {
        ForEach(sections) { section in
            HStack {
                Text("\(section.folder)/")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            ForEach(section.artifacts) { artifact in
                artifactRow(artifact)
                    .id(artifact.path)
            }
        }
    }

    private func rowHighlightColor(for artifact: Artifact) -> Color {
        if store.highlightedArtifactPath == artifact.path {
            return Color.yellow.opacity(0.24)
        }
        if selectedArtifact?.id == artifact.id {
            return Color.blue.opacity(0.16)
        }
        return Color.clear
    }

    private func selectArtifact(_ artifact: Artifact) {
        selectedArtifact = artifact
        store.selectedArtifactPath = artifact.path

        loadingContent = true
        selectedContent = ""
        selectedImage = nil
        selectedNotebook = nil

        previewTask?.cancel()
        let requestedPath = artifact.path
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

    private func loadPreview(artifact: Artifact) async -> ArtifactPreviewPayload {
        switch artifact.kind {
        case .image:
            let data = await store.fetchArtifactData(projectID: projectID, path: artifact.path)
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
            let content = await store.fetchArtifactContent(projectID: projectID, path: artifact.path)
            return ArtifactPreviewPayload(text: content, image: nil, notebook: nil)
        }
    }

    private func loadTextPreferRawIfLarge(artifact: Artifact) async -> String {
        if let size = artifact.sizeBytes, size > 1_048_576, let data = await store.fetchArtifactData(projectID: projectID, path: artifact.path) {
            return String(decoding: data, as: UTF8.self)
        }
        return await store.fetchArtifactContent(projectID: projectID, path: artifact.path)
    }

    private func handleDeepLinkSelection(proxy: ScrollViewProxy) {
        guard let path = store.selectedArtifactPath,
              let target = resultsArtifacts.first(where: { $0.path == path })
        else {
            if let selectedArtifact,
               !resultsArtifacts.contains(where: { $0.id == selectedArtifact.id }) {
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
            selectArtifact(target)
        }
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

private struct ArtifactSection: Identifiable {
    let folder: String
    let artifacts: [Artifact]

    var id: String { folder }
}

private struct ArtifactPreviewPayload {
    var text: String
    var image: UIImage?
    var notebook: NotebookDocument?
}
#endif
