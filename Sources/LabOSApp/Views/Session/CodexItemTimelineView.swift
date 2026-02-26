#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit

struct CodexItemTimelineView: View {
    let items: [CodexThreadItem]
    let statusText: String?
    let persistedDurationByTurnID: [String: Int]
    let startedAtByTurnID: [String: Date]
    let isPlanModeEnabled: Bool
    let interruptedTurnIDs: Set<String>
    let proposedPlanTextByTurnID: [String: String]
    var isSessionInFlight: Bool = false
    var isStreaming: Bool = false
    var showAssistantActionBar: Bool = true
    var onEditUserMessage: (CodexUserMessageItem) -> Void = { _ in }
    var onBranchAgentMessage: (CodexAgentMessageItem) -> Void = { _ in }
    var onFinalizeTurnDuration: (_ turnID: String, _ durationMs: Int) -> Void = { _, _ in }

    private struct TurnKey: Hashable, Sendable {
        let signature: String
        let occurrence: Int
    }

    @State private var expandedTurnKeys: Set<TurnKey> = []
    @State private var expandedGroupIDs: Set<String> = []
    @State private var expandedLeafIDs: Set<String> = []
    @State private var turnKeyByTurnID: [String: TurnKey] = [:]
    @State private var startedAtByTurnKey: [TurnKey: Date] = [:]
    @State private var finalizedDurationMsByTurnKey: [TurnKey: Int] = [:]
    @State private var wasStreamingByTurnKey: [TurnKey: Bool] = [:]

    private static let turnExpansionAnimation = Animation.easeInOut(duration: 0.2)
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
        let shouldShowSummary = turn.hasTrajectorySummary
            || turn.isStreaming
            || (isPlanModeEnabled && (turn.hasThinkingStatus || turn.finalAnswerItemID != nil))
        let proposedPlanText = inlineProposedPlanText(for: turn)

        VStack(alignment: .leading, spacing: 8) {
            userBubble(item: turn.userMessage)

            if shouldShowSummary {
                let turnKey = turnKeyByTurnID[turn.id]
                CodexTrajectorySummaryBar(
                    turnID: turn.id,
                    isExpanded: isTurnExpanded(turn.id),
                    isStreaming: turn.isStreaming,
                    isInterrupted: interruptedTurnIDs.contains(turn.id),
                    startedAt: turnKey.flatMap { startedAtByTurnKey[$0] },
                    completedDurationMs: turnKey.flatMap { finalizedDurationMsByTurnKey[$0] },
                    estimatedDurationMs: turn.estimatedDurationMs,
                    onToggle: {
                        toggleTurn(turn.id)
                    }
                )

                if isTurnExpanded(turn.id) {
                    trajectoryDetails(for: turn)
                        .transition(.opacity)
                }
            }

            if let finalID = turn.finalAnswerItemID,
               let finalText = turn.finalAnswerText,
               !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalAnswerBlock(
                    turn: turn,
                    finalID: finalID,
                    finalText: finalText,
                    proposedPlanText: proposedPlanText,
                    isLatestTurn: turns.last?.id == turn.id
                )
            } else if let proposedPlanText {
                proposedPlanCard(proposedPlanText)
            } else if turn.isStreaming || turn.hasThinkingStatus {
                Text(pendingTurnStatus(for: turn))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex.turn.thinking.\(turn.id.lowercased())")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .animation(Self.turnExpansionAnimation, value: isTurnExpanded(turn.id))
        .accessibilityIdentifier("codex.turn.\(turn.id.lowercased())")
    }

    private func finalAnswerBlock(
        turn: CodexTrajectoryTurn,
        finalID: String,
        finalText: String,
        proposedPlanText: String?,
        isLatestTurn: Bool
    ) -> some View {
        let actionItem = agentMessageByID[finalID]
        let targetStreaming = turn.isStreaming && finalID == latestStreamingAgentMessageID
        let isLatestInFlightTurn = isSessionInFlight && isLatestTurn
        let copyText = finalAnswerCopyText(from: finalText)
        let hasCopyText = !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canShowActions = showAssistantActionBar
            && actionItem != nil
            && !turn.isStreaming
            && !targetStreaming
            && !isLatestInFlightTurn

        return VStack(alignment: .leading, spacing: 6) {
            finalAnswerContent(finalText, isStreaming: targetStreaming)
                .accessibilityIdentifier("codex.final.answer.\(finalID.lowercased())")

            if let proposedPlanText, !proposedPlanText.isEmpty {
                proposedPlanCard(proposedPlanText)
            }

            if canShowActions, let actionItem {
                assistantActionBar(item: actionItem, copyText: copyText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if canShowActions, hasCopyText {
                Button {
                    copyToPasteboard(copyText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if canShowActions, let actionItem {
                Button {
                    onBranchAgentMessage(actionItem)
                } label: {
                    Label("Branch", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }

    private func inlineProposedPlanText(for turn: CodexTrajectoryTurn) -> String? {
        let text: String? = {
            if let mapped = proposedPlanTextByTurnID[turn.id] {
                return mapped
            }
            guard isPlanModeEnabled else { return nil }
            return CodexProposedPlanExtractor.extract(
                from: turn.trajectoryLeaves.map(\.item),
                allowHeuristicFallback: true
            )
        }()
        guard let text else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let finalText = turn.finalAnswerText,
           CodexProposedPlanParser.parse(from: finalText) != nil {
            return nil
        }

        if let finalText = turn.finalAnswerText,
           finalText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            return nil
        }

        return trimmed
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
            HStack(alignment: .center, spacing: 8) {
                Text("Proposed plan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    copyToPasteboard(planText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy plan")
            }
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

    private func isTurnExpanded(_ turnID: String) -> Bool {
        guard let turnKey = turnKeyByTurnID[turnID] else { return false }
        return expandedTurnKeys.contains(turnKey)
    }

    private func toggleTurn(_ turnID: String) {
        guard let turnKey = turnKeyByTurnID[turnID] else { return }
        if expandedTurnKeys.contains(turnKey) {
            expandedTurnKeys.remove(turnKey)
        } else {
            expandedTurnKeys.insert(turnKey)
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
        var activeTurnKeys: Set<TurnKey> = []
        var nextTurnKeyByTurnID: [String: TurnKey] = [:]

        var seenOccurrencesBySignature: [String: Int] = [:]

        for turn in turns {
            let signature = userInputSignature(turn.userMessage.content)
            let occurrence = seenOccurrencesBySignature[signature, default: 0]
            seenOccurrencesBySignature[signature] = occurrence + 1
            let turnKey = TurnKey(signature: signature, occurrence: occurrence)

            activeTurnKeys.insert(turnKey)
            nextTurnKeyByTurnID[turn.id] = turnKey

            if let persistedDurationMs = persistedDurationByTurnID[turn.id],
               persistedDurationMs > 0 {
                let existingDurationMs = finalizedDurationMsByTurnKey[turnKey] ?? 0
                if persistedDurationMs > existingDurationMs {
                    finalizedDurationMsByTurnKey[turnKey] = persistedDurationMs
                }
            }

            if let authoritativeStartedAt = startedAtByTurnID[turn.id] {
                startedAtByTurnKey[turnKey] = authoritativeStartedAt
            } else if (turn.isStreaming || turn.hasTrajectorySummary),
                      startedAtByTurnKey[turnKey] == nil {
                startedAtByTurnKey[turnKey] = now
            }

            let wasStreaming = wasStreamingByTurnKey[turnKey] ?? false

            if !turn.isStreaming, wasStreaming {
                finalizeTurnDurationIfNeeded(turnKey: turnKey, turnID: turn.id, now: now)
            }

            wasStreamingByTurnKey[turnKey] = turn.isStreaming
        }

        expandedTurnKeys = expandedTurnKeys.intersection(activeTurnKeys)
        turnKeyByTurnID = nextTurnKeyByTurnID
        startedAtByTurnKey = startedAtByTurnKey.filter { activeTurnKeys.contains($0.key) }
        finalizedDurationMsByTurnKey = finalizedDurationMsByTurnKey.filter { activeTurnKeys.contains($0.key) }
        wasStreamingByTurnKey = wasStreamingByTurnKey.filter { activeTurnKeys.contains($0.key) }

        let activeGroupIDs = Set(turns.flatMap { $0.groups.map(\.id) })
        expandedGroupIDs = expandedGroupIDs.intersection(activeGroupIDs)

        let activeLeafIDs = Set(turns.flatMap { $0.trajectoryLeaves.map(\.id) })
        expandedLeafIDs = expandedLeafIDs.intersection(activeLeafIDs)
    }

    private func userInputSignature(_ inputs: [CodexUserInput]) -> String {
        AppStore.codexUserContentSignature(inputs)
    }

    private func finalizeTurnDurationIfNeeded(turnKey: TurnKey, turnID: String, now: Date) {
        guard finalizedDurationMsByTurnKey[turnKey] == nil,
              let startedAt = startedAtByTurnKey[turnKey]
        else { return }

        let durationMs = max(0, Int(now.timeIntervalSince(startedAt) * 1_000))
        guard durationMs > 0 else { return }
        finalizedDurationMsByTurnKey[turnKey] = durationMs
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

    private func assistantActionBar(item: CodexAgentMessageItem, copyText: String) -> some View {
        let itemID = item.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasCopyText = !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(spacing: 14) {
            if hasCopyText {
                actionIconButton(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    identifier: "codex.message.copy.\(itemID)"
                ) {
                    copyToPasteboard(copyText)
                }
            }

            actionIconButton(
                title: "Branch",
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

    private func finalAnswerCopyText(from text: String) -> String {
        guard let proposedPlan = CodexProposedPlanParser.parse(from: text) else {
            return text
        }

        let parts = [proposedPlan.leadingText, proposedPlan.trailingText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "\n\n")
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
