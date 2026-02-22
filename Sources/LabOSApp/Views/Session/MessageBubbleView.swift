#if os(iOS)
import LabOSCore
import MarkdownUI
import SwiftUI
import UIKit

struct MessageBubbleView: View {
    let message: ChatMessage
    let modelOptions: [GatewayModelInfo]
    let onArtifactTap: (ChatArtifactReference) -> Void
    let onEditMessage: (ChatMessage) -> Void
    let onRetryMessage: (ChatMessage, String?) -> Void
    let onBranchMessage: (ChatMessage) -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var streamingIdleFallbackActive = false
    @State private var streamingIdleTask: Task<Void, Never>?

    private var inlineActiveProcessForMessage: ActiveInlineProcess? {
        store.activeInlineProcess(for: message.sessionID, assistantMessageID: message.id)
    }

    private var inlineActiveLine: String? {
        inlineActiveProcessForMessage?.activeLine
    }

    private var inlineShouldBlink: Bool {
        guard let process = inlineActiveProcessForMessage else { return false }
        return process.phase == .thinking && process.activeLine != nil
    }

    private var inlinePersistedSummary: AssistantProcessSummary? {
        store.persistedProcessSummary(for: message.id)
    }

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantMessage
        case .tool, .system:
            statusMessage
        }
    }

    private var userBubble: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 8) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.95) : Color(uiColor: .secondarySystemBackground))
                    )

                if !message.artifactRefs.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(Array(message.artifactRefs.enumerated()), id: \.offset) { _, ref in
                            artifactReferenceBadge(ref)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contextMenu {
            messageActionsMenu
        }
    }

    private var assistantMessage: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                if let activeLine = inlineActiveLine {
                    AssistantProcessInlineView(
                        activeLine: activeLine,
                        isBlinking: inlineShouldBlink,
                        summary: nil
                    )
                }

                assistantText
                    .font(.body)

                if let summary = inlinePersistedSummary {
                    AssistantProcessInlineView(
                        activeLine: nil,
                        isBlinking: false,
                        summary: summary
                    )
                }

                if let plan = message.proposedPlan {
                    planSummary(plan)
                }

                if !message.artifactRefs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(message.artifactRefs.enumerated()), id: \.offset) { _, ref in
                            artifactReferenceBadge(ref)
                        }
                    }
                }

                assistantActionBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contextMenu {
            messageActionsMenu
        }
    }

    @ViewBuilder
    private func artifactReferenceBadge(_ ref: ChatArtifactReference) -> some View {
        let isSessionScoped = (ref.scope ?? "").lowercased() == "session"
        if isSessionScoped {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                Text(ref.displayText)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
        } else {
            Button {
                onArtifactTap(ref)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                    Text(ref.displayText)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var statusMessage: some View {
        Group {
            if message.role == .tool {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: toolMessageIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(toolMessageHeader)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let output = toolMessageOutput {
                            Text(output)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Text(message.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private var toolMessageHeader: String {
        let parts = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return message.text }
        return String(first)
    }

    private var toolMessageOutput: String? {
        let parts = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var toolMessageIcon: String {
        let header = toolMessageHeader.lowercased()
        if header.contains("command") { return "terminal" }
        if header.contains("tool call") { return "wrench.and.screwdriver" }
        if header.contains("output") { return "doc.badge.plus" }
        return "info.circle"
    }

    @ViewBuilder
    private var assistantText: some View {
        let isStoreStreaming = store.streamingAssistantMessageIDBySession[message.sessionID] == message.id
        let isStreaming = isStoreStreaming && !streamingIdleFallbackActive
        let normalized = MarkdownDisplayNormalizer.normalizeChatMessage(message.text)
        let prefersMathRenderer = normalized.contains("\\(")
            || normalized.contains("\\[")
            || normalized.contains("$$")
            || normalized.contains("\\begin{")

        Group {
            if isStreaming || !prefersMathRenderer {
                StreamingMarkdownView(text: message.text, isStreaming: isStreaming)
            } else {
                // Keep markdown-it + KaTeX for richer finalized payloads, but avoid WKWebView
                // for plain assistant text to reduce delayed pop-in on session open.
                MarkdownMathView(markdown: normalized)
            }
        }
        .onAppear { scheduleStreamingIdleFallback() }
        .onDisappear {
            streamingIdleTask?.cancel()
            streamingIdleTask = nil
        }
        .onChange(of: message.text) { _, _ in
            scheduleStreamingIdleFallback()
        }
        .onChange(of: store.streamingAssistantMessageIDBySession[message.sessionID] == message.id) { _, _ in
            scheduleStreamingIdleFallback()
        }
    }

    private func scheduleStreamingIdleFallback() {
        streamingIdleTask?.cancel()
        streamingIdleTask = nil

        let isStoreStreaming = store.streamingAssistantMessageIDBySession[message.sessionID] == message.id
        guard isStoreStreaming else {
            streamingIdleFallbackActive = false
            return
        }

        streamingIdleFallbackActive = false
        let snapshot = message.text

        streamingIdleTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let stillStoreStreaming = store.streamingAssistantMessageIDBySession[message.sessionID] == message.id
                if stillStoreStreaming, message.text == snapshot {
                    streamingIdleFallbackActive = true
                }
            }
        }
    }

    private func planSummary(_ plan: ExecutionPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Proposed Plan")
                .font(.caption.weight(.semibold))
            ForEach(plan.steps.indices, id: \.self) { idx in
                Text("\(idx + 1). \(plan.steps[idx].title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.yellow.opacity(0.14))
        )
    }

    private var assistantActionBar: some View {
        let messageID = message.id.uuidString.lowercased()
        return HStack(spacing: 14) {
            actionIconButton(
                title: "Copy",
                systemImage: "doc.on.doc",
                identifier: "message.copy.\(messageID)"
            ) {
                copyMessageText(message.text)
            }

            actionIconButton(
                title: "Retry",
                systemImage: "arrow.clockwise",
                identifier: "message.retry.\(messageID)"
            ) {
                onRetryMessage(message, nil)
            }

            if modelOptions.count > 1 {
                Menu {
                    let currentModelId = store.selectedModelId(for: message.sessionID)
                    ForEach(modelOptions, id: \.id) { model in
                        Button {
                            onRetryMessage(message, model.id)
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.id == currentModelId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry with different model")
                .accessibilityIdentifier("message.retry.modelMenu.\(messageID)")
            }

            actionIconButton(
                title: "Branch",
                systemImage: "arrow.triangle.branch",
                identifier: "message.branch.\(messageID)"
            ) {
                onBranchMessage(message)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func actionIconButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var messageActionsMenu: some View {
        switch message.role {
        case .user, .assistant:
            Button {
                copyMessageText(message.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                onEditMessage(message)
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button {
                onRetryMessage(message, nil)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }

            if !modelOptions.isEmpty {
                Menu {
                    let currentModelId = store.selectedModelId(for: message.sessionID)
                    ForEach(modelOptions, id: \.id) { model in
                        Button {
                            onRetryMessage(message, model.id)
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.id == currentModelId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Retry With Different Model", systemImage: "shuffle")
                }
            }
        case .tool, .system:
            EmptyView()
        }
    }

private func copyMessageText(_ text: String) {
        UIPasteboard.general.string = text
    }
}

struct AssistantProcessInlineView: View {
    let activeLine: String?
    let isBlinking: Bool
    let summary: AssistantProcessSummary?

    @State private var isExpanded = false
    @State private var blinkPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let activeLine {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                    Text(activeLine)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .opacity(isBlinking ? (blinkPulse ? 0.42 : 1.0) : 1.0)
            }

            if let summary {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(summary.headline)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.entries) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: detailIcon(for: entry.state))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12, height: 12)

                                Text(detailText(for: entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .onAppear {
            refreshBlink()
        }
        .onChange(of: isBlinking) { _, _ in
            refreshBlink()
        }
        .onChange(of: activeLine) { _, _ in
            refreshBlink()
        }
    }

    private func refreshBlink() {
        guard isBlinking, activeLine != nil else {
            blinkPulse = false
            return
        }
        blinkPulse = false
        withAnimation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true)) {
            blinkPulse = true
        }
    }

    private func detailText(for entry: ProcessEntry) -> String {
        switch entry.state {
        case .active:
            return entry.activeText
        case .completed:
            return entry.completedText
        case .failed:
            let text = entry.completedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Failed" : "Failed: \(text)"
        }
    }

    private func detailIcon(for state: ProcessEntryState) -> String {
        switch state {
        case .active:
            return "clock"
        case .completed:
            return "checkmark"
        case .failed:
            return "exclamationmark.triangle"
        }
    }
}
#endif
