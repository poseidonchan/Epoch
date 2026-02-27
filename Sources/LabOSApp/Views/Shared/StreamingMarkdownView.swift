#if os(iOS)
import LabOSCore
import MarkdownUI
import SwiftUI

struct StreamingMarkdownView: View {
    let text: String
    var isStreaming: Bool
    var throttleInterval: TimeInterval = 0.2
    var onImageTap: ((URL) -> Void)? = nil
    var resolveImageURL: ((URL) -> URL?)? = nil
    var onLinkTap: ((URL) -> Void)? = nil

    @State private var renderedText: String = ""
    @State private var pendingText: String = ""
    @State private var lastFlush: Date = .distantPast
    @State private var scheduledFlush: DispatchWorkItem?

    private var normalizedRenderedText: String {
        let source = renderedText.isEmpty ? text : renderedText
        return MarkdownDisplayNormalizer.normalizeChatMessage(source)
    }

    private var shouldRenderMarkdown: Bool {
        Self.likelyContainsMarkdownSyntax(normalizedRenderedText)
    }

    private var shouldBypassMarkdownRenderer: Bool {
        // MarkdownUI can become expensive for very large payloads (especially with many links).
        // Fall back to plain text rendering to keep the chat responsive.
        if normalizedRenderedText.count > 40_000 {
            return true
        }
        return Self.containsTooManyLinks(normalizedRenderedText, limit: 40)
    }

    var body: some View {
        Group {
            if shouldRenderMarkdown, !shouldBypassMarkdownRenderer {
                Markdown(normalizedRenderedText)
                    .markdownTheme(.labOS)
                    .markdownImageProvider(
                        ChatMarkdownImageProvider(
                            onImageTap: onImageTap,
                            resolveImageURL: resolveImageURL
                        )
                    )
                    .environment(\.openURL, OpenURLAction { url in
                        if let handler = onLinkTap {
                            handler(url)
                            return .handled
                        }
                        return .systemAction
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            } else {
                Text(normalizedRenderedText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
        }
        .onAppear {
            renderedText = text
            pendingText = text
            lastFlush = .distantPast
        }
        .onDisappear {
            scheduledFlush?.cancel()
            scheduledFlush = nil
        }
        .onChange(of: text) { _, newValue in
            pendingText = newValue
            flushIfNeeded()
        }
        .onChange(of: isStreaming) { _, _ in
            flushIfNeeded(force: !isStreaming)
        }
    }

    private func flushIfNeeded(force: Bool = false) {
        if !isStreaming || force {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            renderedText = pendingText
            lastFlush = Date()
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastFlush)
        if elapsed >= throttleInterval {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            renderedText = pendingText
            lastFlush = now
            return
        }

        guard scheduledFlush == nil else { return }
        let delay = throttleInterval - elapsed
        let work = DispatchWorkItem {
            renderedText = pendingText
            lastFlush = Date()
            scheduledFlush = nil
        }
        scheduledFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func likelyContainsMarkdownSyntax(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if MarkdownDisplayNormalizer.likelyContainsCodeBlock(text) { return true }
        if text.contains("`") || text.contains("**") || text.contains("__") || text.contains("](") {
            return true
        }
        if text.contains("$$") || text.contains("\\(") || text.contains("\\[") || text.contains("\\begin{") {
            return true
        }
        if text.range(of: #"(?m)^\s{0,3}#{1,6}\s+\S+"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?m)^\s{0,3}[-*+]\s+\S+"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?m)^\s{0,3}\d+\.\s+\S+"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?m)^\s{0,3}>\s+\S+"#, options: .regularExpression) != nil,
           text.contains("\n> ") {
            return true
        }
        if text.range(of: #"\|.*\n\s*\|?\s*:?-{3,}"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func containsTooManyLinks(_ text: String, limit: Int) -> Bool {
        guard limit >= 0 else { return true }
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            guard let range = text.range(of: "http", range: searchStart..<text.endIndex) else {
                return false
            }
            count += 1
            if count > limit {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }
}
#endif
