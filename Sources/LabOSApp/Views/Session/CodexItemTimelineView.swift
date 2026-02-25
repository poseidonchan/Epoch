#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit

struct CodexItemTimelineView: View {
    let items: [CodexThreadItem]
    let statusText: String?
    let persistedDurationByTurnID: [String: Int]
    var isStreaming: Bool = false
    var showAssistantActionBar: Bool = true
    var onEditUserMessage: (CodexUserMessageItem) -> Void = { _ in }
    var onBranchAgentMessage: (CodexAgentMessageItem) -> Void = { _ in }
    var onFinalizeTurnDuration: (_ turnID: String, _ durationMs: Int) -> Void = { _, _ in }

    @State private var expandedTurnIDs: Set<String> = []
    @State private var expandedGroupIDs: Set<String> = []
    @State private var expandedLeafIDs: Set<String> = []
    @State private var turnStartByID: [String: Date] = [:]
    @State private var turnStartByIdentity: [String: Date] = [:]
    @State private var finalizedDurationByID: [String: Int] = [:]
    @State private var wasStreamingByTurnID: [String: Bool] = [:]
    @State private var pendingAutoCollapseTokenByTurnID: [String: UUID] = [:]

    private static let autoCollapseDelayNanoseconds: UInt64 = 420_000_000
    private static let autoCollapseAnimation = Animation.easeInOut(duration: 0.2)
    private static let searchingWebStatusText = "Searching web..."

    private var turns: [CodexTrajectoryTurn] {
        CodexTrajectoryAssembler.assemble(from: items, isStreaming: isStreaming)
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

    private var agentMessageByID: [String: CodexAgentMessageItem] {
        var map: [String: CodexAgentMessageItem] = [:]
        for item in items {
            if case let .agentMessage(agent) = item {
                map[agent.id] = agent
            }
        }
        return map
    }

    private var latestFinalTurnActionTarget: CodexAssistantActionTarget? {
        CodexAssistantActionTargets.latestFinalTurnTarget(in: turns)
    }

    private var preTurnItems: [CodexThreadItem] {
        guard let firstUserIndex = items.firstIndex(where: Self.isUserMessage) else {
            return items
        }
        guard firstUserIndex > 0 else { return [] }
        return Array(items.prefix(firstUserIndex))
    }

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(preTurnItems, id: \.id) { item in
                fallbackRow(for: item)
            }

            ForEach(turns) { turn in
                turnRow(turn)
            }

            if turns.isEmpty,
               preTurnItems.isEmpty,
               let status = displayStatus(statusText) {
                statusPill(status)
            }
        }
        .onAppear {
            syncTrajectoryState(with: turns)
        }
        .onChange(of: turns) { _, updatedTurns in
            syncTrajectoryState(with: updatedTurns)
        }
        .onChange(of: persistedDurationByTurnID) { _, _ in
            syncTrajectoryState(with: turns)
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: CodexTrajectoryTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            userBubble(item: turn.userMessage)

            if turn.hasTrajectorySummary {
                CodexTrajectorySummaryBar(
                    turnID: turn.id,
                    isExpanded: expandedTurnIDs.contains(turn.id),
                    isStreaming: turn.isStreaming,
                    startedAt: turnStartByID[turn.id],
                    completedDurationMs: finalizedDurationByID[turn.id],
                    estimatedDurationMs: turn.estimatedDurationMs,
                    onToggle: {
                        toggleTurn(turn.id)
                    }
                )

                if expandedTurnIDs.contains(turn.id) {
                    trajectoryDetails(for: turn)
                        .transition(.opacity)
                }
            }

            if let finalID = turn.finalAnswerItemID,
               let finalText = turn.finalAnswerText,
               !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalAnswerBlock(turn: turn, finalID: finalID, finalText: finalText)
            } else if turn.isStreaming || turn.hasThinkingStatus {
                Text(pendingTurnStatus(for: turn))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex.turn.thinking.\(turn.id.lowercased())")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .animation(Self.autoCollapseAnimation, value: expandedTurnIDs.contains(turn.id))
        .accessibilityIdentifier("codex.turn.\(turn.id.lowercased())")
    }

    private func finalAnswerBlock(turn: CodexTrajectoryTurn, finalID: String, finalText: String) -> some View {
        let actionItem = agentMessageByID[finalID]
        let targetStreaming = turn.isStreaming && finalID == latestStreamingAgentMessageID
        let canShowActions = showAssistantActionBar
            && actionItem != nil
            && actionTargetIsActionable(turnID: turn.id, actionItem: actionItem)
            && !targetStreaming

        return VStack(alignment: .leading, spacing: 6) {
            finalAnswerContent(finalText, isStreaming: targetStreaming)
                .accessibilityIdentifier("codex.final.answer.\(finalID.lowercased())")

            if canShowActions, let actionItem {
                assistantActionBar(item: actionItem)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    copyToPasteboard(finalText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if canShowActions, let actionItem {
                Button {
                    onBranchAgentMessage(actionItem)
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }

    @ViewBuilder
    private func finalAnswerContent(_ text: String, isStreaming: Bool) -> some View {
        if let proposedPlan = CodexProposedPlanParser.parse(from: text) {
            VStack(alignment: .leading, spacing: 10) {
                if !proposedPlan.leadingText.isEmpty {
                    codexMarkdownText(proposedPlan.leadingText, isStreaming: isStreaming)
                }
                proposedPlanCard(proposedPlan.planText)
                if !proposedPlan.trailingText.isEmpty {
                    codexMarkdownText(proposedPlan.trailingText, isStreaming: isStreaming)
                }
            }
        } else {
            codexMarkdownText(text, isStreaming: isStreaming)
        }
    }

    private func proposedPlanCard(_ planText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proposed plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            codexMarkdownText(planText, isStreaming: false)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func trajectoryDetails(for turn: CodexTrajectoryTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.hasThinkingStatus {
                Text("Thinking...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex.trajectory.thinking.\(turn.id.lowercased())")
            }

            ForEach(turn.groups) { group in
                CodexTrajectoryGroupView(
                    group: group,
                    isExpanded: expandedGroupIDs.contains(group.id),
                    isLeafExpanded: { leafID in
                        expandedLeafIDs.contains(leafID)
                    },
                    onToggleGroup: {
                        toggleGroup(group.id)
                    },
                    onToggleLeaf: { leafID in
                        toggleLeaf(leafID)
                    }
                )
            }
        }
        .padding(.leading, 2)
        .accessibilityIdentifier("codex.trajectory.details.\(turn.id.lowercased())")
    }

    @ViewBuilder
    private func fallbackRow(for item: CodexThreadItem) -> some View {
        switch item {
        case let .userMessage(userItem):
            userBubble(item: userItem)
        case let .plan(planItem):
            bubble(title: "Plan", text: planItem.text)
        case let .commandExecution(commandItem):
            CodexCommandExecutionCard(item: commandItem)
        case let .fileChange(fileItem):
            CodexFileChangeCard(item: fileItem)
        case let .mcpToolCall(toolItem):
            bubble(title: "Tool \(toolItem.tool)", text: toolItem.status)
        case let .webSearch(item):
            bubble(title: "Web search", text: item.query)
        case let .unknown(unknown):
            if isReasoningItem(unknown) {
                Text("Thinking...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                bubble(title: unknown.type, text: unknownText(unknown))
            }
        case let .agentMessage(agentItem):
            codexMarkdownText(agentItem.text, isStreaming: false)
        }
    }

    private static func isUserMessage(_ item: CodexThreadItem) -> Bool {
        if case .userMessage = item {
            return true
        }
        return false
    }

    private func toggleTurn(_ turnID: String) {
        if expandedTurnIDs.contains(turnID) {
            expandedTurnIDs.remove(turnID)
        } else {
            expandedTurnIDs.insert(turnID)
        }
    }

    private func toggleGroup(_ groupID: String) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
    }

    private func toggleLeaf(_ leafID: String) {
        if expandedLeafIDs.contains(leafID) {
            expandedLeafIDs.remove(leafID)
        } else {
            expandedLeafIDs.insert(leafID)
        }
    }

    private func syncTrajectoryState(with turns: [CodexTrajectoryTurn]) {
        let now = Date()
        let activeTurnIDs = Set(turns.map(\.id))
        var activeIdentities: Set<String> = []

        for (index, turn) in turns.enumerated() {
            let turnIdentity = trajectoryIdentity(for: turn, index: index)
            activeIdentities.insert(turnIdentity)

            if finalizedDurationByID[turn.id] == nil,
               let persistedDurationMs = persistedDurationByTurnID[turn.id],
               persistedDurationMs > 0 {
                finalizedDurationByID[turn.id] = persistedDurationMs
            }

            if turnStartByID[turn.id] == nil,
               let preservedStartedAt = turnStartByIdentity[turnIdentity] {
                turnStartByID[turn.id] = preservedStartedAt
            }

            if (turn.isStreaming || turn.hasTrajectorySummary),
               turnStartByID[turn.id] == nil {
                turnStartByID[turn.id] = now
            }

            if let startedAt = turnStartByID[turn.id] {
                turnStartByIdentity[turnIdentity] = startedAt
            }

            let wasStreaming = wasStreamingByTurnID[turn.id] ?? false

            if turn.isStreaming {
                expandedTurnIDs.insert(turn.id)
                pendingAutoCollapseTokenByTurnID.removeValue(forKey: turn.id)
            } else if wasStreaming {
                finalizeTurnDurationIfNeeded(turnID: turn.id, now: now)
                if turn.hasTrajectorySummary, turn.finalAnswerItemID != nil {
                    scheduleAutoCollapse(for: turn.id)
                } else {
                    pendingAutoCollapseTokenByTurnID.removeValue(forKey: turn.id)
                }
            }

            wasStreamingByTurnID[turn.id] = turn.isStreaming
        }

        expandedTurnIDs = expandedTurnIDs.intersection(activeTurnIDs)
        turnStartByID = turnStartByID.filter { activeTurnIDs.contains($0.key) }
        turnStartByIdentity = turnStartByIdentity.filter { activeIdentities.contains($0.key) }
        finalizedDurationByID = finalizedDurationByID.filter { activeTurnIDs.contains($0.key) }
        wasStreamingByTurnID = wasStreamingByTurnID.filter { activeTurnIDs.contains($0.key) }
        pendingAutoCollapseTokenByTurnID = pendingAutoCollapseTokenByTurnID.filter { activeTurnIDs.contains($0.key) }

        let activeGroupIDs = Set(turns.flatMap { $0.groups.map(\.id) })
        expandedGroupIDs = expandedGroupIDs.intersection(activeGroupIDs)

        let activeLeafIDs = Set(turns.flatMap { $0.trajectoryLeaves.map(\.id) })
        expandedLeafIDs = expandedLeafIDs.intersection(activeLeafIDs)
    }

    private func trajectoryIdentity(for turn: CodexTrajectoryTurn, index: Int) -> String {
        "\(index):\(userInputSignature(turn.userMessage.content))"
    }

    private func userInputSignature(_ inputs: [CodexUserInput]) -> String {
        inputs
            .map { input in
                [
                    input.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    input.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    input.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                ].joined(separator: "|")
            }
            .joined(separator: "||")
    }

    private func scheduleAutoCollapse(for turnID: String) {
        let token = UUID()
        pendingAutoCollapseTokenByTurnID[turnID] = token

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.autoCollapseDelayNanoseconds)

            guard pendingAutoCollapseTokenByTurnID[turnID] == token else { return }
            guard let turn = turns.first(where: { $0.id == turnID }),
                  !turn.isStreaming,
                  turn.finalAnswerItemID != nil else {
                return
            }

            withAnimation(Self.autoCollapseAnimation) {
                expandedTurnIDs.remove(turnID)
            }
            pendingAutoCollapseTokenByTurnID.removeValue(forKey: turnID)
            finalizeTurnDurationIfNeeded(turnID: turnID, now: Date())
        }
    }

    private func finalizeTurnDurationIfNeeded(turnID: String, now: Date) {
        guard finalizedDurationByID[turnID] == nil,
              let startedAt = turnStartByID[turnID]
        else { return }

        let durationMs = max(0, Int(now.timeIntervalSince(startedAt) * 1_000))
        guard durationMs > 0 else { return }
        finalizedDurationByID[turnID] = durationMs
        onFinalizeTurnDuration(turnID, durationMs)
    }

    private func pendingTurnStatus(for turn: CodexTrajectoryTurn) -> String {
        if turn.isStreaming {
            if displayStatus(statusText) == Self.searchingWebStatusText {
                return Self.searchingWebStatusText
            }
            if case .webSearch? = latestActionableItem(in: turn) {
                return Self.searchingWebStatusText
            }
        }
        return "Thinking..."
    }

    private func latestActionableItem(in turn: CodexTrajectoryTurn) -> CodexThreadItem? {
        for leaf in turn.trajectoryLeaves.reversed() {
            switch leaf.item {
            case let .agentMessage(agent) where agent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                continue
            default:
                return leaf.item
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
        case "websearch", "web search":
            return Self.searchingWebStatusText
        case "inprogress", "in_progress", "running", "thinking":
            return "Thinking..."
        default:
            let lower = trimmed.lowercased()
            if lower.contains("websearch")
                || lower.contains("web search")
                || lower.contains("web.search") {
                return Self.searchingWebStatusText
            }
            if lower.contains("waiting for updates") {
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
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                        .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
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
        let rowWidth = userImageRowWidth(imageCount: inputs.count)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(inputs.enumerated()), id: \.offset) { _, input in
                    codexUserImageThumbnail(input)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: rowWidth, alignment: .trailing)
        .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
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
            return text
        }
        if let status = codexString(unknown.rawPayload["status"]),
           !status.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return status
        }
        if let message = codexString(unknown.rawPayload["message"]),
           !message.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            return message
        }
        return "Thinking..."
    }

    private func isReasoningItem(_ unknown: CodexUnknownItem) -> Bool {
        unknown.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "reasoning"
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

    private func actionTargetIsActionable(turnID: String, actionItem: CodexAgentMessageItem?) -> Bool {
        guard let actionItem,
              let target = latestFinalTurnActionTarget else {
            return false
        }
        return target.turnID == turnID && target.messageID == actionItem.id
    }

    private func userImageRowWidth(imageCount: Int) -> CGFloat {
        guard imageCount > 0 else { return userBubbleMaxWidth }
        let thumbnailWidth: CGFloat = 88
        let spacing: CGFloat = 8
        let horizontalPadding: CGFloat = 4
        let totalWidth = (CGFloat(imageCount) * thumbnailWidth)
            + (CGFloat(max(0, imageCount - 1)) * spacing)
            + horizontalPadding
        return min(userBubbleMaxWidth, totalWidth)
    }
}
#endif
