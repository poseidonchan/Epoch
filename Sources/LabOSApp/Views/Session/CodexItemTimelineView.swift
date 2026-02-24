#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit

struct CodexItemTimelineView: View {
    let items: [CodexThreadItem]
    let statusText: String?
    var isStreaming: Bool = false
    var modelOptions: [GatewayModelInfo] = []
    var selectedModelId: String = ""
    var showAssistantActionBar: Bool = true
    var onEditUserMessage: (CodexUserMessageItem) -> Void = { _ in }
    var onRetryAgentMessage: (CodexAgentMessageItem, String?) -> Void = { _, _ in }
    var onBranchAgentMessage: (CodexAgentMessageItem) -> Void = { _ in }

    var body: some View {
        LazyVStack(spacing: 10) {
            if let statusText = displayStatus(statusText) {
                statusPill(statusText)
            }
            ForEach(items, id: \CodexThreadItem.id) { item in
                timelineRow(for: item)
            }
        }
    }

    @ViewBuilder
    private func timelineRow(for item: CodexThreadItem) -> some View {
        switch item {
        case let .userMessage(userItem):
            userBubble(item: userItem)
        case let .agentMessage(agentItem):
            agentFlat(
                item: agentItem,
                isStreaming: isStreaming && agentItem.id == latestStreamingAgentMessageID
            )
        case let .plan(planItem):
            bubble(title: "Plan", text: planItem.text)
        case let .commandExecution(commandItem):
            CodexCommandExecutionCard(item: commandItem)
        case let .fileChange(fileItem):
            CodexFileChangeCard(item: fileItem)
        case let .mcpToolCall(toolItem):
            bubble(title: "Tool \(toolItem.tool)", text: toolItem.status)
        case let .unknown(unknown):
            if isReasoningItem(unknown) {
                reasoningFlat(text: reasoningText(unknown))
            } else {
                bubble(title: unknown.type, text: unknownText(unknown))
            }
        }
    }

    private var latestStreamingAgentMessageID: String? {
        guard isStreaming else { return nil }
        for item in items.reversed() {
            if case let .agentMessage(agentItem) = item {
                return agentItem.id
            }
        }
        return nil
    }

    private func displayStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "completed", "failed":
            return nil
        case "inprogress", "in_progress", "running", "thinking":
            return "Thinking..."
        default:
            if trimmed.lowercased().contains("waiting for updates") {
                return "Thinking..."
            }
            return trimmed
        }
    }

    private func statusPill(_ status: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text(status)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var userBubbleMaxWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.8, 460)
    }

    private func userBubble(item: CodexUserMessageItem) -> some View {
        let text = userText(from: item.content)
        let images = userImageInputs(from: item.content)
        return HStack(alignment: .bottom) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 10) {
                if !images.isEmpty {
                    codexUserImageRow(images)
                        .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: userBubbleMaxWidth, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            if !text.isEmpty {
                Button {
                    copyToPasteboard(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            Button {
                onEditUserMessage(item)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
    }

    private func codexUserImageRow(_ inputs: [CodexUserInput]) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                        codexUserImageThumbnail(input)
                    }
                }
                .padding(.leading, 2)
                .padding(.trailing, 2)
            }
            .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func codexUserImageThumbnail(_ input: CodexUserInput) -> some View {
        ZStack {
            if let image = codexUserPreviewImage(input) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
    }

    private func userText(from content: [CodexUserInput]) -> String {
        content
            .compactMap { input in
                if input.type == "text" {
                    return input.text
                }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private func userImageInputs(from content: [CodexUserInput]) -> [CodexUserInput] {
        content.filter { input in
            let type = input.type.lowercased()
            if type == "localimage" { return true }
            if type == "image" {
                return input.url != nil || input.path != nil
            }
            return false
        }
    }

    private func codexUserPreviewImage(_ input: CodexUserInput) -> UIImage? {
        if let path = input.path?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !path.isEmpty,
           let image = UIImage(contentsOfFile: path) {
            return image
        }

        if let rawURL = input.url?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !rawURL.isEmpty,
           let parsed = URL(string: rawURL),
           parsed.isFileURL,
           let image = UIImage(contentsOfFile: parsed.path) {
            return image
        }

        return nil
    }

    private func agentFlat(item: CodexAgentMessageItem, isStreaming: Bool) -> some View {
        let text = item.text.isEmpty ? "Thinking..." : item.text
        return VStack(alignment: .leading, spacing: 6) {
            Text("Agent")
                .font(.caption)
                .foregroundStyle(.secondary)
            codexMarkdownText(text, isStreaming: isStreaming)

            if showAssistantActionBar {
                assistantActionBar(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contextMenu {
            Button {
                copyToPasteboard(item.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            if showAssistantActionBar {
                Button {
                    onRetryAgentMessage(item, nil)
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }

                if !modelOptions.isEmpty {
                    Menu {
                        ForEach(modelOptions, id: \.id) { model in
                            Button {
                                onRetryAgentMessage(item, model.id)
                            } label: {
                                HStack {
                                    Text(model.name)
                                    if model.id == selectedModelId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Choose Model", systemImage: "shuffle")
                    }
                }

                Button {
                    onBranchAgentMessage(item)
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }

    private func reasoningFlat(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent")
                .font(.caption)
                .foregroundStyle(.secondary)
            codexMarkdownText(text, isStreaming: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func codexMarkdownText(_ text: String, isStreaming: Bool) -> some View {
        let normalized = MarkdownDisplayNormalizer.normalizeChatMessage(text)
        let prefersMathRenderer = normalized.contains("\\(")
            || normalized.contains("\\[")
            || normalized.contains("$$")
            || normalized.contains("\\begin{")

        if prefersMathRenderer {
            MarkdownMathView(markdown: normalized)
        } else {
            StreamingMarkdownView(text: text, isStreaming: isStreaming)
        }
    }

    private func bubble(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            codexMarkdownText(text, isStreaming: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func assistantActionBar(item: CodexAgentMessageItem) -> some View {
        let itemID = item.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return HStack(spacing: 14) {
            actionIconButton(
                title: "Copy",
                systemImage: "doc.on.doc",
                identifier: "codex.message.copy.\(itemID)"
            ) {
                copyToPasteboard(item.text)
            }

            actionIconButton(
                title: "Regenerate",
                systemImage: "arrow.clockwise",
                identifier: "codex.message.retry.\(itemID)"
            ) {
                onRetryAgentMessage(item, nil)
            }

            if modelOptions.count > 1 {
                Menu {
                    ForEach(modelOptions, id: \.id) { model in
                        Button {
                            onRetryAgentMessage(item, model.id)
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.id == selectedModelId {
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
                .accessibilityIdentifier("codex.message.retry.modelMenu.\(itemID)")
            }

            actionIconButton(
                title: "Fork",
                systemImage: "arrow.triangle.branch",
                identifier: "codex.message.branch.\(itemID)"
            ) {
                onBranchAgentMessage(item)
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

    private func unknownText(_ unknown: CodexUnknownItem) -> String {
        if let text = codexString(unknown.rawPayload["text"]),
           !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return normalizeReasoningCopy(text)
        }
        if let status = codexString(unknown.rawPayload["status"]),
           !status.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return normalizeReasoningCopy(status)
        }
        if let message = codexString(unknown.rawPayload["message"]),
           !message.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return normalizeReasoningCopy(message)
        }
        return "Thinking..."
    }

    private func isReasoningItem(_ unknown: CodexUnknownItem) -> Bool {
        unknown.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "reasoning"
    }

    private func reasoningText(_ unknown: CodexUnknownItem) -> String {
        if let text = codexString(unknown.rawPayload["text"]),
           !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return normalizeReasoningCopy(text)
        }
        if let summary = codexString(unknown.rawPayload["summary"]),
           !summary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return normalizeReasoningCopy(summary)
        }
        if let status = codexString(unknown.rawPayload["status"]),
           !status.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return normalizeReasoningCopy(status)
        }
        return "Thinking..."
    }

    private func normalizeReasoningCopy(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Thinking..." }
        let lower = trimmed.lowercased()
        if lower == "inprogress"
            || lower == "in_progress"
            || lower == "running"
            || lower == "thinking"
            || lower.contains("waiting for updates")
            || lower.contains("waiting for response")
            || lower == "reasoning" {
            return "Thinking..."
        }
        return trimmed
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func codexString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(text):
            return text
        case let .number(number):
            return String(number)
        case let .bool(flag):
            return flag ? "true" : "false"
        default:
            return nil
        }
    }
}
#endif
