#if os(iOS)
import LabOSCore
import MarkdownUI
import SwiftUI
import UIKit

struct NotebookPreviewView: View {
    let notebook: NotebookDocument

    @State private var modal: PreviewModal?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(notebook.cells.enumerated()), id: \.offset) { idx, cell in
                    cellView(cell, index: idx)
                }
            }
            .padding(12)
        }
        .sheet(item: $modal) { modal in
            NavigationStack {
                ScrollView {
                    switch modal.kind {
                    case let .code(code, language):
                        HighlightedCodeWebView(code: code, language: language)
                            .frame(minHeight: 420)
                            .padding(12)
                    case let .html(html):
                        SanitizedHTMLWebView(html: html)
                            .frame(minHeight: 420)
                            .padding(12)
                    }
                }
                .navigationTitle(modal.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { self.modal = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: NotebookDocument.Cell, index: Int) -> some View {
        switch cell.cellType {
        case .markdown:
            markdownCell(cell.source)
        case .code:
            codeCell(cell, index: index)
        case .raw, .unknown:
            rawCell(cell.source)
        }
    }

    private func markdownCell(_ markdown: String) -> some View {
        Markdown(markdown)
            .markdownTheme(.gitHub)
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(.primary)
                BackgroundColor(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06))
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                )
            }
            .textSelection(.enabled)
    }

    private func rawCell(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
    }

    private func codeCell(_ cell: NotebookDocument.Cell, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                let count = cell.executionCount.map(String.init) ?? " "
                Text("In [\(count)]")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    copyToPasteboard(cell.source)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)

                Button {
                    modal = PreviewModal(kind: .code(cell.source, language: notebook.language), title: "Code Cell \(index + 1)")
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            HighlightedCodeWebView(code: cell.source, language: notebook.language)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                )

            if !cell.outputs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(cell.outputs.enumerated()), id: \.offset) { _, output in
                        outputView(output)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    @ViewBuilder
    private func outputView(_ output: NotebookDocument.Output) -> some View {
        switch output {
        case let .stream(_, text):
            outputBubble(title: "Output", systemImage: "terminal", accent: .blue) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .error(ename, evalue, traceback):
            let header = [ename, evalue].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ": ")
            outputBubble(title: header.isEmpty ? "Error" : header, systemImage: "exclamationmark.triangle.fill", accent: .red) {
                Text(traceback.isEmpty ? (header.isEmpty ? "Error" : header) : traceback)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .rich(rich):
            VStack(alignment: .leading, spacing: 10) {
                if let text = rich.textPlain, !text.isEmpty {
                    outputBubble(title: "Result", systemImage: "doc.text", accent: .secondary) {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let html = rich.html, !html.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("HTML Output", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Expand") {
                                modal = PreviewModal(kind: .html(html), title: "HTML Output")
                            }
                            .font(.caption.weight(.semibold))
                        }

                        SanitizedHTMLWebView(html: html)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                            )
                    }
                }

                if let png = rich.imagePNGBase64, let image = decodeBase64Image(png) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        )
                } else if let jpg = rich.imageJPEGBase64, let image = decodeBase64Image(jpg) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        )
                }
            }
        }
    }

    private func outputBubble<Content: View>(
        title: String,
        systemImage: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func decodeBase64Image(_ value: String) -> UIImage? {
        guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: data)
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }
}

private struct PreviewModal: Identifiable {
    enum Kind {
        case code(String, language: String)
        case html(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
}
#endif
