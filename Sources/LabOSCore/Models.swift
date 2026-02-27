import Foundation

public enum SessionLifecycle: String, Codable, CaseIterable, Sendable {
    case active
    case archived
}

public struct Project: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var backendEngine: String?
    public var codexModelProvider: String?
    public var codexModel: String?
    public var codexApprovalPolicy: String?
    public var codexSandbox: JSONValue?
    public var hpcWorkspacePath: String?
    public var hpcWorkspaceState: String?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        backendEngine: String? = nil,
        codexModelProvider: String? = nil,
        codexModel: String? = nil,
        codexApprovalPolicy: String? = nil,
        codexSandbox: JSONValue? = nil,
        hpcWorkspacePath: String? = nil,
        hpcWorkspaceState: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.backendEngine = backendEngine
        self.codexModelProvider = codexModelProvider
        self.codexModel = codexModel
        self.codexApprovalPolicy = codexApprovalPolicy
        self.codexSandbox = codexSandbox
        self.hpcWorkspacePath = hpcWorkspacePath
        self.hpcWorkspaceState = hpcWorkspaceState
    }
}

public struct Session: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public var title: String
    public var lifecycle: SessionLifecycle
    public let createdAt: Date
    public var updatedAt: Date
    public var backendEngine: String?
    public var codexThreadId: String?
    public var codexModel: String?
    public var codexModelProvider: String?
    public var codexApprovalPolicy: String?
    public var codexSandbox: JSONValue?
    public var hpcWorkspaceState: String?
    public var hasPendingUserInput: Bool?
    public var pendingUserInputCount: Int?
    public var pendingUserInputKind: String?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String,
        lifecycle: SessionLifecycle = .active,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        backendEngine: String? = nil,
        codexThreadId: String? = nil,
        codexModel: String? = nil,
        codexModelProvider: String? = nil,
        codexApprovalPolicy: String? = nil,
        codexSandbox: JSONValue? = nil,
        hpcWorkspaceState: String? = nil,
        hasPendingUserInput: Bool? = nil,
        pendingUserInputCount: Int? = nil,
        pendingUserInputKind: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.backendEngine = backendEngine
        self.codexThreadId = codexThreadId
        self.codexModel = codexModel
        self.codexModelProvider = codexModelProvider
        self.codexApprovalPolicy = codexApprovalPolicy
        self.codexSandbox = codexSandbox
        self.hpcWorkspaceState = hpcWorkspaceState
        self.hasPendingUserInput = hasPendingUserInput
        self.pendingUserInputCount = pendingUserInputCount
        self.pendingUserInputKind = pendingUserInputKind
    }
}

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case notebook
    case python
    case image
    case text
    case json
    case log
    case unknown

    public static func infer(from path: String) -> ArtifactKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "ipynb":
            return .notebook
        case "py":
            return .python
        case "png", "jpg", "jpeg":
            return .image
        case "txt", "md":
            return .text
        case "json":
            return .json
        case "log":
            return .log
        default:
            return .unknown
        }
    }
}

public enum ArtifactOrigin: String, Codable, CaseIterable, Sendable {
    case userUpload = "user_upload"
    case generated = "generated"
}

public enum ArtifactIndexStatus: String, Codable, CaseIterable, Sendable {
    case processing
    case indexed
    case failed
}

public struct Artifact: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public var path: String
    public var kind: ArtifactKind
    public var origin: ArtifactOrigin
    public var modifiedAt: Date
    public var sizeBytes: Int?
    public var createdBySessionID: UUID?
    public var createdByRunID: UUID?
    public var indexStatus: ArtifactIndexStatus?
    public var indexSummary: String?
    public var indexedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        path: String,
        kind: ArtifactKind? = nil,
        origin: ArtifactOrigin = .generated,
        modifiedAt: Date = .now,
        sizeBytes: Int? = nil,
        createdBySessionID: UUID? = nil,
        createdByRunID: UUID? = nil,
        indexStatus: ArtifactIndexStatus? = nil,
        indexSummary: String? = nil,
        indexedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.path = path
        self.kind = kind ?? ArtifactKind.infer(from: path)
        self.origin = origin
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.createdBySessionID = createdBySessionID
        self.createdByRunID = createdByRunID
        self.indexStatus = indexStatus
        self.indexSummary = indexSummary
        self.indexedAt = indexedAt
    }
}

public enum WorkspaceEntryType: String, Codable, CaseIterable, Sendable {
    case file
    case dir
}

public struct WorkspaceEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public var path: String
    public var type: WorkspaceEntryType
    public var sizeBytes: Int?
    public var modifiedAt: Date?

    public init(
        path: String,
        type: WorkspaceEntryType,
        sizeBytes: Int? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.type = type
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct OpenAIHubSettingsStatus: Hashable, Codable, Sendable {
    public var configured: Bool
    public var updatedAt: Date?
    public var source: String?
    public var ocrModel: String?

    public init(configured: Bool, updatedAt: Date? = nil, source: String? = nil, ocrModel: String? = nil) {
        self.configured = configured
        self.updatedAt = updatedAt
        self.source = source
        self.ocrModel = ocrModel
    }
}

public enum RunStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case canceled
}

public enum RunActionType: String, Codable, CaseIterable, Sendable {
    case toolCall
    case command
    case output
    case info
}

public struct RunActionEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public var type: RunActionType
    public var summary: String
    public var detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        type: RunActionType,
        summary: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.summary = summary
        self.detail = detail
    }
}

public struct RunRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public var sessionID: UUID?
    public var status: RunStatus
    public let initiatedAt: Date
    public var completedAt: Date?
    public var currentStep: Int
    public var totalSteps: Int
    public var logSnippet: String
    public var stepTitles: [String]
    public var stepDetails: [String]
    public var activity: [RunActionEvent]
    public var producedArtifactPaths: [String]
    public var hpcJobID: String?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sessionID: UUID?,
        status: RunStatus,
        initiatedAt: Date = .now,
        completedAt: Date? = nil,
        currentStep: Int,
        totalSteps: Int,
        logSnippet: String,
        stepTitles: [String],
        stepDetails: [String] = [],
        activity: [RunActionEvent] = [],
        producedArtifactPaths: [String] = [],
        hpcJobID: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.sessionID = sessionID
        self.status = status
        self.initiatedAt = initiatedAt
        self.completedAt = completedAt
        self.currentStep = currentStep
        self.totalSteps = totalSteps
        self.logSnippet = logSnippet
        self.stepTitles = stepTitles
        self.stepDetails = stepDetails
        self.activity = activity
        self.producedArtifactPaths = producedArtifactPaths
        self.hpcJobID = hpcJobID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case sessionID
        case status
        case initiatedAt
        case completedAt
        case currentStep
        case totalSteps
        case logSnippet
        case stepTitles
        case stepDetails
        case activity
        case producedArtifactPaths
        case hpcJobID = "hpcJobId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        status = try container.decode(RunStatus.self, forKey: .status)
        initiatedAt = try container.decode(Date.self, forKey: .initiatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        currentStep = try container.decode(Int.self, forKey: .currentStep)
        totalSteps = try container.decode(Int.self, forKey: .totalSteps)
        logSnippet = try container.decode(String.self, forKey: .logSnippet)
        stepTitles = try container.decodeIfPresent([String].self, forKey: .stepTitles) ?? []
        stepDetails = try container.decodeIfPresent([String].self, forKey: .stepDetails) ?? []
        activity = try container.decodeIfPresent([RunActionEvent].self, forKey: .activity) ?? []
        producedArtifactPaths = try container.decodeIfPresent([String].self, forKey: .producedArtifactPaths) ?? []
        hpcJobID = try container.decodeIfPresent(String.self, forKey: .hpcJobID)
    }
}

public enum ThinkingLevel: String, Codable, CaseIterable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public enum OpenAIVoiceTranscriptionModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gpt4oTranscribe:
            return "gpt-4o-transcribe"
        case .gpt4oMiniTranscribe:
            return "gpt-4o-mini-transcribe"
        }
    }
}

public struct OpenAIVoiceSettings: Hashable, Codable, Sendable {
    public static let defaultTranscriptionPrompt = """
    Transcribe the user's speech into polished written text while preserving original meaning, terminology, and intent.
    Add punctuation and sentence boundaries. Remove filler words and verbal hesitations.
    Keep the output concise, natural, and ready to send as a chat message.
    """

    public var transcriptionModel: OpenAIVoiceTranscriptionModel
    public var transcriptionPrompt: String
    public var hasAPIKey: Bool

    public init(
        transcriptionModel: OpenAIVoiceTranscriptionModel,
        transcriptionPrompt: String,
        hasAPIKey: Bool
    ) {
        self.transcriptionModel = transcriptionModel
        self.transcriptionPrompt = transcriptionPrompt
        self.hasAPIKey = hasAPIKey
    }
}

public enum SessionPermissionLevel: String, Codable, CaseIterable, Sendable {
    case `default` = "default"
    case full = "full"
}

public struct GatewayModelInfo: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var reasoning: Bool

    public init(id: String, name: String, reasoning: Bool) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
    }
}

public struct ModelsCurrentResponse: Hashable, Codable, Sendable {
    public var provider: String
    public var defaultModelId: String
    public var models: [GatewayModelInfo]
    public var thinkingLevels: [ThinkingLevel]

    public init(provider: String, defaultModelId: String, models: [GatewayModelInfo], thinkingLevels: [ThinkingLevel]) {
        self.provider = provider
        self.defaultModelId = defaultModelId
        self.models = models
        self.thinkingLevels = thinkingLevels
    }
}

public struct SessionContextState: Hashable, Codable, Sendable {
    public var projectId: UUID
    public var sessionId: UUID
    public var permissionLevel: String?
    public var modelId: String?
    public var contextWindowTokens: Int?
    public var usedInputTokens: Int?
    public var usedTokens: Int?
    public var remainingTokens: Int?
    public var updatedAt: Date?

    public init(
        projectId: UUID,
        sessionId: UUID,
        permissionLevel: String? = nil,
        modelId: String? = nil,
        contextWindowTokens: Int? = nil,
        usedInputTokens: Int? = nil,
        usedTokens: Int? = nil,
        remainingTokens: Int? = nil,
        updatedAt: Date? = nil
    ) {
        self.projectId = projectId
        self.sessionId = sessionId
        self.permissionLevel = permissionLevel
        self.modelId = modelId
        self.contextWindowTokens = contextWindowTokens
        self.usedInputTokens = usedInputTokens
        self.usedTokens = usedTokens
        self.remainingTokens = remainingTokens
        self.updatedAt = updatedAt
    }
}

public struct JudgmentOption: Hashable, Codable, Sendable {
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct JudgmentQuestion: Hashable, Codable, Sendable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [JudgmentOption]
    public var allowFreeform: Bool

    public init(
        id: String,
        header: String,
        question: String,
        options: [JudgmentOption],
        allowFreeform: Bool
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowFreeform = allowFreeform
    }
}

public struct ChatArtifactReference: Hashable, Codable, Sendable {
    public var displayText: String
    public var projectID: UUID
    public var path: String
    public var artifactID: UUID?
    public var scope: String?
    public var mimeType: String?
    public var sourceName: String?
    public var inlineDataBase64: String?
    public var byteCount: Int?

    public init(
        displayText: String,
        projectID: UUID,
        path: String,
        artifactID: UUID? = nil,
        scope: String? = nil,
        mimeType: String? = nil,
        sourceName: String? = nil,
        inlineDataBase64: String? = nil,
        byteCount: Int? = nil
    ) {
        self.displayText = displayText
        self.projectID = projectID
        self.path = path
        self.artifactID = artifactID
        self.scope = scope
        self.mimeType = mimeType
        self.sourceName = sourceName
        self.inlineDataBase64 = inlineDataBase64
        self.byteCount = byteCount
    }
}

public struct ComposerAttachment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var displayName: String
    public var mimeType: String?
    public var inlineDataBase64: String?
    public var byteCount: Int?
    public var sourceToken: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        mimeType: String? = nil,
        inlineDataBase64: String? = nil,
        byteCount: Int? = nil,
        sourceToken: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.mimeType = mimeType
        self.inlineDataBase64 = inlineDataBase64
        self.byteCount = byteCount
        self.sourceToken = sourceToken
    }
}

public enum MessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public var role: MessageRole
    public var text: String
    public let createdAt: Date
    public var artifactRefs: [ChatArtifactReference]
    public var linkedRunID: UUID?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        role: MessageRole,
        text: String,
        createdAt: Date = .now,
        artifactRefs: [ChatArtifactReference] = [],
        linkedRunID: UUID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.artifactRefs = artifactRefs
        self.linkedRunID = linkedRunID
    }
}

public enum AgentLiveEventType: String, Hashable, Sendable {
    case thinking
    case toolCall
    case info
}

public enum ProcessActionFamily: String, Hashable, Codable, CaseIterable, Sendable {
    case search
    case list
    case read
    case write
    case exec
    case other
}

public enum ProcessEntryState: String, Hashable, Codable, Sendable {
    case active
    case completed
    case failed
}

public enum AgentTurnPhase: String, Hashable, Sendable {
    case thinking
    case toolCalling
    case responding
    case completed
    case failed
}

public struct ProcessEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var toolCallID: String?
    public var family: ProcessActionFamily
    public var activeText: String
    public var completedText: String
    public var state: ProcessEntryState
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        toolCallID: String? = nil,
        family: ProcessActionFamily,
        activeText: String,
        completedText: String,
        state: ProcessEntryState,
        createdAt: Date = .now
    ) {
        self.id = id
        self.toolCallID = toolCallID
        self.family = family
        self.activeText = activeText
        self.completedText = completedText
        self.state = state
        self.createdAt = createdAt
    }
}

public struct ActiveInlineProcess: Hashable, Sendable {
    public var sessionID: UUID
    public var agentRunID: UUID
    public var assistantMessageID: UUID?
    public var phase: AgentTurnPhase
    public var activeLine: String?
    public var entries: [ProcessEntry]
    public var familyCounts: [ProcessActionFamily: Int]

    public init(
        sessionID: UUID,
        agentRunID: UUID,
        assistantMessageID: UUID? = nil,
        phase: AgentTurnPhase,
        activeLine: String? = nil,
        entries: [ProcessEntry] = [],
        familyCounts: [ProcessActionFamily: Int] = [:]
    ) {
        self.sessionID = sessionID
        self.agentRunID = agentRunID
        self.assistantMessageID = assistantMessageID
        self.phase = phase
        self.activeLine = activeLine
        self.entries = entries
        self.familyCounts = familyCounts
    }
}

public struct AssistantProcessSummary: Hashable, Codable, Sendable {
    public var sessionID: UUID
    public var assistantMessageID: UUID
    public var headline: String
    public var entries: [ProcessEntry]
    public var familyCounts: [ProcessActionFamily: Int]

    public init(
        sessionID: UUID,
        assistantMessageID: UUID,
        headline: String,
        entries: [ProcessEntry],
        familyCounts: [ProcessActionFamily: Int]
    ) {
        self.sessionID = sessionID
        self.assistantMessageID = assistantMessageID
        self.headline = headline
        self.entries = entries
        self.familyCounts = familyCounts
    }
}

public struct AgentLiveEvent: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public var type: AgentLiveEventType
    public var summary: String
    public var detail: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        type: AgentLiveEventType,
        summary: String,
        detail: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.type = type
        self.summary = summary
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct HPCStatus: Hashable, Codable, Sendable {
    public var partition: String?
    public var account: String?
    public var qos: String?
    public var runningJobs: Int
    public var pendingJobs: Int
    public var limit: Tres?
    public var inUse: Tres?
    public var available: Tres?
    public var updatedAt: Date?

    public init(
        partition: String? = nil,
        account: String? = nil,
        qos: String? = nil,
        runningJobs: Int,
        pendingJobs: Int,
        limit: Tres? = nil,
        inUse: Tres? = nil,
        available: Tres? = nil,
        updatedAt: Date? = nil
    ) {
        self.partition = partition
        self.account = account
        self.qos = qos
        self.runningJobs = runningJobs
        self.pendingJobs = pendingJobs
        self.limit = limit
        self.inUse = inUse
        self.available = available
        self.updatedAt = updatedAt
    }

    public struct Tres: Hashable, Codable, Sendable {
        public var cpu: Int?
        public var memMB: Int?
        public var gpus: Int?

        public init(cpu: Int? = nil, memMB: Int? = nil, gpus: Int? = nil) {
            self.cpu = cpu
            self.memMB = memMB
            self.gpus = gpus
        }
    }
}

public struct ResourceStatus: Hashable, Codable, Sendable {
    public var computeConnected: Bool
    public var queueDepth: Int
    public var storageUsedPercent: Double
    public var storageTotalBytes: Int64?
    public var storageUsedBytes: Int64?
    public var storageAvailableBytes: Int64?
    public var cpuPercent: Double
    public var ramPercent: Double
    public var hpc: HPCStatus?

    public init(
        computeConnected: Bool,
        queueDepth: Int,
        storageUsedPercent: Double,
        storageTotalBytes: Int64? = nil,
        storageUsedBytes: Int64? = nil,
        storageAvailableBytes: Int64? = nil,
        cpuPercent: Double,
        ramPercent: Double,
        hpc: HPCStatus? = nil
    ) {
        self.computeConnected = computeConnected
        self.queueDepth = queueDepth
        self.storageUsedPercent = storageUsedPercent
        self.storageTotalBytes = storageTotalBytes
        self.storageUsedBytes = storageUsedBytes
        self.storageAvailableBytes = storageAvailableBytes
        self.cpuPercent = cpuPercent
        self.ramPercent = ramPercent
        self.hpc = hpc
    }

    public static let placeholder = ResourceStatus(
        computeConnected: false,
        queueDepth: 0,
        storageUsedPercent: 0,
        storageTotalBytes: nil,
        storageUsedBytes: nil,
        storageAvailableBytes: nil,
        cpuPercent: 0,
        ramPercent: 0,
        hpc: nil
    )
}

public enum ResultsTab: String, CaseIterable, Codable, Sendable {
    case artifacts = "Artifacts"
    case runs = "Runs"
}

public enum AppContext: Hashable, Sendable {
    case home
    case project(projectID: UUID)
    case session(projectID: UUID, sessionID: UUID)
}

public struct HomeTaskRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let runID: UUID
    public let title: String
    public let status: RunStatus
    public let progressText: String

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        projectName: String,
        runID: UUID,
        title: String,
        status: RunStatus,
        progressText: String
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.runID = runID
        self.title = title
        self.status = status
        self.progressText = progressText
    }
}

public struct HomePendingApprovalRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let sessionID: UUID
    public let sessionTitle: String
    public let pendingCount: Int
    public let pendingKind: String?
    public let updatedAt: Date

    public init(
        id: UUID? = nil,
        projectID: UUID,
        projectName: String,
        sessionID: UUID,
        sessionTitle: String,
        pendingCount: Int,
        pendingKind: String?,
        updatedAt: Date
    ) {
        self.id = id ?? sessionID
        self.projectID = projectID
        self.projectName = projectName
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.pendingCount = pendingCount
        self.pendingKind = pendingKind
        self.updatedAt = updatedAt
    }
}

public enum MarkdownDisplayNormalizer {
    public static func normalize(_ text: String) -> String {
        guard text.contains("\\`") else { return text }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var normalized: [String] = []
        normalized.reserveCapacity(lines.count)

        var changed = false
        for raw in lines {
            let line = String(raw)
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let body = String(line.dropFirst(leading.count))

            if body.hasPrefix("\\`\\`\\`") {
                let tail = String(body.dropFirst("\\`\\`\\`".count))
                normalized.append(String(leading) + "```" + tail)
                changed = true
                continue
            }

            if body.hasPrefix("\\```") {
                let tail = String(body.dropFirst("\\```".count))
                normalized.append(String(leading) + "```" + tail)
                changed = true
                continue
            }

            normalized.append(line)
        }

        guard changed else { return text }
        return normalized.joined(separator: "\n")
    }

    public static func normalizeChatMessage(_ text: String) -> String {
        let normalized = normalize(text)
        return stripAccidentalWholeMessageBlockquote(normalized)
    }

    public static func likelyContainsCodeBlock(_ text: String) -> Bool {
        var indentedBlockLineCount = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for raw in lines {
            let line = String(raw)
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let body = String(line.dropFirst(leading.count))

            if body.hasPrefix("```")
                || body.hasPrefix("\\`\\`\\`")
                || body.hasPrefix("\\```")
                || body.hasPrefix("~~~")
            {
                return true
            }

            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    indentedBlockLineCount += 1
                    if indentedBlockLineCount >= 2 {
                        return true
                    }
                }
            } else {
                indentedBlockLineCount = 0
            }
        }

        return false
    }

    private static func stripAccidentalWholeMessageBlockquote(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return text }

        let nonEmptyIndices = lines.indices.filter {
            !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonEmptyIndices.count >= 2 else { return text }

        let quotedIndices = nonEmptyIndices.filter { lineStartsWithMarkdownBlockquote(lines[$0]) }
        guard !quotedIndices.isEmpty else { return text }

        let quoteRatio = Double(quotedIndices.count) / Double(nonEmptyIndices.count)
        guard quoteRatio >= 0.75 else { return text }

        var out = lines
        for idx in quotedIndices {
            out[idx] = stripLeadingBlockquoteMarker(from: out[idx])
        }
        return out.joined(separator: "\n")
    }

    private static func lineStartsWithMarkdownBlockquote(_ line: String) -> Bool {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isWhitespace, line[idx] != "\n", line[idx] != "\r" {
            idx = line.index(after: idx)
        }
        return idx < line.endIndex && line[idx] == ">"
    }

    private static func stripLeadingBlockquoteMarker(from line: String) -> String {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isWhitespace, line[idx] != "\n", line[idx] != "\r" {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == ">" else { return line }

        var next = line.index(after: idx)
        if next < line.endIndex, line[next] == " " {
            next = line.index(after: next)
        }
        // Remove the accidental leading indentation along with the quote marker
        // so de-quoted prose is not reinterpreted as an indented code block.
        return String(line[next...])
    }
}
