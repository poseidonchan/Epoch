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
    let showAssistantActionBar: Bool

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

    private var userImageArtifactRefs: [ChatArtifactReference] {
        message.artifactRefs.filter { isUserImageArtifact($0) }
    }

    private var userNonImageArtifactRefs: [ChatArtifactReference] {
        message.artifactRefs.filter { !isUserImageArtifact($0) }
    }

    private var userBubbleMaxWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.8, 460)
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
        let userText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(alignment: .bottom) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 8) {
                if !userImageArtifactRefs.isEmpty {
                    userImageAttachmentsRow
                        .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
                }

                if !userText.isEmpty {
                    Text(userText)
                        .font(.body)
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: userBubbleMaxWidth, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.95) : Color(uiColor: .secondarySystemBackground))
                        )
                }

                if !userNonImageArtifactRefs.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(Array(userNonImageArtifactRefs.enumerated()), id: \.offset) { _, ref in
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

    private var userImageAttachmentsRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(userImageArtifactRefs.enumerated()), id: \.offset) { _, ref in
                        userImageThumbnail(ref)
                    }
                }
                .padding(.leading, 2)
                .padding(.trailing, 2)
            }
            .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func userImageThumbnail(_ ref: ChatArtifactReference) -> some View {
        ZStack {
            if let image = userPreviewImage(for: ref) {
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

    private func userPreviewImage(for ref: ChatArtifactReference) -> UIImage? {
        if let image = imageFromBase64(ref.inlineDataBase64) {
            return image
        }

        if let data = cachedAttachmentImageData(for: ref),
           let image = UIImage(data: data) {
            return image
        }

        if let image = imageFromFilePath(ref.path) {
            return image
        }

        return nil
    }

    private func isUserImageArtifact(_ ref: ChatArtifactReference) -> Bool {
        let mime = (ref.mimeType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime.hasPrefix("image/") {
            return true
        }

        if Self.imageExtensions.contains(pathExtension(of: ref.path)) {
            return true
        }

        if let sourceName = ref.sourceName,
           Self.imageExtensions.contains(pathExtension(of: sourceName)) {
            return true
        }

        if Self.imageExtensions.contains(pathExtension(of: ref.displayText)) {
            return true
        }

        return cachedAttachmentImageData(for: ref) != nil
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "avif",
    ]

    private func imageFromBase64(_ base64: String?) -> UIImage? {
        guard let base64,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    private func cachedAttachmentImageData(for ref: ChatArtifactReference) -> Data? {
        let payloads = store.attachmentPayload(for: message.sessionID, messageID: message.id)
        guard !payloads.isEmpty else { return nil }

        let normalizedRefName = normalizedAttachmentName(ref.sourceName ?? ref.displayText)

        let matched = payloads.first { attachment in
            if let artifactID = ref.artifactID, attachment.id == artifactID {
                return true
            }
            let attachmentName = normalizedAttachmentName(attachment.displayName)
            return !normalizedRefName.isEmpty && attachmentName == normalizedRefName
        }

        let fallbackAttachment: ComposerAttachment? = {
            if let matched { return matched }
            if payloads.count == 1 { return payloads[0] }
            return payloads.first { ($0.mimeType ?? "").lowercased().hasPrefix("image/") }
        }()

        guard let base64 = fallbackAttachment?.inlineDataBase64 else { return nil }
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private func imageFromFilePath(_ rawPath: String?) -> UIImage? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = URL(string: trimmed),
           parsed.isFileURL,
           let image = UIImage(contentsOfFile: parsed.path) {
            return image
        }

        if trimmed.hasPrefix("/") {
            return UIImage(contentsOfFile: trimmed)
        }

        return nil
    }

    private func normalizedAttachmentName(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func pathExtension(of rawPath: String?) -> String {
        guard let rawPath else { return "" }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let parsed = URL(string: trimmed),
           !parsed.pathExtension.isEmpty {
            return parsed.pathExtension.lowercased()
        }

        return URL(fileURLWithPath: trimmed).pathExtension.lowercased()
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

                if showAssistantActionBar {
                    assistantActionBar
                }
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
        case .user:
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

        case .assistant:
            Button {
                copyMessageText(message.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            if showAssistantActionBar {
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
