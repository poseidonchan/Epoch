public struct CodexAssistantActionTarget: Hashable, Sendable {
    public var turnID: String
    public var messageID: String

    public init(turnID: String, messageID: String) {
        self.turnID = turnID
        self.messageID = messageID
    }
}

public enum CodexAssistantActionTargets {
    public static func latestOnly(in items: [CodexThreadItem]) -> Set<String> {
        guard let latestID = latestNonEmptyAssistantMessageID(in: items) else {
            return []
        }
        return [latestID]
    }

    public static func latestNonEmptyAssistantMessageID(in items: [CodexThreadItem]) -> String? {
        for item in items.reversed() {
            guard case let .agentMessage(agent) = item else { continue }
            let text = agent.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return agent.id
        }
        return nil
    }

    public static func latestFinalTurnTarget(in turns: [CodexTrajectoryTurn]) -> CodexAssistantActionTarget? {
        for turn in turns.reversed() {
            guard let messageID = turn.finalAnswerItemID else { continue }
            let text = turn.finalAnswerText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            return CodexAssistantActionTarget(turnID: turn.id, messageID: messageID)
        }
        return nil
    }
}
