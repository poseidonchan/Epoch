import Foundation

public enum CodexProposedPlanExtractor {
    private static let maxCharacters = 4000
    private static let truncationSuffix = "\n[...truncated...]"

    public static func extract(from items: [CodexThreadItem], allowHeuristicFallback: Bool) -> String? {
        for item in items {
            guard case let .agentMessage(agent) = item else { continue }
            if let block = CodexProposedPlanParser.parse(from: agent.text),
               let normalized = normalize(block.planText) {
                return normalized
            }
        }

        for item in items {
            guard case let .plan(plan) = item else { continue }
            if let normalized = normalize(plan.text) {
                return normalized
            }
        }

        guard allowHeuristicFallback else { return nil }

        for item in items {
            guard case let .agentMessage(agent) = item else { continue }
            guard textContainsPlanSteps(agent.text) else { continue }
            if let normalized = normalize(agent.text) {
                return normalized
            }
        }

        return nil
    }

    private static func normalize(_ raw: String) -> String? {
        let normalized = raw
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if normalized.count <= maxCharacters {
            return normalized
        }

        let headCount = max(0, maxCharacters - truncationSuffix.count)
        let prefix = normalized.prefix(headCount).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)\(truncationSuffix)"
    }

    private static func textContainsPlanSteps(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var numberedCount = 0
        var bulletCount = 0
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if lineIsNumberedStep(line) { numberedCount += 1 }
            if lineIsBulletStep(line) { bulletCount += 1 }
        }
        return numberedCount >= 3 || bulletCount >= 3
    }

    private static func lineIsNumberedStep(_ line: Substring) -> Bool {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return false }

        var digitCount = 0
        while index < line.endIndex, line[index].isNumber {
            digitCount += 1
            index = line.index(after: index)
        }
        guard digitCount > 0 else { return false }
        guard index < line.endIndex, line[index] == "." else { return false }

        index = line.index(after: index)
        guard index < line.endIndex, line[index].isWhitespace else { return false }

        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        return index < line.endIndex
    }

    private static func lineIsBulletStep(_ line: Substring) -> Bool {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return false }
        let marker = line[index]
        guard marker == "-" || marker == "*" else { return false }

        index = line.index(after: index)
        guard index < line.endIndex, line[index].isWhitespace else { return false }

        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        return index < line.endIndex
    }
}
