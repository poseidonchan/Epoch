#if os(iOS)
import LabOSCore
import MarkdownUI
import SwiftUI

struct StreamingMarkdownView: View {
    let text: String
    var isStreaming: Bool
    var throttleInterval: TimeInterval = 0.08

    @Environment(\.colorScheme) private var colorScheme

    @State private var renderedText: String = ""
    @State private var pendingText: String = ""
    @State private var lastFlush: Date = .distantPast
    @State private var scheduledFlush: DispatchWorkItem?

    private var normalizedRenderedText: String {
        let source = renderedText.isEmpty ? text : renderedText
        return MarkdownDisplayNormalizer.normalize(source)
    }

    var body: some View {
        Markdown(normalizedRenderedText)
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
}
#endif
