import Foundation

public enum CodexRequestID: Hashable, Sendable, Codable {
    case string(String)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        }
    }
}

public struct CodexRPCError: Hashable, Codable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct CodexRPCRequest: Hashable, Codable, Sendable {
    public var id: CodexRequestID
    public var method: String
    public var params: JSONValue?

    public init(id: CodexRequestID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct CodexRPCNotification: Hashable, Codable, Sendable {
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public struct CodexRPCResponse: Hashable, Codable, Sendable {
    public var id: CodexRequestID
    public var result: JSONValue?
    public var error: CodexRPCError?

    public init(id: CodexRequestID, result: JSONValue? = nil, error: CodexRPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public enum CodexRPCInbound: Hashable, Sendable {
    case request(CodexRPCRequest)
    case notification(CodexRPCNotification)
    case response(CodexRPCResponse)
}

public struct CodexTurnError: Hashable, Codable, Sendable {
    public var message: String
    public var codexErrorInfo: JSONValue?
    public var additionalDetails: String?
}

public struct CodexTurn: Hashable, Codable, Sendable {
    public var id: String
    public var items: [CodexThreadItem]
    public var status: String
    public var error: CodexTurnError?
}

public struct CodexThread: Hashable, Codable, Sendable {
    public var id: String
    public var preview: String
    public var modelProvider: String
    public var createdAt: Int
    public var updatedAt: Int
    public var path: String?
    public var cwd: String
    public var cliVersion: String
    public var source: String
    public var gitInfo: JSONValue?
    public var turns: [CodexTurn]
}

public struct CodexPlanStep: Hashable, Codable, Sendable {
    public var step: String
    public var status: String
}

public enum CodexThreadItem: Hashable, Sendable {
    case userMessage(CodexUserMessageItem)
    case agentMessage(CodexAgentMessageItem)
    case plan(CodexPlanItem)
    case commandExecution(CodexCommandExecutionItem)
    case fileChange(CodexFileChangeItem)
    case mcpToolCall(CodexMCPToolCallItem)
    case unknown(CodexUnknownItem)

    public var id: String {
        switch self {
        case let .userMessage(item):
            return item.id
        case let .agentMessage(item):
            return item.id
        case let .plan(item):
            return item.id
        case let .commandExecution(item):
            return item.id
        case let .fileChange(item):
            return item.id
        case let .mcpToolCall(item):
            return item.id
        case let .unknown(item):
            return item.id
        }
    }

    public var itemType: String {
        switch self {
        case .userMessage:
            return "userMessage"
        case .agentMessage:
            return "agentMessage"
        case .plan:
            return "plan"
        case .commandExecution:
            return "commandExecution"
        case .fileChange:
            return "fileChange"
        case .mcpToolCall:
            return "mcpToolCall"
        case let .unknown(item):
            return item.type
        }
    }
}

extension CodexThreadItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "userMessage":
            self = .userMessage(try CodexUserMessageItem(from: decoder))
        case "agentMessage":
            self = .agentMessage(try CodexAgentMessageItem(from: decoder))
        case "plan":
            self = .plan(try CodexPlanItem(from: decoder))
        case "commandExecution":
            self = .commandExecution(try CodexCommandExecutionItem(from: decoder))
        case "fileChange":
            self = .fileChange(try CodexFileChangeItem(from: decoder))
        case "mcpToolCall":
            self = .mcpToolCall(try CodexMCPToolCallItem(from: decoder))
        default:
            self = .unknown(try CodexUnknownItem(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .userMessage(item):
            try item.encode(to: encoder)
        case let .agentMessage(item):
            try item.encode(to: encoder)
        case let .plan(item):
            try item.encode(to: encoder)
        case let .commandExecution(item):
            try item.encode(to: encoder)
        case let .fileChange(item):
            try item.encode(to: encoder)
        case let .mcpToolCall(item):
            try item.encode(to: encoder)
        case let .unknown(item):
            try item.encode(to: encoder)
        }
    }
}

public struct CodexUserInput: Hashable, Codable, Sendable {
    public var type: String
    public var text: String?
    public var url: String?
    public var path: String?
}

public struct CodexUserMessageItem: Hashable, Codable, Sendable {
    public var type: String
    public var id: String
    public var content: [CodexUserInput]
}

public struct CodexAgentMessageItem: Hashable, Codable, Sendable {
    public var type: String
    public var id: String
    public var text: String
}

public struct CodexPlanItem: Hashable, Codable, Sendable {
    public var type: String
    public var id: String
    public var text: String
}

public struct CodexCommandExecutionItem: Hashable, Codable, Sendable {
    public var type: String
    public var id: String
    public var command: String
    public var cwd: String
    public var processId: String?
    public var status: String
    public var aggregatedOutput: String?
    public var exitCode: Int?
    public var durationMs: Int?
    public var commandActions: [JSONValue]
}

public struct CodexFileUpdateChange: Hashable, Codable, Sendable {
    public var path: String
    public var kind: String
    public var diff: String
}

public struct CodexFileChangeItem: Hashable, Codable, Sendable {
    public var type: String
    public var id: String
    public var changes: [CodexFileUpdateChange]
    public var status: String
}

public struct CodexMCPToolCallItem: Hashable, Codable, Sendable {
    public var type: String
    public var id: String
    public var server: String
    public var tool: String
    public var status: String
    public var arguments: JSONValue?
    public var result: JSONValue?
    public var error: JSONValue?
    public var durationMs: Int?
}

public struct CodexUnknownItem: Hashable, Codable, Sendable {
    public var type: String
    public var id: String
    public var rawPayload: [String: JSONValue]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            self.intValue = intValue
            stringValue = String(intValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var raw: [String: JSONValue] = [:]
        for key in container.allKeys {
            raw[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        rawPayload = raw
        type = (raw["type"]?.stringValue ?? "unknown")
        id = (raw["id"]?.stringValue ?? UUID().uuidString)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        var payload = rawPayload
        payload["type"] = .string(type)
        payload["id"] = .string(id)
        for (key, value) in payload {
            if let codingKey = DynamicCodingKey(stringValue: key) {
                try container.encode(value, forKey: codingKey)
            }
        }
    }
}

extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .number(value):
            return Int(value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }
}

public struct CodexTokenUsage: Hashable, Sendable {
    public var threadId: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var contextWindowTokens: Int?
    public var remainingTokens: Int?
    public var model: String?

    public init(
        threadId: String,
        inputTokens: Int?,
        outputTokens: Int?,
        totalTokens: Int?,
        contextWindowTokens: Int?,
        remainingTokens: Int?,
        model: String?
    ) {
        self.threadId = threadId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.contextWindowTokens = contextWindowTokens
        self.remainingTokens = remainingTokens
        self.model = model
    }
}

public enum CodexApprovalKind: String, Hashable, Sendable {
    case commandExecution = "item/commandExecution/requestApproval"
    case fileChange = "item/fileChange/requestApproval"
}

public struct CodexPendingApproval: Identifiable, Hashable, Sendable {
    public var id: String { "\(requestID)" }
    public var requestID: CodexRequestID
    public var kind: CodexApprovalKind
    public var sessionID: UUID
    public var threadId: String
    public var turnId: String?
    public var itemId: String?
    public var reason: String?
    public var command: String?
    public var cwd: String?
    public var grantRoot: String?
    public var rawParams: JSONValue?

    public init(
        requestID: CodexRequestID,
        kind: CodexApprovalKind,
        sessionID: UUID,
        threadId: String,
        turnId: String?,
        itemId: String?,
        reason: String?,
        command: String?,
        cwd: String?,
        grantRoot: String?,
        rawParams: JSONValue?
    ) {
        self.requestID = requestID
        self.kind = kind
        self.sessionID = sessionID
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.reason = reason
        self.command = command
        self.cwd = cwd
        self.grantRoot = grantRoot
        self.rawParams = rawParams
    }
}

public struct CodexPendingPrompt: Identifiable, Hashable, Sendable {
    public var id: String { "\(requestID)" }
    public var requestID: CodexRequestID
    public var sessionID: UUID
    public var threadId: String
    public var turnId: String?
    public var prompt: String?
    public var questions: [CodexPromptQuestion]
    public var rawParams: JSONValue?

    public init(
        requestID: CodexRequestID,
        sessionID: UUID,
        threadId: String,
        turnId: String?,
        prompt: String?,
        questions: [CodexPromptQuestion] = [],
        rawParams: JSONValue?
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.threadId = threadId
        self.turnId = turnId
        self.prompt = prompt
        self.questions = questions
        self.rawParams = rawParams
    }
}

public struct CodexPromptQuestion: Hashable, Sendable {
    public var id: String
    public var prompt: String
    public var options: [CodexPromptOption]

    public init(id: String, prompt: String, options: [CodexPromptOption]) {
        self.id = id
        self.prompt = prompt
        self.options = options
    }
}

public struct CodexPromptOption: Hashable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
    public var isOther: Bool

    public init(id: String, label: String, description: String? = nil, isOther: Bool = false) {
        self.id = id
        self.label = label
        self.description = description
        self.isOther = isOther
    }
}

public enum CodexSteerQueueItemStatus: String, Hashable, Sendable {
    case queued
    case sending
    case failed
}

public struct CodexSteerQueueItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var text: String
    public var createdAt: Date
    public var status: CodexSteerQueueItemStatus
    public var error: String?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        text: String,
        createdAt: Date = .now,
        status: CodexSteerQueueItemStatus = .queued,
        error: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.error = error
    }
}
