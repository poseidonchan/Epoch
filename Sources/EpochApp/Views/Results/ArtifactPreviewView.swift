#if os(iOS)
import EpochCore
import MarkdownUI
import SwiftUI
import UIKit

struct ArtifactPreviewView: View {
    let artifact: Artifact
    let content: String
    let image: UIImage?
    let notebook: NotebookDocument?
    let isLoading: Bool

    @State private var showExpanded = false
    @State private var showCopyToast = false
    @State private var showShareSheet = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()

                Menu {
                    Button {
                        showExpanded = true
                    } label: {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        copyPath(artifact.path)
                        showCopyToast = true
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .padding(4)
                }
            }

            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                previewBody()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(minHeight: 220, alignment: .topLeading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemBackground)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .fullScreenCover(isPresented: $showExpanded) {
            ExpandedArtifactPreview(artifact: artifact, content: content, image: image, notebook: notebook)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .overlay(alignment: .bottom) {
            if showCopyToast {
                Text("Path copied")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .foregroundStyle(.white)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showCopyToast = false
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func previewBody() -> some View {
        switch artifact.kind {
        case .image:
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "photo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 130)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                    Text("Image preview unavailable for \(artifact.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        case .notebook:
            if let notebook {
                NotebookPreviewView(notebook: notebook)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        case .python:
            HighlightedCodeWebView(code: content, language: "python", filePathForLanguageHint: artifact.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        default:
            if isMarkdownFile {
                ScrollView {
                    Group {
                        if MarkdownMathPreprocessor.likelyContainsMath(content) {
                            MarkdownMathView(markdown: content)
                        } else {
                            Markdown(content)
                                .markdownTheme(.epoch)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let language = resolvedCodeLanguage {
                HighlightedCodeWebView(code: content, language: language, filePathForLanguageHint: artifact.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var isMarkdownFile: Bool {
        URL(fileURLWithPath: artifact.path).pathExtension.lowercased() == "md"
    }

    private var resolvedCodeLanguage: String? {
        HighlightedCodeWebView.languageForFilePath(artifact.path)
    }

    private var shareItems: [Any] {
        if artifact.kind == .image, let image {
            return [image]
        }
        if !content.isEmpty {
            return [content]
        }
        return [artifact.path]
    }

    private func copyPath(_ path: String) {
#if os(iOS)
        UIPasteboard.general.string = path
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
#endif
    }
}

private struct ExpandedArtifactPreview: View {
    let artifact: Artifact
    let content: String
    let image: UIImage?
    let notebook: NotebookDocument?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            contentBody
            .navigationTitle(URL(fileURLWithPath: artifact.path).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch artifact.kind {
        case .image:
            if let image {
                ZoomableImageView(image: image)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "photo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                    Text("Image preview unavailable for \(artifact.path)")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }

        case .notebook:
            if let notebook {
                NotebookPreviewView(notebook: notebook)
            } else {
                ScrollView {
                    Text(content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
            }

        case .python:
            ScrollView {
                HighlightedCodeWebView(code: content, language: "python", filePathForLanguageHint: artifact.path)
                    .frame(minHeight: 520)
                    .padding(12)
            }

        default:
            if URL(fileURLWithPath: artifact.path).pathExtension.lowercased() == "md" {
                ScrollView {
                    if MarkdownMathPreprocessor.likelyContainsMath(content) {
                        MarkdownMathView(markdown: content)
                            .padding(12)
                    } else {
                        Markdown(content)
                            .markdownTheme(.epoch)
                            .padding(12)
                    }
                }
            } else if let language = HighlightedCodeWebView.languageForFilePath(artifact.path) {
                ScrollView {
                    HighlightedCodeWebView(code: content, language: language, filePathForLanguageHint: artifact.path)
                        .frame(minHeight: 520)
                        .padding(12)
                }
            } else {
                ScrollView {
                    Text(content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
            }
        }
    }
}

private struct ZoomableImageView: View {
    let image: UIImage

    @State private var scale: CGFloat = 1.0
    @State private var accumulatedScale: CGFloat = 1.0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
        .background(Color(.systemBackground))
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    scale = max(1.0, accumulatedScale * value)
                }
                .onEnded { _ in
                    accumulatedScale = scale
                }
        )
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
