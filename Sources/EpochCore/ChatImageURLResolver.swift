import Foundation

public enum ChatImageURLResolver {
    public static func resolve(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "http", "https":
            return parsed
        case "file":
            return URL(fileURLWithPath: parsed.path)
        default:
            return nil
        }
    }
}
