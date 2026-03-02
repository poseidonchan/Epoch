import Foundation

public enum CodexPlanPreview {
    public static let defaultCharacterLimit = 280

    public static func isCollapsible(_ text: String, characterLimit: Int = defaultCharacterLimit) -> Bool {
        text.count > max(0, characterLimit)
    }

    public static func collapsedText(from text: String, characterLimit: Int = defaultCharacterLimit) -> String {
        let limit = max(0, characterLimit)
        guard text.count > limit else { return text }
        guard limit > 3 else { return String(repeating: ".", count: limit) }
        let prefix = text.prefix(limit - 3)
        return "\(prefix)..."
    }
}
