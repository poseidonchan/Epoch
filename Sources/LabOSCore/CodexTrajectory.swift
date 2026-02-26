import Foundation

public enum CodexTrajectoryFamily: String, Codable, Hashable, Sendable {
    case search
    case list
    case read
    case write
    case exec
    case other
}

public struct CodexTrajectoryLeaf: Identifiable, Hashable, Sendable {
    public var id: String
    public var item: CodexThreadItem
    public var family: CodexTrajectoryFamily

    public init(id: String, item: CodexThreadItem, family: CodexTrajectoryFamily) {
        self.id = id
        self.item = item
        self.family = family
    }
}

public struct CodexTrajectoryGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: CodexTrajectoryFamily
    public var leaves: [CodexTrajectoryLeaf]

    public init(id: String, family: CodexTrajectoryFamily, leaves: [CodexTrajectoryLeaf]) {
        self.id = id
        self.family = family
        self.leaves = leaves
    }
}

public struct CodexTrajectoryTurn: Identifiable, Hashable, Sendable {
    public var id: String
    public var userMessage: CodexUserMessageItem
    public var hasThinkingStatus: Bool
    public var finalAnswerItemID: String?
    public var finalAnswerText: String?
    public var trajectoryLeaves: [CodexTrajectoryLeaf]
    public var groups: [CodexTrajectoryGroup]
    public var isStreaming: Bool
    public var estimatedDurationMs: Int?

    public init(
        id: String,
        userMessage: CodexUserMessageItem,
        hasThinkingStatus: Bool,
        finalAnswerItemID: String?,
        finalAnswerText: String?,
        trajectoryLeaves: [CodexTrajectoryLeaf],
        groups: [CodexTrajectoryGroup],
        isStreaming: Bool,
        estimatedDurationMs: Int?
    ) {
        self.id = id
        self.userMessage = userMessage
        self.hasThinkingStatus = hasThinkingStatus
        self.finalAnswerItemID = finalAnswerItemID
        self.finalAnswerText = finalAnswerText
        self.trajectoryLeaves = trajectoryLeaves
        self.groups = groups
        self.isStreaming = isStreaming
        self.estimatedDurationMs = estimatedDurationMs
    }

    public var hasTrajectorySummary: Bool {
        !trajectoryLeaves.isEmpty
    }
}

public struct CodexProposedPlanBlock: Hashable, Sendable {
    public var leadingText: String
    public var planText: String
    public var trailingText: String

    public init(leadingText: String, planText: String, trailingText: String) {
        self.leadingText = leadingText
        self.planText = planText
        self.trailingText = trailingText
    }
}

public enum CodexProposedPlanParser {
    public static func parse(from text: String) -> CodexProposedPlanBlock? {
        let openingTag = "<proposed_plan>"
        let closingTag = "</proposed_plan>"
        guard let openingRange = text.range(of: openingTag) else { return nil }
        guard let closingRange = text.range(of: closingTag, range: openingRange.upperBound..<text.endIndex) else {
            return nil
        }

        let leading = String(text[..<openingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = String(text[openingRange.upperBound..<closingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plan.isEmpty else { return nil }
        let trailing = String(text[closingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexProposedPlanBlock(
            leadingText: leading,
            planText: plan,
            trailingText: trailing
        )
    }
}

public enum CodexTrajectoryAssembler {
    public static func assemble(from items: [CodexThreadItem], isStreaming: Bool) -> [CodexTrajectoryTurn] {
        let chunks = splitTurns(items)
        guard !chunks.isEmpty else { return [] }

        var turns: [CodexTrajectoryTurn] = []
        turns.reserveCapacity(chunks.count)

        for (turnIndex, chunk) in chunks.enumerated() {
            let userMessage = chunk.userMessage
            let finalAnswer = finalAnswerItem(in: chunk.items)
            let finalAnswerIndex = finalAnswer?.index
            let finalAnswerItem = finalAnswer?.item
            // Include all items for this turn (after the user message) except the final answer itself.
            // Some engines emit a `plan` item after the final agent message, and we still want that
            // to appear in trajectory leaves (for plan extraction/UI) rather than being dropped.
            let leafCapacity = max(0, chunk.items.count - 1 - (finalAnswerIndex == nil ? 0 : 1))

            var hasThinkingStatus = false
            var leaves: [CodexTrajectoryLeaf] = []
            leaves.reserveCapacity(leafCapacity)
            var durationAccumulator = 0
            var hasDuration = false

            for (index, item) in chunk.items.enumerated() {
                if index == 0 { continue }
                if let finalAnswerIndex, index == finalAnswerIndex { continue }
                switch item {
                case .userMessage:
                    continue
                case let .agentMessage(agent):
                    if agent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        hasThinkingStatus = true
                        continue
                    }
                    leaves.append(
                        CodexTrajectoryLeaf(
                            id: agent.id,
                            item: item,
                            family: .other
                        )
                    )
                case let .unknown(unknown):
                    if shouldTreatUnknownAsThinking(unknown) {
                        hasThinkingStatus = true
                        continue
                    }
                    leaves.append(
                        CodexTrajectoryLeaf(
                            id: unknown.id,
                            item: item,
                            family: .other
                        )
                    )
                default:
                    let family = family(for: item)
                    leaves.append(
                        CodexTrajectoryLeaf(
                            id: item.id,
                            item: item,
                            family: family
                        )
                    )
                    if let durationMs = durationMs(for: item), durationMs > 0 {
                        durationAccumulator += durationMs
                        hasDuration = true
                    }
                }
            }

            let groups = makeGroups(from: leaves, turnID: userMessage.id)
            let estimatedDurationMs = hasDuration ? durationAccumulator : nil
            let turnIsStreaming = isStreaming && turnIndex == (chunks.count - 1)

            turns.append(
                CodexTrajectoryTurn(
                    id: userMessage.id,
                    userMessage: userMessage,
                    hasThinkingStatus: hasThinkingStatus,
                    finalAnswerItemID: finalAnswerItem?.id,
                    finalAnswerText: finalAnswerItem?.text,
                    trajectoryLeaves: leaves,
                    groups: groups,
                    isStreaming: turnIsStreaming,
                    estimatedDurationMs: estimatedDurationMs
                )
            )
        }

        return turns
    }

    private struct TurnChunk {
        var userMessage: CodexUserMessageItem
        var items: [CodexThreadItem]
    }

    private static func splitTurns(_ items: [CodexThreadItem]) -> [TurnChunk] {
        var turns: [TurnChunk] = []
        turns.reserveCapacity(8)

        var current: TurnChunk?

        for item in items {
            switch item {
            case let .userMessage(user):
                if let current {
                    turns.append(current)
                }
                current = TurnChunk(userMessage: user, items: [item])
            default:
                guard current != nil else { continue }
                current?.items.append(item)
            }
        }

        if let current {
            turns.append(current)
        }

        return turns
    }

    private static func finalAnswerItem(in turnItems: [CodexThreadItem]) -> (index: Int, item: CodexAgentMessageItem)? {
        for (index, item) in turnItems.enumerated().reversed() {
            guard case let .agentMessage(agent) = item else { continue }
            let trimmed = agent.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return (index, agent)
        }
        return nil
    }

    private static func makeGroups(from leaves: [CodexTrajectoryLeaf], turnID: String) -> [CodexTrajectoryGroup] {
        guard !leaves.isEmpty else { return [] }

        var groups: [CodexTrajectoryGroup] = []
        groups.reserveCapacity(leaves.count)

        var currentFamily = leaves[0].family
        var currentLeaves: [CodexTrajectoryLeaf] = []
        var groupIndex = 0

        for leaf in leaves {
            if leaf.family != currentFamily, !currentLeaves.isEmpty {
                groups.append(
                    CodexTrajectoryGroup(
                        id: "\(turnID).group.\(groupIndex)",
                        family: currentFamily,
                        leaves: currentLeaves
                    )
                )
                groupIndex += 1
                currentLeaves.removeAll(keepingCapacity: true)
                currentFamily = leaf.family
            }
            currentLeaves.append(leaf)
        }

        if !currentLeaves.isEmpty {
            groups.append(
                CodexTrajectoryGroup(
                    id: "\(turnID).group.\(groupIndex)",
                    family: currentFamily,
                    leaves: currentLeaves
                )
            )
        }

        return groups
    }

    private static func family(for item: CodexThreadItem) -> CodexTrajectoryFamily {
        switch item {
        case let .mcpToolCall(tool):
            return familyFromSignals([
                tool.tool,
                tool.server,
                tool.status,
            ])

        case let .commandExecution(command):
            return familyFromCommand(command.command)

        case .fileChange:
            return .write

        case .webSearch:
            return .search

        case .plan:
            return .other

        case .agentMessage, .userMessage, .unknown:
            return .other
        }
    }

    private static func familyFromCommand(_ command: String) -> CodexTrajectoryFamily {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return .exec }

        let tokens = commandTokens(text)
        if tokens.intersection(searchTokens).isEmpty == false { return .search }
        if tokens.intersection(listTokens).isEmpty == false { return .list }
        if tokens.intersection(readTokens).isEmpty == false { return .read }
        if tokens.intersection(writeTokens).isEmpty == false { return .write }
        return .exec
    }

    private static func familyFromSignals(_ rawSignals: [String]) -> CodexTrajectoryFamily {
        let tokens = commandTokens(rawSignals.joined(separator: " ").lowercased())
        if tokens.intersection(searchTokens).isEmpty == false { return .search }
        if tokens.intersection(listTokens).isEmpty == false { return .list }
        if tokens.intersection(readTokens).isEmpty == false { return .read }
        if tokens.intersection(writeTokens).isEmpty == false { return .write }
        if tokens.intersection(execTokens).isEmpty == false { return .exec }
        return .other
    }

    private static func commandTokens(_ text: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.inverted
        let pieces = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(pieces)
    }

    private static func durationMs(for item: CodexThreadItem) -> Int? {
        switch item {
        case let .commandExecution(command):
            return command.durationMs
        case let .mcpToolCall(tool):
            return tool.durationMs
        default:
            return nil
        }
    }

    private static func shouldTreatUnknownAsThinking(_ unknown: CodexUnknownItem) -> Bool {
        let type = unknown.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type == "reasoning" || type == "unknown" || type == "thinking" {
            return true
        }

        if let text = unknown.rawPayload["text"]?.stringValue, isThinkingLike(text) {
            return true
        }
        if let status = unknown.rawPayload["status"]?.stringValue, isThinkingLike(status) {
            return true
        }
        if let summary = unknown.rawPayload["summary"]?.stringValue, isThinkingLike(summary) {
            return true
        }
        return false
    }

    private static func isThinkingLike(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return true }
        if normalized == "thinking"
            || normalized == "thinking..."
            || normalized == "inprogress"
            || normalized == "in_progress"
            || normalized == "running"
            || normalized == "reasoning"
            || normalized.contains("waiting for updates")
            || normalized.contains("waiting for response") {
            return true
        }
        return false
    }

    private static let searchTokens: Set<String> = [
        "search", "query", "find", "grep", "rg", "ripgrep",
    ]

    private static let listTokens: Set<String> = [
        "ls", "list", "scan", "dir", "tree",
    ]

    private static let readTokens: Set<String> = [
        "cat", "open", "read", "less", "head", "tail", "sed",
    ]

    private static let writeTokens: Set<String> = [
        "write", "patch", "edit", "apply", "applypatch", "append",
        "create", "update", "delete", "remove", "mkdir", "rm", "mv", "cp",
        "touch", "tee", "truncate", "chmod", "chown",
    ]

    private static let execTokens: Set<String> = [
        "exec", "bash", "zsh", "sh", "python", "node", "npm", "pnpm", "swift",
        "xcodebuild", "git",
    ]
}
