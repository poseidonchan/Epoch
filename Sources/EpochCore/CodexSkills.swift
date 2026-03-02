import Foundation

// MARK: - Codex Skills (experimental)

public struct CodexSkillsListParams: Hashable, Codable, Sendable {
    public var cwds: [String]?
    public var forceReload: Bool?

    public init(cwds: [String]? = nil, forceReload: Bool? = nil) {
        self.cwds = cwds
        self.forceReload = forceReload
    }
}

public struct CodexSkillErrorInfo: Hashable, Codable, Sendable {
    public var message: String
    public var path: String
}

public struct CodexSkillToolDependency: Hashable, Codable, Sendable {
    public var command: String?
    public var description: String?
    public var transport: String?
    public var type: String
    public var url: String?
    public var value: String
}

public struct CodexSkillInterface: Hashable, Codable, Sendable {
    public var brandColor: String?
    public var defaultPrompt: String?
    public var displayName: String?
    public var iconLarge: String?
    public var iconSmall: String?
    public var shortDescription: String?

    public init(
        brandColor: String? = nil,
        defaultPrompt: String? = nil,
        displayName: String? = nil,
        iconLarge: String? = nil,
        iconSmall: String? = nil,
        shortDescription: String? = nil
    ) {
        self.brandColor = brandColor
        self.defaultPrompt = defaultPrompt
        self.displayName = displayName
        self.iconLarge = iconLarge
        self.iconSmall = iconSmall
        self.shortDescription = shortDescription
    }

    private enum SnakeKeys: String, CodingKey {
        case brand_color
        case default_prompt
        case display_name
        case icon_large
        case icon_small
        case short_description
    }

    private enum CamelKeys: String, CodingKey {
        case brandColor
        case defaultPrompt
        case displayName
        case iconLarge
        case iconSmall
        case shortDescription
    }

    public init(from decoder: Decoder) throws {
        let snake = try decoder.container(keyedBy: SnakeKeys.self)
        let camel = try decoder.container(keyedBy: CamelKeys.self)

        brandColor = try snake.decodeIfPresent(String.self, forKey: .brand_color)
            ?? camel.decodeIfPresent(String.self, forKey: .brandColor)
        defaultPrompt = try snake.decodeIfPresent(String.self, forKey: .default_prompt)
            ?? camel.decodeIfPresent(String.self, forKey: .defaultPrompt)
        displayName = try snake.decodeIfPresent(String.self, forKey: .display_name)
            ?? camel.decodeIfPresent(String.self, forKey: .displayName)
        iconLarge = try snake.decodeIfPresent(String.self, forKey: .icon_large)
            ?? camel.decodeIfPresent(String.self, forKey: .iconLarge)
        iconSmall = try snake.decodeIfPresent(String.self, forKey: .icon_small)
            ?? camel.decodeIfPresent(String.self, forKey: .iconSmall)
        shortDescription = try snake.decodeIfPresent(String.self, forKey: .short_description)
            ?? camel.decodeIfPresent(String.self, forKey: .shortDescription)
    }

    public func encode(to encoder: Encoder) throws {
        // Prefer the snake_case encoding to match the spec.
        var container = encoder.container(keyedBy: SnakeKeys.self)
        try container.encodeIfPresent(brandColor, forKey: .brand_color)
        try container.encodeIfPresent(defaultPrompt, forKey: .default_prompt)
        try container.encodeIfPresent(displayName, forKey: .display_name)
        try container.encodeIfPresent(iconLarge, forKey: .icon_large)
        try container.encodeIfPresent(iconSmall, forKey: .icon_small)
        try container.encodeIfPresent(shortDescription, forKey: .short_description)
    }
}

public struct CodexSkillMetadata: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    public var description: String?
    public var dependencies: [CodexSkillToolDependency]?
    public var enabled: Bool?
    public var interface: CodexSkillInterface?
    public var path: String
    public var scope: String?
    public var shortDescription: String?

    public var id: String { path }

    public init(
        name: String,
        description: String? = nil,
        dependencies: [CodexSkillToolDependency]? = nil,
        enabled: Bool? = nil,
        interface: CodexSkillInterface? = nil,
        path: String,
        scope: String? = nil,
        shortDescription: String? = nil
    ) {
        self.name = name
        self.description = description
        self.dependencies = dependencies
        self.enabled = enabled
        self.interface = interface
        self.path = path
        self.scope = scope
        self.shortDescription = shortDescription
    }

    private enum SnakeKeys: String, CodingKey {
        case name
        case description
        case dependencies
        case enabled
        case interface
        case path
        case scope
        case short_description
    }

    private enum CamelKeys: String, CodingKey {
        case name
        case description
        case dependencies
        case enabled
        case interface
        case path
        case scope
        case shortDescription
    }

    public init(from decoder: Decoder) throws {
        let snake = try decoder.container(keyedBy: SnakeKeys.self)
        let camel = try decoder.container(keyedBy: CamelKeys.self)

        name = try snake.decodeIfPresent(String.self, forKey: .name)
            ?? camel.decode(String.self, forKey: .name)
        description = try snake.decodeIfPresent(String.self, forKey: .description)
            ?? camel.decodeIfPresent(String.self, forKey: .description)
        dependencies = try snake.decodeIfPresent([CodexSkillToolDependency].self, forKey: .dependencies)
            ?? camel.decodeIfPresent([CodexSkillToolDependency].self, forKey: .dependencies)
        enabled = try snake.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? camel.decodeIfPresent(Bool.self, forKey: .enabled)
        interface = try snake.decodeIfPresent(CodexSkillInterface.self, forKey: .interface)
            ?? camel.decodeIfPresent(CodexSkillInterface.self, forKey: .interface)
        path = try snake.decodeIfPresent(String.self, forKey: .path)
            ?? camel.decode(String.self, forKey: .path)
        scope = try snake.decodeIfPresent(String.self, forKey: .scope)
            ?? camel.decodeIfPresent(String.self, forKey: .scope)
        shortDescription = try snake.decodeIfPresent(String.self, forKey: .short_description)
            ?? camel.decodeIfPresent(String.self, forKey: .shortDescription)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SnakeKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(dependencies, forKey: .dependencies)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(interface, forKey: .interface)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encodeIfPresent(shortDescription, forKey: .short_description)
    }
}

public struct CodexSkillsListEntry: Hashable, Codable, Sendable, Identifiable {
    public var cwd: String
    public var errors: [CodexSkillErrorInfo]
    public var skills: [CodexSkillMetadata]

    public var id: String { cwd }

    public init(cwd: String, errors: [CodexSkillErrorInfo] = [], skills: [CodexSkillMetadata] = []) {
        self.cwd = cwd
        self.errors = errors
        self.skills = skills
    }
}

public struct CodexSkillsListState: Hashable, Sendable {
    public var isLoading: Bool
    public var entries: [CodexSkillsListEntry]
    public var error: String?
    public var updatedAt: Date?

    public init(
        isLoading: Bool = false,
        entries: [CodexSkillsListEntry] = [],
        error: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.isLoading = isLoading
        self.entries = entries
        self.error = error
        self.updatedAt = updatedAt
    }
}

public struct CodexSkillMentionOption: Hashable, Sendable {
    public var name: String
    public var displayName: String

    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}

public struct CodexSkillMention: Hashable, Sendable {
    public var option: CodexSkillMentionOption
    public var token: String
    public var range: Range<String.Index>

    public init(option: CodexSkillMentionOption, token: String, range: Range<String.Index>) {
        self.option = option
        self.token = token
        self.range = range
    }
}

public enum CodexSkillMentionComponent: Hashable, Sendable {
    case text(String)
    case mention(token: String, option: CodexSkillMentionOption)

    public var rawText: String {
        switch self {
        case let .text(value):
            return value
        case let .mention(token, _):
            return token
        }
    }
}

public struct CodexActiveSkillToken: Hashable, Sendable {
    public var query: String
    public var range: Range<String.Index>

    public init(query: String, range: Range<String.Index>) {
        self.query = query
        self.range = range
    }
}

public enum CodexSkillMentionCodec {
    private static let mentionPattern = #"\$([A-Za-z0-9][A-Za-z0-9._-]*)"#

    private static let trailingTrimCharacterSet: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.controlCharacters)
        // Object replacement, replacement char, zero-width chars, BOM
        set.formUnion(CharacterSet(charactersIn: "\u{FFFC}\u{FFFD}\u{200B}\u{200C}\u{200D}\u{FEFF}"))
        return set
    }()

    /// Trims trailing whitespace, control, and common invisibles so skill tokens must be explicit.
    public static func sanitizedUserInput(_ rawText: String) -> String {
        rawText.trimmingCharacters(in: trailingTrimCharacterSet)
    }

    public static func parseMentions(
        in rawText: String,
        lookup: [String: CodexSkillMentionOption]
    ) -> [CodexSkillMention] {
        guard !rawText.isEmpty, !lookup.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: mentionPattern) else { return [] }

        let fullRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
        return regex.matches(in: rawText, range: fullRange).compactMap { match in
            guard let tokenRange = Range(match.range(at: 0), in: rawText) else { return nil }
            let tokenText = String(rawText[tokenRange])
            let name = String(tokenText.dropFirst()).lowercased()
            guard let option = lookup[name] else { return nil }
            return CodexSkillMention(option: option, token: tokenText, range: tokenRange)
        }
    }

    public static func splitComponents(
        in rawText: String,
        lookup: [String: CodexSkillMentionOption]
    ) -> [CodexSkillMentionComponent] {
        guard !rawText.isEmpty else { return [] }
        let mentions = parseMentions(in: rawText, lookup: lookup)
        guard !mentions.isEmpty else { return [.text(rawText)] }

        var components: [CodexSkillMentionComponent] = []
        var cursor = rawText.startIndex

        for mention in mentions {
            if cursor < mention.range.lowerBound {
                components.append(.text(String(rawText[cursor..<mention.range.lowerBound])))
            }
            components.append(.mention(token: mention.token, option: mention.option))
            cursor = mention.range.upperBound
        }

        if cursor < rawText.endIndex {
            components.append(.text(String(rawText[cursor..<rawText.endIndex])))
        }

        return components
    }

    public static func joinRawText(from components: [CodexSkillMentionComponent]) -> String {
        components.map(\.rawText).joined()
    }

    public static func trailingToken(in rawText: String) -> CodexActiveSkillToken? {
        guard !rawText.isEmpty else { return nil }
        guard rawText.contains("$") else { return nil }

        let trimmed = sanitizedUserInput(rawText)
        guard !trimmed.isEmpty else { return nil }

        // Identify the last whitespace-delimited chunk.
        var tokenStart = trimmed.startIndex
        var cursor = trimmed.endIndex

        while cursor > trimmed.startIndex {
            let previous = trimmed.index(before: cursor)
            if trimmed[previous].isWhitespace {
                tokenStart = cursor
                break
            }
            cursor = previous
        }

        let token = trimmed[tokenStart..<trimmed.endIndex]
        guard token.first == "$" else { return nil }

        let query = token.dropFirst()
        guard query.allSatisfy({ isAllowedSkillNameCharacter($0) }) else { return nil }

        return CodexActiveSkillToken(query: String(query), range: tokenStart..<trimmed.endIndex)
    }

    public static func replacingTrailingToken(
        in rawText: String,
        withSkillName skillName: String
    ) -> String? {
        guard let token = trailingToken(in: rawText) else { return nil }
        var replacement = "$\(skillName)"
        if token.range.upperBound == rawText.endIndex {
            replacement += " "
        }

        var updated = rawText
        updated.replaceSubrange(token.range, with: replacement)
        return updated
    }

    public static func isAllowedSkillNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }
}
